{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}

{-|
Module      : Registers
Description : The class of registers we can use in MicroRAM
Maintainer  : santiago@galois.com
Stability   : alpha at best

The compiler backend is polymorphic on a register type. This allows
the compiler to choose the number of registers as well as the classes
(e.g. 32-bit, 64-bit, modulo P, etc...)

-}
module Compiler.Registers
    ( Regs(..),
      RegBank(..),
      initBank, lookupReg, updateBank,
      RegisterData(..),
      regToList
    ) where

import qualified Data.Map as Map
-- import Data.Word

-- | Class about data structers that can be registers.
class (Show a, Ord a) => Regs a where
  -- Reserved registers
  sp :: a -- ^ Stack pointer 
  bp :: a -- ^ Base pointer
  ax :: a -- ^ Accumulator pointer (Caller saved!)

  toWord :: a -> Word   -- ^ registers are homomorphic to unsigned integers  
  fromWord :: Word -> a
  
-- Register bank
-- | registers can be stored in a register bank with lookups and updates
data RegBank regT wrdT = RegBank (Map.Map regT wrdT) wrdT
  deriving (Show)

initBank ::
  Regs regT =>
  b  -- ^ Initial valuse of sp/bp
  -> b -- ^ Initial value for all other registers
  -> RegBank regT b
initBank spVal def = RegBank (Map.fromList [(sp, spVal), (sp, spVal)]) def

lookupReg :: Regs a => a -> RegBank a b -> b
lookupReg r (RegBank m d) = maybe d id $ Map.lookup r m
updateBank :: Regs a => a -> b -> RegBank a b -> RegBank a b
updateBank r v (RegBank m d) = RegBank (Map.insert r v m) d

-- | Flattens a register bank to a list. Takes a bound
-- in case the register type or the bank is infinite.
regToList :: Regs mreg => Word -> RegBank mreg b -> [b]
regToList bound (RegBank bank def) = fst $ foldr (\i (acc, regs) -> case regs of
    ((j, reg):regs') | i == j -> (reg:acc, regs')
    _                         -> (def:acc, regs)
  ) ([], bankList) $ map fromWord [0..bound - 1]
  where bankList = dropWhile (\(r,_) -> r >= fromWord bound) $ Map.toDescList bank



-- | Integer registers


instance Regs Int where
  sp = 0
  bp = 1
  ax = 2
  -- argc = 3
  -- argv = 4
  fromWord = fromIntegral . toInteger
  toWord = fromIntegral

-- | Machine registers based on X86

data MReg =
  SP | BP | AX | MReg Word
  deriving (Show, Read, Eq, Ord)

instance Regs MReg where
  sp = SP
  bp = BP
  ax = AX
  
  fromWord 0 = SP
  fromWord 1 = BP
  fromWord 2 = AX
  fromWord n = MReg $ n - 3
  
  toWord SP       = 0
  toWord BP       = 1
  toWord AX       = 2
  toWord (MReg n) = n + 3 
  





{- | RegisterData : carries info about the registers.
     Number of regs, classes, types.

     This is different from the Regs class. For example,
     we can implement registers indexed by `Int`s (instance of regs),
     but chose a different number of regs each time. That's what
     RegisterData is for.
-}
data RegisterData = InfinityRegs | NumRegisters Int
  deriving (Eq, Ord, Read, Show)
