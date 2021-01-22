{-# LANGUAGE TypeOperators #-}
{-
Module      : Choosing Segments
Description : 
Maintainer  : santiago@galois.com
Stability   : experimental

-}

module Segments.ChooseSegments where

import MicroRAM
import MicroRAM.MRAMInterpreter
import Util.Util

import qualified Debug.Trace as Debug

import qualified Data.Map as Map 
import qualified Data.Set as Set 
-- import Compiler.Errors

import Segments.Segmenting
import Control.Monad.State.Lazy

data TraceChunk reg = TraceChunk {
  chunkSeg :: Int
  , chunkStates :: Trace reg }
--  deriving Show

instance Show (TraceChunk reg) where
  show tc = "# TraceChunk: Indx = " ++ (show $ chunkSeg tc) ++ ". ChunkStates = " ++ (show $ map pc (chunkStates tc))
  
data PartialState reg = PartialState {
  remainingTrace :: Trace reg
  , pubBlocks :: [TraceChunk reg]
  , priBlocks :: [TraceChunk reg]
  , queueSt :: Trace reg
  , availableSegments :: Map.Map MWord [Int]
  , privLoc :: Int -- The next location of a private segment
  } deriving Show

type InstrNumber = MWord 
type PState reg x = State (PartialState reg) x 
 
chooseSegments :: Show reg => Int -> Trace reg -> Map.Map MWord [Int] -> [Segment reg MWord] ->  [TraceChunk reg]
chooseSegments privSize trace segmentSets segments =
  -- create starting state
  let initSt = PartialState trace [] [] [] segmentSets (length segments)  
  -- run the choose statement
      go = whileJust nextExecState (chooseSegment segments privSize)
      finalSt = execState go initSt in 
  -- extract values and return
    (pubBlocks finalSt) ++ (priBlocks finalSt)

  where whileJust :: PState reg (Maybe a) -> (a -> PState reg b) -> PState reg ()
        whileJust nextM f = do
          next <- nextM
          case next of
            Just a -> f a *> whileJust nextM f
            Nothing -> return ()

        nextExecState :: PState reg (Maybe (ExecutionState reg))
        nextExecState = do
          trace <- remainingTrace <$> get
          case trace of
            x : traceTail -> do
              modify (\st -> st{remainingTrace = traceTail})
              return $ Just x
            [] -> return Nothing 
          
showESt es = "EState at " ++ (show $ pc es) ++ ". "

showQueue q = "[" ++ (concat $ showESt <$> q) ++ "]"
   
-- | chooses the next segment
chooseSegment :: Show reg => [Segment reg MWord] -> Int -> ExecutionState reg -> PState reg ()
chooseSegment segments privSize execSt = do
  segmentSets <- availableSegments <$> get
  maybeSegment <- popSegmentIn (pc execSt)
  case maybeSegment of
    Just segment -> do allocateQueue privSize
                       allocateSegment segments execSt segment
    _ -> pushQueue execSt
         
   where
         -- | Put the queue in as private blocks
         allocateQueue :: Show reg => Int -> PState reg ()
         allocateQueue size =
           do queue <- queueSt <$> get
              modify (\st -> st {queueSt = []})
              currentPrivSegment <- privLoc <$> get
              addPrivBlocks (splitPrivBlocks size currentPrivSegment $ reverse queue)
         addPrivBlocks :: [TraceChunk reg] -> PState reg ()
         addPrivBlocks newBlocks = do
           st <- get
           put (st {priBlocks = priBlocks st ++ newBlocks})
         splitPrivBlocks :: Show reg => Int -> Int -> Trace reg -> [TraceChunk reg]
         splitPrivBlocks size privLoc privTrace =
           let splitTrace = splitEvery size privTrace in
             map (\(states, seg) ->  TraceChunk seg states) (zip splitTrace [privLoc..]) 
         -------
         allocateSegment :: [Segment reg MWord] -> ExecutionState reg -> Int -> PState reg ()
         allocateSegment segments state segmentIndx =
           let segment = segments !! segmentIndx
               len = segLen segment in
             do statesTail <- pullStates (len -1)
                newChunk <- return $ TraceChunk segmentIndx (state : statesTail)
                addPubBlocks newChunk 
               
         addPubBlocks :: TraceChunk reg -> PState reg ()
         addPubBlocks chunk = modify (\st -> st {pubBlocks = chunk : pubBlocks st})

         -- Gets the next n states
         pullStates :: Int -> PState reg [ExecutionState reg]
         pullStates n = do
           remTrace <- remainingTrace <$> get
           modify (\st -> st {remainingTrace = drop n $ remTrace})
           return $ (take n) remTrace
         pushQueue :: ExecutionState reg -> PState reg () 
         pushQueue state = do
           st <- get
           put $ st {queueSt = state : queueSt st}
         popSegmentIn :: MWord -> PState reg (Maybe Int) 
         popSegmentIn instrPc = do
           st <- get
           avalStates <- return $ availableSegments st
           case Map.lookup instrPc avalStates of
             Just (execSt : others) ->
               do
                 _ <- put $ st {availableSegments = Map.insert instrPc others avalStates}
                 return $ Just execSt
             _ -> return Nothing
             

splitEvery :: Int -> [a] -> [[a]]
splitEvery _ [] = []
splitEvery n list = first : (splitEvery n rest)
  where
    (first,rest) = splitAt n list

-------
-- TESTING

fakeState :: MWord -> ExecutionState ()
fakeState n = ExecutionState n Map.empty (0, Map.empty) Set.empty [] False False False 0

testTrace :: Trace ()
testTrace =
  fakeState 0 :
  fakeState 1 :
  fakeState 2 :  --
  fakeState 4 :  
  fakeState 5 :
  fakeState 6 :  -- 
  fakeState 3 :  --
  fakeState 4 :
  fakeState 5 : 
  fakeState 6 :  --
  fakeState 3 :  -- 
  fakeState 4 : 
  fakeState 5 :
  fakeState 6 :  --
  fakeState 3 :  --
  fakeState 7 :
  fakeState 8 : []

segment0 =
  Segment
  [ Iand () () (Reg ()), 
    Isub () () (Reg ()), 
    Ijmp (Reg ()) ]
    0
    3
    []
    False
segment1 =
  Segment
  [Icjmp () (Const 0)]
  3
  1
  []
  False
segment2 =
  Segment
  [Iadd () () (Const 0),
    Isub () () (Const 0), 
    Ijmp (Const 3)]
  4
  3
  []
  False
segment3 =
  Segment
  [Iand () () (Reg ()),
    Isub () () (Const 0)]
  7
  2
  []
  False

testSegments' :: [Segment () MWord]
testSegments' =
  [segment0,
    segment1,
    segment2,
    segment2,
    segment3]


testSegmentSets :: Map.Map MWord [Int]
testSegmentSets = Map.fromList
  [(0, [0]),
   (3, [1]),
   (4, [2,3]),
   (7, [4])
  ]

testchunks :: [TraceChunk ()]
testchunks = chooseSegments 3 testTrace testSegmentSets testSegments'

