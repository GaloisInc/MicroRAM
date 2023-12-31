{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-|
Module      : CBOR Format
Description : Format the output of the compiler and interpreter as CBOR
              to communicate down with the Circuit generator.
Maintainer  : santiago@galois.com
Stability   : experimental

Format for compiler units

-}

module Output.CBORFormat where

import GHC.Generics

import Codec.CBOR.FlatTerm (fromFlatTerm, toFlatTerm, FlatTerm)
import Codec.CBOR.Decoding
import Codec.CBOR.Encoding
import Codec.CBOR.Write
import Codec.CBOR.Read
import Codec.CBOR.Pretty
import Codec.Serialise

import qualified Data.ByteString.Lazy                  as L
import           Data.Maybe (isJust)

import Compiler.CompilationUnit
import Compiler.Common (Name)
import Compiler.Registers
-- import Compiler.IRs
--import Compiler.Sparsity

import MicroRAM.MRAMInterpreter
import MicroRAM

import Segments.Segmenting

import Sparsity.Sparsity

-- Get version number
import Paths_MicroRAM (version)
import Data.Version (Version(..))

import qualified Data.Text as TXT 


import Output.Output


-- * Full Output

encodeOutput :: Serialise reg => Output reg -> Encoding
encodeOutput (SecretOutput prog segs params initM labels trc adv) =
  map2CBOR $ 
  -- NB: The order of entries here must match the order of fields in
  -- `SecretOutput`, since `decodeOutput` only looks at the order and not the
  -- field names.
  [ ("program", encode prog)
  , ("segments", encode segs)
  , ("params", encode params)
  , ("init_mem", encode initM)
  , ("labels", encode labels)
  , ("trace", encode trc)
  , ("advice", encode adv)
  ]
encodeOutput (PublicOutput prog segs params initM labels) =
  map2CBOR $ 
  [ ("program", encode prog)
  , ("segments", encode segs)
  , ("params", encode params)
  , ("init_mem", encode initM)
  , ("labels", encode labels)
  ]

decodeOutput :: Serialise reg => Decoder s (Output reg)
decodeOutput = do
  len <- decodeMapLen
  case len of
    7 -> SecretOutput <$> tagDecode <*> tagDecode <*> tagDecode <*> tagDecode <*> tagDecode  <*> tagDecode <*> tagDecode
    5 -> PublicOutput <$> tagDecode <*> tagDecode <*> tagDecode  <*> tagDecode <*> tagDecode
    n -> fail $ "Only lengths for output are 5 and 7 (Public and Secret). Insted found: " ++ show n

instance Serialise reg => Serialise (Output reg) where 
    encode = encodeOutput
    decode = decodeOutput

-- * Utils

deriving instance Generic Int
deriving instance Generic Word

lengthW :: Foldable t => t a -> Word
lengthW = fromIntegral . length

list2CBOR :: [Encoding] -> Encoding
list2CBOR ls = foldl (<>) mempty (encodeListLen (lengthW ls) : ls )

tagDecode :: Serialise t => Decoder s t
tagDecode = decodeString *> decode

map2CBOR :: [(TXT.Text, Encoding)] -> Encoding
map2CBOR ls =
     foldl (<>) mempty $ (encodeMapLen len) : map encodeField ls
    where len = lengthW ls

          encodeField :: (TXT.Text, Encoding) -> Encoding
          encodeField (str, enc) = encodeString str <> enc
  


-- * Public Output
-- Public output is generated "statically" (without knowing the input). It can be obtained
-- by the verifier and the prover and has the following elements:
-- 1. Program
-- 2. Parameters
--    * Number of registers
--    * Trace length
--    * Sparcity


-- ** Program 

-- It is enough to show an instance of `Serialise (Instruction r w)` to get an instance for
-- full programs (given the instance `Serialise a => Serialise [a]`).



encodeOperand' :: (Serialise regT, Serialise wrdT) => Operand regT wrdT -> [Encoding]
encodeOperand' (Reg r) =  [encodeBool False , encode r] 
encodeOperand' (Const c) =  [encodeBool True, encode c] 

encodeOperand :: (Serialise regT, Serialise wrdT) => Operand regT wrdT -> Encoding
encodeOperand  = list2CBOR . encodeOperand'

decodeOperand' :: (Serialise regT, Serialise wrdT) => Decoder s (Operand regT wrdT)
decodeOperand' = do
  kind <- decodeBool
  case kind of
    False -> Reg <$> decode
    True  -> Const <$> decode

decodeOperand :: (Serialise regT, Serialise wrdT) => Decoder s (Operand regT wrdT)
decodeOperand = do
  _ <- decodeListLen
  kind <- decodeBool
  case kind of
    False -> Reg <$> decode
    True  -> Const <$> decode

instance (Serialise regT, Serialise wrdT) => Serialise (Operand regT wrdT) where
    encode = encodeOperand
    decode = decodeOperand


encodeInstr :: forall regT wrdT. (Serialise regT, Serialise wrdT) =>
  Instruction regT wrdT -> Encoding
encodeInstr (Iand r1 r2 operand  ) = list2CBOR $ encodeString "and"    : encode r1  : encode r2  : (encodeOperand' operand)
encodeInstr (Ior r1 r2 operand   ) = list2CBOR $ encodeString "or"     : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Ixor r1 r2 operand  ) = list2CBOR $ encodeString "xor"    : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Inot r1 operand     ) = list2CBOR $ encodeString "not"    : encode r1  : encodeNull : (encodeOperand' operand) 
encodeInstr (Iadd r1 r2 operand  ) = list2CBOR $ encodeString "add"    : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Isub r1 r2 operand  ) = list2CBOR $ encodeString "sub"    : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Imull r1 r2 operand ) = list2CBOR $ encodeString "mull"   : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Iumulh r1 r2 operand) = list2CBOR $ encodeString "umulh"  : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Ismulh r1 r2 operand) = list2CBOR $ encodeString "smulh"  : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Iudiv r1 r2 operand ) = list2CBOR $ encodeString "udiv"   : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Iumod r1 r2 operand ) = list2CBOR $ encodeString "umod"   : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Ishl r1 r2 operand  ) = list2CBOR $ encodeString "shl"    : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Ishr r1 r2 operand  ) = list2CBOR $ encodeString "shr"    : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Icmpe r1 r2 operand ) = list2CBOR $ encodeString "cmpe"   : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Icmpa r1 r2 operand ) = list2CBOR $ encodeString "cmpa"   : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Icmpae r1 r2 operand) = list2CBOR $ encodeString "cmpae"  : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Icmpg r1 r2 operand ) = list2CBOR $ encodeString "cmpg"   : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Icmpge r1 r2 operand) = list2CBOR $ encodeString "cmpge"  : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Imov r1 operand     ) = list2CBOR $ encodeString "mov"    : encode r1  : encodeNull : (encodeOperand' operand) 
encodeInstr (Icmov r1 r2 operand ) = list2CBOR $ encodeString "cmov"   : encode r1  : encode r2  : (encodeOperand' operand) 
encodeInstr (Ijmp operand        ) = list2CBOR $ encodeString "jmp"    : encodeNull : encodeNull : (encodeOperand' operand) 
encodeInstr (Icjmp r2 operand    ) = list2CBOR $ encodeString "cjmp"   : encodeNull : encode r2  : (encodeOperand' operand) 
encodeInstr (Icnjmp r2 operand   ) = list2CBOR $ encodeString "cnjmp"  : encodeNull : encode r2  : (encodeOperand' operand) 
encodeInstr (Istore W1 operand r2) = list2CBOR $ encodeString "store1" : encodeNull : encode r2  : (encodeOperand' operand) 
encodeInstr (Istore W2 operand r2) = list2CBOR $ encodeString "store2" : encodeNull : encode r2  : (encodeOperand' operand) 
encodeInstr (Istore W4 operand r2) = list2CBOR $ encodeString "store4" : encodeNull : encode r2  : (encodeOperand' operand) 
encodeInstr (Istore W8 operand r2) = list2CBOR $ encodeString "store8" : encodeNull : encode r2  : (encodeOperand' operand) 
encodeInstr (Iload W1 r1 operand ) = list2CBOR $ encodeString "load1"  : encode r1  : encodeNull : (encodeOperand' operand)
encodeInstr (Iload W2 r1 operand ) = list2CBOR $ encodeString "load2"  : encode r1  : encodeNull : (encodeOperand' operand)
encodeInstr (Iload W4 r1 operand ) = list2CBOR $ encodeString "load4"  : encode r1  : encodeNull : (encodeOperand' operand)
encodeInstr (Iload W8 r1 operand ) = list2CBOR $ encodeString "load8"  : encode r1  : encodeNull : (encodeOperand' operand)
encodeInstr (Iread r1 operand    ) = list2CBOR $ encodeString "read"   : encode r1  : encodeNull : (encodeOperand' operand)
encodeInstr (Ianswer operand     ) = list2CBOR $ encodeString "answer" : encodeNull : encodeNull : (encodeOperand' operand) 
encodeInstr (Ipoison W8 operand r2) = list2CBOR $ encodeString "poison8" : encodeNull : encode r2  : (encodeOperand' operand) 
encodeInstr (Ipoison w _ _       ) = error $ "bad poison width " ++ show w
encodeInstr (Iadvise r1 operand  ) = list2CBOR $ encodeString "advise" : encode r1  : encodeNull : (encodeOperand' operand)
encodeInstr (Itaint W1 r2 operand   ) = list2CBOR $ encodeString "taint1"  : encodeNull : encode r2  : (encodeOperand' operand)
encodeInstr (Itaint W2 r2 operand   ) = list2CBOR $ encodeString "taint2"  : encodeNull : encode r2  : (encodeOperand' operand)
encodeInstr (Itaint W4 r2 operand   ) = list2CBOR $ encodeString "taint4"  : encodeNull : encode r2  : (encodeOperand' operand)
encodeInstr (Itaint W8 r2 operand   ) = list2CBOR $ encodeString "taint8"  : encodeNull : encode r2  : (encodeOperand' operand)
encodeInstr (Isink W1 r2 operand    ) = list2CBOR $ encodeString "sink1"   : encodeNull : encode r2  : (encodeOperand' operand)
encodeInstr (Isink W2 r2 operand    ) = list2CBOR $ encodeString "sink2"   : encodeNull : encode r2  : (encodeOperand' operand)
encodeInstr (Isink W4 r2 operand    ) = list2CBOR $ encodeString "sink4"   : encodeNull : encode r2  : (encodeOperand' operand)
encodeInstr (Isink W8 r2 operand    ) = list2CBOR $ encodeString "sink8"   : encodeNull : encode r2  : (encodeOperand' operand)
-- `Iext` and `Iextval` should have been compiled away by a previous pass, but
-- it's sometimes useful for debugging to include them in the output CBOR.  The
-- witness checker generator doesn't support these instructions at all, so how
-- we encode the operands doesn't really matter - it's only for human
-- consumption.
encodeInstr (Iext ext) =
  let parts = case ext of
        XTrace desc ops -> [encodeString "Trace", encodeString desc] ++ concatMap encodeOperand' ops
        XTraceStr ptr -> [encodeString "TraceStr"] ++ encodeOperand' ptr
        XTraceExec name ops -> [encodeString "TraceExec"] ++ concatMap encodeOperand' (name : ops)
        XFree ptr -> [encodeString "Free"] ++ encodeOperand' ptr
        XAccessValid lo hi -> [encodeString "AccessValid"] ++ concatMap encodeOperand' [lo, hi]
        XAccessInvalid lo hi -> [encodeString "AccessInvalid"] ++ concatMap encodeOperand' [lo, hi]
        XStoreUnchecked ptr val -> [ encodeString "StoreUnchecked" ] ++ concatMap encodeOperand' [ptr, val]
        XSnapshot -> [encodeString "Snapshot"]
        XCheck _instr _name _off -> error "Cannon serialize native instruction"
  in list2CBOR $ encodeString "ext" : parts
encodeInstr (Iextval r1 ext) =
  let parts = case ext of
        XLoadUnchecked ptr -> [encodeString "LoadUnchecked"] ++ encodeOperand' ptr
  in list2CBOR $ encodeString "extval" : encode r1 : parts
-- `Iextadvise` is `Iadvise` plus a hint to the interpreter.  We serialize it
-- just like a plain `Iadvise`.
encodeInstr (Iextadvise r1 op2 _) = encodeInstr @regT @wrdT (Iadvise r1 op2)

decodeOperands :: (Serialise regT, Serialise wrdT) => Int -> Decoder s ([regT], Operand regT wrdT)
decodeOperands 0 = fail "invalid number of operands: 0"
decodeOperands 1 = fail "invalid number of operands: 1"
decodeOperands 2 = do
  oper <- decodeOperand
  return $ ([], oper)
decodeOperands n = do
  op <- decode
  (ops, oper) <- decodeOperands (n-1) 
  return $ (op : ops, oper)

decodeInstr :: (Serialise regT, Serialise ops) => Decoder s (Instruction regT ops)
decodeInstr = do
    _ <- decodeListLen
    tag <- decodeString
    case tag of 
      "and"     -> Iand    <$> decode     <*> decode     <*> decodeOperand' 
      "or"      -> Ior     <$> decode     <*> decode     <*> decodeOperand' 
      "xor"     -> Ixor    <$> decode     <*> decode     <*> decodeOperand' 
      "not"     -> Inot    <$> decode     <*  decodeNull <*> decodeOperand' 
      "add"     -> Iadd    <$> decode     <*> decode     <*> decodeOperand' 
      "sub"     -> Isub    <$> decode     <*> decode     <*> decodeOperand' 
      "mull"    -> Imull   <$> decode     <*> decode     <*> decodeOperand' 
      "umulh"   -> Iumulh  <$> decode     <*> decode     <*> decodeOperand' 
      "smulh"   -> Ismulh  <$> decode     <*> decode     <*> decodeOperand' 
      "udiv"    -> Iudiv   <$> decode     <*> decode     <*> decodeOperand' 
      "umod"    -> Iumod   <$> decode     <*> decode     <*> decodeOperand' 
      "shl"     -> Ishl    <$> decode     <*> decode     <*> decodeOperand' 
      "shr"     -> Ishr    <$> decode     <*> decode     <*> decodeOperand' 
      "cmpe"    -> Icmpe   <$> decode     <*> decode     <*> decodeOperand' 
      "cmpa"    -> Icmpa   <$> decode     <*> decode     <*> decodeOperand' 
      "cmpae"   -> Icmpae  <$> decode     <*> decode     <*> decodeOperand' 
      "cmpg"    -> Icmpg   <$> decode     <*> decode     <*> decodeOperand' 
      "cmpge"   -> Icmpge  <$> decode     <*> decode     <*> decodeOperand' 
      "mov"     -> Imov    <$> decode     <*  decodeNull <*> decodeOperand' 
      "cmov"    -> Icmov   <$> decode     <*> decode     <*> decodeOperand' 
      "jmp"     -> Ijmp    <$  decodeNull <*  decodeNull <*> decodeOperand' 
      "cjmp"    -> Icjmp   <$  decodeNull <*> decode     <*> decodeOperand' 
      "cnjmp"   -> Icnjmp  <$  decodeNull <*> decode     <*> decodeOperand' 
      "store1"  -> flip (Istore W1) <$  decodeNull <*> decode     <*> decodeOperand' 
      "store2"  -> flip (Istore W2) <$  decodeNull <*> decode     <*> decodeOperand' 
      "store4"  -> flip (Istore W4) <$  decodeNull <*> decode     <*> decodeOperand' 
      "store8"  -> flip (Istore W8) <$  decodeNull <*> decode     <*> decodeOperand' 
      "load1"   -> Iload W1 <$> decode     <*  decodeNull <*> decodeOperand'
      "load2"   -> Iload W2 <$> decode     <*  decodeNull <*> decodeOperand'
      "load4"   -> Iload W4 <$> decode     <*  decodeNull <*> decodeOperand'
      "load8"   -> Iload W8 <$> decode     <*  decodeNull <*> decodeOperand'
      "read"    -> Iread   <$> decode     <*  decodeNull <*> decodeOperand'
      "answer"  -> Ianswer <$  decodeNull <*  decodeNull <*> decodeOperand'
      "poison8" -> flip (Ipoison W8) <$  decodeNull <*> decode     <*> decodeOperand'  
      "advise"  -> Iadvise <$> decode     <*  decodeNull <*> decodeOperand'
      _ -> fail $ "invalid instruction encoding. Tag: " ++ show tag ++ "."

instance (Serialise regT, Serialise wrdT) => Serialise (Instruction regT wrdT) where
    encode = encodeInstr
    decode = decodeInstr

{- Quick test:-}
a :: Program Word MWord
a = [Istore W4 (Reg 77) 1, Ijmp (Reg 42),Iadd 2 3 (Const 4)]
x :: Either String (Instruction' Word Word (Operand Word MWord))
x = fromFlatTerm decode $ toFlatTerm $ encode a

b :: Instruction Word MWord
b = Istore W4 (Reg 0) 0
y :: L.ByteString
y = serialise b


-- ** Parameters

encodeInstrKind :: InstrKind -> Encoding
encodeInstrKind ik = encodeString $ TXT.pack $ show ik

decodeInstrKind :: Decoder s InstrKind
decodeInstrKind = do
  txt <- decodeString
  return $ read $ TXT.unpack txt

instance Serialise InstrKind where
  encode = encodeInstrKind
  decode = decodeInstrKind

encodeParams :: CircuitParameters -> Encoding 
encodeParams (CircuitParameters numRegs sparc ) = 
  map2CBOR $
  [ ("num_regs", encodeWord numRegs)
  , ("sparcity", encode sparc)
  ]

decodeParams :: Decoder s CircuitParameters 
decodeParams = do
  len <- decodeMapLen
  case len of
    2 -> CircuitParameters <$ decodeString <*> decodeWord
         <* decodeString <*> decode
    _ -> fail $ "invalid parameters encoding. Length should be 3 but found " ++ show len


instance Serialise CircuitParameters where
  encode = encodeParams
  decode = decodeParams


-- ** Initial Mem
-- Some parts of this are public and some private


encodeInitMemSegment :: InitMemSegment -> Encoding
encodeInitMemSegment (InitMemSegment name secret read heapInit start len datas labels) =
  map2CBOR $
  [ ("name", encode name) 
  , ("secret", encodeBool secret) 
  , ("read_only", encodeBool read)
  , ("heap_init", encodeBool heapInit)
  , ("start", encode start)
  , ("len", encode len)
  ] ++  encodeMaybeContent "data" datas
    ++  encodeMaybeContent "tainted" labels


encodeMaybeContent :: Serialise a => TXT.Text -> Maybe a -> [(TXT.Text,Encoding)]
encodeMaybeContent _ Nothing = []
encodeMaybeContent s (Just content) = return (s,encode content)


decodeInitMemSegment :: Decoder s InitMemSegment
decodeInitMemSegment = do
    len <- decodeMapLen
    case len of
      6 -> InitMemSegment <$> tagDecode <*> tagDecode <*> tagDecode <*> tagDecode <*>
           tagDecode <*> tagDecode <*> pure Nothing <*> pure Nothing
      7 -> InitMemSegment <$> tagDecode <*> tagDecode <*> tagDecode <*> tagDecode <*>
           tagDecode <*> tagDecode <*> fmap Just tagDecode <*> pure Nothing
      8 -> InitMemSegment <$> tagDecode <*> tagDecode <*> tagDecode <*> tagDecode <*>
           tagDecode <*> tagDecode <*> fmap Just tagDecode <*> fmap Just tagDecode
      _ -> fail $ "invalid state encoding. Length should be 5-7 but found " ++ show len

instance Serialise InitMemSegment where
  decode = decodeInitMemSegment
  encode = encodeInitMemSegment

-- * Secret Output
-- Public output is generated "statically" (without knowing the input). It can be obtained
-- by the verifier and the prover and has the following elements:
-- 1. Trace
-- 2. Advice
-- 3. Initial Memory



-- ** Traces 

-- *** State Out 

encodeStateOut :: StateOut -> Encoding
encodeStateOut (StateOut pc regs regLabels) =
  map2CBOR $
  [ ("pc", encode pc)
  , ("regs", encode regs)
  ]
  ++ encodeMaybeContent "tainted_regs" regLabels

decodeStateOut :: Decoder s StateOut
decodeStateOut = do
    len <- decodeMapLen
    case len of
      2 -> StateOut <$ decodeString <*> decode
                    <* decodeString <*> decode
                    <*> pure Nothing
      3 -> StateOut <$ decodeString <*> decode
                    <* decodeString <*> decode
                    <* decodeString <*> (fmap Just decode)
      _ -> fail $ "invalid state encoding. Length should be 2 or 3 but found " ++ show len

instance Serialise StateOut where
  decode = decodeStateOut
  encode = encodeStateOut


-- ** Advice

encodeMemOpType :: MemOpType -> Encoding
encodeMemOpType MOStore = encodeString "write"
encodeMemOpType MOLoad = encodeString "read"
encodeMemOpType MOPoison = encodeString "poison"

decodeMemOpType :: Decoder s MemOpType
decodeMemOpType = do
  memOp <- decodeString
  case memOp of
    "write" -> return MOStore
    "read" -> return MOLoad
    "poison" -> return MOPoison
    t -> fail $ "Memory operation not known: " ++ show t 

instance Serialise MemOpType where
  decode = decodeMemOpType
  encode = encodeMemOpType


instance Serialise MemWidth where
  decode = do
    w <- decode :: Decoder s Int
    case w of
      1 -> return W1
      2 -> return W2
      4 -> return W4
      8 -> return W8
      _ -> fail $ "bad memory op width: " ++ show w
  encode w = encode $ widthInt w


encodeAdvice :: Advice -> Encoding 
encodeAdvice  (MemOp addr val opTyp width label) =
  let taintLen = if isJust label then 1 else 0 in
  encodeListLen (5 + taintLen)
  <> encodeString "MemOp"
  <> encode addr
  <> encode val
  <> encode opTyp
  <> encode width
  <> maybe mempty encode label

encodeAdvice (Advise w) =
  encodeListLen 2
  <> encodeString "Advise"
  <> encode w

encodeAdvice  Stutter =
  encodeListLen 1 <>
  encodeString "Stutter"
  
decodeAdvice :: Decoder s Advice
decodeAdvice = do
  ln <- decodeListLen
  name <- decodeString
  case (ln,name) of
    (5, "MemOp") -> MemOp <$> decode <*> decode <*> decode <*> decode <*> pure Nothing
    (6, "MemOp") -> MemOp <$> decode <*> decode <*> decode <*> decode <*> (Just <$> decode)
    (1, "Stutter") -> return Stutter
    (ln,name) -> fail $ "Found bad advice of length " ++ show ln ++ " and name: " ++ show name 

instance Serialise Advice where
  decode = decodeAdvice
  encode = encodeAdvice

encodeConstraints :: Constraints -> Encoding
encodeConstraints (PcConst pc) =
  encodeListLen 2 <>
  encodeString "pc" <>
  encode pc

decodeConstraints :: Decoder s Constraints
decodeConstraints = do
  ln <- decodeListLen
  name <- decodeString
  case (ln, name) of
    (2, "pc") -> PcConst <$> decode
    (ln, name) -> fail $ "Invalid constraint encoding. Found length " ++ (show ln) ++ " and name: " ++ show name  


instance Serialise Constraints where
  decode = decodeConstraints
  encode = encodeConstraints

encodeSegmentOut :: SegmentOut -> Encoding
encodeSegmentOut (SegmentOut constr segLen segSuc fromNet toNet) =
  encodeListLen 5 <>
  encode constr <>
  encode segLen <>
  encode segSuc <>
  encode fromNet <>
  encode toNet

decodeSegmentOut :: Decoder s SegmentOut
decodeSegmentOut = do
  ln <- decodeListLen
  case ln of
    5 -> SegmentOut <$> decode <*> decode <*> decode <*> decode  <*> decode
    ln -> fail $ "Invalid segment encoding. Expected length is 5 but found" ++ show ln 

instance Serialise SegmentOut where
  decode = decodeSegmentOut
  encode = encodeSegmentOut

encodeTraceChunkOut :: Serialise reg => (TraceChunkOut reg) -> Encoding
encodeTraceChunkOut (TraceChunkOut location states) =
  encodeListLen 2 <>
  encode location <>
  encode states


decodeTraceChunkOut :: Serialise reg => Decoder s (TraceChunkOut reg)
decodeTraceChunkOut = do
  ln <- decodeListLen
  case ln of
    2 -> TraceChunkOut <$> decode <*> decode
    ln -> fail $ "Invalid TraceChunkOut encoding. Expected length is 2 but found" ++ show ln 


instance (Serialise reg) => Serialise (TraceChunkOut reg) where
  decode = decodeTraceChunkOut
  encode = encodeTraceChunkOut

  
-- ** Initial memory

-- Serialise is derived from lists and Words.



-- * Patch work
-- We prove the instance of Words to be serialisable
-- The hack here is that is not revertible names will go into Word's

encodeName :: Name -> Encoding
encodeName =  encodeWord . toWord

decodeName :: Decoder s Name
decodeName = do
  wrd <- decodeWord
  return $ fromWord wrd 

instance Serialise Name where
  decode = decodeName
  encode = encodeName

-- * Serialisations and other pretty printing formats

versionedOutput :: Output reg -> [String] -> ([Int], [String], Output reg)
versionedOutput out features = (versionBranch version, features, out)

serialOutput :: Serialise reg => Output reg -> [String] -> L.ByteString
serialOutput out features = toLazyByteString $ (encode $ versionedOutput out features)

serialInput :: Serialise reg => L.ByteString -> Either DeserialiseFailure (L.ByteString, Output reg)
serialInput string = deserialiseFromBytes (decodeOutput) string 

ppHexOutput :: Serialise reg => Output reg -> [String] -> String
ppHexOutput out features = prettyHexEnc $ encode $ versionedOutput out features

flatOutput :: Serialise reg => Output reg  -> [String] -> FlatTerm
flatOutput out features = toFlatTerm $ encode $ versionedOutput out features

data OutFormat =
    StdHex
  | PHex
  | Flat
  deriving (Eq, Ord, Show)


printOutputWithFormat :: Serialise reg => OutFormat -> Output reg -> [String] -> String
printOutputWithFormat StdHex out features = show $ (serialOutput out features) 
printOutputWithFormat PHex out features = ppHexOutput out features
printOutputWithFormat Flat out  features = show $ flatOutput out features
