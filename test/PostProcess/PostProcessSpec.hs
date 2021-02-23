{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
module PostProcess.PostProcessSpec where

import MicroRAM.MRAMInterpreter
import MicroRAM (MWord)

-- Compiler imports
import Compiler
import Compiler.Errors

import LLVMutil.LLVMIO
import Test.Tasty

import qualified Test.QuickCheck.Monadic as QCM
import Test.Tasty.QuickCheck
import Test.QuickCheck.Property as P

import Segments.SegInterpreter
import PostProcess

import Programs.Programs


main :: IO ()
main = defaultMain testsWithOptions 

-- We can't generate inputs right now, so set test number to 1
testsWithOptions :: TestTree
testsWithOptions = localOption (QuickCheckTests 1) postTests
  where postTests = mkPostTests allTests

mkPostTests :: TestGroup -> TestTree
mkPostTests tg = case tg of
  OneTest t -> mkPostTest t
  ManyTests nm ts -> testGroup nm $ mkPostTests <$> ts 

mkPostTest :: TestProgram -> TestTree
mkPostTest (TestProgram name file len res hasBug) = processTest  name file len

processTest :: TestName -> FilePath -> Word -> TestTree
processTest name file len =
  testProperty name $ QCM.monadicIO $ QCM.run (output file len)
  where output :: FilePath -> Word -> IO Property 
        output file len = do
          llvmProg <- llvmParse file
          mramProg <- handleErrorWith $ compile len llvmProg Nothing
          let postProcessed = compilerErrorResolve $ postProcess_v False chunkSize True mramProg
          return $ result2property $ checkOutput <$> postProcessed
        chunkSize = 10
        result2property r = case r of
                              Right _ -> counterexample "" True
                              Left msg -> counterexample msg False
