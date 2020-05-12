{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE DeriveFoldable       #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RankNTypes           #-}
-- Undecidable instances are need for 'Show' instance of 'ConnectionState'.
{-# LANGUAGE UndecidableInstances #-}

-- | The implementation of connection manager's resource managment.
--
module Ouroboros.Network.ConnectionManager.Core
  ( withConnectionManager
  ) where

import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadThrow hiding (handle)
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Tracer (traceWith, contramap)
import           Data.Foldable (traverse_)
import           Data.Functor (($>))
import           Data.Proxy (Proxy (..))
import           Data.Typeable (Typeable)
import           GHC.Stack (HasCallStack, callStack)

import           Data.Map (Map)
import qualified Data.Map as Map

import           Network.Mux.Trace (WithMuxBearer (..))

import           Ouroboros.Network.ConnectionId
import           Ouroboros.Network.ConnectionManager.Types
import           Ouroboros.Network.Snocket


-- | 'ConnectionManager' state: for each peer we keep a 'ConnectionState' in
-- a mutable variable, which reduce congestion on the 'TMVar' which keeps
-- 'ConnectionManagerState'.
--
-- It is important we can lookup by remote @peerAddr@; this way we can find if
-- the connection manager is already managing a connection towards that
-- @peerAddr@ and reuse the 'ConnectionState'.
--
type ConnectionManagerState peerAddr handle handleError version m
  = Map peerAddr (StrictTVar m (ConnectionState peerAddr handle handleError version m))



-- | State of a connection.
--
data ConnectionState peerAddr handle handleError version m =
    -- | Each outbound connections starts in this state.
    ReservedOutboundState
    -- | Each inbound connnection starts in this state, outbound connection
    -- reach this state once `connect` call returned.
  | UnnegotiatedState !Provenance
                      !(ConnectionId peerAddr)
                      !(Async m ())
                      !(PromiseReader  m (Either handleError (handle, version)))

  | InboundState      !(ConnectionId peerAddr) !(Async m ()) !handle !DataFlow
  -- | Outbound state is unidreictional.
  | OutboundState     !(ConnectionId peerAddr) !(Async m ()) !handle
  | DuplexState       !(ConnectionId peerAddr) !(Async m ()) !handle
  -- we don't include handhsake error as a connection state, such connections
  -- are just removed from the connection manager.
  -- | HandshakeError


instance ( Show peerAddr
         , Show (ThreadId m)
         , MonadAsync m
         )
      => Show (ConnectionState peerAddr handle handleError version m) where
    show ReservedOutboundState = "ReservedOutboundState"
    show (UnnegotiatedState pr connId connThread _) =
      concat ["UnnegotiatedState "
             , show pr
             , " "
             , show connId
             , " "
             , show (asyncThreadId (Proxy :: Proxy m) connThread)
             ]
    show (InboundState  connId connThread _handle df) =
      concat [ "InboundState "
             , show connId
             , " "
             , show (asyncThreadId (Proxy :: Proxy m) connThread)
             , " "
             , show df
             ]
    show (OutboundState connId connThread _handle) =
      concat [ "OutboundState "
             , show connId
             , " "
             , show (asyncThreadId (Proxy :: Proxy m) connThread)
             ]
    show (DuplexState   connId connThread _handle) =
      concat [ "DuplexState "
             , show connId
             , " "
             , show (asyncThreadId (Proxy :: Proxy m) connThread)
             ]


getConnThread :: ConnectionState peerAddr handle handleError version m
              -> Maybe (Async m ())
getConnThread ReservedOutboundState                                  = Nothing
getConnThread (UnnegotiatedState _pr _connId connThread _reader)     = Just connThread
getConnThread (InboundState          _connId connThread _handle _df) = Just connThread
getConnThread (OutboundState         _connId connThread _handle)     = Just connThread
getConnThread (DuplexState           _connId connThread _handle)     = Just connThread


-- | A wedge product
-- <https://hackage.haskell.org/package/smash/docs/Data-Wedge.html#t:Wedge>
--
data Wedge a b =
    Nowhere
  | Here a
  | There b


-- | Entry point for using the connection manager.  This is a classic @with@ style
-- combinator, which cleans resources on exit of the callback (whether cleanly
-- or through an exception).
--
-- Including a connection (either inbound or outbound) is an indepotent
-- operation on connection manager state.  The connection manager will always
-- return the handle that was first to be included in its state.
--
-- Once an inbound connection is passed to the 'ConnectionManager', the manager
-- is responsible for the resource.
--
withConnectionManager
    :: forall muxMode peerAddr socket handlerTrace handle handleError version m a.
       ( Monad             m
       -- We use 'MonadFork' to rethrow exceptions in the main thread.
       , MonadFork         m
       , MonadAsync        m
       , MonadEvaluate     m
       , MonadMask         m
       , MonadThrow   (STM m)

       , Ord      peerAddr
       , Show     peerAddr
       , Typeable peerAddr
       )
    => ConnectionManagerArguments muxMode handlerTrace socket peerAddr handle handleError version m
    -> (ConnectionManager         muxMode              socket peerAddr handle handleError         m
         -> m a)
    -- ^ Continuation which receives the 'ConnectionManager'.  It must not leak
    -- outside of scope of this callback.  Once it returns all resources
    -- will be closed.
    -> m a
withConnectionManager ConnectionManagerArguments {
                        connectionManagerTracer    = tracer,
                        connectionManagerMuxTracer = muxTracer,
                        connectionManagerIPv4Address,
                        connectionManagerIPv6Address,
                        connectionManagerAddressType,
                        connectionHandler,
                        connectionSnocket,
                        connectionDataFlow,
                        connectionManagerPrunePolicy = prunPolicy,
                        connectionManagerAcceptedLimits = acceptedLimits
                      } k = do
    stateVar <-
      newTMVarIO
        (Map.empty
          :: ConnectionManagerState peerAddr handle handleError version m)
    let connectionManager :: ConnectionManager muxMode socket peerAddr
                                               handle handleError m
        connectionManager =
          case connectionHandler of
            ConnectionHandler (WithInitiatorMode outboundHandler) ->
              ConnectionManager
                (WithInitiatorMode
                  OutboundConnectionManager {
                      ocmIncludeConnection =
                        includeOutboundConnectionImpl stateVar outboundHandler,
                      ocmUnregisterConnection =
                        unregisterOutboundConnectionImpl stateVar
                    })

            ConnectionHandler (WithResponderMode inboundHandler) ->
              ConnectionManager
                (WithResponderMode
                  InboundConnectionManager {
                      icmIncludeConnection =
                        includeInboundConnectionImpl stateVar inboundHandler,
                      icmUnregisterConnection =
                        unregisterInboundConnectionImpl stateVar,
                      icmIsInDuplexState =
                        isInDuplexStateImpl stateVar,
                      icmNumberOfConnections =
                        readTMVar stateVar >>= countConnections
                    })

            ConnectionHandler (WithInitiatorResponderMode outboundHandler inboundHandler) ->
              ConnectionManager
                (WithInitiatorResponderMode
                  OutboundConnectionManager {
                      ocmIncludeConnection =
                        includeOutboundConnectionImpl stateVar outboundHandler,
                      ocmUnregisterConnection =
                        unregisterOutboundConnectionImpl stateVar
                    }
                  InboundConnectionManager {
                      icmIncludeConnection =
                        includeInboundConnectionImpl stateVar inboundHandler,
                      icmUnregisterConnection =
                        unregisterInboundConnectionImpl stateVar,
                      icmIsInDuplexState =
                        isInDuplexStateImpl stateVar,
                      icmNumberOfConnections =
                        readTMVar stateVar >>= countConnections
                    })

    k connectionManager
      `finally` do
        traceWith tracer TrShutdown
        state <- atomically $ readTMVar stateVar
        traverse_
          (\connVar -> do
            -- cleanup handler for that thread will close socket associated
            -- with the thread
            connState <- atomically (readTVar connVar)
            traverse_ cancel (getConnThread connState) )
          state
  where
    countConnections :: ConnectionManagerState peerAddr handle handleError version m
                     -> STM m Int
    countConnections state =
        Map.size
      . Map.filter
              (\connState -> case connState of
                ReservedOutboundState            -> False
                UnnegotiatedState Inbound  _ _ _ -> True
                UnnegotiatedState Outbound _ _ _ -> False
                InboundState {}                  -> True
                OutboundState {}                 -> False
                DuplexState {}                   -> False)
     <$> traverse readTVar state


    -- Start connection thread and run connection handler on it.
    --
    runConnectionHandler :: StrictTMVar m (ConnectionManagerState peerAddr handle handleError version m)
                         -> ConnectionHandlerFn handlerTrace peerAddr handle handleError version m
                         -> Provenance
                         -> socket
                         -> peerAddr
                         -> PromiseWriter m (Either handleError (handle, version))
                         -> m (ConnectionId peerAddr, Async m ())
    runConnectionHandler stateVar handler provenance socket peerAddr writer = do
      localAddress <- getLocalAddr connectionSnocket socket
      let connId = ConnectionId { remoteAddress = peerAddr
                                , localAddress
                                }
      let cleanup =
            modifyTMVar_ stateVar $ \state' -> do
              close connectionSnocket socket
              traceWith tracer (TrConnectionTerminated connId provenance)
              pure $ Map.delete peerAddr state'

      case
        handler
          writer
          (TrConnectionHandler connId `contramap` tracer)
          connId
          (\bearerTimeout ->
            toBearer
              connectionSnocket
              bearerTimeout
              (WithMuxBearer connId `contramap` muxTracer)
              socket) of
        Action action errorHandler -> do
          -- start connection thread
          thread <-
            mask $ \unmask ->
              async $ do
                labelThisThread "connection-handler"
                errorHandler (unmask action `finally` cleanup)
          return ( connId
                 , thread
                 )

    includeInboundConnectionImpl
        :: HasCallStack
        => StrictTMVar m (ConnectionManagerState peerAddr handle handleError version m)
        -> ConnectionHandlerFn handlerTrace peerAddr handle handleError version m
        -> socket
        -- ^ resource to include in the state
        -> peerAddr
        -- ^ remote address used as an identifier of the resource
        -> m (Connected peerAddr handle handleError)
    includeInboundConnectionImpl stateVar
                                 handler
                                 socket
                                 peerAddr = do
        let provenance = Inbound
        (connVar, connId, connThread, reader)
          <- modifyTMVar stateVar $ \state -> do
              (reader, writer) <- newEmptyPromiseIO
              (connId, connThread)
                <- runConnectionHandler stateVar handler
                                        provenance socket peerAddr writer
              traceWith tracer (TrIncludedConnection connId provenance)

              -- This is subtle part, which needs to handle a near simultanous
              -- open.  We cannot relay on 'ReservedOutboundState' state as
              -- a lock.  It may happen that the `includeOutboudConnection`
              -- will put 'ReservedOutboundState', but before it will call `connect`
              -- the `accept` call will return.  Here we allow to overwrite the
              -- state and replace the connection state 'TVar'.  In this case
              -- it is guaranteed that the original will not be used.
              connVar <- newTVarIO (UnnegotiatedState provenance connId connThread reader)
              return ( Map.insert peerAddr connVar state
                     , (connVar, connId, connThread, reader)
                     )
        (tr, connected) <- atomically $ do
          res <- readPromise reader
          case res of
            Left handleError -> do
              modifyTMVarSTM stateVar (Map.delete peerAddr)
              pure ( Nothing
                   , Disconnected connId handleError
                   )
            Right (handle, version) -> do
              let df = connectionDataFlow version
              state <- readTVar connVar
              case state of
                -- Inbound connections cannot be found in this state.
                ReservedOutboundState  -> throwSTM (withCallStack (ImpossibleState peerAddr))

                -- At this stage the inbound connection cannot be in
                -- 'InboundState', it would mean that there was another
                -- thread that included that connection, but this would
                -- violate @TCP@ constraints.
                InboundState {}  -> throwSTM (withCallStack (ImpossibleState peerAddr))

                -- Outbound state is unreachable when we include
                -- a connection.  This is beacuse
                -- `includeOutboundConnection' will use 'DuplexState' if
                -- it is reusing a connection.
                OutboundState {} -> throwSTM (withCallStack (ImpossibleState peerAddr))

                -- There could be a race between outbound and inbound
                -- threads both awaiting for handshake.  If that would
                -- happen the outbound thread would see
                -- 'UnnegotiatedState' and would block on the same stm
                -- transaction.
                s@DuplexState {} -> writeTVar connVar s

                -- The common case.
                UnnegotiatedState {} ->
                  writeTVar connVar
                            (InboundState connId connThread handle
                              (connectionDataFlow version))

              pure ( Just (TrNegotiatedConnection connId provenance df)
                   , Connected connId handle
                   )
        traverse_ (traceWith tracer) tr
        return connected

    unregisterInboundConnectionImpl
        :: StrictTMVar m (ConnectionManagerState peerAddr handle handleError version m)
        -> peerAddr
        -> m Bool
    unregisterInboundConnectionImpl stateVar peerAddr =
      modifyTMVar stateVar $ \state ->
        case Map.lookup peerAddr state of
          Nothing -> pure ( state, True )
          Just connVar -> do
            a <-
              atomically $ do
                connState <- readTVar connVar
                case connState of
                  -- In any of the following two states unregistering is not
                  -- supported.  'includeInboundConnection' is a synchronous
                  -- opeartion which returns only once the connection is
                  -- negotiated.
                  ReservedOutboundState ->
                    throwSTM (withCallStack (ForbiddenOperation peerAddr InReservedOutboundState))
                  UnnegotiatedState {} ->
                    throwSTM (withCallStack (ForbiddenOperation peerAddr InUnnegotiatedState))
                  OutboundState {} ->
                    throwSTM (withCallStack (ForbiddenOperation peerAddr InUnnegotiatedState))

                  InboundState _peerAddr thread _handle _dataFlow -> do
                    return (Just thread)
                  DuplexState {} -> 
                    return Nothing
            case a of
              Just thread -> do
                cancel thread
                return ( Map.delete peerAddr state, True )
              Nothing ->
                return ( state, False )


    includeOutboundConnectionImpl
        :: HasCallStack
        => StrictTMVar m (ConnectionManagerState peerAddr handle handleError version m)
        -> ConnectionHandlerFn handlerTrace peerAddr handle handleError version m
        -> peerAddr
        -> m (Connected peerAddr handle handleError)
    includeOutboundConnectionImpl stateVar handler peerAddr = do
        let provenance = Outbound
        (connVar, handleWedge) <-
          modifyTMVar stateVar $ \state ->
            case Map.lookup peerAddr state of
              Just connVar -> do
                connState <- atomically (readTVar connVar)
                case connState of
                  ReservedOutboundState -> do
                    traceWith tracer (TrConnectionExists peerAddr provenance)
                    throwIO (withCallStack (ConnectionExists peerAddr provenance))

                  UnnegotiatedState Outbound _connId _connThread _reader -> do
                    traceWith tracer (TrConnectionExists peerAddr provenance)
                    throwIO (withCallStack (ConnectionExists peerAddr provenance))

                  UnnegotiatedState Inbound connId _connThread reader -> do
                    pure ( state
                         , (connVar, There (connId, reader))
                         )

                  OutboundState _connId _connThread _handle -> do
                    traceWith tracer (TrConnectionExists peerAddr provenance)
                    throwIO (withCallStack (ConnectionExists peerAddr provenance))

                  InboundState connId _connThread handle Duplex -> do
                    pure ( state
                         , (connVar, Here (connId, handle))
                         )

                  InboundState connId _connThread _handle Unidirectional -> do
                    -- the remote side negotiated unidirectional connection, we
                    -- cannot re-use it.
                    traceWith tracer (TrForbiddenConnection connId)
                    throwIO (withCallStack (ForbiddenConnection connId))

                  DuplexState connId _connThread  _handle -> do
                    throwIO (withCallStack (ImpossibleConnection connId))

              Nothing -> do
                connVar <- newTVarIO ReservedOutboundState
                pure ( Map.insert peerAddr
                                  connVar
                                  state
                     , (connVar, Nowhere)
                     )

        case handleWedge of
          -- connection manager does not have a connection with @peerAddr@.
          Nowhere -> do
            bracketOnError
              (openToConnect connectionSnocket peerAddr)
              (\socket -> do
                  close connectionSnocket socket
                  atomically $ modifyTMVarSTM stateVar (Map.delete peerAddr)
              )
              $ \socket -> do
                (reader, writer) <- newEmptyPromiseIO
                traceWith tracer (TrConnectionNotFound peerAddr provenance)
                addr <-
                  case connectionManagerAddressType peerAddr of
                    Nothing -> pure Nothing
                    Just IPv4Address ->
                         traverse_ (bind connectionSnocket socket)
                                   connectionManagerIPv4Address
                      $> connectionManagerIPv4Address
                    Just IPv6Address ->
                         traverse_ (bind connectionSnocket socket)
                                   connectionManagerIPv6Address
                      $> connectionManagerIPv6Address
                traceWith tracer (TrConnect addr peerAddr)
                connect connectionSnocket socket peerAddr
                  `catch` \e -> traceWith tracer (TrConnectError addr peerAddr e)
                             -- the handler attached by `bracketOnError` will
                             -- clear the state
                             >> throwIO e

                (connId, connThread)
                  <- runConnectionHandler stateVar handler
                                          provenance socket
                                          peerAddr writer
                traceWith tracer (TrIncludedConnection connId provenance)
                (tr, connected) <- atomically $ do
                  res <- readPromise reader
                  case res of
                    Left handleError -> do
                      modifyTMVarSTM stateVar (Map.delete peerAddr)
                      pure ( Nothing
                           , Disconnected connId handleError
                           )

                    Right (handle, version) -> do
                      let df = connectionDataFlow version
                          connState =
                            case df of
                              Unidirectional -> OutboundState connId connThread handle
                              Duplex         -> DuplexState   connId connThread handle

                      writeTVar connVar connState
                      pure ( Just (TrNegotiatedConnection connId provenance df)
                           , Connected connId handle
                           )
                traverse_ (traceWith tracer) tr
                return connected

          There (connId, reader) -> do
            -- We can only enter the 'There' case if there is an inbound
            -- connection, and we are about to reuse it.
            (tr, connected) <- atomically $ do
              res <- readPromise reader
              case res of
                Left handleError -> do
                  modifyTMVarSTM stateVar (Map.delete peerAddr)
                  pure ( Nothing
                       , Right (Disconnected connId handleError)
                       )

                Right (handle, version) ->
                  case connectionDataFlow version of
                    Unidirectional ->
                      pure ( Just (TrForbiddenConnection connId)
                           , Left (ForbiddenConnection connId callStack)
                           )
                    Duplex -> do
                      modifyTVarOrThrow connVar (alterState connId handle)
                      pure ( Just (TrReusedConnection connId)
                           , Right (Connected connId handle)
                           )
            traverse_ (traceWith tracer) tr
            either throwIO pure connected

          -- Connection manager has a connection which can be reused.
          Here (connId, handle) -> do
            traceWith tracer (TrReusedConnection connId)
            atomically $ modifyTVarOrThrow connVar (alterState connId handle)
            pure (Connected connId handle)
      where
        -- | Alter state once we know that the connection is utilised in duplex
        -- mode. The 'Left' case always returns 'ImpossibleState'.  At the call
        -- site of 'alterState' these states are indeed impossible.  This means
        -- we can safely throw this exception and we do not need to update
        -- 'stateVar'.
        alterState :: HasCallStack
                   => ConnectionId peerAddr
                   -> handle
                   -> ConnectionState peerAddr handle handleError version m
                   -> Either (ConnectionManagerError peerAddr)
                             (ConnectionState peerAddr handle handleError version m)
        alterState connId handle state =
          case state of
            -- connecting state is impossible at this stage,
            -- since we've already seen 'UnnegotiatedState'.
            ReservedOutboundState ->
              Left (withCallStack (ImpossibleState (remoteAddress connId)))

            -- There was a race between inbound and
            -- outbound threads, which we won.  We put the
            -- conection directly intoo 'DuplexState'.
            UnnegotiatedState _ _ connThread _ ->
              Right (DuplexState connId connThread handle)

            -- There can only be one thread that includes
            -- outbound connection and we havent put it,
            -- this is certainly impossible.
            OutboundState {} ->
              Left (withCallStack (ImpossibleState (remoteAddress connId)))

            -- 'UnidirectionDataFlow' is in contradiction
            -- with 'Duplex just above.  This is
            -- impossible as 'version' avaialbe in this
            -- thread must be the same as the one that was
            -- used to compute the data flow below:
            InboundState _ _ _ Unidirectional ->
              Left (withCallStack (ImpossibleState (remoteAddress connId)))

            -- we are reusing a connection
            InboundState _ connThread _ Duplex ->
              Right (DuplexState connId connThread handle)

            -- this is impossible in the same way as
            -- 'OutboundState' above.
            DuplexState {} ->
              Left (withCallStack (ImpossibleState (remoteAddress connId)))


    unregisterOutboundConnectionImpl
        :: StrictTMVar m (ConnectionManagerState peerAddr handle handleError version m)
        -> peerAddr
        -> m ()
    unregisterOutboundConnectionImpl stateVar peerAddr =
      modifyTMVar stateVar $ \state ->
        case Map.lookup peerAddr state of
          -- if the connection errored, it will remove itself from the state.
          -- Calling 'unregisterOutboundConnection' is a no-op in this case.
          Nothing -> pure ( state, () )

          Just connVar -> do
            a <- atomically $ do
              connState <- readTVar connVar
              case connState of
                -- In any of the following three states unregistering is not
                -- supported.  'includeOutboundConnection' is a synchronous
                -- opeartion which returns only once the connection is
                -- negotiated.
                ReservedOutboundState ->
                  throwSTM (withCallStack (ForbiddenOperation peerAddr InReservedOutboundState))
                UnnegotiatedState {} ->
                  throwSTM (withCallStack (ForbiddenOperation peerAddr InUnnegotiatedState))
                InboundState _peerAddr _thread _handle _dataFlow ->
                  throwSTM (withCallStack (ForbiddenOperation peerAddr InInboundState))

                OutboundState _connId thread _handle ->
                  return (Left thread)
                DuplexState connId thread handle -> do
                  writeTVar connVar (InboundState connId thread handle Duplex)
                  numberOfConnections <- countConnections state
                  connectionManagerAddressType
                  return (Right (TrConnectionDemoted connId))
            case a of
              Left thread -> do
                --  This triggers an action which will close the socket and log
                --  'TrConnectionTerminated'.
                cancel thread
                return ( Map.delete peerAddr state, () )

              Right tr -> do
                traceWith tracer tr
                return ( state, () )


    isInDuplexStateImpl
        :: StrictTMVar m (ConnectionManagerState peerAddr handle handleError version m)
        -> peerAddr
        -> STM m (IsInDuplexState m)
    isInDuplexStateImpl stateVar peerAddr = do
      state <- readTMVar stateVar
      case Map.lookup peerAddr state of

        Nothing ->
          throwSTM (withCallStack (UnknownPeer peerAddr))
        Just connVar -> do
          connState <- readTVar connVar
          case connState of
            -- All four states 'ReservedOutboundState', 'UnnegotiatedState'
            -- (with any provenance) and 'OutboundStates' are forbidden.
            ReservedOutboundState ->
              throwSTM (withCallStack (ForbiddenOperation peerAddr InReservedOutboundState))
            UnnegotiatedState {} ->
              throwSTM (withCallStack (ForbiddenOperation peerAddr InUnnegotiatedState))
            OutboundState {} ->
              throwSTM (withCallStack (ForbiddenOperation peerAddr InOutboundState))

            DuplexState {} ->
              return InDuplexState

            InboundState _ _ _ Unidirectional -> 
              -- duplex state will never be reached, 'DataFlow' is a property of
              -- a connection.
              pure (AwaitForDuplexState retry)

            InboundState _ _ _ Duplex ->
              pure (AwaitForDuplexState $ do
                      connState' <- readTVar connVar
                      case connState' of
                        DuplexState {} -> return ()
                        _              -> retry)



      

--
-- Utils
--


--
-- Utils to update stm variables.
--


-- | Like 'modifyTVar' but allows to run stm in the update function.  This is
-- only used to throw exceptions.
--
modifyTVarOrThrow
  :: (MonadSTM m, MonadThrow (STM m), Exception e, HasCallStack)
  => StrictTVar m a
  -> (a -> Either e a)
  -> STM m ()
modifyTVarOrThrow m k =
    readTVar m >>= either throwIO pure . k >>= writeTVar m


-- | Like 'modifyMVar_' but strict
--
modifyTMVar_ :: ( MonadSTM  m
                , MonadMask m
                )
             => StrictTMVar m a -> (a -> m a) -> m ()
modifyTMVar_ m io =
    mask $ \unmask -> do
      a <- atomically (takeTMVar m)
      a' <- unmask (io a) `onException` atomically (putTMVar m a)
      atomically (putTMVar m a')


-- | Like 'modifyMVar' but strict in @a@ and for 'TMVar's
--
modifyTMVar :: ( MonadEvaluate m
               , MonadMask     m
               , MonadSTM      m
               )
            => StrictTMVar m a
            -> (a -> m (a, b))
            -> m b
modifyTMVar m k =
  mask $ \restore -> do
    a      <- atomically (takeTMVar m)
    (!a',b) <- restore (k a >>= evaluate) `onException` atomically (putTMVar m a)
    atomically (putTMVar m a')
    return b


-- | Like 'modifyMVar' but not leaving @'STM' m@ monad.
--
modifyTMVarSTM :: MonadSTM m
               => StrictTMVar m a
               -> (a -> a)
               -> STM m ()
modifyTMVarSTM m k = takeTMVar m >>= putTMVar m . k
