{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE NamedFieldPuns           #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TypeApplications         #-}
module Test.Consensus.Shelley.Ledger.Golden (
    tests
  , mkDummyHash
  ) where

import           Codec.CBOR.FlatTerm (FlatTerm, TermToken (..))
import           Data.Coerce (coerce)
import           Data.Functor.Identity (Identity (..))
import qualified Data.Map.Strict as Map
import           Data.Proxy (Proxy (..))
import qualified Data.Set as Set
import           Data.Time (UTCTime (..), fromGregorian)

import           Cardano.Binary (toCBOR)
import           Cardano.Crypto (ProtocolMagicId (..))
import           Cardano.Slotting.EpochInfo

import           Ouroboros.Network.Block (Point (..), blockHash, genesisPoint)
import           Ouroboros.Network.Magic (NetworkMagic (..))
import           Ouroboros.Network.Point (WithOrigin (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Extended
import           Ouroboros.Consensus.Mempool.API
import           Ouroboros.Consensus.Protocol.Abstract

import           Shelley.Spec.Ledger.BaseTypes (StrictMaybe (..))
import qualified Shelley.Spec.Ledger.BaseTypes as SL
import qualified Shelley.Spec.Ledger.BlockChain as SL
import qualified Shelley.Spec.Ledger.Credential as SL
import qualified Shelley.Spec.Ledger.Crypto as SL
import qualified Shelley.Spec.Ledger.Delegation.Certificates as SL
import qualified Shelley.Spec.Ledger.Keys as SL
import qualified Shelley.Spec.Ledger.PParams as SL
import qualified Shelley.Spec.Ledger.STS.Chain as STS
import qualified Shelley.Spec.Ledger.STS.Ledger as STS
import qualified Shelley.Spec.Ledger.STS.Prtcl as STS
import           Test.Shelley.Spec.Ledger.ConcreteCryptoTypes (ConcreteCrypto,
                     hashKeyVRF)
import qualified Test.Shelley.Spec.Ledger.Examples as Examples
import qualified Test.Shelley.Spec.Ledger.Utils as SL (testGlobals)

import           Ouroboros.Consensus.Shelley.Genesis
import           Ouroboros.Consensus.Shelley.Ledger
import qualified Ouroboros.Consensus.Shelley.Ledger.History as History
import           Ouroboros.Consensus.Shelley.Protocol.State (TPraosState)
import qualified Ouroboros.Consensus.Shelley.Protocol.State as TPraosState

import           Test.Tasty
import           Test.Tasty.HUnit

import           Test.Util.Golden
import           Test.Util.Orphans.Arbitrary ()

import           Test.Cardano.Crypto.VRF.Fake (VerKeyVRF (..))

import           Test.Consensus.Shelley.MockCrypto (TPraosMockCrypto)

tests :: TestTree
tests = testGroup "Golden tests"
    [ testCase "Block"          test_golden_Block
    , testCase "Header"         test_golden_Header
    , testCase "HeaderHash"     test_golden_HeaderHash
    , testCase "GenTx"          test_golden_GenTx
    , testCase "GenTxId"        test_golden_GenTxId
    , testCase "ApplyTxErr"     test_golden_ApplyTxErr
    , testCase "ConsensusState" test_golden_ConsensusState
    , testCase "LedgerState"    test_golden_LedgerState
    , testCase "HeaderState"    test_golden_HeaderState
    , testCase "ExtLedgerState" test_golden_ExtLedgerState
    , testQueries
    , testResults
    ]

type Block = ShelleyBlock TPraosMockCrypto

testQueries :: TestTree
testQueries = testGroup "Queries"
    [ testCase "LedgerTip"
        $ goldenTestQuery GetLedgerTip tipTerm
    , testCase "EpochNo"
        $ goldenTestQuery GetEpochNo echoNoTerm
    , testCase "NonMyopicMemberRewards"
        $ goldenTestQuery queryNonMyopicMemberRewards nonMyopicMemberRewardsTerm
    , testCase "CurrentPParams"
        $ goldenTestQuery GetCurrentPParams currentPParamsTerm
    , testCase "ProposedPParamsUpdates"
        $ goldenTestQuery GetProposedPParamsUpdates proposedPParamsUpdatesTerm
    , testCase "StakeDistribution"
        $ goldenTestQuery GetStakeDistribution stakeDistributionTerm
    ]
  where
    tipTerm, echoNoTerm, nonMyopicMemberRewardsTerm, currentPParamsTerm :: FlatTerm
    proposedPParamsUpdatesTerm, stakeDistributionTerm :: FlatTerm

    tipTerm =
      [ TkListLen 1
      , TkInt 0
      ]

    echoNoTerm =
      [ TkListLen 1
      , TkInt 1
      ]

    nonMyopicMemberRewardsTerm =
      [ TkListLen 2
      , TkInt 2
      , TkTag 258
      , TkListLen 1
      , TkListLen 2
      , TkInt 0
      , TkBytes "}\234\&6+"
      ]

    currentPParamsTerm =
      [ TkListLen 1
      , TkInt 3
      ]

    proposedPParamsUpdatesTerm =
      [ TkListLen 1
      , TkInt 4
      ]

    stakeDistributionTerm =
      [ TkListLen 1
      , TkInt 5
      ]

    queryNonMyopicMemberRewards
      :: Query Block (NonMyopicMemberRewards TPraosMockCrypto)
    queryNonMyopicMemberRewards =
      GetNonMyopicMemberRewards $ Set.singleton $
        (SL.KeyHashObj . SL.hashKey . SL.vKey) $ SL.KeyPair 0 0

    goldenTestQuery :: Query Block result -> FlatTerm -> Assertion
    goldenTestQuery = goldenTestCBOR encodeShelleyQuery

testResults :: TestTree
testResults = testGroup "Results"
    [ testCase "LedgerTip"
        $ goldenTestResult GetLedgerTip (Point Origin) [TkListLen 0]
    , testCase "EpochNo"
        $ goldenTestResult GetEpochNo 0 [TkInt 0]
    , testCase "NonMyopicMemberRewards"
        $ goldenTestResult (GetNonMyopicMemberRewards Set.empty) nonMyopicMemberRewards [TkMapLen 0]
    , testCase "CurrentPParams"
        $ goldenTestResult GetCurrentPParams currentPParams currentPParamsTerm
    , testCase "ProposedPParamsUpdates"
        $ goldenTestResult GetProposedPParamsUpdates proposedPParamsUpdates proposedPParamsUpdatesTerm
    , testCase "StakeDistribution"
        $ goldenTestResult GetStakeDistribution stakeDistribution stakeDistributionTerm
    ]
  where
    nonMyopicMemberRewards :: (NonMyopicMemberRewards TPraosMockCrypto)
    nonMyopicMemberRewards = NonMyopicMemberRewards Map.empty

    currentPParams :: SL.PParams
    currentPParams = SL.emptyPParams

    proposedPParamsUpdates :: SL.ProposedPPUpdates TPraosMockCrypto
    proposedPParamsUpdates = SL.ProposedPPUpdates $ Map.singleton
      (SL.hashKey 0)
      (SL.PParams
        { _minfeeA         = SNothing
        , _minfeeB         = SNothing
        , _maxBBSize       = SNothing
        , _maxTxSize       = SNothing
        , _maxBHSize       = SNothing
        , _keyDeposit      = SJust 100
        , _keyMinRefund    = SNothing
        , _keyDecayRate    = SNothing
        , _poolDeposit     = SNothing
        , _poolMinRefund   = SNothing
        , _poolDecayRate   = SNothing
        , _eMax            = SNothing
        , _nOpt            = SNothing
        , _a0              = SNothing
        , _rho             = SNothing
        , _tau             = SNothing
        , _d               = SNothing
        , _extraEntropy    = SNothing
        , _protocolVersion = SNothing
        , _minUTxOValue    = SNothing
        })

    stakeDistribution :: SL.PoolDistr TPraosMockCrypto
    stakeDistribution = SL.PoolDistr $ Map.singleton
      (SL.KeyHash $ SL.hash 0)
      (1, hashKeyVRF $ VerKeyFakeVRF 0)

    currentPParamsTerm :: FlatTerm
    currentPParamsTerm =
      [ TkListLen 21
      , TkInt 0
      , TkInt 0
      , TkInt 0
      , TkInt 2048
      , TkInt 0
      , TkInt 0
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkInt 0
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkInt 0
      , TkInt 100
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkListLen 1
      , TkInt 0
      , TkInt 0
      , TkInt 0
      , TkInt 0
      ]

    proposedPParamsUpdatesTerm :: FlatTerm
    proposedPParamsUpdatesTerm =
      [ TkMapLen 1
      , TkBytes "}\234\&6+"
      , TkMapLen 1
      , TkInt 5
      , TkInt 100
      ]

    stakeDistributionTerm :: FlatTerm
    stakeDistributionTerm =
      [ TkMapLen 1
      , TkBytes "\247\223\&4\142"
      , TkListLen 2
      , TkListLen 2
      , TkInt 1
      , TkInt 1
      , TkBytes "}\234\&6+"
      ]

    goldenTestResult :: Query Block result -> result -> FlatTerm -> Assertion
    goldenTestResult q = goldenTestCBOR (encodeShelleyResult q)

exampleBlock :: Block
exampleBlock = mkShelleyBlock Examples.blockEx3B

exampleGenTx :: GenTx Block
exampleGenTx = mkShelleyTx Examples.txEx2A

test_golden_Block :: Assertion
test_golden_Block = goldenTestCBOR
    toCBOR
    exampleBlock
    [ TkListLen 4
    , TkListLen 2
    , TkListLen 15
    , TkInt 2
    , TkInt 20
    , TkBytes "\191|nI"
    , TkBytes "16260160"
    , TkBytes "16260160"
    , TkListLen 2
    , TkInt 2
    , TkBytes "16260160\245N"
    , TkListLen 2
    , TkInt 0
    , TkBytes "16260160q\SYN"
    , TkInt 208
    , TkBytes "\211W9O"
    , TkBytes "16260160"
    , TkInt 0
    , TkInt 0
    , TkBytes "\ETX\148G\SO16260160"
    , TkInt 0
    , TkInt 0
    , TkBytes "fh\ACK\135o\180w\134\DC3.\146pK\223\129\193\&16260160\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH"
    , TkListLen 1
    , TkMapLen 5
    , TkInt 0
    , TkListLen 1
    , TkListLen 2
    , TkBytes "-/\249\&7"
    , TkInt 0
    , TkInt 1
    , TkListLen 1
    , TkListLen 2
    , TkBytes "\STX\EOT\140\196$0P\247\158"
    , TkInt 9999999999999998
    , TkInt 2
    , TkInt 1
    , TkInt 3
    , TkInt 31
    , TkInt 6
    , TkListLen 2
    , TkMapLen 2
    , TkBytes "u\197c\227"
    , TkMapLen 2
    , TkInt 8
    , TkInt 200
    , TkInt 17
    , TkListLen 2
    , TkInt 1
    , TkBytes "e\138\176\224\245\253\239\216h\168\232\ENQ\209\SOH\169\140\195Z\181\ETB\233}\243\147q\130\218\fz\243\139="
    , TkBytes "\229\221D\172"
    , TkMapLen 2
    , TkInt 8
    , TkInt 200
    , TkInt 17
    , TkListLen 2
    , TkInt 1
    , TkBytes "e\138\176\224\245\253\239\216h\168\232\ENQ\209\SOH\169\140\195Z\181\ETB\233}\243\147q\130\218\fz\243\139="
    , TkInt 0
    , TkListLen 1
    , TkMapLen 1
    , TkInt 0
    , TkListLen 3
    , TkListLen 2
    , TkBytes "00000214"
    , TkBytes "6\139\GS\DC200000214"
    , TkListLen 2
    , TkBytes "16415019"
    , TkBytes "6\139\GS\DC216415019"
    , TkListLen 2
    , TkBytes "15795584"
    , TkBytes "6\139\GS\DC215795584"
    , TkMapLen 0
    ]

test_golden_Header :: Assertion
test_golden_Header = goldenTestCBOR
    toCBOR
    (getHeader exampleBlock)
    [ TkListLen 2
    , TkListLen 15
    , TkInt 2
    , TkInt 20
    , TkBytes "\191|nI"
    , TkBytes "16260160"
    , TkBytes "16260160"
    , TkListLen 2
    , TkInt 2
    , TkBytes "16260160\245N"
    , TkListLen 2
    , TkInt 0
    , TkBytes "16260160q\SYN"
    , TkInt 208
    , TkBytes "\211W9O"
    , TkBytes "16260160"
    , TkInt 0
    , TkInt 0
    , TkBytes "\ETX\148G\SO16260160"
    , TkInt 0
    , TkInt 0
    , TkBytes "fh\ACK\135o\180w\134\DC3.\146pK\223\129\193\&16260160\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH"
    ]

test_golden_HeaderHash :: Assertion
test_golden_HeaderHash = goldenTestCBOR
    toCBOR
    (blockHash exampleBlock)
    [ TkBytes "=87\168"
    ]

test_golden_GenTx :: Assertion
test_golden_GenTx = goldenTestCBORInCBOR
    toCBOR
    exampleGenTx
    [ TkListLen 3
    , TkMapLen 6
    , TkInt 0
    , TkListLen 1
    , TkListLen 2
    , TkBytes "\157\184\164\ETB"
    , TkInt 0
    , TkInt 1
    , TkListLen 1
    , TkListLen 2
    , TkBytes "\STX\EOT\140\196$0P\247\158"
    , TkInt 9999999999999726
    , TkInt 2
    , TkInt 3
    , TkInt 3
    , TkInt 10
    , TkInt 4
    , TkListLen 5
    , TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "\191\152\145\198"
    , TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkListLen 10
    , TkInt 3
    , TkBytes "0P\247\158"
    , TkBytes "0P\247\158"
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkListLen 1
    , TkBytes "0P\247\158"
    , TkListLen 0
    , TkListLen 2
    , TkString "alice.pool"
    , TkBytes "{}"
    , TkListLen 2
    , TkInt 6
    , TkMapLen 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkInt 110
    , TkListLen 2
    , TkInt 0
    , TkBytes "\144&R("
    , TkInt 99
    , TkInt 6
    , TkListLen 2
    , TkMapLen 1
    , TkBytes "Rsb\139"
    , TkMapLen 1
    , TkInt 5
    , TkInt 255
    , TkInt 0
    , TkMapLen 1
    , TkInt 0
    , TkListLen 8
    , TkListLen 2
    , TkBytes "00000214"
    , TkBytes "9\235\242\239\&00000214"
    , TkListLen 2
    , TkBytes "15485867"
    , TkBytes "9\235\242\239\&15485867"
    , TkListLen 2
    , TkBytes "15640725"
    , TkBytes "9\235\242\239\&15640725"
    , TkListLen 2
    , TkBytes "16260160"
    , TkBytes "9\235\242\239\&16260160"
    , TkListLen 2
    , TkBytes "61943468"
    , TkBytes "9\235\242\239\&61943468"
    , TkListLen 2
    , TkBytes "15950443"
    , TkBytes "9\235\242\239\&15950443"
    , TkListLen 2
    , TkBytes "16105301"
    , TkBytes "9\235\242\239\&16105301"
    , TkListLen 2
    , TkBytes "15795584"
    , TkBytes "9\235\242\239\&15795584"
    , TkNull
    ]

test_golden_GenTxId :: Assertion
test_golden_GenTxId = goldenTestCBOR
    toCBOR
    (txId exampleGenTx)
    [ TkBytes "\253d\142\221" ]

test_golden_ApplyTxErr :: Assertion
test_golden_ApplyTxErr = goldenTestCBOR
    toCBOR
    exampleApplyTxErr
    [ TkListBegin
    , TkListLen 2
    , TkInt 0
    , TkListLen 1
    , TkInt 0
    , TkBreak
    ]
  where
    -- TODO incomplete, this type has tons of constructors that can all
    -- change.
    exampleApplyTxErr :: ApplyTxErr Block
    exampleApplyTxErr =
        ApplyTxError
      $ pure
      $ STS.LedgerFailure
      $ STS.UtxowFailure
      $ STS.InvalidWitnessesUTXOW

test_golden_ConsensusState :: Assertion
test_golden_ConsensusState = goldenTestCBOR
    toCBOR
    exampleConsensusState
    [ TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkMapLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkListLen 6
    , TkMapLen 2
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkBytes "\158h\140X"
    , TkInt 2
    , TkListLen 2
    , TkInt 1
    , TkBytes "U\165@\b"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\bO\237\b\185x\175M}\EMjtF\168kX\NUL\158cka\GS\177b\DC1\182Z\154\173\255)\197"
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 6
    , TkMapLen 2
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkBytes "\158h\140X"
    , TkInt 2
    , TkListLen 2
    , TkInt 1
    , TkBytes "\158h\140X"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\bO\237\b\185x\175M}\EMjtF\168kX\NUL\158cka\GS\177b\DC1\182Z\154\173\255)\197"
    ]
  where
    exampleConsensusState :: ConsensusState (BlockProtocol Block)
    exampleConsensusState =
      TPraosState.append 2      (mkPrtclState 2) $
      TPraosState.empty  (At 1) (mkPrtclState 1)

    mkPrtclState :: Int -> STS.PrtclState TPraosMockCrypto
    mkPrtclState seed = STS.PrtclState
      (Map.fromList
       [ (SL.KeyHash (mkDummyHash (Proxy @TPraosMockCrypto) 1), 1)
       , (SL.KeyHash (mkDummyHash (Proxy @TPraosMockCrypto) 2), 2)
       ])
      (SL.hashHeaderToNonce @TPraosMockCrypto
        (SL.HashHeader (mkDummyHash (Proxy @TPraosMockCrypto) seed)))
      SL.NeutralNonce
      (SL.mkNonce 1)
      (SL.mkNonce 2)
      (SL.mkNonce 3)

test_golden_LedgerState :: Assertion
test_golden_LedgerState = goldenTestCBOR
    encodeShelleyLedgerState
    exampleLedgerState
    [ TkListLen 2
    , TkInt 0
    , TkListLen 3
    , TkListLen 2
    , TkInt 10
    , TkBytes "*d\157H"
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 0
    , TkListLen 7
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 6
    , TkListLen 2
    , TkInt 0
    , TkInt 34000000000000000
    , TkListLen 4
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkInt 0
    , TkListLen 2
    , TkListLen 4
    , TkMapLen 2
    , TkListLen 2
    , TkBytes "\157\184\164\ETB"
    , TkInt 1
    , TkListLen 2
    , TkBytes "\STX\131?\NAK\145\191\152\145\198"
    , TkInt 1000000000000000
    , TkListLen 2
    , TkBytes "\253d\142\221"
    , TkInt 0
    , TkListLen 2
    , TkBytes "\STX\EOT\140\196$0P\247\158"
    , TkInt 9999999999999726
    , TkInt 271
    , TkInt 3
    , TkMapLen 1
    , TkBytes "Rsb\139"
    , TkMapLen 1
    , TkInt 5
    , TkInt 255
    , TkListLen 2
    , TkListLen 7
    , TkMapLen 3
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "\191\152\145\198"
    , TkInt 10
    , TkMapLen 3
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "\191\152\145\198"
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 3
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 1
    , TkListLen 2
    , TkInt 0
    , TkBytes "\191\152\145\198"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkMapLen 0
    , TkMapLen 7
    , TkBytes "\CANg\231\ACK"
    , TkBytes "\CANg\231\ACK"
    , TkBytes "Rsb\139"
    , TkBytes "Rsb\139"
    , TkBytes "u\197c\227"
    , TkBytes "u\197c\227"
    , TkBytes "u\200\129\164"
    , TkBytes "u\200\129\164"
    , TkBytes "\174\134\&0\129"
    , TkBytes "\174\134\&0\129"
    , TkBytes "\203\GS\151\&8"
    , TkBytes "\203\GS\151\&8"
    , TkBytes "\229\221D\172"
    , TkBytes "\229\221D\172"
    , TkMapLen 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkInt 110
    , TkListLen 2
    , TkInt 0
    , TkBytes "\144&R("
    , TkInt 99
    , TkListLen 3
    , TkMapLen 1
    , TkBytes "0P\247\158"
    , TkInt 10
    , TkMapLen 1
    , TkBytes "0P\247\158"
    , TkListLen 9
    , TkBytes "0P\247\158"
    , TkBytes "0P\247\158"
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkListLen 1
    , TkBytes "0P\247\158"
    , TkListLen 0
    , TkListLen 2
    , TkString "alice.pool"
    , TkBytes "{}"
    , TkMapLen 0
    , TkListLen 21
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 500
    , TkInt 250
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 1000
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
    , TkInt 0
    , TkInt 1
    , TkTag 30
    , TkListLen 2
    , TkInt 21
    , TkInt 10000
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 1
    , TkInt 0
    , TkInt 0
    , TkInt 0
    , TkInt 100
    , TkListLen 21
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 500
    , TkInt 250
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 1000
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
     , TkInt 0
     , TkInt 1
     , TkTag 30
     , TkListLen 2
     , TkInt 21
     , TkInt 10000
     , TkTag 30
     , TkListLen 2
     , TkInt 1
     , TkInt 5
     , TkTag 30
     , TkListLen 2
     , TkInt 1
     , TkInt 2
     , TkListLen 1
     , TkInt 0
     , TkInt 0
     , TkInt 0
     , TkInt 100
     , TkListLen 3
     , TkMapLen 0
     , TkInt 0
     , TkListLen 3
     , TkMapLen 0
     , TkMapLen 0
     , TkMapLen 0
     , TkListLen 0
     , TkMapLen 0
     , TkMapLen 7
     , TkBytes "\CANg\231\ACK"
     , TkListBegin
     , TkInt 0
     , TkInt 14
     , TkInt 28
     , TkInt 42
     , TkInt 56
     , TkInt 70
     , TkInt 84
     , TkInt 98
     , TkBreak
     , TkBytes "Rsb\139"
     , TkListBegin
     , TkInt 2
     , TkInt 16
     , TkInt 30
     , TkInt 44
     , TkInt 58
     , TkInt 72
     , TkInt 86
     , TkBreak
     , TkBytes "u\197c\227"
     , TkListBegin
     , TkInt 4
     , TkInt 18
     , TkInt 32
     , TkInt 46
     , TkInt 60
     , TkInt 74
     , TkInt 88
     , TkBreak
     , TkBytes "u\200\129\164"
     , TkListBegin
     , TkInt 6
     , TkInt 20
     , TkInt 34
     , TkInt 48
     , TkInt 62
     , TkInt 76
     , TkInt 90
     , TkBreak
     , TkBytes "\174\134\&0\129"
     , TkListBegin
     , TkInt 8
     , TkInt 22
     , TkInt 36
     , TkInt 50
     , TkInt 64
     , TkInt 78
     , TkInt 92
     , TkBreak
     , TkBytes "\203\GS\151\&8"
     , TkListBegin
     , TkInt 10
     , TkInt 24
     , TkInt 38
     , TkInt 52
     , TkInt 66
     , TkInt 80
     , TkInt 94
     , TkBreak
     , TkBytes "\229\221D\172"
     , TkListBegin
     , TkInt 12
     , TkInt 26
     , TkInt 40
     , TkInt 54
     , TkInt 68
     , TkInt 82
     , TkInt 96
     , TkBreak
     ]

exampleLedgerState :: LedgerState Block
exampleLedgerState = reapplyLedgerBlock
    ledgerCfg
    (mkShelleyBlock newBlock)
    (Ticked 0 ShelleyLedgerState {
        ledgerTip    = genesisPoint
      , history      = History.empty
      , shelleyState = STS.chainNes startState
      })
  where
    Examples.CHAINExample { startState, newBlock } = Examples.ex2A
    ledgerCfg = mkShelleyLedgerConfig testShelleyGenesis testEpochInfo

testEpochInfo :: EpochInfo Identity
testEpochInfo = SL.epochInfo SL.testGlobals

-- | These are dummy values.
testShelleyGenesis :: ShelleyGenesis c
testShelleyGenesis = ShelleyGenesis {
      sgStartTime         = SystemStart $ UTCTime (fromGregorian 2020 5 14) 0
    , sgNetworkMagic      = NetworkMagic 0
    , sgProtocolMagicId   = ProtocolMagicId 0
      -- Chosen to match SL.activeSlotCoeff
    , sgActiveSlotsCoeff  = 0.9
    , sgSecurityParam     = SecurityParam $ SL.securityParameter SL.testGlobals
    , sgEpochLength       = runIdentity $ epochInfoSize testEpochInfo 0
    , sgSlotsPerKESPeriod = SL.slotsPerKESPeriod SL.testGlobals
    , sgMaxKESEvolutions  = SL.maxKESEvo SL.testGlobals
      -- Not important
    , sgSlotLength        = slotLengthFromSec 2
    , sgUpdateQuorum      = SL.quorum  SL.testGlobals
    , sgMaxMajorPV        = SL.maxMajorPV SL.testGlobals
    , sgMaxLovelaceSupply = SL.maxLovelaceSupply SL.testGlobals
    , sgProtocolParams    = SL.emptyPParams
    , sgGenDelegs         = Map.empty
    , sgInitialFunds      = Map.empty
    , sgStaking           = emptyGenesisStaking
    }

test_golden_HeaderState :: Assertion
test_golden_HeaderState = goldenTestCBOR
    encodeShelleyHeaderState
    exampleHeaderState
    [ TkListLen 3
    , TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkMapLen 1
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkListLen 6
    , TkMapLen 1
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkListLen 2
    , TkInt 1
    , TkBytes "U\165@\b"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 0
    , TkListLen 0
    ]

exampleHeaderState :: HeaderState Block
exampleHeaderState = genesisHeaderState st
  where
    prtclState :: STS.PrtclState TPraosMockCrypto
    prtclState = STS.PrtclState
      (Map.fromList
        [(SL.KeyHash (mkDummyHash (Proxy @TPraosMockCrypto) 1), 1)])
      (SL.hashHeaderToNonce @TPraosMockCrypto
        (SL.HashHeader (mkDummyHash (Proxy @TPraosMockCrypto) 1)))
      SL.NeutralNonce
      (SL.mkNonce 1)
      SL.NeutralNonce
      (SL.mkNonce 2)

    st :: TPraosState ConcreteCrypto
    st = TPraosState.empty (At 1) prtclState

test_golden_ExtLedgerState :: Assertion
test_golden_ExtLedgerState = goldenTestCBOR
    encodeShelleyExtLedgerState
    exampleExtLedgerState
    [ TkListLen 2
    , TkInt 0
    , TkListLen 3
    , TkListLen 2
    , TkInt 10
    , TkBytes "*d\157H"
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 0
    , TkListLen 7
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 6
    , TkListLen 2
    , TkInt 0
    , TkInt 34000000000000000
    , TkListLen 4
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkInt 0
    , TkListLen 2
    , TkListLen 4
    , TkMapLen 2
    , TkListLen 2
    , TkBytes "\157\184\164\ETB"
    , TkInt 1
    , TkListLen 2
    , TkBytes "\STX\131?\NAK\145\191\152\145\198"
    , TkInt 1000000000000000
    , TkListLen 2
    , TkBytes "\253d\142\221"
    , TkInt 0
    , TkListLen 2
    , TkBytes "\STX\EOT\140\196$0P\247\158"
    , TkInt 9999999999999726
    , TkInt 271
    , TkInt 3
    , TkMapLen 1
    , TkBytes "Rsb\139"
    , TkMapLen 1
    , TkInt 5
    , TkInt 255
    , TkListLen 2
    , TkListLen 7
    , TkMapLen 3
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "\191\152\145\198"
    , TkInt 10
    , TkMapLen 3
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "\191\152\145\198"
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 3
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 1
    , TkListLen 2
    , TkInt 0
    , TkBytes "\191\152\145\198"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkMapLen 0
    , TkMapLen 7
    , TkBytes "\CANg\231\ACK"
    , TkBytes "\CANg\231\ACK"
    , TkBytes "Rsb\139"
    , TkBytes "Rsb\139"
    , TkBytes "u\197c\227"
    , TkBytes "u\197c\227"
    , TkBytes "u\200\129\164"
    , TkBytes "u\200\129\164"
    , TkBytes "\174\134\&0\129"
    , TkBytes "\174\134\&0\129"
    , TkBytes "\203\GS\151\&8"
    , TkBytes "\203\GS\151\&8"
    , TkBytes "\229\221D\172"
    , TkBytes "\229\221D\172"
    , TkMapLen 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\ACK7\193<"
    , TkInt 110
    , TkListLen 2
    , TkInt 0
    , TkBytes "\144&R("
    , TkInt 99
    , TkListLen 3
    , TkMapLen 1
    , TkBytes "0P\247\158"
    , TkInt 10
    , TkMapLen 1
    , TkBytes "0P\247\158"
    , TkListLen 9
    , TkBytes "0P\247\158"
    , TkBytes "0P\247\158"
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "0P\247\158"
    , TkListLen 1
    , TkBytes "0P\247\158"
    , TkListLen 0
    , TkListLen 2
    , TkString "alice.pool"
    , TkBytes "{}"
    , TkMapLen 0
    , TkListLen 21
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 500
    , TkInt 250
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 1000
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
    , TkInt 0
    , TkInt 1
    , TkTag 30
    , TkListLen 2
    , TkInt 21
    , TkInt 10000
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 1
    , TkInt 0
    , TkInt 0
    , TkInt 0
    , TkInt 100
    , TkListLen 21
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 500
    , TkInt 250
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 1000
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
    , TkInt 0
    , TkInt 1
    , TkTag 30
    , TkListLen 2
    , TkInt 21
    , TkInt 10000
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 1
    , TkInt 0
    , TkInt 0
    , TkInt 0
    , TkInt 100
    , TkListLen 3
    , TkMapLen 0
    , TkInt 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 0
    , TkMapLen 0
    , TkMapLen 7
    , TkBytes "\CANg\231\ACK"
    , TkListBegin
    , TkInt 0
    , TkInt 14
    , TkInt 28
    , TkInt 42
    , TkInt 56
    , TkInt 70
    , TkInt 84
    , TkInt 98
    , TkBreak
    , TkBytes "Rsb\139"
    , TkListBegin
    , TkInt 2
    , TkInt 16
    , TkInt 30
    , TkInt 44
    , TkInt 58
    , TkInt 72
    , TkInt 86
    , TkBreak
    , TkBytes "u\197c\227"
    , TkListBegin
    , TkInt 4
    , TkInt 18
    , TkInt 32
    , TkInt 46
    , TkInt 60
    , TkInt 74
    , TkInt 88
    , TkBreak
    , TkBytes "u\200\129\164"
    , TkListBegin
    , TkInt 6
    , TkInt 20
    , TkInt 34
    , TkInt 48
    , TkInt 62
    , TkInt 76
    , TkInt 90
    , TkBreak
    , TkBytes "\174\134\&0\129"
    , TkListBegin
    , TkInt 8
    , TkInt 22
    , TkInt 36
    , TkInt 50
    , TkInt 64
    , TkInt 78
    , TkInt 92
    , TkBreak
    , TkBytes "\203\GS\151\&8"
    , TkListBegin
    , TkInt 10
    , TkInt 24
    , TkInt 38
    , TkInt 52
    , TkInt 66
    , TkInt 80
    , TkInt 94
    , TkBreak
    , TkBytes "\229\221D\172"
    , TkListBegin
    , TkInt 12
    , TkInt 26
    , TkInt 40
    , TkInt 54
    , TkInt 68
    , TkInt 82
    , TkInt 96
    , TkBreak
    , TkListLen 3
    , TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkMapLen 1
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkListLen 6
    , TkMapLen 1
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkListLen 2
    , TkInt 1
    , TkBytes "U\165@\b"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 0
    , TkListLen 0
    ]
  where
    exampleExtLedgerState = ExtLedgerState
      { ledgerState = exampleLedgerState
      , headerState = exampleHeaderState
      }

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

mkDummyHash :: forall c a. Crypto c => Proxy c -> Int -> SL.Hash c a
mkDummyHash _ = coerce . SL.hash @(SL.HASH c)