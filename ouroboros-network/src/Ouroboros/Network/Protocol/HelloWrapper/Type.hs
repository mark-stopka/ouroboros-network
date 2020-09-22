{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE EmptyCase             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE InstanceSigs          #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

module Ouroboros.Network.Protocol.HelloWrapper.Type where

import           Data.Void (Void)

import           Network.TypedProtocol.Core
import           Ouroboros.Network.Util.ShowProxy


-- | 'Hello' is a protocol transformer.  It allows to transform a protocol
-- which initial state is 'stIdle' (in which the agancy might be held by
-- either side), to a protocol with initial state is 'StIdle' in which the
-- client has agancy.  It adds a 'MsgHello' which is a transition from 'StIdle'
-- to @'StEmbedded' stIdle@.
--
data Hello ps (stIdle :: ps) where
    -- | 'StIdle' state is the initial state of the 'Hello' protocol.
    --
    StIdle  :: Hello ps stIdle

    -- | 'StEmbedded' embeds states of the inner protocol.
    --
    StEmbedded :: ps -> Hello ps stIdle

instance (ShowProxy ps, ShowProxy stIdle) => ShowProxy (Hello ps (stIdle :: ps)) where
    showProxy _ = "Hello "
               ++ showProxy (Proxy :: Proxy ps)
               ++ " "
               ++ showProxy (Proxy :: Proxy stIdle)



instance Protocol ps => Protocol (Hello ps stIdle) where
    data Message (Hello ps stIdle) from to where
      MsgHello :: Message (Hello ps stIdle) StIdle (StEmbedded st)

      MsgEmbedded :: Message ps stInner stInner'
                  -> Message (Hello ps stIdle) (StEmbedded stInner) (StEmbedded stInner')


    data ClientHasAgency (st :: Hello ps stIdle) where
      TokIdle        :: ClientHasAgency StIdle

      TokClientInner :: ClientHasAgency stInner
                     -> ClientHasAgency (StEmbedded stInner)


    data ServerHasAgency (st :: Hello ps stIdle) where
      TokServerInner :: ServerHasAgency stInner
                     -> ServerHasAgency (StEmbedded stInner)


    data NobodyHasAgency (st :: Hello ps stIdle) where
      TokDone :: NobodyHasAgency stInner
              -> NobodyHasAgency (StEmbedded stInner)


    exclusionLemma_ClientAndServerHaveAgency
      :: forall (st :: Hello ps stIdle).
         ClientHasAgency st
      -> ServerHasAgency st
      -> Void
    exclusionLemma_ClientAndServerHaveAgency TokIdle tok = case tok of {}
    exclusionLemma_ClientAndServerHaveAgency (TokClientInner tokClient)
                                             (TokServerInner tokServer) =
      exclusionLemma_ClientAndServerHaveAgency tokClient tokServer


    exclusionLemma_NobodyAndClientHaveAgency
      :: forall (st :: Hello ps stIdle).
         NobodyHasAgency st
      -> ClientHasAgency st
      -> Void
    exclusionLemma_NobodyAndClientHaveAgency (TokDone tokDone)
                                             (TokClientInner tokClient) =
      exclusionLemma_NobodyAndClientHaveAgency tokDone tokClient


    exclusionLemma_NobodyAndServerHaveAgency
      :: forall (st :: Hello ps stIdle).
         NobodyHasAgency st
      -> ServerHasAgency st
      -> Void
    exclusionLemma_NobodyAndServerHaveAgency (TokDone tokDone)
                                             (TokServerInner tokServer) =
      exclusionLemma_NobodyAndServerHaveAgency tokDone tokServer


instance (forall (from' :: ps) (to' :: ps). Show (Message ps from' to'))
      => Show (Message (Hello ps stIdle) from to) where
    show MsgHello = "MsgHello"
    show (MsgEmbedded msg) = show msg

instance (forall (stInner :: ps). Show (ClientHasAgency stInner))
      => Show (ClientHasAgency (st :: Hello ps (stIdle :: ps))) where
    show TokIdle = "TokIdle"
    show (TokClientInner tokInner) = "TokClientInner " ++ show tokInner

instance (forall (stInner :: ps). Show (ServerHasAgency stInner))
      => Show (ServerHasAgency (st :: Hello ps stIdle)) where
    show (TokServerInner tokInner) = "TokServerInner " ++ show tokInner


-- | Wrap a client 'Peer' for 'ps' protocol into @'Hello' ps stIdle@.
--
wrapClientPeer :: forall ps (stIdle :: ps) m a.
                  Functor m
               => Peer ps AsClient stIdle m a
               -> Peer (Hello ps stIdle) AsClient StIdle m a
wrapClientPeer peer = Yield (ClientAgency TokIdle) MsgHello (embedPeer peer)


-- | Embed either a client or a server 'Peer' for 'ps' protocol into @'Hello'
-- ps stIdle@.
--
embedPeer :: forall ps (pr :: PeerRole) (stIdle :: ps) (st :: ps) m a.
             Functor m
          => Peer        ps         pr             st  m a
          -> Peer (Hello ps stIdle) pr (StEmbedded st) m a
embedPeer (Effect m) = Effect (embedPeer <$> m)
embedPeer (Done tok a) = Done (TokDone tok) a
embedPeer (Yield (ClientAgency tok) msg peer) =
  Yield (ClientAgency (TokClientInner tok)) (MsgEmbedded msg) (embedPeer peer)
embedPeer (Yield (ServerAgency tok) msg peer) =
  Yield (ServerAgency (TokServerInner tok)) (MsgEmbedded msg) (embedPeer peer)
embedPeer (Await (ServerAgency tok) next) =
  Await (ServerAgency (TokServerInner tok)) (\(MsgEmbedded msg) -> embedPeer (next msg))
embedPeer (Await (ClientAgency tok) next) =
  Await (ClientAgency (TokClientInner tok)) (\(MsgEmbedded msg) -> embedPeer (next msg))
