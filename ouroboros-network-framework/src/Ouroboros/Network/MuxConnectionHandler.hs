{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeApplications          #-}

-- | Implementation of 'ConnectionHandler'
--
-- While connection manager responsibility is to keep track of resources:
-- sockets and threads running connection and their state changes (including
-- changes imposed by 'ConnectionHandler', e.g. weather a uni- or duplex- data
-- flow was negotiated), the responsibility of 'ConnectionHandler' is to:
--
-- * run handshake protocol on the underlying bearer
-- * start mux
--
-- 'ConnectionHandler' is run on each inbound or outbound connection and returns
-- 'MuxHandle'.  Upon successful handshake negotiation it returns all the
-- necessary information to run mini-protocols.  Note that it is not responsible
-- for running them: that's what a server does or p2p-governor by means of
-- 'PeerStateActions'.
--
module Ouroboros.Network.MuxConnectionHandler
  ( MuxHandle (..)
  , MuxHandleError (..)
  , MuxConnectionHandler
  , makeMuxConnectionHandler
  , MuxConnectionManager
  -- * tracing
  , ConnectionHandlerTrace (..)
  ) where

import           Control.Exception (SomeAsyncException)
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Tracer (Tracer, contramap, traceWith)

import           Data.ByteString.Lazy (ByteString)
import           Data.Typeable (Typeable)

import           Network.Mux hiding (miniProtocolNum)

import           Ouroboros.Network.Mux
import           Ouroboros.Network.Protocol.Handshake
import           Ouroboros.Network.ConnectionId (ConnectionId (..))
import           Ouroboros.Network.RethrowPolicy
import           Ouroboros.Network.ConnectionManager.Types

-- | We place an upper limit of `30s` on the time we wait on receiving an SDU.
-- There is no upper bound on the time we wait when waiting for a new SDU.
-- This makes it possible for mini-protocols to use timeouts that are larger
-- than 30s or wait forever.  `30s` for receiving an SDU corresponds to
-- a minimum speed limit of 17kbps.
--
-- ( 8      -- mux header length
-- + 0xffff -- maximum SDU payload
-- )
-- * 8
-- = 524_344 -- maximum bits in an SDU
--
--  524_344 / 30 / 1024 = 17kbps
--
sduTimeout :: DiffTime
sduTimeout = 30


-- | For handshake, we put a limit of `10s` for sending or receiving a single
-- `MuxSDU`.
--
sduHandshakeTimeout :: DiffTime
sduHandshakeTimeout = 10


-- | States of the connection handler thread.
--
-- * 'MuxRunning' - successful Handshake, mux started
-- * 'MuxPromiseHandshakeClientError'
--                - the connection handler thread was running client side
--                of the handshake negotiation, which failed with
--                a 'HandshakeException'
-- * 'MuxPromiseHandshakeServerError'
--                - the connection handler thread was running server side of the
--                handshake protocol, which fail with 'HandshakeException'
-- * 'MuxPromiseError'
--                - the multiplexer thrown 'MuxError'.
--
data MuxHandle (muxMode :: MuxMode) peerAddr bytes m a b =
    MuxHandle {
        mhMux            :: !(Mux muxMode m),
        mhMuxBundle      :: !(MuxBundle muxMode bytes m a b),
        mhControlMessage :: !(Bundle (StrictTVar m ControlMessage))
      }


data MuxHandleError (muxMode :: MuxMode) versionNumber where
    MuxPromiseHandshakeClientError
     :: HasInitiator muxMode ~ True
     => !(HandshakeException (HandshakeClientProtocolError versionNumber))
     -> MuxHandleError muxMode versionNumber

    MuxPromiseHandshakeServerError
      :: HasResponder muxMode ~ True
      => !(HandshakeException (RefuseReason versionNumber))
      -> MuxHandleError muxMode versionNumber

    MuxPromiseError
     :: !SomeException
     -> MuxHandleError muxMode versionNumber


instance Show versionNumber
      => Show (MuxHandleError muxMode versionNumber) where
    show (MuxPromiseHandshakeServerError err) = "MuxPromiseHandshakeServerError " ++ show err
    show (MuxPromiseHandshakeClientError err) = "MuxPromiseHandshakeClientError " ++ show err
    show (MuxPromiseError err)                = "MuxPromiseError " ++ show err


-- | Type of 'ConnectionHandler' implemented in this module.
--
type MuxConnectionHandler muxMode peerAddr versionNumber versionData bytes m a b =
    ConnectionHandler muxMode
                      (ConnectionHandlerTrace versionNumber versionData)
                      peerAddr
                      (MuxHandle muxMode peerAddr bytes m a b)
                      (MuxHandleError muxMode versionNumber)
                      (versionNumber, versionData)
                      m

-- | Type alias for 'ConnectionManager' using 'MuxPromise'.
--
type MuxConnectionManager muxMode socket peerAddr versionNumber bytes m a b =
    ConnectionManager muxMode socket peerAddr
                      (MuxHandle muxMode peerAddr bytes m a b)
                      (MuxHandleError muxMode versionNumber)
                      m

-- | To be used as `makeConnectionHandler` field of 'ConnectionManagerArguments'.
--
-- Note: We need to pass `MiniProtocolBundle` what forces us to have two
-- different `ConnectionManager`s: one for `node-to-client` and another for
-- `node-to-node` connections.  But this is ok, as these resources are
-- independent.
--
makeMuxConnectionHandler
    :: forall peerAddr muxMode versionNumber versionData m a b.
       ( MonadAsync m
       , MonadCatch m
       , MonadFork  m
       , MonadThrow (STM m)
       , MonadTime  m
       , MonadTimer m
       , MonadMask  m
       , Ord      versionNumber
       , Show     peerAddr
       , Typeable peerAddr
       )
    => Tracer m (WithMuxBearer (ConnectionId peerAddr) MuxTrace)
    -> SingInitiatorResponderMode muxMode
    -- ^ describe whether this is outbound or inbound connection, and bring
    -- evidence that we can use mux with it.
    -> MiniProtocolBundle muxMode
    -> HandshakeArguments (ConnectionId peerAddr) versionNumber versionData m
                          (OuroborosBundle muxMode peerAddr ByteString m a b)
    -> (versionNumber -> versionData -> DataFlow)
    -> (ConnectionId peerAddr -> MuxHandle muxMode peerAddr ByteString m a b -> m ())
    -- ^ This method allows to pass control over responders to the server (for
    -- outbound connections), see
    -- 'Ouroboros.Network.ConnectionManager.Server.ControlChannel.newOutboundConnection'.
    -> (ThreadId m, RethrowPolicy)
    -> MuxConnectionHandler muxMode peerAddr versionNumber versionData ByteString m a b
makeMuxConnectionHandler muxTracer singMuxMode
                         miniProtocolBundle
                         handshakeArguments
                         dataFlowTypeFn
                         announceOutboundConnection
                         (mainThreadId, rethrowPolicy) =
    ConnectionHandler $
      case singMuxMode of
        SInitiatorMode          -> WithInitiatorMode          outboundConnectionHandler
        SResponderMode          -> WithResponderMode          inboundConnectionHandler
        SInitiatorResponderMode -> WithInitiatorResponderMode outboundConnectionHandler
                                                              inboundConnectionHandler
  where
    outboundConnectionHandler
      :: HasInitiator muxMode ~ True
      => ConnectionHandlerFn (ConnectionHandlerTrace versionNumber versionData)
                             peerAddr
                             (MuxHandle muxMode peerAddr ByteString m a b)
                             (MuxHandleError muxMode versionNumber)
                             (versionNumber, versionData)
                             m
    outboundConnectionHandler
        writer@PromiseWriter { writePromise }
        tracer
        connectionId@ConnectionId { remoteAddress }
        muxBearer =
          Action {
              action       = outboundAction,
              errorHandler = exceptionHandling tracer writer remoteAddress OutboundError
            }
      where
        outboundAction = do
          hsResult <- runHandshakeClient (muxBearer sduHandshakeTimeout)
                                         connectionId
                                         handshakeArguments
          case hsResult of
            Left !err -> do
              atomically $ writePromise (Left (MuxPromiseHandshakeClientError err))
              traceWith tracer (TrHandshakeClientError err)
            Right (app, versionNumber, agreedOptions) -> do
              traceWith tracer (TrHandshakeSuccess versionNumber agreedOptions)
              controlMessageVarBundle
                <- (\a b c -> Bundle (WithHot a) (WithWarm b) (WithEstablished c))
                    <$> newTVarIO Continue
                    <*> newTVarIO Continue
                    <*> newTVarIO Continue
              let muxApp
                    = mkMuxApplicationBundle
                        connectionId
                        (readTVar <$> controlMessageVarBundle)
                        app
              mux <- newMux miniProtocolBundle
              let !muxHandle = MuxHandle mux muxApp controlMessageVarBundle
              atomically $ writePromise (Right (muxHandle, (versionNumber, agreedOptions)))

              -- For outbound connections we need to on demand start receivers.
              -- This is, in a sense, a no man land: the server will not act, as
              -- it's only reacting to inbound connections, and it also does not
              -- belong to initiator (peer-2-peer governor).
              case (singMuxMode, dataFlowTypeFn versionNumber agreedOptions) of
                (SInitiatorResponderMode, Duplex) ->
                  announceOutboundConnection connectionId muxHandle
                _ -> pure ()

              runMux (WithMuxBearer connectionId `contramap` muxTracer)
                     mux (muxBearer sduTimeout)


    inboundConnectionHandler
      :: HasResponder muxMode ~ True
      => ConnectionHandlerFn (ConnectionHandlerTrace versionNumber versionData)
                             peerAddr
                             (MuxHandle muxMode peerAddr ByteString m a b)
                             (MuxHandleError muxMode versionNumber)
                             (versionNumber, versionData)
                             m
    inboundConnectionHandler writer@PromiseWriter { writePromise }
                             tracer
                             connectionId@ConnectionId { remoteAddress }
                             muxBearer =
          Action {
              action       = inboundAction,
              errorHandler = exceptionHandling tracer writer remoteAddress InboundError
            }
      where
        inboundAction = do
          hsResult <- runHandshakeServer (muxBearer sduHandshakeTimeout)
                                         connectionId
                                         handshakeArguments
          case hsResult of
            Left !err -> do
              atomically $ writePromise (Left (MuxPromiseHandshakeServerError err))
              traceWith tracer (TrHandshakeServerError err)
            Right (app, versionNumber, agreedOptions) -> do
              traceWith tracer (TrHandshakeSuccess versionNumber agreedOptions)
              controlMessageVarBundle
                <- (\a b c -> Bundle (WithHot a) (WithWarm b) (WithEstablished c))
                    <$> newTVarIO Continue
                    <*> newTVarIO Continue
                    <*> newTVarIO Continue
              let muxApp
                    = mkMuxApplicationBundle
                        connectionId
                        (readTVar <$> controlMessageVarBundle)
                        app
              mux <- newMux miniProtocolBundle
              let !muxHandle = MuxHandle mux muxApp controlMessageVarBundle
              atomically $ writePromise (Right (muxHandle, (versionNumber, agreedOptions)))
              runMux (WithMuxBearer connectionId `contramap` muxTracer)
                         mux (muxBearer sduTimeout)

    -- minimal error handling, just to make adequate changes to
    -- `muxPromiseVar`; Classification of errors is done by
    -- 'withConnectionManager' when the connection handler thread is started..
    exceptionHandling :: forall x.
                         Tracer m (ConnectionHandlerTrace versionNumber versionData)
                      -> PromiseWriter m
                           (Either (MuxHandleError muxMode versionNumber)
                                   ( MuxHandle muxMode peerAddr ByteString m a b
                                   , (versionNumber, versionData) ))
                      -> peerAddr
                      -> ErrorContext
                      -> m x -> m x
    exceptionHandling tracer writer remoteAddress errorContext io =
      -- handle non-async exceptions
      catchJust
        (\e -> case fromException e :: Maybe SomeAsyncException of
                Just _ -> Nothing
                Nothing -> Just e)
        io
        (\e -> do
          -- we use 'forcePromise', whent he exception handler runs we don't
          -- know weather the promise is fullfiled or not.
          atomically (forcePromise writer (Left (MuxPromiseError e)))
          let errorCommand = runRethrowPolicy rethrowPolicy errorContext e
          traceWith tracer (TrError errorCommand errorContext e)
          case errorCommand of
            ShutdownNode -> throwTo mainThreadId (ExceptionInHandler remoteAddress e)
                         >> throwIO e
            ShutdownPeer -> throwIO e)


--
-- Tracing
--


-- | 'ConnectionHandlerTrace' is embedded into 'ConnectionManagerTrace' with
-- 'Ouroboros.Network.ConnectionManager.Types.ConnectionHandlerTrace'
-- constructor.  It already includes 'ConnectionId' so we don't need to take
-- care of it here.
--
-- TODO: when 'Handshake' will get its own tracer, independent of 'Mux', it
-- should be embedded into 'ConnectionHandlerTrace'.
--
data ConnectionHandlerTrace versionNumber versionData =
      TrHandshakeSuccess versionNumber versionData
    | TrHandshakeClientError
        !(HandshakeException (HandshakeClientProtocolError versionNumber))
    | TrHandshakeServerError
        !(HandshakeException (RefuseReason versionNumber))
    | TrError !ErrorCommand !ErrorContext !SomeException
  deriving Show
