{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Explorer.Node.Insert
  ( insertByronBlockOrEBB
  , insertGenesisDistribution
  ) where

import           Cardano.Prelude

import           Cardano.Binary (Raw)
import           Cardano.BM.Trace (Trace, logInfo)
import qualified Cardano.Crypto as Crypto

-- Import all 'cardano-ledger' functions and data types qualified so they do not
-- clash with the Explorer DB functions and data types which are also imported
-- qualified.
import qualified Cardano.Chain.Block as Ledger
import qualified Cardano.Chain.Common as Ledger
import qualified Cardano.Chain.Genesis as Ledger
import qualified Cardano.Chain.Slotting as Ledger
import qualified Cardano.Chain.UTxO as Ledger

import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Reader (ReaderT)
import           Control.Monad.Extra (mapMaybeM)

import           Crypto.Hash (Blake2b_256)

import           Data.Coerce (coerce)
import qualified Data.ByteArray
import qualified Data.Text as Text

import           Database.Persist.Sql (SqlBackend, transactionSave)

import qualified Explorer.DB as DB
import           Explorer.Node.Insert.Genesis

import           Ouroboros.Consensus.Ledger.Byron (ByronBlockOrEBB (..))


insertByronBlockOrEBB :: MonadIO m => Trace IO Text -> ByronBlockOrEBB cfg -> m ()
insertByronBlockOrEBB tracer blk =
  liftIO $ case unByronBlockOrEBB blk of
            Ledger.ABOBBlock ablk -> insertABlock tracer ablk
            Ledger.ABOBBoundary abblk -> insertABOBBoundary tracer abblk

insertABOBBoundary :: Trace IO Text -> Ledger.ABoundaryBlock ByteString -> IO ()
insertABOBBoundary tracer blk = do
    if False
      then DB.runDbIohkLogging tracer insertAction
      else DB.runDbNoLogging insertAction

    logInfo tracer $ Text.concat
                    [ "insertABOBBoundary: epoch "
                    , textShow (Ledger.boundaryEpoch $ Ledger.boundaryHeader blk)
                    , " hash "
                    , textShow hash
                    ]
  where
    insertAction :: MonadIO m => ReaderT SqlBackend m ()
    insertAction = do
      prevHash <- case Ledger.boundaryPrevHash (Ledger.boundaryHeader blk) of
                    Left gh -> do
                      validateGenesisTxs (Ledger.unGenesisHash gh)
                      pure $ genesisToHeaderHash gh
                    Right hh -> pure hh
      -- Do a transaction around a block insert.
      transactionSave
      pbid <- fromMaybe (panic $ "insertABOBBoundary: queryBlockId failed: " <> textShow prevHash)
                  <$> DB.queryBlockId (unHeaderHash prevHash)
      void . DB.insertBlock $
                DB.Block
                  { DB.blockHash = unHeaderHash hash
                  , DB.blockSlotNo = Nothing -- No slotNo for a boundary block
                  , DB.blockBlockNo = 0
                  , DB.blockPrevious = Just pbid
                  , DB.blockMerkelRoot = Nothing -- No merkelRoot for a boundary block
                  , DB.blockSize = fromIntegral $ Ledger.boundaryBlockLength blk
                  }
      transactionSave

    hash :: Ledger.HeaderHash
    hash = Ledger.boundaryHashAnnotated blk

insertABlock :: Trace IO Text -> Ledger.ABlock ByteString -> IO ()
insertABlock tracer blk = do
    if False
      then DB.runDbIohkLogging tracer insertAction
      else DB.runDbNoLogging insertAction

    when False $
      logInfo tracer $ "insertABlock: " <> textShow hash
  where
    insertAction :: MonadIO m => ReaderT SqlBackend m ()
    insertAction = do
      pbid <- fromMaybe (panic $ "insertABlock: queryBlockId failed: " <> textShow prevHash)
                  <$> DB.queryBlockId (unHeaderHash prevHash)

      -- Do a transaction around a block insert.
      transactionSave
      blkId <- fmap both $
                DB.insertBlock $
                    DB.Block
                      { DB.blockHash = unHeaderHash hash
                      , DB.blockSlotNo = Just (Ledger.unSlotNumber . Ledger.headerSlot $ Ledger.blockHeader blk)
                      , DB.blockBlockNo = blockNo
                      , DB.blockPrevious = Just pbid
                      , DB.blockMerkelRoot = Just $ unCryptoHash merkelRoot
                      , DB.blockSize = fromIntegral $ Ledger.blockLength blk
                      }

      mapM_ (insertTx tracer blkId) $ blockPayload blk
      transactionSave

    blockNo :: Word64
    blockNo = Ledger.unChainDifficulty . Ledger.headerDifficulty $ Ledger.blockHeader blk

    prevHash :: Ledger.HeaderHash
    prevHash = Ledger.headerPrevHash $ Ledger.blockHeader blk

    hash :: Ledger.HeaderHash
    hash = Ledger.blockHashAnnotated blk

    merkelRoot :: Crypto.AbstractHash Blake2b_256 Raw
    merkelRoot = Ledger.getMerkleRoot . Ledger.txpRoot . Ledger.recoverTxProof . Ledger.bodyTxPayload $ Ledger.blockBody blk


insertTx :: MonadIO m => Trace IO Text -> DB.BlockId -> Ledger.TxAux -> ReaderT SqlBackend m ()
insertTx tracer blkId tx = do
    let txHash = Crypto.hash $ Ledger.taTx tx
    fee <- calculateTxFee $ Ledger.taTx tx
    txId <- fmap both $ DB.insertTx $
                            DB.Tx
                              { DB.txHash = unTxHash txHash
                              , DB.txBlock = blkId
                              , DB.txFee = fee
                              }

    -- Insert outputs for a transaction before inputs in case the inputs for this transaction
    -- references the output (noit sure this can even happen).
    zipWithM_ (insertTxOut tracer txId) [0 ..] (toList . Ledger.txOutputs $ Ledger.taTx tx)
    mapM_ (insertTxIn tracer txId) (Ledger.txInputs $ Ledger.taTx tx)


insertTxOut :: MonadIO m => Trace IO Text -> DB.TxId -> Word32 -> Ledger.TxOut -> ReaderT SqlBackend m ()
insertTxOut _tracer txId index txout = do
  void . DB.insertTxOut $
            DB.TxOut
              { DB.txOutTxId = txId
              , DB.txOutIndex = fromIntegral index
              , DB.txOutAddress = unAddressHash (Ledger.addrRoot $ Ledger.txOutAddress txout)
              , DB.txOutValue = Ledger.unsafeGetLovelace $ Ledger.txOutValue txout
              }


insertTxIn :: MonadIO m => Trace IO Text -> DB.TxId -> Ledger.TxIn -> ReaderT SqlBackend m ()
insertTxIn _tracer txInId (Ledger.TxInUtxo txHash inIndex) = do
  txOutId <- fromMaybe (panic $ "insertTxIn: queryTxId failed: " <> textShow txHash)
                <$> DB.queryTxId (unTxHash txHash)
  void $ DB.insertTxIn $
            DB.TxIn
              { DB.txInTxInId = txInId
              , DB.txInTxOutId = txOutId
              , DB.txInTxOutIndex = fromIntegral inIndex
              }

-- -----------------------------------------------------------------------------

calculateTxFee :: MonadIO m => Ledger.Tx -> ReaderT SqlBackend m Word64
calculateTxFee tx = do
    case output of
      Left err -> panic $ "calculateTxFee: " <> textShow err
      Right outval -> do
        inval <- sum <$> mapMaybeM DB.queryTxOutValue inputs
        if outval > inval
          then panic $ "calculateTxFee: " <> textShow (outval, inval)
          else pure $ inval - outval
  where
    inputs :: [(ByteString, Word16)]
    inputs = map unpack $ toList (Ledger.txInputs tx)

    unpack :: Ledger.TxIn -> (ByteString, Word16)
    unpack (Ledger.TxInUtxo txHash index) = (unTxHash txHash, fromIntegral index)

    output :: Either Ledger.LovelaceError Word64
    output =
      Ledger.unsafeGetLovelace
        <$> Ledger.sumLovelace (map Ledger.txOutValue $ Ledger.txOutputs tx)

genesisToHeaderHash :: Ledger.GenesisHash -> Ledger.HeaderHash
genesisToHeaderHash = coerce

blockPayload :: Ledger.ABlock a -> [Ledger.TxAux]
blockPayload =
  Ledger.unTxPayload . Ledger.bodyTxPayload . Ledger.blockBody

unHeaderHash :: Ledger.HeaderHash -> ByteString
unHeaderHash = Data.ByteArray.convert

unAddressHash :: Ledger.AddressHash Ledger.Address' -> ByteString
unAddressHash = Data.ByteArray.convert

unTxHash :: Crypto.Hash Ledger.Tx -> ByteString
unTxHash = Data.ByteArray.convert

unCryptoHash :: Crypto.Hash Raw -> ByteString
unCryptoHash = Data.ByteArray.convert

textShow :: Show a => a -> Text
textShow = Text.pack . show

both :: Either a a -> a
both (Left a) = a
both (Right a) = a