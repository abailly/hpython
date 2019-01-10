{-# language DataKinds #-}
{-# language FlexibleContexts #-}
{-# language MultiParamTypeClasses, FlexibleInstances #-}

{-|
Module      : Language.Python.Parse
Copyright   : (C) CSIRO 2017-2018
License     : BSD3
Maintainer  : Isaac Elliott <isaace71295@gmail.com>
Stability   : experimental
Portability : non-portable
-}

module Language.Python.Parse
  ( module Language.Python.Parse.Error
  , Parser
  , parseModule
  , parseStatement
  , parseExpr
  , parseExprList
    -- * Source Information
  , SrcInfo(..), initialSrcInfo
  )
where

import Control.Applicative ((<|>))
import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Validation (Validation, bindValidation, fromEither)
import Text.Megaparsec (eof)

import Language.Python.Internal.Lexer
  ( SrcInfo(..), initialSrcInfo, withSrcInfo
  , tokenize, insertTabs
  )
import Language.Python.Internal.Token (PyToken)
import Language.Python.Internal.Parse
  ( Parser, runParser, level, module_, statement, exprOrStarList
  , expr, space
  )
import Language.Python.Internal.Syntax.IR (AsIRError)
import Language.Python.Parse.Error
import Language.Python.Syntax.Expr (Expr)
import Language.Python.Syntax.Module (Module)
import Language.Python.Syntax.Statement (Statement)
import Language.Python.Syntax.Whitespace (Indents (..))

import qualified Language.Python.Internal.Syntax.IR as IR

-- | Parse a module
--
-- https://docs.python.org/3/reference/toplevel_components.html#file-input
parseModule
  :: ( AsLexicalError e Char
     , AsTabError e SrcInfo
     , AsIncorrectDedent e SrcInfo
     , AsParseError e (PyToken SrcInfo)
     , AsIRError e SrcInfo
     )
  => FilePath -- ^ File name
  -> Text -- ^ Input to parse
  -> Validation (NonEmpty e) (Module '[] SrcInfo)
parseModule fp input =
  let
    si = initialSrcInfo fp
    ir = do
      tokens <- tokenize fp input
      tabbed <- insertTabs si tokens
      runParser fp module_ tabbed
  in
    fromEither (first pure ir) `bindValidation` IR.fromIR

-- | Parse a statement
--
-- https://docs.python.org/3/reference/compound_stmts.html#grammar-token-statement
parseStatement
  :: ( AsLexicalError e Char
     , AsTabError e SrcInfo
     , AsIncorrectDedent e SrcInfo
     , AsParseError e (PyToken SrcInfo)
     , AsIRError e SrcInfo
     )
  => FilePath -- ^ File name
  -> Text -- ^ Input to parse
  -> Validation (NonEmpty e) (Statement '[] SrcInfo)
parseStatement fp input =
  let
    si = initialSrcInfo fp
    ir = do
      tokens <- tokenize fp input
      tabbed <- insertTabs si tokens
      runParser fp ((statement tlIndent =<< tlIndent) <* eof) tabbed
  in
    fromEither (first pure ir) `bindValidation` IR.fromIR_statement
  where
    tlIndent = level <|> withSrcInfo (pure $ Indents [])

-- | Parse an expression list (unparenthesised tuple)
--
-- https://docs.python.org/3.5/reference/expressions.html#grammar-token-expression_list
parseExprList
  :: ( AsLexicalError e Char
     , AsTabError e SrcInfo
     , AsIncorrectDedent e SrcInfo
     , AsParseError e (PyToken SrcInfo)
     , AsIRError e SrcInfo
     )
  => FilePath -- ^ File name
  -> Text -- ^ Input to parse
  -> Validation (NonEmpty e) (Expr '[] SrcInfo)
parseExprList fp input =
  let
    si = initialSrcInfo fp
    ir = do
      tokens <- tokenize fp input
      tabbed <- insertTabs si tokens
      runParser fp (exprOrStarList space <* eof) tabbed
  in
    fromEither (first pure ir) `bindValidation` IR.fromIR_expr

-- | Parse an expression
--
-- https://docs.python.org/3.5/reference/expressions.html#grammar-token-expression
parseExpr
  :: ( AsLexicalError e Char
     , AsTabError e SrcInfo
     , AsIncorrectDedent e SrcInfo
     , AsParseError e (PyToken SrcInfo)
     , AsIRError e SrcInfo
     )
  => FilePath -- ^ File name
  -> Text -- ^ Input to parse
  -> Validation (NonEmpty e) (Expr '[] SrcInfo)
parseExpr fp input =
  let
    si = initialSrcInfo fp
    ir = do
      tokens <- tokenize fp input
      tabbed <- insertTabs si tokens
      runParser fp (expr space <* eof) tabbed
  in
    fromEither (first pure ir) `bindValidation` IR.fromIR_expr
