{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
module Ouroboros.Consensus.Node.Run.Mock () where

import           Codec.Serialise (Serialise, decode, encode)
import           Data.Time.Calendar (fromGregorian)
import           Data.Time.Clock (UTCTime (..))
import           Data.Typeable (Typeable)

import           Ouroboros.Network.Magic (NetworkMagic (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.BlockchainTime (SystemStart (..))
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Mock
import           Ouroboros.Consensus.Ledger.Mock.Run
import           Ouroboros.Consensus.Node.Run.Abstract

{-------------------------------------------------------------------------------
  RunNode instance for the mock ledger
-------------------------------------------------------------------------------}

instance ( ProtocolLedgerView (SimpleBlock SimpleMockCrypto ext)
           -- The below constraint seems redundant but is not! When removed,
           -- some of the tests loop, but only when compiled with @-O2@ ; with
           -- @-O0@ it is perfectly fine. ghc bug?!
         , SupportedBlock (SimpleBlock SimpleMockCrypto ext)
         , Typeable ext
         , Serialise ext
         , RunMockBlock (BlockProtocol (SimpleBlock SimpleMockCrypto ext))
                        SimpleMockCrypto
                        ext
         ) => RunNode (SimpleBlock SimpleMockCrypto ext) where
  nodeForgeBlock          = forgeSimple
  nodeBlockMatchesHeader  = matchesSimpleHeader
  nodeBlockFetchSize      = fromIntegral . simpleBlockSize . simpleHeaderStd
  nodeIsEBB               = const Nothing
  nodeEpochSize           = \_ _ _ -> return 100
  nodeStartTime           = \_ _ -> SystemStart dummyDate
    where
      --  This doesn't matter much
      dummyDate = UTCTime (fromGregorian 2019 8 13) 0
  nodeNetworkMagic        = \_ _ -> NetworkMagic 0x0000ffff

  nodeProtocolMagicId     = const mockProtocolMagicId
  nodeHashInfo            = const simpleBlockHashInfo

  nodeEncodeBlockWithInfo = const simpleBlockBinaryInfo
  nodeEncodeHeader        = const encode
  nodeEncodeGenTx         =       encode
  nodeEncodeGenTxId       =       encode
  nodeEncodeHeaderHash    = const encode
  nodeEncodeLedgerState   = const encode
  nodeEncodeChainState    = const mockEncodeChainState
  nodeEncodeApplyTxError  = const encode

  nodeDecodeBlock         = const (const <$> decode)
  nodeDecodeHeader        = const (const <$> decode)
  nodeDecodeGenTx         =       decode
  nodeDecodeGenTxId       =       decode
  nodeDecodeHeaderHash    = const decode
  nodeDecodeLedgerState   = const decode
  nodeDecodeChainState    = const mockDecodeChainState
  nodeDecodeApplyTxError  = const decode
