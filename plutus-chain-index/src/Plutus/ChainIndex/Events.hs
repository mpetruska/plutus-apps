{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Plutus.ChainIndex.Events where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, dupTChan, tryReadTChan)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (catMaybes)
import Plutus.ChainIndex qualified as CI
import Plutus.ChainIndex.Effects (appendBlocks)
import Plutus.ChainIndex.Lib

batchSize :: Int
batchSize = 25000

-- | 30s
period :: Int
period = 30_000_000

processEventsChan :: RunRequirements -> EventsChan -> IO ()
processEventsChan runReq eventsChan = void $ do
  chan <- liftIO $ atomically $ dupTChan eventsChan
  putStrLn "started"
  go chan
  where
    go chan = do
      events :: [ChainSyncEvent] <- readEventsFromTChan chan
      case events of
        backwardOrResume : forwardEvents -> do
          print $ show $ length forwardEvents
          void $ runChainIndexDuringSync runReq $ do
            let
              getBlock = \case
                (RollForward block _) -> Just block
                _                     -> Nothing
              blocks = catMaybes $ map getBlock forwardEvents
            CI.appendBlocks blocks
            case backwardOrResume of
              (RollBackward point _) -> CI.rollback point
              (Resume point)         -> CI.resumeSync point
              _                      -> error "impossible"
        [] -> putStrLn "empty list of events"
      go chan


-- | Read 'RollForward' events from the 'TChan' the until 'RollBackward' or 'Resume'.
readEventsFromTChan :: EventsChan -> IO [ChainSyncEvent]
readEventsFromTChan chan =
    let go combined  = do
            eventM <- atomically $ tryReadTChan chan
            case eventM of
              Nothing    -> putStrLn "nothing here, waiting" >> threadDelay period >> go combined
              Just event -> case event of
                (RollForward _ _) -> go (event : combined)
                _                 -> pure (event : combined)
     in go []