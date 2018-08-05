{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE TemplateHaskell   #-}
module Language.Python.Internal.Syntax.Numbers where

import Data.Deriving (deriveEq1)
import Data.Digit.Binary (BinDigit)
import Data.Digit.Decimal (DecDigit)
import Data.Digit.Hexa1 (HeXDigit)
import Data.Digit.Octal (OctDigit)
import Data.List.NonEmpty (NonEmpty)
import Data.These (These)

data IntLiteral a
  = IntLiteralDec
  { _intLiteralAnn            :: a
  , _unsafeIntLiteralDecValue :: NonEmpty DecDigit
  }
  | IntLiteralBin
  { _intLiteralAnn                :: a
  , _unsafeIntLiteralBinUppercase :: Bool
  , _unsafeIntLiteralBinValue     :: NonEmpty BinDigit
  }
  | IntLiteralOct
  { _intLiteralAnn                :: a
  , _unsafeIntLiteralOctUppercase :: Bool
  , _unsafeIntLiteralOctValue     :: NonEmpty OctDigit
  }
  | IntLiteralHex
  { _intLiteralAnn                :: a
  , _unsafeIntLiteralHexUppercase :: Bool
  , _unsafeIntLiteralHexValue     :: NonEmpty HeXDigit
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)
deriveEq1 ''IntLiteral

data Sign = Pos | Neg deriving (Eq, Show)

data FloatExponent = FloatExponent Bool (Maybe Sign) (NonEmpty DecDigit)
  deriving (Eq, Show)

data FloatLiteral a
  = FloatLiteralFull
  { _floatLiteralAnn :: a
  , _floatLiteralFullLeft :: NonEmpty DecDigit
  , _floatLiteralFullRight
      :: Maybe (These (NonEmpty DecDigit) FloatExponent)
  }
  | FloatLiteralPoint
  { _floatLiteralAnn           :: a
  -- . [0-9]+
  , _floatLiteralPointRight    :: NonEmpty DecDigit
  -- [ 'e' ['-' | '+'] [0-9]+ ]
  , _floatLiteralPointExponent :: Maybe FloatExponent
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)
deriveEq1 ''FloatLiteral
