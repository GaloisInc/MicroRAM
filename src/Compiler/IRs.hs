{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
module Compiler.IRs where

import MicroRAM.MicroRAM(MAOperand)
import qualified MicroRAM.MicroRAM as MRAM
import Data.ByteString.Short

type ($) a b = a b

{-|
Module      : Irs
Description : Several intermediate representations between LLVM and MicroRAM
Maintainer  : santiago@galois.com
Stability   : Prototype

Intermedaiate representations are Languages taking all the instructions from MicroRAM
and adding some functionality such as functions Stack locations etc.

-}

-- ** Generic IR
-- An IR is made of MRAM instructions plus some new ones
data IRInstruction metadata regT wrdT irinst =
   MRI (MRAM.MAInstruction regT wrdT) metadata
  | IRI irinst metadata

data Function nameT paramT blockT =
  Function nameT paramT [paramT] [blockT] deriving (Functor)

type DAGinfo = [Name]
-- | Basic blocks:
-- | it's a list of instructions + all the blocks that it can jump to
data BB instrT = BB Name [instrT] DAGinfo
  deriving (Functor)

type IRFunction mdata regT wrdT irinstr =
  Function Name Ty (BB $ IRInstruction mdata regT wrdT irinstr)

data Name =
  Name ShortByteString -- | we keep the LLVM names
  | NewName Word         -- | and add some new ones
  deriving (Eq, Ord, Read, Show)

type TypeEnv = () -- TODO

data GlobalVariable wrdT = GlobalVariable
  { name :: Name
  , isConstant :: Bool
  , gType :: Ty
  , initializer :: Maybe wrdT
  }
type GEnv wrdT = [GlobalVariable wrdT] -- Maybe better as a map:: Name -> "gvar description"
data IRprog mdata wrdT funcT = IRprog
  { typeEnv :: TypeEnv
  , globals :: GEnv wrdT
  , code :: [funcT]
  } deriving (Functor)




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
    
    
type RTLInstr mdata wrdT = IRInstruction mdata VReg wrdT (RTLInstr' $ MAOperand VReg wrdT)


type RFunction mdata wrdT =
  IRFunction mdata VReg wrdT (RTLInstr' $ MAOperand VReg wrdT)
  
type Rprog mdata wrdT = IRprog mdata wrdT $ RFunction mdata wrdT









-- -------------------------------
-- ** Location Transfer Language
-- -------------------------------

-- It's the target language for register allocation: Close to RTL but uses machine registers and stack slots instead of virtual registers.

-- | Ty determines the type of something in the stack. Helps us calculate
-- stack offsets for stack layout
-- FIXME: For now we assume everything is an int, but the code should be
--  written genrically over this type so it's easy to change
data Ty = Tint

-- Determines the relative size of types (relative to a 32bit integer)
tySize :: Ty -> Word
tySize _ = 1


-- | Slots are abstract representation of locations in the activation record and come in three kinds
data Slot =
    Local     -- ^ Used by register allocation to spill pseudo-registers to the stack
  | Incoming  -- ^ Stores parameters of the current function
  | Outgoing  -- ^ Stores arguments to the called function that cannot be in registers.
  deriving (Eq, Read, Show)

-- | Locations are the disjoint union of machine registers and stack loctions
data Loc mreg where
  R :: mreg -> Loc mreg
  L :: Slot -> Int -> Ty -> Loc mregm

-- | LTL unique instrustions
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
    mreg -- ^ return register (gives location)
    Ty   -- ^ type of the allocated thing
    operand -- ^ number of things allocated
  
type LTLInstr mdata mreg wrdT =
  IRInstruction mdata mreg wrdT (LTLInstr' mreg wrdT $ MAOperand mreg wrdT)

-- data Function nameT paramT blockT =
--  Function nameT paramT [paramT] [blockT]
data LFunction mdata mreg wrdT = LFunction {
  funName :: String -- should this be a special label?
  , funMetadata :: mdata
  , retType :: Ty
  , paramTypes :: [Ty]
  , stackSize :: Word
  , funBody:: [BB $ LTLInstr mdata mreg wrdT]
}

type Lprog mdata mreg wrdT = IRprog mdata wrdT $ LFunction mdata mreg wrdT