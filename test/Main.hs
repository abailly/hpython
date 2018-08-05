{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators    #-}

module Main where

import Language.Python.Internal.Optics
import Language.Python.Internal.Parse
import Language.Python.Internal.Render
import Language.Python.Internal.Syntax
import Language.Python.Validate.Indentation
import Language.Python.Validate.Indentation.Error
import Language.Python.Validate.Syntax
import Language.Python.Validate.Syntax.Error

import LexerParser
import Scope
import Helpers (doToPython)

import qualified Generators.General as General
import qualified Generators.Correct as Correct

import Control.Lens
import Control.Monad.IO.Class
import Control.Monad.State
import Data.Functor
import Data.List
import Data.Text.Lazy(pack)
import Data.Validate
import System.Exit
import System.Process
import qualified Data.Text.Lazy as Lazy

import Hedgehog
import qualified Hedgehog.Gen as Gen

validateExprSyntax'
  :: Expr '[Indentation] a
  -> Validate [SyntaxError '[Indentation] a] (Expr '[Syntax, Indentation] a)
validateExprSyntax' = runValidateSyntax initialSyntaxContext [] . validateExprSyntax

validateExprIndentation'
  :: Expr '[] a
  -> Validate [IndentationError '[] a] (Expr '[Indentation] a)
validateExprIndentation' = runValidateIndentation . validateExprIndentation

validateStatementSyntax' ::
     Statement '[ Indentation] a
  -> Validate [SyntaxError '[ Indentation] a] (Statement '[ Syntax, Indentation] a)
validateStatementSyntax' =
  runValidateSyntax initialSyntaxContext [] . validateStatementSyntax

validateStatementIndentation' ::
     Statement '[] a
  -> Validate [IndentationError '[] a] (Statement '[ Indentation] a)
validateStatementIndentation' =
  runValidateIndentation . validateStatementIndentation

validateModuleSyntax' ::
     Module '[ Indentation] a
  -> Validate [SyntaxError '[ Indentation] a] (Module '[ Syntax, Indentation] a)
validateModuleSyntax' =
  runValidateSyntax initialSyntaxContext [] . validateModuleSyntax

validateModuleIndentation' ::
     Module '[] a
  -> Validate [IndentationError '[] a] (Module '[ Indentation] a)
validateModuleIndentation' = runValidateIndentation . validateModuleIndentation

runPython3 :: (MonadTest m, MonadIO m) => FilePath -> Bool -> String -> m ()
runPython3 path shouldSucceed str = do
  () <- liftIO $ writeFile path str
  when shouldSucceed $ liftIO $ putStrLn str
  (ec, sto, ste) <-
    liftIO $ readProcessWithExitCode "python3" ["-m", "py_compile", path] ""
  annotateShow shouldSucceed
  annotateShow ec
  annotate sto
  annotate ste
  case (shouldSucceed, ec) of
    (True, ExitSuccess) -> success
    (True, ExitFailure {})
      | "SyntaxError" `isInfixOf` last (lines ste) -> failure
      | otherwise -> success
    (False, ExitSuccess) -> failure
    (False, ExitFailure {}) -> success

syntax_expr :: FilePath -> Property
syntax_expr path =
  property $ do
    ex <- forAll $ Gen.resize 300 General.genExpr
    let rex = Lazy.unpack $ showExpr ex
    shouldSucceed <-
      case validateExprIndentation' ex of
        Failure errs -> annotateShow errs $> False
        Success res ->
          case validateExprSyntax' res of
            Failure []     -> pure True
            Failure errs'' -> annotateShow errs'' $> False
            Success res'   -> pure True
    annotate rex
    runPython3 path shouldSucceed rex

syntax_statement :: FilePath -> Property
syntax_statement path =
  property $ do
    st <- forAll $ Gen.resize 300 General.genStatement
    let rst = Lazy.unpack $ showStatement st
    shouldSucceed <-
      case validateStatementIndentation' st of
        Failure errs -> annotateShow errs $> False
        Success res ->
          case validateStatementSyntax' res of
            Failure []     -> pure True
            Failure errs'' -> annotateShow errs'' $> False
            Success res'   -> pure True
    annotate rst
    runPython3 path shouldSucceed rst

syntax_module :: FilePath -> Property
syntax_module path =
  property $ do
    st <- forAll $ Gen.resize 300 General.genModule
    let rst = Lazy.unpack $ showModule st
    shouldSucceed <-
      case validateModuleIndentation' st of
        Failure errs -> annotateShow errs $> False
        Success res ->
          case validateModuleSyntax' res of
            Failure []     -> pure True
            Failure errs'' -> annotateShow errs'' $> False
            Success res'   -> pure True
    annotate rst
    runPython3 path shouldSucceed rst

correct_syntax_expr :: FilePath -> Property
correct_syntax_expr path =
  property $ do
    ex <- forAll $ evalStateT Correct.genExpr Correct.initialGenState
    case validateExprIndentation' ex of
      Failure errs -> annotateShow errs *> failure
      Success res ->
        case validateExprSyntax' res of
          Failure errs' -> annotateShow errs' *> failure
          Success res' -> runPython3 path True (Lazy.unpack $ showExpr ex)

correct_syntax_statement :: FilePath -> Property
correct_syntax_statement path =
  property $ do
    st <- forAll $ evalStateT Correct.genStatement Correct.initialGenState
    annotate . Lazy.unpack $ showStatement st
    case validateStatementIndentation' st of
      Failure errs -> annotateShow errs *> failure
      Success res ->
        case validateStatementSyntax' res of
          Failure errs' -> annotateShow errs' *> failure
          Success res' -> runPython3 path True . Lazy.unpack $ showStatement st

expr_printparseprint_print :: Property
expr_printparseprint_print =
  property $ do
    ex <- forAll $ evalStateT Correct.genExpr Correct.initialGenState
    -- annotate (showExpr ex)
    case validateExprIndentation' ex of
      Failure errs -> annotateShow errs *> failure
      Success res ->
        case validateExprSyntax' res of
          Failure errs' -> annotateShow errs' *> failure
          Success res' -> do
            py <- doToPython (expr space) (Lazy.unpack $ showExpr res')
            showExpr (res' ^. unvalidated) === showExpr (res $> ())

statement_printparseprint_print :: Property
statement_printparseprint_print =
  property $ do
    st <- forAll $ evalStateT Correct.genStatement Correct.initialGenState
    -- annotate $ showStatement st
    case validateStatementIndentation' st of
      Failure errs -> annotateShow errs *> failure
      Success res ->
        case validateStatementSyntax' res of
          Failure errs' -> annotateShow errs' *> failure
          Success res' -> do
            py <- doToPython statement . Lazy.unpack $ showStatement res'
            annotateShow py
            showStatement (res' ^. unvalidated) === showStatement (py $> ())

statement_parse_print :: String -> Property
statement_parse_print str = do
  property $ do
    py <- doToPython statement str
    showStatement (py $> ()) === pack str

main = do
  check $ statement_parse_print "def fun(a:int):\n    return 1"
  check $ statement_parse_print "def fun(a:str) ->  int:\n    return 1"
  check $ statement_parse_print "@decorate\ndef fun(a:str) ->  int:\n    return 1"
  check $ statement_parse_print "@decorate\ndef fun(a:foo.str) ->  bar.int:\n    return 1"
  check $ statement_parse_print "def fun(a,b):\n    return a // b"
  checkParallel lexerParserTests
  let file = "hedgehog-test.py"
  check . withTests 200 $ syntax_expr file
  check . withTests 200 $ syntax_statement file
  check . withTests 200 $ syntax_module file
  check . withTests 200 $ correct_syntax_expr file
  check . withTests 200 $ correct_syntax_statement file
  check expr_printparseprint_print
  check . withShrinks 2000 $ statement_printparseprint_print
  checkParallel scopeTests
