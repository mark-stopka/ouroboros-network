{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- 'withInitiatorMode' has @HasInitiator muxMode ~ True@ constraint, which is
-- not redundant at all!  It limits case analysis.
--
-- TODO: this might not by needed by `ghc-8.10`.
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- | Connection manager core types.
--
-- Connection manager is responsible for managing uni- or bi-directional
-- connections and threads which are running network applications.  In
-- particular it is responsible for:
--
-- * opening new connection / reusing connections (for bidirectional
--   connections)
-- * run connection handler, i.e. 'ConnectionHandler'
-- * error handling for connection threads
-- * keeping track of handshake negotiation: weather a uni- or bidirectional
--   connection was negotiated.
-- * tracking state of a connection
--
-- Connection manager is disigned to work for any 'MuxMode'.  This way we can
-- use it for managing connections from a local clients, i.e. share the same
-- server implementation which accepts connections over Unix socket / Windows
-- named pipe.
--
-- First and last tasks are implemented directly in
-- 'Ouroboros.Network.ConnectionManager.Core' using the types provided in this
-- module.  The second task is delegated to 'ConnectionHandler' (see
-- 'Ouroboros.Network.MuxConnectionHandler.makeConnectionHandler').
--
-- The calls 'includeOutboundConnection' and
-- 'includeOutboundConnection' only return one a connection has been negotiated.
-- The returned 'handle' contains all the information that is need to start and
-- monitor mini-protocols through the mux interface.
--
-- To support bi-directional connections we need to be able to (on-demand)
-- start responder sides of mini-protocols on incoming connections.  The
-- interface to give control over bi-directional outbound connection to the
-- server is using an @STM@ queue (see 'ControlChannel') over which messages
-- are passed to the server.  The server runs a single thread which accepts
-- them and acts on them.
--
--
-- When calling 'includeOutboundConnection' the connection manager will wait for
-- handshake negotiation, once resolved it will create the @handle@ and pass it
-- to 'PeerStateActions' (the peer-to-peer governor component which interacts
-- with connection manager).  If that connection was negotiated as duplex, it
-- will also be passed to the server.
--
-- For inbound connections, the connection manager will pass handle (also after
-- negotiation).
--
-- >                                                                               ┌───────────────────┐
-- >                                                                               │                   │
-- >                                                                               │  PeerStateActions │
-- >                                                                      ┏━━━━━━━▶│                   │
-- >                                                                      ┃        └───────────────────┘
-- >                                                                      ┃
-- >                                                                      ┃
-- >                                                                      ┃
-- >                                                                      ┃
-- >                                                                      ┃
-- >                                                                      ┃
-- >   ┌────────────────────────────────┐                                 ┃
-- >   │                                │        ┏━━━━━━━━━━━━━━━━━━━━━━━━┻━┓
-- >   │      ConnectionHandler         │        ┃                          ┃
-- >   │                                ┝━━━━━━━▶┃         handle           ┃
-- >   │     inbound / outbound         │        ┃                          ┃
-- >   │                 ┃              │        ┗━┳━━━━━━━━━━━━━━━━━━━━━━━━┛
-- >   └─────────────────╂──────────────┘          ┃
-- >                     ┃                         ┃
-- >                     ▼                         ┃
-- >              ┏━━━━━━━━━━━━━━━━━┓              ┃
-- >              ┃ Control Channel ┃              ┃
-- >              ┗━━━━━━┳━━━━━━━━━━┛              ┃
-- >                     ┃                         ┃
-- >                     ┃                         ┃
-- >                     ▼                         ┃
-- >   ┌────────────────────────────────┐          ┃
-- >   │                                │          ┃
-- >   │            Server              │          ┃
-- >   │                                │◀━━━━━━━━━┛
-- >   └────────────────────────────────┘
--
-- Termination prcedure is not described in this haddock, see associated
-- specification.
--
module Ouroboros.Network.ConnectionManager.Types
  ( -- * Connection manager core types
    Provenance (..)
  , ConnectionHandler (..)
  , ConnectionHandlerFn
  , DataFlow  (..)
  , Action (..)
  , ConnectionManagerArguments (..)
  , AddressType (..)
    -- * 'ConnectionManager'
  , ConnectionManager (..)
  , Connected (..)
  , OutboundConnectionManager (..)
  , InboundConnectionManager (..)
  , IncludeOutboundConnection
  , includeOutboundConnection
  , unregisterOutboundConnection
  , IncludeInboundConnection
  , includeInboundConnection
  , unregisterInboundConnection
  , numberOfConnections
  , IsInDuplexState (..)
  , isInDuplexState
    -- * Exceptions
  , ExceptionInHandler (..)
  , ConnectionManagerError (..)
  , ErrorReason (..)
  , withCallStack
    -- * Mux types
  , WithMuxMode (..)
  , WithMuxTuple
  , withInitiatorMode
  , withResponderMode
  , SingInitiatorResponderMode (..)
    -- * Tracing
  , ConnectionManagerTrace (..)
   -- * Promises
   -- $promise
  , PromiseReader (..)
  , readPromiseIO
  , PromiseWriter (..)
  , PromiseWriterException (..)
  , newEmptyPromiseIO
  ) where

import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadTime (DiffTime)
import           Control.Monad.Class.MonadThrow
import           Control.Monad (unless)
import           Control.Tracer (Tracer)
import           Data.Functor (void)
import           Data.Typeable (Typeable)
import           GHC.Stack (CallStack, HasCallStack, callStack, prettyCallStack)

import           Network.Mux.Types ( MuxBearer
                                   , MuxMode (..)
                                   , HasInitiator
                                   , HasResponder
                                   )
import           Network.Mux.Trace ( MuxTrace
                                   , WithMuxBearer )

import           Ouroboros.Network.ConnectionId (ConnectionId)
import           Ouroboros.Network.Snocket (Snocket)


-- | Each connection is is either initiated locally (outbound) or by a remote
-- peer (inbound).
--
data Provenance =
    --  | An inbound connection: one that was initiated by a remote peer.
    --
    Inbound

    -- | An outbound connection: one that was initiated by us.
    --
  | Outbound
  deriving (Eq, Show)


--
-- Mux types
--
-- TODO: find a better place for them, maybe 'Ouroboros.Network.Mux'
--

data WithMuxMode (muxMode :: MuxMode) a b where
    WithInitiatorMode          :: a -> WithMuxMode InitiatorMode a b
    WithResponderMode          :: b -> WithMuxMode ResponderMode a b
    WithInitiatorResponderMode :: a -> b -> WithMuxMode InitiatorResponderMode a b

type WithMuxTuple muxMode a = WithMuxMode muxMode a a

withInitiatorMode :: HasInitiator muxMode ~ True
                  => WithMuxMode muxMode a b
                  -> a
withInitiatorMode (WithInitiatorMode          a  ) = a
withInitiatorMode (WithInitiatorResponderMode a _) = a

withResponderMode :: HasResponder muxMode ~ True
                  => WithMuxMode muxMode a b
                  -> b
withResponderMode (WithResponderMode            b) = b
withResponderMode (WithInitiatorResponderMode _ b) = b


-- | Singletons for matching the 'muxMode'.
--
data SingInitiatorResponderMode (muxMode :: MuxMode) where
    SInitiatorMode          :: SingInitiatorResponderMode InitiatorMode
    SResponderMode          :: SingInitiatorResponderMode ResponderMode
    SInitiatorResponderMode :: SingInitiatorResponderMode InitiatorResponderMode


-- | Each connection get negotiate weather it's uni- or bi-directionalal.
-- 'DataFlow' is a lifte time property of a connection, i.e. once negotiated it
-- never changes.
--
data DataFlow
    = Unidirectional
    | Duplex
  deriving (Eq, Show)


-- | Split error handling from action.  The indentend usage is:
-- ```
-- \(Action action errorHandler) -> mask (errorHandler (unmask action))
-- ```
-- This allows to attach various error handlers to the action, e.g. both
-- `finally` and `catch`.
data Action m a = Action {
    action       :: m a,
    errorHandler :: m a -> m a
  }


-- $promise
--
-- Promise interface, backed by a `StrictTMVar`.
--
-- Making two seprate interfaces: 'PromiseWriter' and 'PromiseReader' allows us
-- to make a clear distinction between consumer and producers threads.

data PromiseWriter m a = PromiseWriter {
    -- | 'putPromise', is a non-blocking operation, it throws
    -- 'PromiseWriterException' if it would block.
    writePromise :: a -> STM m (),

    -- | If the promise is empty it fills it, if it is non-empty it swaps the
    -- current value.
    forcePromise :: a -> STM m ()
  }

data PromiseWriterException = PromiseWriterBlocked
  deriving (Show, Typeable)

instance Exception PromiseWriterException


newtype PromiseReader m a = PromiseReader {
    -- | A blocking read operation.
    readPromise :: STM m a
  }

readPromiseIO :: MonadSTM m => PromiseReader m a -> m a
readPromiseIO = atomically . readPromise

newEmptyPromise :: forall m a.
                   ( MonadSTM m
                   , MonadThrow (STM m) )
                => STM m (PromiseReader m a, PromiseWriter m a)
newEmptyPromise = do
    (v :: StrictTMVar m a) <- newEmptyTMVar
    let reader = PromiseReader { readPromise = readTMVar v }
        writer = PromiseWriter {
                    writePromise = \a -> do
                      r <- tryPutTMVar v a
                      unless r
                        (throwSTM PromiseWriterBlocked),

                    -- Both 'putTMVar' and 'swapTMVar' are blocking
                    -- operations, but the first blocks if @v@ is non-empty
                    -- and the latter blocks when @b@ is empty.  Combining them
                    -- with 'orElse' is a non-blocking operation.
                    forcePromise = \a -> putTMVar v a
                        `orElse` void (swapTMVar v a)
                  }
    pure (reader, writer)

newEmptyPromiseIO :: ( MonadSTM m
                     , MonadThrow (STM m) )
                  => m (PromiseReader m a, PromiseWriter m a)
newEmptyPromiseIO = atomically newEmptyPromise


--
-- ConnectionHandler
--


-- | Action which is executed by thread designated for a given connection.
--
type ConnectionHandlerFn handlerTrace peerAddr handle handleError version m
     = PromiseWriter m (Either handleError (handle, version))
    -> Tracer m handlerTrace
    -> ConnectionId peerAddr
    -> (DiffTime -> MuxBearer m)
    -> Action m ()


newtype ConnectionHandler muxMode handlerTrace peerAddr handle handleError version m =
    ConnectionHandler
      (WithMuxTuple muxMode (ConnectionHandlerFn handlerTrace peerAddr handle handleError version m))

-- | Exception which where caught in the connection thread and were re-thrown
-- in the main thread by the 'rethrowPolicy'.
--
data ExceptionInHandler peerAddr where
    ExceptionInHandler :: !peerAddr
                       -> !SomeException
                       -> ExceptionInHandler peerAddr
  deriving Typeable

instance   Show peerAddr => Show (ExceptionInHandler peerAddr) where
    show (ExceptionInHandler peerAddr e) = "ExceptionInHandler "
                                        ++ show peerAddr
                                        ++ " "
                                        ++ show e
instance ( Show peerAddr
         , Typeable peerAddr ) => Exception (ExceptionInHandler peerAddr)


data ConnectionManagerError peerAddr
    -- | A connection turned out to be unidrectional and we already have
    -- a connection in that direction (this it outbound only).
    = ConnectionExists     !peerAddr !Provenance    !CallStack
    -- | Like above but it could only happen when there was a race condition
    -- between inbound and outbound threads which was won by the inbound side and
    -- the connection turned out to be unidirectional.
    | ForbiddenConnection  !(ConnectionId peerAddr) !CallStack
    -- | Connections that would be forbidden by the kernel, or by the
    -- connection manager (e.g. accessing two outbound connections with the
    -- same peer).
    | ImpossibleConnection !(ConnectionId peerAddr) !CallStack
    -- | Error thrown when a connection was not found in connection manager state.
    -- It indicates that some other thread removed it because of some connection
    -- error.
    | ConnectionFailure    !(ConnectionId peerAddr) !CallStack

    -- | Connection manager in impossible state
    | ImpossibleState      !peerAddr                !CallStack

    -- | A forbidden operation in the given connection state
    | ForbiddenOperation   !peerAddr !ErrorReason   !CallStack

    -- | a connection does not exists.
    --
    | UnknownPeer          !peerAddr                !CallStack
    deriving (Show, Typeable)

data ErrorReason
  = InReservedOutboundState
  | InUnnegotiatedState
  | InInboundState
  | InOutboundState
  deriving (Show, Typeable)


instance ( Show peerAddr
         , Typeable peerAddr ) => Exception (ConnectionManagerError peerAddr) where

    displayException (ConnectionExists peerAddr provenance cs) =
      concat [ "Connection already exists with peer "
             , show peerAddr
             , " "
             , show provenance
             , "\n"
             , prettyCallStack cs
             ]
    displayException (ForbiddenConnection connId cs) =
      concat [ "Forbidden to reuse a connection (UnidirectionalDataFlow) with peer "
             , show connId
             , "\n"
             , prettyCallStack cs
             ]
    displayException (ImpossibleConnection connId cs) =
      concat [ "Impossible connection with peer "
             , show connId
             , "\n"
             , prettyCallStack cs
             ]
    displayException (ConnectionFailure connId cs) =
      concat [ "Connection thread failed for "
             , show connId
             , "\n"
             , prettyCallStack cs
             ]
    displayException (ImpossibleState peerAddr cs) =
      concat [ "Imposible connection state for peer "
             , show peerAddr
             , "\n"
             , prettyCallStack cs
             ]
    displayException (ForbiddenOperation peerAddr reason cs) =
      concat [ "Forbidden operation"
             , show peerAddr
             , " "
             , show reason
             , "\n"
             , prettyCallStack cs
             ]
    displayException (UnknownPeer peerAddr cs) =
      concat [ "Forbidden operation"
             , show peerAddr
             , "\n"
             , prettyCallStack cs
             ]


-- | Connection manager supports `IPv4` and `IPv6` addresses.
--
data AddressType = IPv4Address | IPv6Address
    deriving Show


-- | Assumptions \/ arguments for a 'ConnectionManager'.
--
-- Move to `Core`!
--
data ConnectionManagerArguments (muxMode :: MuxMode) handlerTrace socket peerAddr handle handleError version m =
    ConnectionManagerArguments {
        connectionManagerTracer         :: Tracer m (ConnectionManagerTrace peerAddr handlerTrace),

        -- | Mux trace.
        --
        connectionManagerMuxTracer      :: Tracer m (WithMuxBearer (ConnectionId peerAddr) MuxTrace),

        -- | Local @IPv4@ address of the connection manager.  If given, outbound
        -- connections to an @IPv4@ address will bound to it.
        --
        connectionManagerIPv4Address    :: Maybe peerAddr,

        -- | Local @IPv6@ address of the connection manager.  If given, outbound
        -- connections to an @IPv6@ address will bound to it.
        --
        connectionManagerIPv6Address    :: Maybe peerAddr,

        connectionManagerAddressType    :: peerAddr -> Maybe AddressType,

        -- | Callback which runs in a thread dedicated for a given connection.
        --
        connectionHandler               :: ConnectionHandler muxMode handlerTrace peerAddr handle handleError version m,

        -- | Snocket for the 'socket' type.
        --
        connectionSnocket               :: Snocket m socket peerAddr,

        -- | @version@ represnts the tuple of @versionNumber@ and
        -- @agreedOptions@.
        --
        connectionDataFlow              :: version -> DataFlow,

        connectionManagerPrunePolicy    :: Map peerAddr DataFlow -> Int -> STM m [peerAddr],
        connectionManagerAcceptedLimits :: AcceptedConnectionsLimit
      }


-- | Result of 'IncludeOutboundConnection' or 'IncludeInboundConnection'.
--
data Connected peerAddr handle handleError =
    -- | We are connected and mux is running.
    --
    Connected    !(ConnectionId peerAddr) !handle

    -- | There was an error during handshake negotiation.
    --
  | Disconnected !(ConnectionId peerAddr) !handleError


-- | Returns wheather a connection is in 'DuplexState', and if not returns an
-- stm action wchich blocks until the peer is in 'DuplexState'.  If the initial
-- state is @'InboundState' 'Unidirectional'@ then the stm action will block
-- forever, thus this action must only be used as a part of a first-to-finish
-- synchronisation (e.g. via 'orElse').
--
data IsInDuplexState m
  = InDuplexState
  | AwaitForDuplexState (STM m ())


type IncludeOutboundConnection        peerAddr handle handleError m
    =           peerAddr -> m (Connected peerAddr handle handleError)
type IncludeInboundConnection  socket peerAddr handle handleError m
    = socket -> peerAddr -> m (Connected peerAddr handle handleError)


-- | Outbound connection manager API.
--
data OutboundConnectionManager (muxMode :: MuxMode) socket peerAddr handle handleError m where
    OutboundConnectionManager
      :: HasInitiator muxMode ~ True
      => { ocmIncludeConnection    :: IncludeOutboundConnection peerAddr handle handleError m
         , ocmUnregisterConnection :: peerAddr -> m ()
         }
      -> OutboundConnectionManager muxMode socket peerAddr handle handleError m

-- | Inbound connection manager API.  For a server implementation we also need
-- to know how many connections are now managed by the connection manager.
--
-- This type is an internal detail of 'Ouroboros.Network.ConnectionManager'
--
data InboundConnectionManager (muxMode :: MuxMode) socket peerAddr handle handleError m where
    InboundConnectionManager
      :: HasResponder muxMode ~ True
      => { icmIncludeConnection    :: IncludeInboundConnection socket peerAddr handle handleError m
         , icmUnregisterConnection :: peerAddr -> m Bool
         , icmIsInDuplexState      :: peerAddr -> STM m (IsInDuplexState m)
         , icmNumberOfConnections  :: STM m Int
         }
      -> InboundConnectionManager muxMode socket peerAddr handle handleError m

-- | 'ConnectionManager'.
--
-- We identify resources (e.g. 'Network.Socket.Socket') by their address.   It
-- is enough for us to use just the remote address rather than connection
-- identifier, since we just need one connection towards that peer, even if we
-- are connected through multiple addresses.  It is safe to share a connection
-- manager with all the accepting sockets.
--
-- Explain `muxMode` here! Including examples!
--
newtype ConnectionManager (muxMode :: MuxMode) socket peerAddr handle handleError m =
    ConnectionManager {
        getConnectionManager
          :: WithMuxMode
              muxMode
              (OutboundConnectionManager muxMode socket peerAddr handle handleError m)
              (InboundConnectionManager  muxMode socket peerAddr handle handleError m)
      }

--
-- ConnectionManager API
--

-- | Include outbound connection into 'ConnectionManager'.
--
includeOutboundConnection :: HasInitiator muxMode ~ True
                          => ConnectionManager muxMode socket peerAddr handle handleError m
                          -> IncludeOutboundConnection        peerAddr handle handleError m
includeOutboundConnection = ocmIncludeConnection . withInitiatorMode . getConnectionManager

-- | Unregister outbound connection.
--
unregisterOutboundConnection :: HasInitiator muxMode ~ True
                             => ConnectionManager muxMode socket peerAddr handle handleError m
                             -> peerAddr -> m ()
unregisterOutboundConnection = ocmUnregisterConnection . withInitiatorMode . getConnectionManager

-- | Include an inbound connection into 'ConnectionManager'.
--
includeInboundConnection :: HasResponder muxMode ~ True
                         => ConnectionManager muxMode socket peerAddr handle handleError m
                         -> IncludeInboundConnection  socket peerAddr handle handleError m
includeInboundConnection =  icmIncludeConnection . withResponderMode . getConnectionManager

-- | Unregister outbound connection.  Returns if the operation was successul.
--
unregisterInboundConnection :: HasResponder muxMode ~ True
                            => ConnectionManager muxMode socket peerAddr handle handleError m
                            -> peerAddr -> m Bool
unregisterInboundConnection = icmUnregisterConnection . withResponderMode . getConnectionManager

-- | Number of connections tracked by the server.
--
numberOfConnections :: HasResponder muxMode ~ True
                    => ConnectionManager muxMode socket peerAddr handle handleError m
                    -> STM m Int
numberOfConnections = icmNumberOfConnections . withResponderMode . getConnectionManager


-- | See 'IsInDuplexState' for explanation.
--
isInDuplexState  :: HasResponder muxMode ~ True
                 => ConnectionManager muxMode socket peerAddr handle handleError m
                 -> peerAddr -> STM m (IsInDuplexState m)
isInDuplexState = icmIsInDuplexState . withResponderMode . getConnectionManager


--
-- Tracing
--

-- | 'ConenctionManagerTrace' contains a hole for a trace of single connection
-- which is filled with 'ConnectionHandlerTrace'.
--
data ConnectionManagerTrace peerAddr a
  = TrIncludedConnection      !(ConnectionId peerAddr) !Provenance
  | TrNegotiatedConnection    !(ConnectionId peerAddr) !Provenance !DataFlow
  | TrConnect                 !(Maybe peerAddr) !peerAddr
  | TrConnectError            !(Maybe peerAddr) !peerAddr !SomeException
  -- | We reused a duplex connection.  This can only be emitted by
  -- 'includeOutboundConnection'.
  | TrReusedConnection        !(ConnectionId peerAddr)
  | TrConnectionTerminated    !(ConnectionId peerAddr) !Provenance
  | TrConnectionHandler       !(ConnectionId peerAddr) !a
  | TrShutdown

  | TrConnectionExists        !peerAddr                !Provenance
  | TrForbiddenConnection     !(ConnectionId peerAddr)
  | TrImpossibleConnection    !(ConnectionId peerAddr)
  | TrConnectionFailure       !(ConnectionId peerAddr)
  | TrConnectionNotFound      !peerAddr                !Provenance
  -- | A connection transitioned from 'DuplexState' to @'Inbound' 'Duplex'@.
  --
  | TrConnectionDemoted       !(ConnectionId peerAddr)
  deriving Show


--
-- Utils
--

-- | Useful to attach 'CallStack' to 'ConnectionManagerError'.
--
withCallStack :: HasCallStack => (CallStack -> a) -> a
withCallStack k = k callStack
