{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
module Compiler.IRs where

import MicroRAM.MicroRAM(MAOperand)
import qualified MicroRAM.MicroRAM as MRAM
import MicroRAM.MicroRAM(MWord)
import qualified Data.ByteString.Char8 as BSC
import Data.ByteString.Short

import qualified Data.Map as Map

import Compiler.Registers
import Compiler.Errors
import Util.Util



{-|
Module      : Irs
Description : Several intermediate representations between LLVM and MicroRAM
Maintainer  : santiago@galois.com
Stability   : Prototype

Intermedaiate representations are Languages taking all the instructions from MicroRAM
and adding some functionality such as functions Stack locations etc.

-}



-- ** Types
-- | Ty determines the type of something in the stack. Helps us calculate
-- stack offsets for stack layout
-- FIXME: For now we assume everything is an int, but the code should be
--  written genrically over this type so it's easy to change
data Ty =
   Tint
  | Tptr 
  | Tarray MWord Ty 
  | Tstruct [Ty]
  deriving (Show)

-- Determines the relative size of types (relative to a 32bit integer/64bit)
tySize ::  Ty -> MWord
tySize (Tarray length subTyp) = length * (tySize subTyp)
tySize (Tstruct tys) = sum $ map tySize tys   
tySize _ = 1 -- Pointers have the same sizer as Tint


type TypeEnv = Map.Map Name Ty




-- ** MicroIR
-- High-level IR based on MicroRAM.  Includes MicroRAM instructions with
-- support for extended operand kinds and two non-register operands per
-- instruction (normal MicroRAM requires one operand to be a register), as well
-- as extended high-level instructions (`RTLInstr'`).

data MIRInstruction metadata regT wrdT =
  MirM (MRAM.MA2Instruction regT wrdT) metadata
  | MirI (RTLInstr' (MAOperand regT wrdT)) metadata
  deriving (Show)

type MIRInstr metadata wrdT = MIRInstruction metadata VReg wrdT

type MIRFunction metadata wrdT =
  Function Name Ty (BB Name $ MIRInstr metadata wrdT)

type MIRprog metadata wrdT =
  IRprog metadata wrdT (MIRFunction metadata wrdT)



-- ** Generic low-level IR
-- An IR is made of standard (register-and-operand) MRAM instructions plus some
-- new ones
data IRInstruction metadata regT wrdT irinst =
   MRI (MRAM.MAInstruction regT wrdT) metadata
  | IRI irinst metadata
  deriving (Show,Functor, Foldable, Traversable)
data Function nameT paramT blockT = Function
  { funcName :: nameT
  , funcRetTy :: paramT
  , funcArgTys :: [paramT]
  , funcBlocks :: [blockT]
  , funcNextReg :: Word
  }
  deriving (Show, Functor)

-- | Traverse the IR instruction changing operands  
traverseOpIRInstr :: (Traversable irinst, Applicative f) =>
  (MAOperand regT wrdT -> f (MAOperand regT wrdT'))
  -> IRInstruction metadata regT wrdT (irinst $ MAOperand regT wrdT)
  -> f (IRInstruction metadata regT wrdT' (irinst $ MAOperand regT wrdT'))
traverseOpIRInstr fop (MRI maInstr metadata) = 
  MRI <$> (traverse fop maInstr) <*> (pure metadata) 
traverseOpIRInstr fop (IRI irinst metadata) = 
  IRI <$> (traverse fop irinst) <*> (pure metadata)



type DAGinfo name = [name]
-- | Basic blocks:
--  it's a list of instructions + all the blocks that it can jump to
--  It separates the body from the instructions of the terminator.
data BB name instrT = BB name [instrT] [instrT] (DAGinfo name)
  deriving (Show,Functor, Foldable, Traversable)

-- | Traverse the Basic Blocks changing operands  
traverseOpBB :: (Applicative f) =>
  (MAOperand regT wrdT -> f (MAOperand regT wrdT))
  -> BB name $ LTLInstr mdata regT wrdT
  -> f (BB name $ LTLInstr mdata regT wrdT)
traverseOpBB fop = traverse (traverseOpLTLInstr fop)  

type IRFunction mdata regT wrdT irinstr =
  Function Name Ty (BB Name $ IRInstruction mdata regT wrdT irinstr)
 

data Name =
  Name ShortByteString   -- ^ we keep the LLVM names
  | NewName Word         -- ^ and add some new ones
  deriving (Eq, Ord, Read, Show)


instance Regs Name where
  sp = NewName 0
  bp = NewName 1
  ax = NewName 2
  -- argc = Name "0" -- Where the first arguemtns to main is passed
  -- argv = Name "1" -- Where the second arguemtns to main is passed
  fromWord w      -- FIXME this is terribled: depends on read and show! Ugh!
    | w == 1 = Name "0"
    | even w = NewName $ w `div` 2
    | otherwise = Name $ pack $ read $ show $ digits ((w-1) `div` 2)
  toWord (NewName x) = 2*x
  toWord (Name sh) = 1 + (2 * (read $ read $ show sh))
  data RMap Name x = RMap x (Map.Map Name x)
  initBank d init = RMap d $ (Map.fromList [(sp,init),(bp,init)])
  lookupReg r (RMap d m) = case Map.lookup r m of
                        Just x -> x
                        Nothing -> d
  updateBank r x (RMap d m) = RMap d (Map.insert r x m)

--myShort:: ShortByteString
--myShort = "1234567890"

-- Produces the digits, shifted by 48 (ie. the ASCII representation)
digits :: Integral x => x -> [x]
digits 0 = []
digits x = digits (x `div` 10) ++ [x `mod` 10 + 48] -- ASCII 0 = 0

-- | Translate LLVM Names into strings
-- We use show, but this might add dependencies.
-- Should we just carry a shortString instead?
-- Moved to Instruction Selection

data GlobalVariable wrdT = GlobalVariable
  { name :: String -- Optimize?
  , isConstant :: Bool
  , gType :: Ty
  , initializer :: Maybe [wrdT]
  , secret :: Bool
  } deriving (Show)
type GEnv wrdT = [GlobalVariable wrdT] -- Maybe better as a map:: Name -> "gvar description"
data IRprog mdata wrdT funcT = IRprog
  { typeEnv :: TypeEnv
  , globals :: GEnv wrdT
  , code :: [funcT]
  } deriving (Show, Functor, Foldable, Traversable)




-- -------------------------------
-- ** Register Transfer language (RTL)
-- -------------------------------

-- RTL uses infinite registers, function calls and regular MRAM instructions for the rest.
data CallInstrs operand = 
   ICall operand -- ^ function
        [operand] -- ^ arguments
  | IRet (Maybe operand) -- ^ return this value
        

-- | Virtual registers
type VReg = Name 

-- | Instructions for the RTL language
data RTLInstr' operand =
    RCall
      Ty           -- ^ return type
      (Maybe VReg) -- ^ return register
      operand      -- ^ function
      [Ty]         -- ^ types of parameters 
      [operand]    -- ^ arguments
  | RRet (Maybe operand) -- ^ return this value
  | RAlloc
    (Maybe VReg) -- ^ return register (gives location)
    Ty   -- ^ type of the allocated thing
    operand -- ^ number of things allocated
  | RPhi VReg [(operand,Name)]
  deriving (Show)
    
    
type RTLInstr mdata wrdT = IRInstruction mdata VReg wrdT (RTLInstr' $ MAOperand VReg wrdT)

-- |  Traverse the RTL instruction changing operands  
traverseOpRTLInstr :: (Applicative f) =>
  (MAOperand regT wrdT -> f (MAOperand regT wrdT))
  -> LTLInstr metadata regT wrdT
  -> f (LTLInstr metadata regT wrdT)
traverseOpRTLInstr = traverseOpIRInstr

type RFunction mdata wrdT =
  IRFunction mdata VReg wrdT (RTLInstr' $ MAOperand VReg wrdT)
  
type Rprog mdata wrdT = IRprog mdata wrdT $ RFunction mdata wrdT









-- -------------------------------
-- ** Location Transfer Language
-- -------------------------------

-- It's the target language for register allocation: Close to RTL but uses machine registers and stack slots instead of virtual registers.

-- | Slots are abstract representation of locations in the activation record and come in three kinds
data Slot =
    Local     -- ^ Used by register allocation to spill pseudo-registers to the stack
  | Incoming  -- ^ Stores parameters of the current function
--  | Outgoing  -- ^ Stores arguments to the called function that cannot be in registers.
  deriving (Eq, Read, Show)

-- | Locations are the disjoint union of machine registers and stack loctions
data Loc mreg where
  R :: mreg -> Loc mreg
  L :: Slot -> Int -> Ty -> Loc mregm
  deriving (Show)

-- | LTL unique instrustions
-- JP: wrdT is unused. Drop?
data LTLInstr' mreg wrdT operand =
    Lgetstack Slot Word Ty mreg -- load from the stack into a register
  | Lsetstack mreg Slot Word Ty -- store into the stack from a register
  | LCall
      Ty
      (Maybe mreg) -- ^ return register
      operand -- ^ function
      [Ty]         -- ^ types of parameters 
      [operand] -- ^ arguments
  | LRet (Maybe operand) -- ^ return this value
  | LAlloc
    (Maybe mreg) -- ^ return register (gives location)
    Ty   -- ^ type of the allocated thing
    operand -- ^ number of things allocated
  deriving (Show, Functor, Foldable, Traversable)
  
type LTLInstr mdata mreg wrdT =
  IRInstruction mdata mreg wrdT (LTLInstr' mreg wrdT $ MAOperand mreg wrdT)
  


-- |  Traverse the LTL instruction changing operands  
traverseOpLTLInstr :: (Applicative f) =>
  (MAOperand regT wrdT -> f (MAOperand regT wrdT))
  -> LTLInstr metadata regT wrdT
  -> f (LTLInstr metadata regT wrdT)
traverseOpLTLInstr = traverseOpIRInstr




-- data Function nameT paramT blockT =
--  Function nameT paramT [paramT] [blockT]
data LFunction mdata mreg wrdT = LFunction {
    funName :: String -- should this be a special label?
  , funMetadata :: mdata
  , retType :: Ty
  , paramTypes :: [Ty]
  , stackSize :: Word
  , funBody:: [BB Name $ LTLInstr mdata mreg wrdT]
  } deriving (Show)

-- | Traverse the LTL functions and replacing operands 
traverseOpLFun :: (Applicative f) =>
  (MAOperand regT wrdT -> f (MAOperand regT wrdT))
  -> LFunction mdata regT wrdT
  -> f $ LFunction mdata regT wrdT
traverseOpLFun fop lf = (\body -> lf {funBody = body}) <$>
                        traverseOpBBs fop (funBody lf)
  where traverseOpBBs fop = traverse (traverseOpBB fop)

type Lprog mdata mreg wrdT = IRprog mdata wrdT $ LFunction mdata mreg wrdT


-- | Traverse the LTL Program and replacing operands
traverseOpLprog :: (Applicative f) =>
  (MAOperand regT wrdT -> f (MAOperand regT wrdT))
  -> Lprog mdata regT wrdT
  -> f $ Lprog mdata regT wrdT
traverseOpLprog fop = traverse (traverseOpLFun fop)


-- Converts a RTL program to a LTL program.
rtlToLtl :: forall mdata wrdT . Monoid mdata => Rprog mdata wrdT -> Hopefully $ Lprog mdata VReg wrdT
rtlToLtl (IRprog tenv globals code) = do
  code' <- mapM convertFunc code
  return $ IRprog tenv globals code'
  where
   convertFunc :: RFunction mdata wrdT -> Hopefully $ LFunction mdata VReg wrdT
   convertFunc (Function name retType paramTypes body _nextReg) = do
     -- JP: Where should we get the metadata and stack size from?
     let mdata = mempty
     let stackSize = 0 -- Since nothing is spilled 0
     let name' = case name of
           Name n -> BSC.unpack $ fromShort n
           NewName n -> show n

     body' <- mapM convertBasicBlock body
     return $ LFunction name' mdata retType paramTypes stackSize body' 

   convertBasicBlock :: BB name (RTLInstr mdata wrdT) -> Hopefully $ BB name (LTLInstr mdata VReg wrdT)
   convertBasicBlock (BB name instrs term dag) = do
     instrs' <- mapM convertIRInstruction instrs
     term' <- mapM convertIRInstruction term
     return $ BB name instrs' term' dag

   convertIRInstruction :: RTLInstr mdata wrdT -> Hopefully $ LTLInstr mdata VReg wrdT
   convertIRInstruction (MRI inst mdata) = return $ MRI inst mdata
   convertIRInstruction (IRI inst mdata) = do
     inst' <- convertInstruction inst
     return $ IRI inst' mdata

   convertInstruction ::
     RTLInstr' (MAOperand VReg wrdT)
     -> Hopefully $ LTLInstr' VReg wrdT (MAOperand VReg wrdT)
   convertInstruction (RCall t mr f ts as) = return $ LCall t mr f ts as
   convertInstruction (RRet mo) = return $ LRet mo
   convertInstruction (RAlloc mr t o) = return $ LAlloc mr t o
   convertInstruction (RPhi _ _) = implError "Phi. Not implemented in the trivial Register allocation."
   
