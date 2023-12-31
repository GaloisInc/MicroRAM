{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-|
Module      : Removing Labels
Description : Replaces labels with concrete instruction numbers : MARAM -> MRAM
Maintainer  : santiago@galois.com
Stability   : experimental


This module compiles Translates MicroASM to MicroRAM.

MicroASM is different to MicrRAM in that it allows the operands
`Label` and lazy constants. The assembler will replace those labels
with the actual instruction numbers to obtain MicroRAM. In particular
a MicroASM program can be "partial" and needs to be linked to another part
that contains some of the labels (this allows some simple separta compilation.

Note: This module is completly parametric over the machine register type.

The assembler translates all `Label` and lazy constants to the actual
instruction number to produce well formed MicroRAM. It does so in three passes:
 
1) Create a label map, mapping names -> instruction

2) "Flatten": Removing the names from blocks, leaving a list of instructions

3) Replace all labels with the location given in the label map.

TODO: It can all be done in 2 passes. Optimize?


-}
module Compiler.RemoveLabels
    ( removeLabels,
      stashGlobals
    ) where


import Control.Monad

import MicroRAM
import Compiler.IRs
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Compiler.Common
import Compiler.CompilationUnit
import Compiler.Errors
import Compiler.LazyConstants
import Compiler.Tainted
import Compiler.Layout (alignTo)

import RiscV.RiscVAsm (instrTraverseImm, Imm(..))

import Debug.Trace


type Wrd = MWord

-- * Assembler

blocksStart :: MWord
blocksStart = 0

blockSize :: NamedBlock md regT MWord -> MWord
blockSize (NamedBlock { blockInstrs = instrs}) = fromIntegral $ length instrs

globalsStart :: MWord
globalsStart = 1 * fromIntegral wordBytes

nextGlobalAddr :: MWord -> GlobalVariable MWord -> MWord
nextGlobalAddr addr g =
  alignTo (fromIntegral wordBytes * gAlign g) $
    addr + fromIntegral wordBytes * gSize g

buildLabelMap ::
  [NamedBlock md regT MWord] ->
  [GlobalVariable MWord] ->
  Hopefully (Map Name MWord)
buildLabelMap blocks globs = do
  blockMap <- goBlocks mempty blocksStart blocks
  globMap <- goGlobs mempty globalsStart globs
  let overlap = Set.intersection (Map.keysSet blockMap) (Map.keysSet globMap)
  when (not $ Set.null overlap) $
    assumptError $ "name collision between blocks and globals: " ++ show overlap
  return $ blockMap <> globMap
  where
    goBlocks m _addr [] = return m
    goBlocks m addr (b : bs)
      | Just name <- blockName b = do
        when (Map.member name m) $
          assumptError $ "name collision between blocks: " ++ show name
        goBlocks (Map.insert name addr m) (addr + blockSize b) bs
      | otherwise = trace "warning: unnamed block in RemoveLabels" $
        goBlocks m (addr + blockSize b) bs

    goGlobs :: Map.Map Name MWord -> MWord -> [GlobalVariable MWord] -> Hopefully (Map.Map Name MWord)
    goGlobs m _addr [] = return m
    goGlobs m addr (g:gs) = do
      let entries = entryPoints g
      let (addr', nextAddr) = if gvHeapInit g then
              (heapInitAddress, addr)
            else
              (addr, nextGlobalAddr addr g)
      m' <- foldM (insertLabel addr') m [(name, offset) | (name, offset, _extern) <- entries]
      -- Note this still increments by the size of `g`, even for heap-init
      -- globals.
      goGlobs m' nextAddr gs

    insertLabel :: MWord -> Map.Map Name MWord -> (Name, MWord) -> Hopefully (Map.Map Name MWord)
    insertLabel addr m (name, offset) = do
      when (Map.member name m) $
        assumptError $ "name collision between globals: " ++ show name
      return (Map.insert name (addr + offset) m)

getOrZero :: Map Name MWord -> Name -> MWord
getOrZero m n = case Map.lookup n m of
  Nothing -> trace ("warning: label " ++ show n ++ " is missing; defaulting to zero") 0
  Just x -> x

flattenBlocks :: Show regT => 
  Map Name MWord ->
  [NamedBlock md regT MWord] ->
  [(Instruction regT MWord, md)]
flattenBlocks lm bs = snd $ foldr goBlock (totalBlockSize, []) bs
  where
    !totalBlockSize = blocksStart + sum (map blockSize bs)

    -- Walks over blocks in reverse order.
    -- The instructions for the last block are placed at the end of the accumulated list and each block is processed right to left.
    goBlock blk (!postAddr,!acc) =
      foldr goInstr (postAddr, acc) (blockInstrs blk)

    -- Walks over instructions in reverse order.
    goInstr :: Show regT => (MAInstruction regT MWord, md) -> (MWord,[(Instruction regT MWord, md)]) -> (MWord,[(Instruction regT MWord, md)])
    goInstr (i, md) (!lastAddr,!acc) =
      -- Get the address of the current instruction.
      let addr = lastAddr - 1 in
      -- Replace all the labels and lazy constants in the operands of each instruction
      -- Starting with the XCheck instructions, which have different opperands
      let i' = goXCheck addr i in
      let !i''  = goOperand addr <$> i' in
        (addr, (i'', md):acc)

    goOperand :: MWord -> MAOperand regT MWord -> Operand regT MWord
    goOperand _ (AReg r) = Reg r
    goOperand addr (LImm lc) = Const $ makeConcreteConst (lmFuncWithPc addr) lc
    goOperand _ (Label name) = Const $ lmFunc name
    
    -- Add the current pc address to the map (replaces the old
    -- HereLabel)
    lmFuncWithPc pcAddress = getOrZero $ Map.insert pcName pcAddress lm
    lmFunc = getOrZero lm

    -- Replace all the `ImmLazy` with `ImmWord`
    goXCheck :: MWord -> MAInstruction regT MWord -> MAInstruction regT MWord
    goXCheck addr (Iext (XCheck nativeInstr name off)) =
      Iext $ XCheck (instrTraverseImm (goImm addr) nativeInstr) name off -- goImm addr
    goXCheck _ i = i

    goImm :: MWord -> Imm -> Imm
    goImm addr (ImmLazy lc) =
      ImmNumber $ makeConcreteConst (lmFuncWithPc addr) lc
    goImm _ imm = error $ "RemoveLabels: Expected a `ImmLazy` but found: "<> show imm <> ".\n\tThe transpiler should have turned this into a `ImmLazy`"
    

flattenGlobals ::
  Bool ->
  Map Name MWord ->
  [GlobalVariable MWord] ->
  Hopefully [InitMemSegment]
flattenGlobals tainted lm gs = goGlobals globalsStart gs
  where
    goGlobals :: MWord -> [GlobalVariable MWord] -> Hopefully [InitMemSegment]
    goGlobals _addr [] = return []
    goGlobals addr (g:gs) = do
      init' <- mapM (mapM goLazyConst) (initializer g)
      let (addr', nextAddr) = if gvHeapInit g then
              (heapInitAddress, addr)
            else
              (addr, nextGlobalAddr addr g)
      let seg = InitMemSegment {
            isName   = short2string $  dbName $ globSectionName g,
            isSecret = secret g,
            isReadOnly = isConstant g,
            isHeapInit = gvHeapInit g,
            location = addr' `div` fromIntegral wordBytes,
            segmentLen = gSize g,
            content = init',
            labels = if tainted then
                Just $ replicate (fromIntegral $ gSize g) bottomWord
              else Nothing
            }
      rest <- goGlobals nextAddr gs
      return $ seg : rest

    goLazyConst :: LazyConst MWord -> Hopefully MWord
    goLazyConst lc = return $ makeConcreteConst lmFunc lc

    lmFunc = getOrZero lm

-- ** Remove labels from the entire CompilationUnit  
removeLabels ::
  Show regT =>
  Bool ->
  CompilationUnit [GlobalVariable MWord] (MAProgram md regT Wrd) ->
  Hopefully (CompilationUnit () (AnnotatedProgram md regT Wrd))
removeLabels tainted cu = do
  let blocks = pmProg $ programCU cu
  let globs = intermediateInfo cu
  lm <- buildLabelMap blocks globs
  let prog = flattenBlocks lm blocks
  mem <- flattenGlobals tainted lm globs
  return $ cu {
    programCU = ProgAndMem prog mem lm,
    intermediateInfo = ()
  }

-- FIXME: This is a temporary hack.  Instead MAProgram should contain both a
-- list of blocks and a list of globals, and Stacking should copy the global
-- env into the right field of the MAProgram.
stashGlobals ::
  CompilationUnit () (Lprog m mreg MWord) ->
  CompilationUnit [GlobalVariable MWord] (Lprog m mreg MWord)
stashGlobals cu = cu { intermediateInfo = gs }
  where gs = globals $ pmProg $ programCU cu

