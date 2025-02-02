{-# LANGUAGE TypeApplications #-}
module Cardano.DbTool.Validate.BlockProperties
  ( validateBlockProperties
  ) where

import           Cardano.DbTool.Validate.Util

import           Cardano.Db hiding (queryBlockTxCount)

import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Trans.Reader (ReaderT)

import           Data.Int (Int64)
import qualified Data.List as List
import qualified Data.List.Extra as List
import           Data.Time.Clock (UTCTime)
import qualified Data.Time.Clock as Time
import           Data.Word (Word64)

import           Database.Esqueleto.Experimental (SqlBackend, asc, desc, from, limit, orderBy,
                   select, table, unValue, val, where_, (>.), (^.))

import qualified System.Random as Random

{- HLINT ignore "Reduce duplication" -}

validateBlockProperties :: IO ()
validateBlockProperties = do
  blkCount <- fromIntegral <$> runDbNoLoggingEnv queryBlockCount
  validateBlockTimesInPast
  validataBlockNosContiguous blkCount
  validateTimestampsOrdered blkCount

-- -------------------------------------------------------------------------------------------------

validateBlockTimesInPast :: IO ()
validateBlockTimesInPast = do
    putStrF "All block times are in the past: "
    now <- Time.getCurrentTime
    xs <- runDbNoLoggingEnv $ queryBlocksTimeAfters now
    if List.null xs
      then putStrLn $ greenText "ok"
      else error $ redText (reportFailures xs)
  where
    reportFailures :: [(Maybe Word64, Int64, UTCTime)] -> String
    reportFailures xs =
      mconcat
        [ "\nThere are ", show (length xs), " blocks with time stamps in the future.\n"
        , "First future block is: ", showFirst (head xs)
        ]

    showFirst :: (Maybe Word64, Int64, UTCTime) -> String
    showFirst (mEpoch, blockNo, time) =
      mconcat [ "epoch ", show mEpoch, " block ", show blockNo, " time ", show time ]

validataBlockNosContiguous :: Word64 -> IO ()
validataBlockNosContiguous blkCount = do
    startBlock <- Random.randomRIO (0, blkCount - testBlocks)
    putStrF $ "Block numbers [" ++ show startBlock ++ " .. "
                ++ show (startBlock + testBlocks) ++ "] are contiguous: "
    blockNos <- runDbNoLoggingEnv $ queryBlockNoList startBlock testBlocks
    case checkContinguous blockNos of
      Nothing -> putStrLn $ greenText "ok"
      Just xs -> error $ redText "failed: " ++ show xs
  where
    testBlocks :: Word64
    testBlocks = 100000

    checkContinguous :: [Int64] -> Maybe [Int64]
    checkContinguous xs =
      case xs of
        (a : b : ys) -> if a + 1 == b
                          then checkContinguous (b : ys)
                          else Just [a, b]
        _otherwise -> Nothing

validateTimestampsOrdered :: Word64 -> IO ()
validateTimestampsOrdered blkCount = do
    startBlock <- Random.randomRIO (0, blkCount - testBlocks)
    putStrF $ "Block time stamps for blocks [" ++ show startBlock ++ " .. "
                ++ show (startBlock + testBlocks) ++ "] are ordered: "
    ts <- runDbNoLoggingEnv $ queryBlockTimestamps startBlock testBlocks
    if List.nubOrd ts == ts
      then putStrLn $ greenText "ok"
      else error $ redText "failed: " ++ show ts
  where
    testBlocks :: Word64
    testBlocks = 100000

-- -------------------------------------------------------------------------------------------------

queryBlockNoList :: MonadIO m => Word64 -> Word64 -> ReaderT SqlBackend m [Int64]
queryBlockNoList start count = do
  res <- select $ do
    blk <- from $ table @Block
    where_ (blk ^. BlockBlockNo >. val (fromIntegral start))
    orderBy [asc (blk ^. BlockBlockNo)]
    limit (fromIntegral count)
    pure (blk ^. BlockBlockNo)
  pure $ map unValue res

queryBlockTimestamps :: MonadIO m => Word64 -> Word64 -> ReaderT SqlBackend m [UTCTime]
queryBlockTimestamps start count = do
  res <- select $ do
    blk <- from $ table @Block
    where_ (blk ^. BlockBlockNo >. val (fromIntegral start))
    orderBy [asc (blk ^. BlockBlockNo)]
    limit (fromIntegral count)
    pure (blk ^. BlockTime)
  pure $ map unValue res

queryBlocksTimeAfters :: MonadIO m => UTCTime -> ReaderT SqlBackend m [(Maybe Word64, Int64, UTCTime)]
queryBlocksTimeAfters now = do
  res <- select $ do
    blk <- from $ table @Block
    where_ (blk ^. BlockTime >. val now)
    orderBy [desc (blk ^. BlockTime)]
    pure (blk ^. BlockEpochNo, blk ^. BlockBlockNo, blk ^. BlockTime)
  pure $ map unValue3 res
