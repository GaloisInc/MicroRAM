{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

{-
Module      : Concrete implementation of the interpreter. 
Description : Interpreter for MicrRAM programs
Maintainer  : santiago@galois.com
Stability   : experimental

The concrete instantiation of the interpreter is an
instance of the abstract domain with `v =  MWord`.

-}

module MicroRAM.MRAMInterpreter.Concrete (splitAddr, splitAlignedAddr, WordMemory(..), Mem, Poison, Concretizable(..)) where

import Control.Monad
import Control.Lens (makeLenses, at, (^.), (&), (.~), (%~))
import Data.Bits
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Map.Strict (Map)
import Data.Vector (Vector)

import Compiler.CompilationUnit
import Compiler.Errors
import Compiler.Tainted ( Label )
import MicroRAM
import MicroRAM.MRAMInterpreter.Generic

import Util.Util

data WordMemory = WordMemory {
    _wmDefault :: MWord,
    _wmMem :: Map MWord MWord,
    _wmPoison :: Set MWord
  }
  deriving (Show)
makeLenses ''WordMemory

toMInt :: MWord -> MInt
toMInt = fromIntegral

toSignedInteger :: MWord -> Integer
toSignedInteger = toInteger . toMInt

subBytes :: Functor f => MemWidth -> Int -> (MWord -> f MWord) -> MWord -> f MWord
subBytes w off f x = put <$> f x'
  where
    offBits = off * 8
    mask = (1 `shiftL` (widthInt w * 8)) - 1
    -- Extract `w` bytes from `x` at `off`
    x' = (x `shiftR` offBits) .&. mask
    -- Insert `w` bytes of `y'` into `x` at `off`
    put y' = (x .&. complement (mask `shiftL` offBits)) .|. ((y' .&. mask) `shiftL` offBits)

-- | Takes a byte memory address and returns the corresponding a word memory address and byte offset.
splitAddr :: MWord -> (MWord, Int)
splitAddr a = (waddr, offset)
  where
    waddr = a `shiftR` logWordBytes
    offset = fromIntegral $ a .&. ((1 `shiftL` logWordBytes) - 1)

splitAlignedAddr :: MemWidth -> MWord -> Hopefully (MWord, Int)
splitAlignedAddr w a = do
  let (waddr, offset) = splitAddr a
  when (offset `mod` widthInt w /= 0) $ do
    otherError $ "unaligned access of " ++ show (widthInt w) ++ " bytes at " ++ showHex a
  return (waddr, offset)

instance AbsDomain MWord where
  type Memory MWord = WordMemory

  absInitMem mem = WordMemory {
      _wmDefault = 0,
      _wmMem = flatInitMem mem,
      _wmPoison = mempty
    }

  absExact = id

  absAdd = (+)
  absSub = (-)
  absUMul a b = (lo, hi)
    where
      prod = toInteger a * toInteger b
      lo = fromInteger prod
      hi = fromInteger $ prod `shiftR` wordBits
  absSMul a b = (lo, hi)
    where
      prod = toSignedInteger a * toSignedInteger b
      lo = fromIntegral prod
      hi = fromIntegral $ prod `shiftR` wordBits
  absDiv a b = if b == 0 then 0 else a `div` b
  absMod a b = if b == 0 then 0 else a `mod` b

  absAnd = (.&.)
  absOr = (.|.)
  absXor = xor
  absNot = complement
  absShl a b = a `shiftL` fromIntegral b
  absShr a b = a `shiftR` fromIntegral b

  absEq a b = if a == b then 1 else 0
  absUGt a b = if a > b then 1 else 0
  absUGe a b = if a >= b then 1 else 0
  absSGt a b = if toMInt a > toMInt b then 1 else 0
  absSGe a b = if toMInt a >= toMInt b then 1 else 0

  absMux c t e = if c /= 0 then t else e

  absStore w addr val mem = do
    (waddr, offset) <- splitAlignedAddr w addr
    let old = maybe (mem ^. wmDefault) id (mem ^. wmMem . at waddr)
    let new = old & subBytes w offset .~ val
    return $ mem & wmMem . at waddr .~ Just new

  absLoad w addr mem = do
    (waddr, offset) <- splitAlignedAddr w addr
    let wval = maybe (mem ^. wmDefault) id (mem ^. wmMem . at waddr)
    return $ wval ^. subBytes w offset

  absPoison w addr mem = do
    when (w /= WWord) $ otherError $ "bad poison width " ++ show w
    (waddr, _offset) <- splitAlignedAddr w addr
    return $ mem & wmPoison %~ Set.insert waddr

  absGetPoison w addr mem = do
    (waddr, _offset) <- splitAlignedAddr w addr
    return $ Set.member waddr (mem ^. wmPoison)

  absGetValue x = return x



-- | Memory for trace. Contains the default value, the stored values and,
-- when using taint tracking, the tainted labels.
-- TODO: We could merge the values and the labels into a single map of type:
--     `Map MWord v`
-- where `v` is instantiated to `MWord` or `TaintedValue`. Then we can keep everything
-- abstract.
type Mem = (MWord,
            Map MWord MWord,
            Maybe (Map MWord (Vector Label))) -- When tainted
type Poison = Set MWord


-- | Further properies of concrete values that should be mappable to
-- machine words
class AbsDomain v => Concretizable v where
  -- Assumes: `forall v. absGetValue v = Just $ conGetvalue v
  conGetValue :: v -> MWord
  conGetTaint :: v -> Maybe (Vector Label)
  
  conMem :: Memory v -> Mem
  conPoison :: Memory v -> Poison
