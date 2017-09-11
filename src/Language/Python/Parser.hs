-- from https://docs.python.org/3.5/reference/grammar.html
-- `test` is the production for an expression

{-# language ConstraintKinds #-}
{-# language DataKinds #-}
{-# language FlexibleContexts #-}
{-# language FlexibleInstances #-}
{-# language MultiParamTypeClasses #-}
{-# language TypeFamilies #-}
module Language.Python.Parser where

import GHC.Stack
import Prelude (error)

import Papa hiding (Space, zero, o, Plus, (\\), Product, argument)
import Data.CharSet ((\\))
import Data.Functor.Compose
import Data.Functor.Sum
import Text.Parser.LookAhead
import Data.Separated.After (After(..))
import Data.Separated.Before (Before(..))
import Data.Separated.Between (Between(..), Between'(..))
import Text.Trifecta as P hiding
  (stringLiteral, integer, octDigit, hexDigit, comma, colon)

import qualified Data.CharSet as CharSet
import qualified Data.CharSet.Common as CharSet
import qualified Data.Text as T

import Language.Python.AST.BytesLiteral
import Language.Python.AST.BytesPrefix
import Language.Python.AST.CompOperator
import Language.Python.AST.Digits
import Language.Python.AST.EscapeSeq
import Language.Python.AST.FactorOperator
import Language.Python.AST.Float
import Language.Python.AST.Identifier
import Language.Python.AST.Imag
import Language.Python.AST.Integer
import Language.Python.AST.Keywords
import Language.Python.AST.LongBytes
import Language.Python.AST.LongBytesChar
import Language.Python.AST.LongString
import Language.Python.AST.LongStringChar
import Language.Python.AST.ShortBytes
import Language.Python.AST.ShortBytesChar
import Language.Python.AST.ShortString
import Language.Python.AST.ShortStringChar
import Language.Python.AST.StringLiteral
import Language.Python.AST.StringPrefix
import Language.Python.AST.Symbols as S
import Language.Python.AST.TermOperator
import Language.Python.Parser.IR
import Language.Python.Parser.SrcInfo

leftParen ::(DeltaParsing m, LookAheadParsing m) => m LeftParen
leftParen = char '(' $> LeftParen

rightParen ::(DeltaParsing m, LookAheadParsing m) => m RightParen
rightParen = char ')' $> RightParen

whitespaceChar :: CharParsing m => m WhitespaceChar
whitespaceChar =
  (char ' ' $> Space) <|>
  (char '\t' $> Tab) <|>
  fmap Continued (char '\\' *> newlineChar)

whitespaceBefore :: CharParsing m => m a -> m (Before [WhitespaceChar] a)
whitespaceBefore m = Before <$> many whitespaceChar <*> m

whitespaceBeforeF
  :: CharParsing m
  => m (f a)
  -> m (Compose (Before [WhitespaceChar]) f a)
whitespaceBeforeF = fmap Compose . whitespaceBefore

whitespaceBefore1
  :: CharParsing m
  => m a
  -> m (Before (NonEmpty WhitespaceChar) a)
whitespaceBefore1 m = Before <$> some1 whitespaceChar <*> m

whitespaceBefore1F
  :: CharParsing m
  => m (f a)
  -> m (Compose (Before (NonEmpty WhitespaceChar)) f a)
whitespaceBefore1F = fmap Compose . whitespaceBefore1

whitespaceAfter :: CharParsing m => m a -> m (After [WhitespaceChar] a)
whitespaceAfter m = flip After <$> m <*> many whitespaceChar

whitespaceAfterF
  :: CharParsing m
  => m (f a)
  -> m (Compose (After [WhitespaceChar]) f a)
whitespaceAfterF = fmap Compose . whitespaceAfter

whitespaceAfter1
  :: CharParsing m
  => m a
  -> m (After (NonEmpty WhitespaceChar) a)
whitespaceAfter1 m = After <$> some1 whitespaceChar <*> m

whitespaceAfter1F
  :: CharParsing m
  => m (f a)
  -> m (Compose (After (NonEmpty WhitespaceChar)) f a)
whitespaceAfter1F = fmap Compose . whitespaceAfter1

betweenWhitespace
  :: CharParsing m
  => m a
  -> m (Between' [WhitespaceChar] a)
betweenWhitespace m =
  fmap Between' $
  Between <$>
  many whitespaceChar <*>
  m <*>
  many whitespaceChar

betweenWhitespaceF
  :: CharParsing m
  => m (f a)
  -> m (Compose (Between' [WhitespaceChar]) f a)
betweenWhitespaceF = fmap Compose . betweenWhitespace

betweenWhitespace1
  :: CharParsing m
  => m a
  -> m (Between' (NonEmpty WhitespaceChar) a)
betweenWhitespace1 m =
  fmap Between' $
  Between <$>
  some1 whitespaceChar <*>
  m <*>
  some1 whitespaceChar

betweenWhitespace1F
  :: CharParsing m
  => m (f a)
  -> m (Compose (Between' (NonEmpty WhitespaceChar)) f a)
betweenWhitespace1F = fmap Compose . betweenWhitespace1

ifThenElse ::(DeltaParsing m, LookAheadParsing m) => m (IfThenElse SrcInfo)
ifThenElse =
  IfThenElse <$>
  betweenWhitespace1 (string "if" $> KIf) <*>
  orTest <*>
  betweenWhitespace1 (string "else" $> KElse) <*>
  test

test ::(DeltaParsing m, LookAheadParsing m) => m (Test SrcInfo)
test = try testCond <|> testLambdef
  where
    testLambdef = unexpected "testLambdef not implemented"
    testCond =
      annotated $
      TestCond <$>
      orTest <*>
      optionalF (try $ whitespaceBefore1F ifThenElse)

kOr ::(DeltaParsing m, LookAheadParsing m) => m KOr
kOr = string "or" $> KOr

kAnd ::(DeltaParsing m, LookAheadParsing m) => m KAnd
kAnd = string "and" $> KAnd

orTest ::(DeltaParsing m, LookAheadParsing m) => m (OrTest SrcInfo)
orTest =
  annotated $
  OrTest <$>
  andTest <*>
  manyF (try $ beforeF (betweenWhitespace1 kOr) andTest)

varargsList ::(DeltaParsing m, LookAheadParsing m) => m (VarargsList SrcInfo)
varargsList = error "varargsList not implemented"

lambdefNocond ::(DeltaParsing m, LookAheadParsing m) => m (LambdefNocond SrcInfo)
lambdefNocond =
  annotated $
  LambdefNocond <$>
  optionalF
    (try $ betweenF
      (some1 whitespaceChar)
      (many whitespaceChar)
      varargsList) <*>
  whitespaceBeforeF testNocond

testNocond ::(DeltaParsing m, LookAheadParsing m) => m (TestNocond SrcInfo)
testNocond =
  annotated $
  TestNocond <$> (try (InL <$> orTest) <|> (InR <$> lambdefNocond))

compIf ::(DeltaParsing m, LookAheadParsing m) => m (CompIf SrcInfo)
compIf =
  annotated $
  CompIf <$>
  (betweenWhitespace1 $ string "if" $> KIf) <*>
  testNocond <*>
  optionalF (try $ whitespaceBeforeF compIter)

compIter ::(DeltaParsing m, LookAheadParsing m) => m (CompIter SrcInfo)
compIter =
  annotated $
  CompIter <$> (try (InL <$> compFor) <|> (InR <$> compIf))

starExpr ::(DeltaParsing m, LookAheadParsing m) => m (StarExpr SrcInfo)
starExpr =
  annotated $
  StarExpr <$>
  (char '*' *> whitespaceBeforeF expr)

exprList ::(DeltaParsing m, LookAheadParsing m) => m (ExprList SrcInfo)
exprList =
  annotated $
  ExprList <$>
  exprOrStar <*>
  manyF (try $ beforeF (betweenWhitespace comma) exprOrStar) <*>
  optional (try $ whitespaceBefore comma)
  where
    exprOrStar = try (InL <$> expr) <|> (InR <$> starExpr)

compFor
  :: (DeltaParsing m, LookAheadParsing m)
  => m (CompFor SrcInfo)
compFor =
  annotated $
  CompFor <$>
  beforeF
    (betweenWhitespace1 $ string "for" $> KFor)
    (whitespaceAfter1F exprList) <*>
  (string "in" *> whitespaceBefore1F orTest) <*>
  optionalF (try $ whitespaceBeforeF compIter)

doubleAsterisk ::(DeltaParsing m, LookAheadParsing m) => m DoubleAsterisk
doubleAsterisk = string "**" $> DoubleAsterisk

asterisk ::(DeltaParsing m, LookAheadParsing m) => m Asterisk
asterisk = char '*' $> Asterisk

colon ::(DeltaParsing m, LookAheadParsing m) => m Colon
colon = char ':' $> Colon

idStart ::(DeltaParsing m, LookAheadParsing m) => m Char
idStart = try letter <|> char '_'

idContinue ::(DeltaParsing m, LookAheadParsing m) => m Char
idContinue = try idStart <|> digit

identifier ::(DeltaParsing m, LookAheadParsing m) => m (Identifier SrcInfo)
identifier =
  annotated $
  Identifier . T.pack <$>
  liftA2 (:) idStart (many $ try idContinue)

stringPrefix ::(DeltaParsing m, LookAheadParsing m) => m StringPrefix
stringPrefix =
  try (char 'r' $> StringPrefix_r) <|>
  try (char 'u' $> StringPrefix_u) <|>
  try (char 'R' $> StringPrefix_R) <|>
  (char 'u' $> StringPrefix_U)

shortString :: (HasCallStack, DeltaParsing m, LookAheadParsing m) => m (ShortString SrcInfo)
shortString = try shortStringSingle <|> shortStringDouble
  where
    shortStringSingle =
      annotated $
      ShortStringSingle <$>
      (singleQuote *> manyTill charOrEscapeSingle (try singleQuote))

    shortStringDouble =
      annotated $
      ShortStringDouble <$>
      (doubleQuote *> manyTill charOrEscapeDouble (try doubleQuote))

    charOrEscapeSingle =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseShortStringCharSingle)

    charOrEscapeDouble =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseShortStringCharDouble)

longString :: (HasCallStack, DeltaParsing m, LookAheadParsing m) => m (LongString SrcInfo)
longString =
  (try longStringSingle <|> longStringSingleEmpty) <|>
  (try longStringDouble <|> longStringDoubleEmpty)
  where
    longStringSingleEmpty =
      annotated $
      tripleSinglequote *>
      tripleSinglequote $>
      LongStringSingleEmpty

    longStringDoubleEmpty =
      annotated $
      tripleDoublequote *>
      tripleDoublequote $>
      LongStringDoubleEmpty

    longStringSingle =
      annotated $
      LongStringSingle <$>
      (tripleSinglequote *>
       manyTill
         charOrEscape
         (lookAhead . try $ finalCharSingleOrEscape *> tripleSinglequote)) <*>
      (finalCharSingleOrEscape <* tripleSinglequote)

    longStringDouble =
      annotated $
      LongStringDouble <$>
      (tripleDoublequote *>
       manyTill
         charOrEscape
         (lookAhead . try $ finalCharDoubleOrEscape *> tripleDoublequote)) <*>
      (finalCharDoubleOrEscape <* tripleDoublequote)

    finalCharSingleOrEscape =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseLongStringCharFinalSingle)

    finalCharDoubleOrEscape =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseLongStringCharFinalDouble)

    charOrEscape =
      try (Right <$> escapeSeq) <|>
      (Left <$> longStringChar)

    longStringChar
      :: (HasCallStack, DeltaParsing m, LookAheadParsing m) => m LongStringChar
    longStringChar =
      -- (^?! _LongStringChar) <$> satisfy (/= '\\')
      (\c -> fromMaybe (error $ show c) $ c ^? _LongStringChar) <$>
      oneOfSet CharSet.ascii

stringLiteral ::(DeltaParsing m, LookAheadParsing m) => m (StringLiteral SrcInfo)
stringLiteral =
  annotated $
  StringLiteral <$>
  beforeF
    (optional $ try stringPrefix)
    ((InR <$> longString) <|> (InL <$> shortString))

bytesPrefix ::(DeltaParsing m, LookAheadParsing m) => m BytesPrefix
bytesPrefix =
  try (char 'b' $> BytesPrefix_b) <|>
  try (char 'B' $> BytesPrefix_B) <|>
  try (string "br" $> BytesPrefix_br) <|>
  try (string "Br" $> BytesPrefix_Br) <|>
  try (string "bR" $> BytesPrefix_bR) <|>
  try (string "BR" $> BytesPrefix_BR) <|>
  try (string "rb" $> BytesPrefix_rb) <|>
  try (string "rB" $> BytesPrefix_rB) <|>
  try (string "Rb" $> BytesPrefix_Rb) <|>
  (string "RB" $> BytesPrefix_RB)

shortBytes ::(DeltaParsing m, LookAheadParsing m) => m (ShortBytes SrcInfo)
shortBytes = try shortBytesSingle <|> shortBytesDouble
  where
    shortBytesSingle =
      annotated $
      ShortBytesSingle <$>
      (singleQuote *> manyTill charOrEscapeSingle (try singleQuote))
      
    shortBytesDouble =
      annotated $
      ShortBytesDouble <$>
      (doubleQuote *> manyTill charOrEscapeDouble (try doubleQuote))

    charOrEscapeSingle =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseShortBytesCharSingle)

    charOrEscapeDouble =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseShortBytesCharDouble)

tripleDoublequote ::(DeltaParsing m, LookAheadParsing m) => m ()
tripleDoublequote = string "\"\"\"" $> ()

tripleSinglequote ::(DeltaParsing m, LookAheadParsing m) => m ()
tripleSinglequote = string "'''" $> ()

doubleQuote ::(DeltaParsing m, LookAheadParsing m) => m ()
doubleQuote = char '"' $> ()

singleQuote ::(DeltaParsing m, LookAheadParsing m) => m ()
singleQuote = char '\'' $> ()

longBytes ::(DeltaParsing m, LookAheadParsing m) => m (LongBytes SrcInfo)
longBytes =
  (try longBytesSingle <|> longBytesSingleEmpty) <|>
  (try longBytesDouble <|> longBytesDoubleEmpty)
  where
    longBytesSingleEmpty =
      annotated $
      tripleSinglequote *>
      tripleSinglequote $>
      LongBytesSingleEmpty

    longBytesDoubleEmpty =
      annotated $
      tripleDoublequote *>
      tripleDoublequote $>
      LongBytesDoubleEmpty

    longBytesSingle =
      annotated $
      LongBytesSingle <$>
      (tripleSinglequote *>
       manyTill
         charOrEscape
         (lookAhead . try $ finalCharSingleOrEscape *> tripleSinglequote)) <*>
      (finalCharSingleOrEscape <* tripleSinglequote)

    longBytesDouble =
      annotated $
      LongBytesDouble <$>
      (tripleDoublequote *>
       manyTill
         charOrEscape
         (lookAhead . try $ finalCharDoubleOrEscape *> tripleDoublequote)) <*>
      (finalCharDoubleOrEscape <* tripleDoublequote)

    finalCharSingleOrEscape =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseLongBytesCharFinalSingle)

    finalCharDoubleOrEscape =
      try (Right <$> escapeSeq) <|>
      (Left <$> parseLongBytesCharFinalDouble)

    charOrEscape =
      try (Right <$> escapeSeq) <|>
      (Left <$> longBytesChar)

    longBytesChar
      :: (HasCallStack, DeltaParsing m, LookAheadParsing m) => m LongBytesChar
    longBytesChar =
      (\c -> fromMaybe (error $ show c) $ c ^? _LongBytesChar) <$>
      oneOfSet CharSet.ascii

bytesLiteral ::(DeltaParsing m, LookAheadParsing m) => m (BytesLiteral SrcInfo)
bytesLiteral =
  annotated $
  BytesLiteral <$>
  bytesPrefix <*>
  ((InR <$> longBytes) <|> (InL <$> shortBytes))

nonZeroDigit ::(DeltaParsing m, LookAheadParsing m) => m NonZeroDigit
nonZeroDigit =
  try (char '1' $> NonZeroDigit_1) <|>
  try (char '2' $> NonZeroDigit_2) <|>
  try (char '3' $> NonZeroDigit_3) <|>
  try (char '4' $> NonZeroDigit_4) <|>
  try (char '5' $> NonZeroDigit_5) <|>
  try (char '6' $> NonZeroDigit_6) <|>
  try (char '7' $> NonZeroDigit_7) <|>
  try (char '8' $> NonZeroDigit_8) <|>
  (char '9' $> NonZeroDigit_9)

digit' ::(DeltaParsing m, LookAheadParsing m) => m Digit
digit' =
  try (char '0' $> Digit_0) <|>
  try (char '1' $> Digit_1) <|>
  try (char '2' $> Digit_2) <|>
  try (char '3' $> Digit_3) <|>
  try (char '4' $> Digit_4) <|>
  try (char '5' $> Digit_5) <|>
  try (char '6' $> Digit_6) <|>
  try (char '7' $> Digit_7) <|>
  try (char '8' $> Digit_8) <|>
  (char '9' $> Digit_9)

zero ::(DeltaParsing m, LookAheadParsing m) => m Zero
zero = char '0' $> Zero

o ::(DeltaParsing m, LookAheadParsing m) => m (Either Char_o Char_O)
o =
  try (fmap Left $ char 'o' $> Char_o) <|>
  fmap Right (char 'O' $> Char_O)
  
x ::(DeltaParsing m, LookAheadParsing m) => m (Either Char_x Char_X)
x =
  try (fmap Left $ char 'x' $> Char_x) <|>
  fmap Right (char 'X' $> Char_X)
  
b ::(DeltaParsing m, LookAheadParsing m) => m (Either Char_b Char_B)
b =
  try (fmap Left $ char 'b' $> Char_b) <|>
  fmap Right (char 'B' $> Char_B)
  
octDigit ::(DeltaParsing m, LookAheadParsing m) => m OctDigit
octDigit = 
  try (char '0' $> OctDigit_0) <|>
  try (char '1' $> OctDigit_1) <|>
  try (char '2' $> OctDigit_2) <|>
  try (char '3' $> OctDigit_3) <|>
  try (char '4' $> OctDigit_4) <|>
  try (char '5' $> OctDigit_5) <|>
  try (char '6' $> OctDigit_6) <|>
  (char '7' $> OctDigit_7)
  
hexDigit ::(DeltaParsing m, LookAheadParsing m) => m HexDigit
hexDigit = 
  try (char '0' $> HexDigit_0) <|>
  try (char '1' $> HexDigit_1) <|>
  try (char '2' $> HexDigit_2) <|>
  try (char '3' $> HexDigit_3) <|>
  try (char '4' $> HexDigit_4) <|>
  try (char '5' $> HexDigit_5) <|>
  try (char '6' $> HexDigit_6) <|>
  try (char '7' $> HexDigit_7) <|>
  try (char '8' $> HexDigit_8) <|>
  try (char '9' $> HexDigit_9) <|>
  try (char 'a' $> HexDigit_a) <|>
  try (char 'A' $> HexDigit_A) <|>
  try (char 'b' $> HexDigit_b) <|>
  try (char 'B' $> HexDigit_B) <|>
  try (char 'c' $> HexDigit_c) <|>
  try (char 'C' $> HexDigit_C) <|>
  try (char 'd' $> HexDigit_d) <|>
  try (char 'D' $> HexDigit_D) <|>
  try (char 'e' $> HexDigit_e) <|>
  try (char 'E' $> HexDigit_E) <|>
  try (char 'f' $> HexDigit_f) <|>
  (char 'F' $> HexDigit_F)
  
binDigit ::(DeltaParsing m, LookAheadParsing m) => m BinDigit
binDigit = try (char '0' $> BinDigit_0) <|> (char '1' $> BinDigit_1)

integer ::(DeltaParsing m, LookAheadParsing m) => m (Integer' SrcInfo)
integer =
  try integerBin <|>
  try integerOct <|>
  try integerHex <|>
  integerDecimal
  where
    integerDecimal =
      annotated $
      IntegerDecimal <$>
      (try (Left <$> liftA2 (,) nonZeroDigit (many digit')) <|>
      (Right <$> some1 zero))
    integerOct =
      annotated .
      fmap IntegerOct $
      Before <$> (zero *> o) <*> some1 octDigit
    integerHex =
      annotated .
      fmap IntegerHex $
      Before <$> (zero *> x) <*> some1 hexDigit
    integerBin =
      annotated .
      fmap IntegerBin $
      Before <$> (zero *> b) <*> some1 binDigit

e ::(DeltaParsing m, LookAheadParsing m) => m (Either Char_e Char_E)
e = try (fmap Left $ char 'e' $> Char_e) <|> fmap Right (char 'E' $> Char_E)

plusOrMinus ::(DeltaParsing m, LookAheadParsing m) => m (Either Plus Minus)
plusOrMinus =
  try (fmap Left $ char '+' $> Plus) <|>
  fmap Right (char '-' $> Minus)

float ::(DeltaParsing m, LookAheadParsing m) => m (Float' SrcInfo)
float = try floatDecimalBase <|> try floatDecimalNoBase <|> floatNoDecimal
  where
    floatDecimalBase =
      annotated $
      FloatDecimalBase <$>
      try (some1 digit') <*>
      (char '.' *> optionalF (some1 digit')) <*>
      ex

    floatDecimalNoBase =
      annotated $
      FloatDecimalNoBase <$>
      (char '.' *> some1 digit') <*>
      ex

    floatNoDecimal =
      annotated $
      FloatNoDecimal <$>
      try (some1 digit') <*>
      ex

    ex = optional (try $ Before <$> e <*> some1 digit')

j ::(DeltaParsing m, LookAheadParsing m) => m (Either Char_j Char_J)
j = try (fmap Left $ char 'j' $> Char_j) <|> fmap Right (char 'J' $> Char_J)

imag ::(DeltaParsing m, LookAheadParsing m) => m (Imag SrcInfo)
imag =
  annotated . fmap Imag $
  Compose <$>
  (flip After <$> floatOrInt <*> j)
  where
    floatOrInt = fmap InL float <|> fmap (InR . Const) (some1 digit')

optionalF ::(DeltaParsing m, LookAheadParsing m) => m (f a) -> m (Compose Maybe f a)
optionalF m = Compose <$> optional m

some1F ::(DeltaParsing m, LookAheadParsing m) => m (f a) -> m (Compose NonEmpty f a)
some1F m = Compose <$> some1 m

manyF ::(DeltaParsing m, LookAheadParsing m) => m (f a) -> m (Compose [] f a)
manyF m = Compose <$> many m

afterF ::(DeltaParsing m, LookAheadParsing m) => m s -> m (f a) -> m (Compose (After s) f a)
afterF ms ma = fmap Compose $ flip After <$> ma <*> ms

beforeF ::(DeltaParsing m, LookAheadParsing m) => m s -> m (f a) -> m (Compose (Before s) f a)
beforeF ms ma = fmap Compose $ Before <$> ms <*> ma

betweenF
  :: (DeltaParsing m, LookAheadParsing m)
  => m s
  -> m t
  -> m (f a)
  -> m (Compose (Between s t) f a)
betweenF ms mt ma = fmap Compose $ Between <$> ms <*> ma <*> mt

between'F ::(DeltaParsing m, LookAheadParsing m) => m s -> m (f a) -> m (Compose (Between' s) f a)
between'F ms ma = fmap (Compose . Between') $ Between <$> ms <*> ma <*> ms

between' ::(DeltaParsing m, LookAheadParsing m) => m s -> m a -> m (Between' s a)
between' ms ma = fmap Between' $ Between <$> ms <*> ma <*> ms

comma ::(DeltaParsing m, LookAheadParsing m) => m Comma
comma = char ',' $> Comma

dictOrSetMaker ::(DeltaParsing m, LookAheadParsing m) => m (DictOrSetMaker SrcInfo)
dictOrSetMaker = error "dictOrSetMaker not implemented"

tupleTestlistComp ::(DeltaParsing m, LookAheadParsing m) => m (TupleTestlistComp SrcInfo)
tupleTestlistComp = try tupleTestlistCompFor <|> tupleTestlistCompList
  where
    tupleTestlistCompFor =
      annotated $
      TupleTestlistCompFor <$>
      testOrStar <*>
      whitespaceBeforeF compFor

    tupleTestlistCompList =
      annotated $
      TupleTestlistCompList <$>
      testOrStar <*>
      manyF (try $ beforeF (betweenWhitespace comma) testOrStar) <*>
      optional (try $ whitespaceBefore comma)

    testOrStar = try (InL <$> test) <|> (InR <$> starExpr)

listTestlistComp ::(DeltaParsing m, LookAheadParsing m) => m (ListTestlistComp SrcInfo)
listTestlistComp = try listTestlistCompFor <|> listTestlistCompList
  where
    listTestlistCompFor =
      annotated $
      ListTestlistCompFor <$>
      testOrStar <*>
      whitespaceBeforeF compFor

    listTestlistCompList =
      annotated $
      ListTestlistCompList <$>
      testOrStar <*>
      manyF (try $ beforeF (betweenWhitespace comma) testOrStar) <*>
      optional (try $ whitespaceBefore comma)

    testOrStar = try (InL <$> test) <|> (InR <$> starExpr)

testList ::(DeltaParsing m, LookAheadParsing m) => m (TestList SrcInfo)
testList =
  annotated $
  TestList <$>
  test <*>
  beforeF (betweenWhitespace comma) test <*>
  optional (try $ whitespaceBefore comma)

yieldArg ::(DeltaParsing m, LookAheadParsing m) => m (YieldArg SrcInfo)
yieldArg = try yieldArgFrom <|> yieldArgList
  where
    yieldArgFrom =
      annotated $
      YieldArgFrom <$>
      (string "from" *> whitespaceBefore1F test)
    yieldArgList =
      annotated $
      YieldArgList <$> testList

yieldExpr ::(DeltaParsing m, LookAheadParsing m) => m (YieldExpr SrcInfo)
yieldExpr =
  annotated $
  YieldExpr <$>
  (string "yield" *> optionalF (try $ whitespaceBefore1F yieldArg))


atom ::(DeltaParsing m, LookAheadParsing m) => m (Atom SrcInfo)
atom =
  try atomParen <|>
  try atomBracket <|>
  try atomCurly <|>
  try atomInteger <|>
  try atomFloat <|>
  try atomString <|>
  try atomEllipsis <|>
  try atomNone <|>
  try atomTrue <|>
  try atomFalse <|>
  atomIdentifier
  where
    atomIdentifier =
      annotated $
      AtomIdentifier <$>
      identifier

    atomParen =
      annotated $
      AtomParen <$>
      between (char '(') (char ')')
      (betweenWhitespaceF
        (optionalF
          (try $ (InL <$> try yieldExpr) <|> (InR <$> tupleTestlistComp))))

    atomBracket =
      annotated $
      AtomBracket <$>
      between
        (char '[')
        (char ']')
        (betweenWhitespaceF $
          optionalF $ try listTestlistComp)

    atomCurly =
      annotated $
      AtomCurly <$>
      between
        (char '{')
        (char '}')
        (betweenWhitespaceF $
          optionalF $ try dictOrSetMaker)

    atomInteger =
      annotated $
      AtomInteger <$> integer

    atomFloat =
      annotated $
      AtomFloat <$> float

    stringOrBytes = (InL <$> try stringLiteral) <|> (InR <$> bytesLiteral)

    atomString =
      annotated $
      AtomString <$>
      stringOrBytes <*>
      manyF (try $ whitespaceBeforeF stringOrBytes)

    atomEllipsis =
      annotated $
      string "..." $> AtomEllipsis

    atomNone =
      annotated $
      (string "None" *> notFollowedBy idContinue) $> AtomNone

    atomTrue =
      annotated $
      (string "True" *> notFollowedBy idContinue) $> AtomTrue

    atomFalse =
      annotated $
      (string "False" *> notFollowedBy idContinue) $> AtomFalse

sliceOp ::(DeltaParsing m, LookAheadParsing m) => m (SliceOp SrcInfo)
sliceOp =
  annotated $
  SliceOp <$>
  (char ':' *> optionalF (try $ whitespaceBeforeF test))

argument ::(DeltaParsing m, LookAheadParsing m) => m (Argument SrcInfo)
argument = try argumentUnpack <|> try argumentDefault <|> argumentFor
  where
    argumentFor =
      annotated $
      ArgumentFor <$>
      test <*>
      optionalF (try $ whitespaceBeforeF compFor)
    argumentDefault =
      annotated $
      ArgumentDefault <$>
      (whitespaceAfterF test <* char '=') <*>
      whitespaceBeforeF test
    argumentUnpack =
      annotated $
      ArgumentUnpack <$>
      (try (Right <$> doubleAsterisk) <|> (Left <$> asterisk)) <*>
      whitespaceBeforeF test

subscript ::(DeltaParsing m, LookAheadParsing m) => m (Subscript SrcInfo)
subscript = try subscriptTest <|> subscriptSlice
  where
    subscriptTest =
      annotated $
      SubscriptTest <$>
      test <* notFollowedBy (try $ many whitespaceChar *> char ':')
    subscriptSlice =
      annotated $
      SubscriptSlice <$>
      whitespaceAfterF (optionalF $ try test) <*>
      whitespaceAfter (char ':' $> Colon) <*>
      optionalF (try $ whitespaceAfterF test) <*>
      optionalF (try $ whitespaceAfterF sliceOp)

argList ::(DeltaParsing m, LookAheadParsing m) => m (ArgList SrcInfo)
argList =
  annotated $
  ArgList <$>
  argument <*>
  manyF (try $ beforeF (betweenWhitespace comma) argument) <*>
  optional (try $ whitespaceBefore comma)

subscriptList ::(DeltaParsing m, LookAheadParsing m) => m (SubscriptList SrcInfo)
subscriptList =
  annotated $
  SubscriptList <$>
  subscript <*>
  manyF (try $ beforeF (betweenWhitespace comma) subscript) <*>
  optional (try $ whitespaceBefore comma)

trailer ::(DeltaParsing m, LookAheadParsing m) => m (Trailer SrcInfo)
trailer = try trailerCall <|> try trailerSubscript <|> trailerAccess
  where
    trailerCall =
      annotated $
      TrailerCall <$>
      between
        (char '(')
        (char ')')
        (betweenWhitespaceF . optionalF $ try argList)

    trailerSubscript =
      annotated $
      TrailerSubscript <$>
      between
        (char '[')
        (char ']')
        (betweenWhitespaceF subscriptList)

    trailerAccess =
      annotated $
      TrailerAccess <$>
      (char '.' *> whitespaceBeforeF identifier)

atomExpr ::(DeltaParsing m, LookAheadParsing m) => m (AtomExpr SrcInfo)
atomExpr =
  annotated $
  AtomExpr <$>
  (optional . try $ string "await" *> whitespaceAfter1 (pure KAwait)) <*>
  atom <*>
  manyF (try $ whitespaceBeforeF trailer)

power ::(DeltaParsing m, LookAheadParsing m) => m (Power SrcInfo)
power =
  annotated $
  Power <$>
  atomExpr <*>
  optionalF (try $ beforeF (betweenWhitespace doubleAsterisk) factor)

factorOp ::(DeltaParsing m, LookAheadParsing m) => m FactorOperator
factorOp =
  try (char '-' $> FactorNeg) <|>
  try (char '+' $> FactorPos) <|>
  (char '~' $> FactorInv)

factor ::(DeltaParsing m, LookAheadParsing m) => m (Factor SrcInfo)
factor = try factorOne <|> factorNone
  where
    factorNone = annotated $ FactorNone <$> power
    factorOne =
      annotated $
      FactorOne <$>
      whitespaceAfter factorOp <*>
      factor

termOp ::(DeltaParsing m, LookAheadParsing m) => m TermOperator
termOp =
  try (char '*' $> TermMult) <|>
  try (char '@' $> TermAt) <|>
  try (string "//" $> TermFloorDiv) <|>
  try (char '/' $> TermDiv) <|>
  (char '%' $> TermMod)

term ::(DeltaParsing m, LookAheadParsing m) => m (Term SrcInfo)
term =
  annotated $
  Term <$>
  factor <*>
  manyF (try $ beforeF (betweenWhitespace termOp) factor)

arithExpr ::(DeltaParsing m, LookAheadParsing m) => m (ArithExpr SrcInfo)
arithExpr =
  annotated $
  ArithExpr <$>
  term <*>
  manyF (try $ beforeF (betweenWhitespace plusOrMinus) term)

shiftExpr ::(DeltaParsing m, LookAheadParsing m) => m (ShiftExpr SrcInfo)
shiftExpr =
  annotated $
  ShiftExpr <$>
  arithExpr <*>
  manyF (try $ beforeF (betweenWhitespace shiftLeftOrRight) arithExpr)
  where
    shiftLeftOrRight =
      (symbol "<<" $> Left DoubleLT) <|>
      (symbol ">>" $> Right DoubleGT)

andExpr ::(DeltaParsing m, LookAheadParsing m) => m (AndExpr SrcInfo)
andExpr =
  annotated $
  AndExpr <$>
  shiftExpr <*>
  manyF (try $ beforeF (betweenWhitespace $ char '&' $> Ampersand) shiftExpr)

xorExpr ::(DeltaParsing m, LookAheadParsing m) => m (XorExpr SrcInfo)
xorExpr =
  annotated $
  XorExpr <$>
  andExpr <*>
  manyF (try $ beforeF (betweenWhitespace $ char '^' $> S.Caret) andExpr)

expr ::(DeltaParsing m, LookAheadParsing m) => m (Expr SrcInfo)
expr =
  annotated $
  Expr <$>
  xorExpr <*>
  manyF (try $ beforeF (betweenWhitespace $ char '|' $> Pipe) xorExpr)

compOperator ::(DeltaParsing m, LookAheadParsing m) => m CompOperator
compOperator =
  try compEq <|>
  try compGEq <|>
  try compLEq <|>
  try compNEq <|>
  try compLT <|>
  try compGT <|>
  try compIsNot <|>
  try compIs <|>
  try compIn <|>
  compNotIn
  where
    compEq =
      CompEq <$>
      (many (try whitespaceChar) <* string "==") <*>
      many whitespaceChar

    compGEq =
      CompGEq <$>
      (many (try whitespaceChar) <* string ">=") <*>
      many whitespaceChar

    compNEq =
      CompNEq <$>
      (many (try whitespaceChar) <* string "!=") <*>
      many whitespaceChar

    compLEq =
      CompLEq <$>
      (many (try whitespaceChar) <* string "<=") <*>
      many whitespaceChar

    compLT =
      CompLT <$>
      (many (try whitespaceChar) <* string "<") <*>
      many whitespaceChar

    compGT =
      CompGT <$>
      (many (try whitespaceChar) <* string ">") <*>
      many whitespaceChar

    compIsNot =
      CompIsNot <$>
      (some1 whitespaceChar <* string "is") <*>
      (some1 whitespaceChar <* string "not") <*>
      some1 whitespaceChar

    compIs =
      CompIs <$>
      (some1 whitespaceChar <* string "is") <*>
      some1 whitespaceChar

    compIn =
      CompIn <$>
      (some1 whitespaceChar <* string "in") <*>
      some1 whitespaceChar

    compNotIn =
      CompNotIn <$>
      (some1 whitespaceChar <* string "not") <*>
      (some1 whitespaceChar <* string "in") <*>
      some1 whitespaceChar

comparison ::(DeltaParsing m, LookAheadParsing m) => m (Comparison SrcInfo)
comparison =
  annotated $
  Comparison <$>
  expr <*>
  manyF (try $ beforeF compOperator expr)

notTest ::(DeltaParsing m, LookAheadParsing m) => m (NotTest SrcInfo)
notTest = try notTestMany <|> notTestOne
  where
    notTestMany =
      annotated $
      NotTestMany <$>
      beforeF (whitespaceAfter1 $ string "not" $> KNot) notTest

    notTestOne =
      annotated $ NotTestOne <$> comparison

andTest ::(DeltaParsing m, LookAheadParsing m) => m (AndTest SrcInfo)
andTest =
  annotated $
  AndTest <$>
  notTest <*>
  manyF (try $ beforeF (betweenWhitespace1 kAnd) andTest)

newlineChar :: CharParsing m => m NewlineChar
newlineChar =
  (char '\r' $> CR) <|>
  (char '\n' $> LF) <|>
  (string "\r\n" $> CRLF)
