{-# language DeriveFunctor #-}
{-# language DeriveFoldable #-}
{-# language DeriveTraversable #-}
{-# language TemplateHaskell #-}
module Language.Python.AST.Symbols where

import Papa

data Backslash = Backslash deriving (Eq, Show)
data SingleQuote = SingleQuote deriving (Eq, Show)
data DoubleQuote = DoubleQuote deriving (Eq, Show)
data TripleSingleQuote = TripleSingleQuote deriving (Eq, Show)
data TripleDoubleQuote = TripleDoubleQuote deriving (Eq, Show)
data Plus = Plus deriving (Eq, Show)
data Minus = Minus deriving (Eq, Show)
data Char_e = Char_e deriving (Eq, Show)
data Char_E = Char_E deriving (Eq, Show)
data Char_o = Char_o deriving (Eq, Show)
data Char_O = Char_O deriving (Eq, Show)
data Char_x = Char_x deriving (Eq, Show)
data Char_X = Char_X deriving (Eq, Show)
data Char_b = Char_b deriving (Eq, Show)
data Char_B = Char_B deriving (Eq, Show)
data Char_j = Char_j deriving (Eq, Show)
data Char_J = Char_J deriving (Eq, Show)
data Zero = Zero deriving (Eq, Show)
data LeftParen = LeftParen deriving (Eq, Show)
data RightParen = RightParen deriving (Eq, Show)
data NewlineChar = CR | LF | CRLF deriving (Eq, Show)
data WhitespaceChar = Space | Tab | Continued NewlineChar deriving (Eq, Show)
data Comma = Comma deriving (Eq, Show)
data Hash = Hash deriving (Eq, Show)
data Colon = Colon deriving (Eq, Show)
data Asterisk = Asterisk deriving (Eq, Show)
data DoubleAsterisk = DoubleAsterisk deriving (Eq, Show)
data Pipe = Pipe deriving (Eq, Show)
data Caret = Caret deriving (Eq, Show)
data Ampersand = Ampersand deriving (Eq, Show)
data DoubleLT = DoubleLT deriving (Eq, Show)
data DoubleGT = DoubleGT deriving (Eq, Show)