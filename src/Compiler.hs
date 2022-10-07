{-# LANGUAGE TypeOperators #-}


{-|
Module      : Compiler
Description : Cheesecloth compiler
Maintainer  : santiago@galois.com
Stability   : prototype

The cheesecloth compiler translates LLVM modules to MicroRAM as diagramed below:
  @
   +---------+
   |  LLVM   |
   +----+----+
        | Instruction selection
   +----v----+
   |         +---+
c  |         |   | Rename Intrinsics / Lower intrinsics
o  |         <---+
m  | MicroIR |
p  |         +---+
i  |         |   | Check for Undefined Functions
l  |         <---+
e  |         |
1  +----+----+
        | Legalize
   +----v----+
   |         +---+
   |         |   | Localize labels
   |         <---+
   |         |
   |         +---+
   |         |   | Edge Split
   |         <---+
   |         |
   |   RTL   +---+                 
   |         |   | Lower Extension Instrs (depends on run: hi/low)
   |         <---+
   |         |
   |         +---+
   |         |   | Remove Phi
   |         <---+
   |         |
   +----+----+
        | Register allocation
   +----v----+
   |         +---+
   |   LTL   |   | Calling conventions
   |         <---+
   +----+----+
        | Stacking
   +----v----+     Sparsity
   |MicroASM +------------->
   |         +---+
   |         |   | Block Cleanup
   |         <---+
   +----+----+
        | Label removal
   +----v----+
   |MicroRAM |
   +---------+
   @


= Source, intermediate and target languages: syntax and semantics

* __LLVM__ The LLVM assembly language as defined in <https://llvm.org/docs/LangRef.html>.
  We use the haskell implementation of `llvm-hs`.

* __MicroIR__ High-level IR based on MicroRAM.  Includes MicroRAM instructions with
   support for extended operand kinds and two non-register operands per
   instruction (normal MicroRAM requires one operand to be a register), as well
   as extended high-level instructions (see `MIRprog`).

* __RTL__ : Register Transfer language (RTL) uses infinite virtual registers,
  function calls, Stack allocation and regular MicroRAM instructions (see `Rprog`). 

* __LTL__ Location Transfer Language (LTL) is close to RTL but uses machine registers
  and stack slots instead of virtual registers (see `Lprog`). 

* __MicroASM__ : MicroRAM assembly langues. It enhances MicroRAM with support for
  global variables and code labels

* __MicroRAM__ : A simple machine language designed for zero knowledge
execution of programs.

= Compiler passes

* __Instruction Selection__ (`instrSelect`): Instruction selection translates LLVM to
  MicroIR. It's a linear pass that translates each LLVM instruction to 0 or MicroIR
  instructinos. For now, it does not combine instructinos.

* __Intrinsics__ (`renameLLVMIntrinsicImpls`, lowerIntrinsics): Inlines calls to
  intrinsics to MicroASM instructions. Renames the intrinsics from using underscors ("__") to
  using dot (".") and removes the empty bodies of those functions.

* _Check undefined functions_ (`checkUndefinedFuncs`): Produces an error if, at this point,
  any function has an empty body.

* __Legalize__ (`legalize`): This module compiles MicroIR to RTL.  It looks for
  instruction formats that aren't legal in RTL/MicroRAM, such as addition of two
  constants, and replaces them with legal sequences.  Usually this means adding an
  `Imov` to put one operand into a register, but for some instructions we can do better.

* __Localize labels__ (`localizeLabels`): Rename blocks local to a function to avoid conflicts
between functions.

* __Edge Split__ (`edgeSplit`) :  Split edges between blocks to ensure the unique
  successor or predecessor property.

* __Remove Phi__ (`removePhi`) : Removes phi functions inherited from the SSA form.

* __Register Allocation__ (`registerAlloc`): Register allocation

* __Calling Convention__ (`callingConvention`): Saving callee saved registersto the stack.

* __Stacking__ (`stacking`): Lays out the stack in memory. Moreover this pass adds
  the necessary instructions from stack frame creation and destruction on function
  call and return.

* __Sparsity analysis__ (`sparsity`): Estimates the minimum distance between two
  executions of the same opcode or op codes of the same class. For example, it can
  estimate the distance between memory operations. This pass is pureley analitical
  and does not modify the program. 

* __Remove Labels__ (`removeLabels`): Translates MicroASM to MicroRAM by
  removing code labels and replacing them with constant code pointers.

-}
module Compiler
    ( compile
    , CompilerOptions(..), defOptions
    , module Export
    ) where

import           Compiler.Analysis
import           Compiler.BlockCleanup
import           Compiler.CallingConvention
import           Compiler.Common (GlobalVariable)
import           Compiler.CompilationUnit
import           Compiler.CountFunctions
import           Compiler.Errors
import           Compiler.Extension
import           Compiler.IRs
import           Compiler.InstructionSelection
import           Compiler.Intrinsics
import           Compiler.LayArgs
import           Compiler.Legalize
import           Compiler.LocalizeLabels
import           Compiler.Metadata
import           Compiler.Name (firstUnusedName)
import           Compiler.RegisterAlloc
import           Compiler.RegisterAlloc as Export (AReg)
import           Compiler.RemoveLabels
import           Compiler.RemovePhi
import           Compiler.Stacking
import           Compiler.UndefinedFunctions

import           MicroRAM (MWord)
import           Sparsity.Sparsity
import           Util.Util

import           Data.Default
import           Debug.Trace

import qualified LLVM.AST as LLVM

-- When verbose, shows the current compilation pass for debugging. 
verbTagPass :: Bool -> String -> (a -> Hopefully b) -> a -> Hopefully b
verbTagPass verb txt x =
  (if verb then trace ("\tCompiler Pass: " <> txt) else id) $ tagPass txt x

data CompilerOptions = CompilerOptions
  { verb::Bool
  , allowUndefFun::Bool
  , spars::Maybe Int
  , tainted::Bool
  , skipRegisterAllocation::Bool
  , numberRegs::Maybe Word
  }

defOptions :: CompilerOptions
defOptions = CompilerOptions
  { verb = False
  , allowUndefFun = False
  , spars = Nothing
  , tainted = False
  , skipRegisterAllocation = False
  , numberRegs = Nothing
  }

compile1
  :: CompilerOptions
  -> Word
  -> LLVM.Module
  -> Word
  -> Hopefully (CompilationUnit () (MIRprog Metadata MWord))
compile1 options len llvmProg firstName = (return $ prog2unit len llvmProg firstName)
  >>= (verbTagPass verb "Instruction Selection" $ justCompileWithNames instrSelect)
  >>= (verbTagPass verb "Rename LLVM Intrinsic Implementations" $ justCompile renameLLVMIntrinsicImpls)
  >>= (verbTagPass verb "Lower Intrinsics" $ justCompileWithNamesSt lowerIntrinsics)
  >>= (verbTagPass verb "Catch undefined Functions" $ justCompile (catchUndefinedFunctions allowUndefFun))
  where CompilerOptions {verb=verb, allowUndefFun=allowUndefFun} = options

compile2
  :: CompilerOptions
  -> CompilationUnit () (MIRprog Metadata MWord)
  -> Hopefully (CompilationUnit [GlobalVariable MWord] (MAProgram Metadata AReg MWord))
compile2 options prog = return prog
  >>= (verbTagPass verb "Legalize Instructions" $ justCompileWithNames legalize)
  >>= (verbTagPass verb "Localize Labels"     $ justCompileWithNames localizeLabels)
  >>= (verbTagPass verb "Edge split"          $ justCompileWithNames edgeSplit)
  >>= (verbTagPass verb "Remove Phi Nodes"    $ justCompileWithNames removePhi)
  >>= (verbTagPass verb "Layout arguments"    $ justCompileWithNamesSt layArgs)
  >>= (verbTagPass verb "Register Allocation" $ registerAlloc skipRegisterAllocation numRegs)
  >>= (verbTagPass verb "Calling Convention"  $ justCompile callingConvention)
  >>= (verbTagPass verb "Stash Globals"       $ return . stashGlobals)
  >>= (verbTagPass verb "Count Functions"     $ justAnalyse countFunctions)
  >>= (verbTagPass verb "Stacking"            $ justCompileWithNames stacking)
  >>= (verbTagPass verb "Computing Sparsity"  $ justAnalyse (return . SparsityData . (forceSparsity spars))) 
  >>= (verbTagPass verb "Block cleanup"       $ blockCleanup)
  where numRegs = case numberRegs of
          Just n -> RegisterAllocOptions n
          Nothing -> def

        CompilerOptions { verb=verb
                        , spars=spars
                        , skipRegisterAllocation=skipRegisterAllocation
                        , numberRegs=numberRegs
                        } = options

compile3
  :: CompilerOptions
  -> CompilationUnit [GlobalVariable MWord] (MAProgram Metadata AReg MWord)
  -> Hopefully (CompilationUnit () (AnnotatedProgram Metadata AReg MWord))
compile3 options prog = return prog
  >>= (verbTagPass verb "Removing labels"     $ removeLabels tainted)
  where CompilerOptions { verb=verb, tainted=tainted } = options

compileLowerExt
  :: CompilerOptions
  -> CompilationUnit g (MIRprog Metadata MWord)
  -> Hopefully (CompilationUnit g (MIRprog Metadata MWord))
compileLowerExt options = verbTagPass (verb options) "Lower Extension Instructions" $
  justCompileWithNames lowerExtensionInstrs

compile :: CompilerOptions
        -> Word
        -> LLVM.Module
        -> Hopefully $ CompilationResult (AnnotatedProgram Metadata AReg MWord)
compile options len llvmProg = do
  ir <- compile1 options len llvmProg firstUnusedName
  high <- return ir
    >>= compile2 options
    >>= compile3 options
  low <- return ir
    >>= compileLowerExt options
    >>= compile2 options
    >>= compile3 options
  -- Return both programs, using the analysis data from the final one.
  return $ low { programCU = MultiProg (programCU high) (programCU low) }
