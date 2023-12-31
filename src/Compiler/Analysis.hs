{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}

{-|
Module      : Analysis
Description : The data type of analysis information
Maintainer  : santiago@galois.com
Stability   : experimental

Metadata is produced by the compiler and passed down to the witness generator.

-}
module Compiler.Analysis where

import qualified Data.Map as Map
import Data.Default
import Sparsity.Sparsity

import Compiler.Common (Name)

data AnalysisPiece =
  SparsityData Sparsity
  | FunctionUsage (Map.Map Name Int)
  deriving (Eq, Ord, Read, Show)

data AnalysisData =
  AnalysisData {
  -- | sparsity of different instruction kinds
  sparsityData :: Sparsity
  -- | Estimate the number of times each function is called 
  , functionUsage :: Map.Map Name Int
  } deriving (Eq, Ord, Read, Show)

instance Default AnalysisData where
  def = AnalysisData {
    sparsityData = mempty
    , functionUsage = mempty
    }

    
addAnalysisPiece :: AnalysisPiece -> AnalysisData -> AnalysisData
addAnalysisPiece piece adata =
 case piece of
   SparsityData spar -> adata {sparsityData = spar}
   FunctionUsage fusage -> adata {functionUsage = fusage }

appendAnalysisData :: AnalysisData -> AnalysisData -> AnalysisData
appendAnalysisData ad1 ad2 = AnalysisData
  { sparsityData = Map.unionWith max (sparsityData ad1) (sparsityData ad2)
  , functionUsage = Map.unionWith (+) (functionUsage ad1) (functionUsage ad2)
  }

renameAnalysisData :: (Name -> Name) -> AnalysisData -> AnalysisData
renameAnalysisData f (AnalysisData sd fu) =
  AnalysisData
    sd
    (Map.fromListWith (+) [(f name, count) | (name, count) <- Map.toList fu])
