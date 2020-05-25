{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}

-- | Server implementation based on 'ConnectionManager'
--
-- TODO: in the futures this should be moved to `Ouroboros.Network.Server`, but
-- to avoid confusion it will be kept here for now.
--
module Ouroboros.Network.ConnectionManager.Server
  ( ServerArguments (..)
  , run
  -- * Trace
  , ServerTrace (..)
  , AcceptConnectionsPolicyTrace (..)
  ) where

import           Control.Applicative ((<|>))
import           Control.Exception (assert)
import           Control.Monad.Class.MonadAsync
import qualified Control.Monad.Class.MonadSTM as LazySTM
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadThrow hiding (handle)
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Tracer (Tracer, contramap, traceWith)

import           Data.ByteString.Lazy (ByteString)
import           Data.Functor (($>))
import           Data.Void (Void)
import           Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Typeable (Typeable)

import qualified Network.Mux as Mux

import           Ouroboros.Network.ConnectionId (ConnectionId (..))
import           Ouroboros.Network.ConnectionManager.Types
import           Ouroboros.Network.MuxConnectionHandler
import           Ouroboros.Network.ConnectionManager.Server.ControlChannel (ServerControlChannel)
import qualified Ouroboros.Network.ConnectionManager.Server.ControlChannel as Server
import           Ouroboros.Network.Mux hiding (ControlMessage)
import           Ouroboros.Network.Channel (fromChannel)
import           Ouroboros.Network.Server.RateLimiting
import           Ouroboros.Network.Snocket


-- |
--
type MonitorState muxMode peerAddr versionNumber m a b
    = Map (ConnectionId peerAddr)
          (ConnectionState muxMode peerAddr versionNumber m a b)

data ConnectionState muxMode peerAddr versionNumber m a b = ConnectionState {
      -- | Mux interface.
      csMux                 :: !(Mux.Mux muxMode m),

      -- | All supported mini-protocols.
      csMiniProtocolsMap    :: !(Map MiniProtocolNum (WithSomeProtocolTemperature (MiniProtocol muxMode ByteString m a b))),

      -- | Mini protocol stm actions to monitor.
      csMiniProtocolActions :: !(Map MiniProtocolNum ((STM m (WithSomeProtocolTemperature (Either SomeException b))))),

      -- | When we enter termination we hold an stm action which blocks until
      -- all the protocol terminate or a timeout is reached or the connection is
      -- promoted to 'DuplexState'.
      csProtocolState       :: !(ProtocolState muxMode peerAddr versionNumber m a b)
    }


-- | 'ProtocolState' can be either in running mode or terminating state.  It
-- should not be confused with a mini-protocol state (protocol is a suite of
-- mini-protocols, e.g. node-to-node protocol or node-to-client protocol).
--
-- In the 'IsTerminating' sate it holds a last to finish synchronisation between
-- terminating protocols and a timeout 'TVar', which will be reused to construct
-- 'csProtocolState' whenever a mini-protocol terminates.  This alows us to set
-- overall timeout on termination of all mini-protocols.
--
data ProtocolState muxMode peerAddr versionNumber m a b
  -- Protocol is running.
  = IsRunning
  -- An established protcol terminated, we will wait for all mini-protocols to
  -- shutdown if the connection is in @'InboundState' dataFlow@.
  | IsTerminating
    -- | timeout tvar,
    !(LazySTM.TVar m Bool)
    -- | An STM transactions which returns if the connection changes its state
    -- to @'DuplexState'@.  It returns the original 'MonitorEvent' which put the
    -- connection in this 'IsTerminating' state.
    !(STM m (MonitorEvent muxMode peerAddr versionNumber m a b))


-- When we re-start a mini-protocol, we register its stm action in
-- 'csMiniProtocolActions' map.  We also set protocol state to 'IsRunning'.
--
registerMiniProtocol
  :: Ord peerAddr
  => ConnectionId peerAddr
  -> MiniProtocolNum
  -> STM m (WithSomeProtocolTemperature (Either SomeException b))
  -> MonitorState muxMode peerAddr versionNumber m a b
  -> MonitorState muxMode peerAddr versionNumber m a b
registerMiniProtocol connId miniProtocolNum stm =
    Map.update
      (\st@ConnectionState { csMiniProtocolActions } ->
        Just st { csMiniProtocolActions =
                    Map.insert
                      miniProtocolNum
                      stm
                      csMiniProtocolActions
                , csProtocolState = IsRunning
                }
      )
      connId

unregisterMiniProtocol
  :: Ord peerAddr
  => ConnectionId peerAddr
  -> MiniProtocolNum
  -> MonitorState muxMode peerAddr versionNumber m a b
  -> MonitorState muxMode peerAddr versionNumber m a b
unregisterMiniProtocol connId miniProtocolNum state =
  Map.update
    (\cs -> Just cs { csMiniProtocolActions =
                        Map.delete miniProtocolNum (csMiniProtocolActions cs)
                    })
    connId
    state


insertConnection
    :: Ord peerAddr
    => ConnectionId peerAddr
    -> Mux.Mux muxMode m
    -> Map MiniProtocolNum (WithSomeProtocolTemperature (MiniProtocol muxMode ByteString m a b))
    -> Map MiniProtocolNum (STM m (WithSomeProtocolTemperature (Either SomeException b)))
    -> MonitorState muxMode peerAddr versionNumber m a b
    -> MonitorState muxMode peerAddr versionNumber m a b
insertConnection connId csMux csMiniProtocolsMap csMiniProtocolActions =
    Map.insert connId
      ConnectionState {
          csMux,
          csMiniProtocolsMap,
          csMiniProtocolActions,
          csProtocolState = IsRunning
      }


lookupMiniProtocol
    :: Ord peerAddr
    => ConnectionId peerAddr
    -> MiniProtocolNum
    -> MonitorState muxMode peerAddr versionNumber m a b
    -> Maybe ( Mux.Mux muxMode m
             , WithSomeProtocolTemperature (MiniProtocol muxMode ByteString m a b)
             , ProtocolState muxMode peerAddr versionNumber m a b
             )
lookupMiniProtocol connId miniProtocolNum ms =
    case Map.lookup connId ms of
      Nothing -> Nothing
      Just ConnectionState { csMux,
                             csMiniProtocolsMap,
                             csProtocolState } ->
        Just ( csMux
             -- 'csMiniProtocolsMap' is static, it never changes during during
             -- connection lifetime.
             , csMiniProtocolsMap Map.! miniProtocolNum 
             , csProtocolState
             )


data ServerArguments (muxMode :: MuxMode) socket peerAddr versionNumber bytes m a b = ServerArguments {
      serverSockets           :: NonEmpty socket,
      serverSnocket           :: Snocket m socket peerAddr,
      serverTracer            :: Tracer m (ServerTrace peerAddr versionNumber),
      serverConnectionLimits  :: AcceptedConnectionsLimit,
      serverConnectionManager :: MuxConnectionManager muxMode socket peerAddr
                                                      versionNumber bytes m a b,

      -- | Server control var is passed as an argument; this allows to use the
      -- server to run and manage responders which needs to be started on
      -- inbound connections.
      --
      serverControlChannel    :: ServerControlChannel m muxMode peerAddr
                                                      versionNumber a b
    }


data MonitorEvent (muxMode :: MuxMode) peerAddr versionNumber m a b =
    -- | A request to start mini-protocol bundle, either from the server or from
    -- connection manager.
    --
      MonitorMessage !(Server.ControlMessage (muxMode :: MuxMode) peerAddr versionNumber m a b)

    -- | A mini-protocol terminated with an exception.
    --
    | MiniProtocolErrored
        !(ConnectionId peerAddr)
        !MiniProtocolNum
        !SomeException

    -- | A mini-protocol terminated.  This initialises procedure
    -- which might either terminate all protocols or restart the protocol,
    -- depending on connection state.
    --
    | MiniProtocolReturned
        !(ConnectionId peerAddr)
        !MiniProtocolNum
        !(WithSomeProtocolTemperature b)

    -- | All mini-protocols terminated.
    --
    | ProtocolTerminated
        !(ConnectionId peerAddr)

    -- | Not all mini-protocols terminated within a timeout.
    --
    | ProtocolTerminationTimeout
        !(ConnectionId peerAddr)
        !MiniProtocolNum


-- | Termination timeout.  This is a common timeout for termination all of the
-- mini-protocols.  It should be kept in sync with what we use on the outbound
-- side.
--
-- TODO: it should be made configurable, and defined where outbound timeouts are
-- defined.
--
terminationTimeout :: DiffTime
terminationTimeout = 120


firstMiniProtocolToFinish :: MonadSTM m
                          => MonitorState muxMode peerAddr versionNumber m a b
                          -> STM m (MonitorEvent muxMode peerAddr versionNumber m a b)
firstMiniProtocolToFinish =
    Map.foldrWithKey
      (\connId ConnectionState { csMiniProtocolActions, csProtocolState } outerAcc ->
        Map.foldrWithKey
          (\miniProtocolNum stm innerAcc ->
                (\resultWithTemp ->
                  case withoutSomeProtocolTemperature resultWithTemp of
                    Left err -> MiniProtocolErrored  connId miniProtocolNum err
                    Right a  -> MiniProtocolReturned connId miniProtocolNum (resultWithTemp $> a)
                )
             <$> stm
             <|> (case csProtocolState of
                    IsTerminating _ awaitTermination -> awaitTermination
                    IsRunning -> retry)
             <|> innerAcc
          )
          outerAcc
          csMiniProtocolActions)
      retry



-- | Start and run the server, which consists of two parts:
--
-- * monitoring thread (also called inbound protocol governor) (which
--   corresponds to p2p-governor on oubound side
-- * accept loop(s), one per given ip.  We support up to one ipv4 address
--   and up to one ipv6 address, i.e. an ipv6 enabled node will run two
--   accept loops on different addresses with shared monitoring thread.
--
run :: forall muxMode socket peerAddr versionNumber m a b.
       ( MonadAsync m
       , MonadCatch m
       , MonadTime  m
       , MonadTimer m
       , Mux.HasResponder muxMode ~ True
       , Ord      peerAddr
       , Typeable peerAddr
       , Show     peerAddr
       )
    => ServerArguments muxMode socket peerAddr versionNumber ByteString m a b
    -> m Void
run ServerArguments {
      serverSockets,
      serverSnocket,
      serverTracer = tracer,
      serverConnectionLimits,
      serverConnectionManager,
      serverControlChannel
    } = do
      let sockets = NonEmpty.toList serverSockets
      localAddresses <- traverse (getLocalAddr serverSnocket) sockets
      traceWith tracer (Started localAddresses)
      runConcurrently
        $ foldr1 (<>)
        $ Concurrently (monitoringThread Map.empty)
        : (Concurrently . acceptLoop . accept serverSnocket) `map` sockets
      `finally`
        traceWith tracer Stopped
  where
    -- The inbound protocol governor.
    --
    monitoringThread
      :: MonitorState muxMode peerAddr versionNumber m a b
      -> m Void
    monitoringThread state = do
      monitorMessage
        <- atomically
            $ (MonitorMessage <$> Server.readControlMessage serverControlChannel)
              `orElse`
              (firstMiniProtocolToFinish state)

      case monitorMessage of
        MonitorMessage
          -- new connection has been announced by either accept loop or
          -- by connection manager (in which case the connection is in
          -- 'DuplexState').
          (Server.NewConnection
            connId
            (MuxHandle mux
                       (Bundle
                         (WithHot hotPtls)
                         (WithWarm warmPtls)
                         (WithEstablished establishedPtls))
                       _)) -> do
              traceWith tracer
                (StartRespondersOnInboundConncetion
                  connId)
              let miniProtocolsMap :: Map MiniProtocolNum
                                          (WithSomeProtocolTemperature
                                            (MiniProtocol muxMode ByteString m a b))
                  miniProtocolsMap =
                    Map.fromList $
                      [ (miniProtocolNum p, WithSomeProtocolTemperature (WithEstablished p))
                      | p <- establishedPtls
                      ] ++
                      [ (miniProtocolNum p, WithSomeProtocolTemperature (WithWarm p))
                      | p <- warmPtls
                      ] ++
                      [ (miniProtocolNum p, WithSomeProtocolTemperature (WithHot p))
                      | p <- hotPtls
                      ]
              -- start responder protocols
              miniProtocolActions
                <- traverse (runResponder (WithResponder @muxMode) mux Mux.StartEagerly)
                            miniProtocolsMap

              monitoringThread
                (insertConnection
                  connId mux
                  miniProtocolsMap
                  miniProtocolActions
                  state)


        MiniProtocolErrored connId miniProtocolNum err -> do
          case fromException err of
            -- Do not log 'MuxError's here; That's already logged by
            -- 'ConnectionManager' and we don't want to multiplex these errors
            -- for each mini-protocol.
            Just Mux.MuxError {} -> pure ()
            Nothing -> traceWith tracer (MiniProtocolError connId miniProtocolNum err)

          -- exceptions raised by mini-protocols are terminal to the bearer; we
          -- can stop tracking thet connection.
          monitoringThread (Map.delete connId state)


        msg@(MiniProtocolReturned connId miniProtocolNum resultWithTemp) -> do
          case resultWithTemp of
            -- established protocol terminated, this triggers termination
            WithSomeProtocolTemperature (WithEstablished _) -> do
              -- timeout 'TVar'; only create a new one if there doesn't exists one
              -- for this connection.
              timeoutVar <-
                case csProtocolState <$> Map.lookup connId state  of
                  Nothing                      -> registerDelay terminationTimeout
                  Just IsRunning               -> registerDelay terminationTimeout
                  Just (IsTerminating tv _stm) -> return tv

              (inDuplexState, state') <-
                atomically $ do
                  -- isInbDuplexState can error if the connection is in
                  -- 'UnnegotiatedState' or 'ReservedOutboundState', this is
                  -- impossible if a mini-protocol returned cleanly.
                  cmConnState <-
                    isInDuplexState serverConnectionManager (remoteAddress connId)

                  case cmConnState of
                    InDuplexState ->
                      return
                        ( True
                        -- state is updated after restarting a mini-protocol, we
                        -- don't need to remove the mini-protocol which return as
                        -- shortly we will start it.
                        , state
                        )

                    AwaitForDuplexState promotedSTM ->
                      return
                        ( False
                        , Map.update
                            (\connState@(ConnectionState { csMiniProtocolActions }) ->
                              -- remove the mini-protocol which terminated, and
                              -- register last to finish synchronisation between all
                              -- mini-protocol threads
                              let miniProtocolActions = Map.delete miniProtocolNum csMiniProtocolActions

                                  -- this synchronisation must terminate if first of
                                  -- the three conditions is met:
                                  -- * all mini-protocols terminated (hence the
                                  --   name),
                                  -- * timeout fired,
                                  -- * connection was promoted to 'DuplexState'.
                                  --
                                  -- In the last case, we will come back to his case
                                  -- and we will consider if we actually can restart
                                  -- the protocol.
                                  --
                                  -- Life time of 'lastToFinish' starts here.  It
                                  -- will be garbage collected once: 
                                  -- * all mini-protocols terminated
                                  -- * timeout fired
                                  -- * connection was promoted to 'DuplexState'.
                                  --
                                  -- In the first two cases it will be gc-ed
                                  -- together with 'ConnectionState', in the last
                                  -- case by 'registerMiniProtocol'
                                  --
                                  terminating :: ProtocolState muxMode peerAddr versionNumber m a b
                                  terminating = IsTerminating
                                      timeoutVar
                                      ( -- wait for all mini-protocols to termnate
                                            (sequence_ miniProtocolActions $> ProtocolTerminated connId)
                                        -- or else wait for timeout
                                        <|> ((LazySTM.readTVar timeoutVar >>= check)
                                              $> ProtocolTerminationTimeout connId miniProtocolNum)
                                        -- or else wait for promotion of the
                                        -- connection to 'DuplexState'.
                                        <|> (promotedSTM $> msg)
                                      )
                              in Just connState { csMiniProtocolActions = miniProtocolActions,
                                                  csProtocolState = terminating }
                            )
                            connId
                            state
                        )


              if inDuplexState
                -- in 'DuplexState'
                then 
                  case lookupMiniProtocol connId miniProtocolNum state' of
                    Nothing ->
                      assert False $ monitoringThread state'

                    Just (mux, miniProtocol, _) -> do
                      stm <- runResponder (WithResponder @muxMode) mux Mux.StartEagerly miniProtocol
                      traceWith
                        tracer
                        (MiniProtocolRestarted connId miniProtocolNum)
                      monitoringThread
                        $ registerMiniProtocol
                            connId
                            miniProtocolNum
                            stm
                            state'

                -- not in 'DuplexState'
                else do
                  traceWith
                    tracer
                    (MiniProtocolTerminated connId miniProtocolNum)
                  monitoringThread state'


            -- hot or warm protocol terminated, just restart it.  This is a
            -- resutl of `hot → warm` or `warm → hot` transition on the remote
            -- end or part of `any → cold` transition.
            _ -> 
              case lookupMiniProtocol connId miniProtocolNum state of
                Nothing ->
                  assert False $ monitoringThread state

                Just (mux, miniProtocol, protocolState) ->
                  case protocolState of
                    -- remote end is exuecuting `any → cold` transition.
                    IsTerminating {} -> do
                      traceWith
                        tracer
                        (MiniProtocolTerminated connId miniProtocolNum)
                      monitoringThread
                        $ unregisterMiniProtocol
                            connId
                            miniProtocolNum
                            state

                    -- remote end is executing `wamr → hot` or `hot → warm`
                    -- transition.
                    IsRunning -> do
                      stm <- runResponder (WithResponder @muxMode) mux Mux.StartEagerly miniProtocol
                      traceWith
                        tracer
                        (MiniProtocolRestarted connId miniProtocolNum)
                      -- overwrite mini-protocol action; the 'monitoringThread'
                      -- will now seek when @stm@ returns.
                      monitoringThread
                        $ registerMiniProtocol
                            connId
                            miniProtocolNum
                            stm
                            state


        ProtocolTerminated connId -> do
          a <- unregisterInboundConnection serverConnectionManager (remoteAddress connId)
              `catch` \(_ :: ConnectionManagerError peerAddr) -> return True
          state' <-
            if a
              then return $ Map.delete connId state
              else
                -- all responder protocols terminated, but the connection manager
                -- refused to unregister the connection.  We are now respondible
                -- for starting all mini-protocols.
                case Map.lookup connId state of
                  Nothing ->
                    return state
                  Just ConnectionState { csMux, csMiniProtocolsMap } -> do
                    miniProtocolActions
                      <- traverse (runResponder (WithResponder @muxMode) csMux Mux.StartEagerly)
                                  csMiniProtocolsMap
                    return
                      $ Map.update
                          (\cs -> Just cs { csMiniProtocolActions = miniProtocolActions })
                          connId
                          state
          monitoringThread state'


        ProtocolTerminationTimeout connId miniProtocolNum -> do
          a <- unregisterInboundConnection serverConnectionManager (remoteAddress connId)
              `catch` \(_ :: ConnectionManagerError peerAddr) -> return True
          if a
            then
              monitoringThread (Map.delete connId state)

            -- connection manager refused to unregister the connection; At
            -- this point we know that 'miniProtocolNum' terminated, so we
            -- need to restart it.
            else
              assert (Map.member connId state) $ do
                let ConnectionState { csMux,
                                      csMiniProtocolsMap
                                      } = state Map.! connId
                stm <- runResponder (WithResponder @muxMode) csMux Mux.StartEagerly (csMiniProtocolsMap Map.! miniProtocolNum)
                monitoringThread
                  $ registerMiniProtocol
                      connId
                      miniProtocolNum
                      stm
                      state


    acceptLoop :: Accept m SomeException peerAddr socket
               -> m Void
    acceptLoop acceptOne = do
      runConnectionRateLimits
        (AcceptPolicyTrace `contramap` tracer)
        (numberOfConnections serverConnectionManager)
        serverConnectionLimits
      result <- runAccept acceptOne
      case result of
        (AcceptException err, acceptNext) -> do
          traceWith tracer (AcceptError err)
          acceptLoop acceptNext
        (Accepted socket peerAddr, acceptNext) -> do
          traceWith tracer (AcceptConnection peerAddr)
          -- using withAsync ensures that the thread that includes inbound
          -- connection (which is a blockng operation), is killed when the
          -- server is killed, possibley by an async exception.
          withAsync
            (do
              a <-
                includeInboundConnection
                  serverConnectionManager
                  socket peerAddr
              case a of
                Connected connId handle ->
                  Server.writeControlMessage
                    serverControlChannel
                    (Server.NewConnection connId handle)
                Disconnected {} ->
                  pure ()
            )
            $ \_ -> acceptLoop acceptNext


-- | 'HasResponder muxMode ~ True' constraint.
--
data WithResponder (muxMode :: MuxMode) where
    WithResponder :: HasResponder muxMode ~ True => WithResponder muxMode


-- | Run a responder mini-protocol.
--
runResponder :: ( MonadAsync m
                , MonadCatch m
                )
             => WithResponder muxMode
             -- ^ we pass the @'HasResponder' ~ muxMode@ explicitly, otherwise
             -- the constraint would be redundant.
             -> Mux.Mux muxMode m
             -> Mux.StartOnDemandOrEagerly
             -> WithSomeProtocolTemperature (MiniProtocol muxMode ByteString m a b)
             -> m (STM m (WithSomeProtocolTemperature (Either SomeException b)))
runResponder WithResponder
             mux
             startOnDemandOrEagerly
             miniProtocol =
  case withoutSomeProtocolTemperature miniProtocol of
    MiniProtocol {
        miniProtocolNum,
        miniProtocolRun
      } ->
        case miniProtocolRun of
          ResponderProtocolOnly responder ->
            -- thread through the same 'WithProtocolTemperature'
            fmap (\res -> miniProtocol $> res) <$>
              Mux.runMiniProtocol
                mux miniProtocolNum
                Mux.ResponderDirectionOnly
                startOnDemandOrEagerly
                -- TODO: eliminate 'fromChannel'
                (runMuxPeer responder . fromChannel)

          InitiatorAndResponderProtocol _ responder ->
              -- thread through the same 'WithProtocolTemperature'
            fmap (\res -> miniProtocol $> res) <$>
              Mux.runMiniProtocol
                mux miniProtocolNum
                Mux.ResponderDirection
                startOnDemandOrEagerly
                (runMuxPeer responder . fromChannel)


--
-- Trace
--

data ServerTrace peerAddr versionNumber
    = AcceptConnection                    !peerAddr
    | StartRespondersOnInboundConncetion  !(ConnectionId peerAddr)
    | StartRespondersOnOutboundConnection !(ConnectionId peerAddr)
    | AcceptError                         !SomeException
    | AcceptPolicyTrace                   !AcceptConnectionsPolicyTrace
    | Started                             ![peerAddr]
    | Stopped
    | MiniProtocolRestarted  !(ConnectionId peerAddr) !MiniProtocolNum
    | MiniProtocolError      !(ConnectionId peerAddr) !MiniProtocolNum !SomeException
    | MiniProtocolTerminated !(ConnectionId peerAddr) !MiniProtocolNum
    | Terminating            !(ConnectionId peerAddr)
  deriving Show
