module Compiler.Compiler
    ( compile, compileStraight
    ) where

import qualified LLVM.AST as LLVM
import qualified LLVM.AST.Constant as LLVM.Constant
import Control.Monad.State.Lazy
import Control.Monad.Except
import qualified Data.List as List
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Short as Short
import qualified Data.Sequence as Seq (lookup, fromList)
import qualified Data.Word as Word

import Compiler.CodeGenerator
import Compiler.Assembler
import MicroRAM.MicroRAM (Program,NamedBlock(..))

compile :: LLVM.Module
        -> CgMonad (MicroRAM.MicroRAM.Program Int Word)
compile llvmProg = do
  assProg <- codeGen llvmProg
  mramProg <- assemble assProg
  Right mramProg


compileStraight :: [LLVM.Named LLVM.Instruction]
        -> CgMonad (MicroRAM.MicroRAM.Program Int Word)
compileStraight llvmProg = do
  assCode <- codeGenStraight llvmProg
  mramProg <- assemble [NBlock Nothing $ assCode]
  Right mramProg
