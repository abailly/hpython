{-# language DataKinds #-}
{-# language FlexibleContexts #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language TemplateHaskell #-}
module Language.Python.Internal.Parse where

import Control.Lens.Fold (foldOf, folded)
import Control.Lens.Getter ((^.), use)
import Control.Lens.Setter (assign)
import Control.Lens.TH (makeLenses)
import Control.Monad (unless)
import Control.Monad.Except (ExceptT(..), runExceptT, throwError)
import Control.Monad.State
  (MonadState, StateT(..), get, put, evalStateT, runStateT)
import Control.Monad.Writer.Strict (MonadWriter, Writer, runWriter, writer, tell)
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.Function ((&))
import Data.Functor (($>))
import Data.Functor.Alt (Alt((<!>)), many, some, optional)
import Data.Functor.Classes (liftEq)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty(..))
import Data.Sequence (viewl, ViewL(..))

import qualified Data.List.NonEmpty as NonEmpty

import Language.Python.Internal.Lexer
import Language.Python.Internal.Syntax
import Language.Python.Internal.Token

some1 :: (Alt f, Applicative f) => f a -> f (NonEmpty a)
some1 a = (:|) <$> a <*> many a

data ParseError ann
  = UnexpectedEndOfInput ann
  | UnexpectedEndOfLine ann
  | UnexpectedEndOfBlock ann
  | UnexpectedIndent ann
  | ExpectedIndent ann
  | ExpectedEndOfBlock { peGotCtxt :: Line ann }
  | ExpectedIdentifier { peGot :: PyToken ann }
  | ExpectedContinued { peGot :: PyToken ann }
  | ExpectedNewline { peGot :: PyToken ann }
  | ExpectedStringOrBytes { peGot :: PyToken ann }
  | ExpectedInteger { peGot :: PyToken ann }
  | ExpectedComment { peGot :: PyToken ann }
  | ExpectedToken { peExpected :: PyToken (), peGot :: PyToken ann }
  | ExpectedEndOfLine { peGotTokens :: [PyToken ann] }
  | ExpectedEndOfInput { peGotCtxt :: Line ann }
  deriving (Eq, Show)

newtype Consumed = Consumed { unConsumed :: Bool }
  deriving (Eq, Show)

instance Monoid Consumed where
  mempty = Consumed False
  Consumed a `mappend` Consumed b = Consumed $! a || b

data ParseState ann
  = ParserState
  { _parseLocation :: ann
  , _parseContext :: [[Either (Nested ann) (Line ann)]]
  }
makeLenses ''ParseState

firstLine :: Either (Nested a) (Line a) -> Line a
firstLine (Right a) = a
firstLine (Left a) =
  case viewl (unNested a) of
    EmptyL -> error "no line to return in firstLine"
    a :< _ -> firstLine a

newtype Parser ann a
  = Parser
  { unParser
      :: StateT
           (ParseState ann)
           (ExceptT (ParseError ann) (Writer Consumed))
           a
  } deriving (Functor, Applicative, Monad)

instance Alt (Parser ann) where
  Parser pa <!> Parser pb =
    Parser $ do
      st <- get
      let (res, Consumed b) = runWriter . runExceptT $ runStateT pa st
      if b
        then StateT $ \_ -> ExceptT (writer (res, Consumed b))
        else case res of
          Left{}         -> pb
          Right (a, st') -> put st' $> a

runParser :: ann -> Parser ann a -> Nested ann -> Either (ParseError ann) a
runParser initial (Parser p) input =
  fst . runWriter . runExceptT $
  evalStateT p (ParserState initial (pure . toList $ unNested input))

currentToken :: Parser ann (PyToken ann)
currentToken = Parser $ do
  ctxt <- use parseContext
  ann <- use parseLocation
  case ctxt of
    [] -> throwError $ UnexpectedEndOfInput ann
    current : rest ->
      case current of
        [] -> throwError $ UnexpectedEndOfBlock ann
        Right ll@(Line _ _ tks nl) : rest' ->
          case tks of
            [] -> throwError $ UnexpectedEndOfLine ann
            [tk] | Nothing <- nl -> do
              assign parseContext $ case rest' of
                [] -> rest
                _  -> rest' : rest
              pure tk
            tk : rest'' ->
              assign parseContext ((Right (ll { lineLine = rest'' }) : rest') : rest) $> tk
        Left _ : _ -> throwError $ UnexpectedIndent ann

eol :: Parser ann Newline
eol = Parser $ do
  ctxt <- use parseContext
  ann <- use parseLocation
  case ctxt of
    [] -> throwError $ UnexpectedEndOfInput ann
    current : rest ->
      case current of
        [] -> throwError $ UnexpectedEndOfBlock ann
        Left _ : _ -> throwError $ UnexpectedIndent ann
        Right ll@(Line _ _ tks nl) : rest' ->
          case tks of
            _ : _ -> throwError $ ExpectedEndOfLine tks
            [] ->
              case nl of
                Nothing -> throwError $ ExpectedEndOfLine tks
                Just nl' -> do
                  assign parseContext (rest' : rest)
                  tell (Consumed True) $> nl'

eof :: Parser ann ()
eof = Parser $ do
  ctxt <- use parseContext
  case ctxt of
    [] -> tell $ Consumed True
    x : xs ->
      case x of
        [] -> assign parseContext xs *> unParser eof
        ls : _ -> throwError . ExpectedEndOfInput $ firstLine ls

indent :: Parser ann ()
indent = Parser $ do
  ctxt <- use parseContext
  ann <- use parseLocation
  case ctxt of
    [] -> throwError $ UnexpectedEndOfInput ann
    current : rest ->
      case current of
        [] -> throwError $ UnexpectedEndOfBlock ann
        Right _ : _ -> throwError $ ExpectedIndent ann
        Left inner : rest' -> do
          assign parseContext $ toList (unNested inner) : rest' : rest
          tell $ Consumed True

dedent :: Parser ann ()
dedent = Parser $ do
  ctxt <- use parseContext
  case ctxt of
    [] -> pure ()
    current : rest ->
      case current of
        [] -> assign parseContext rest *> tell (Consumed True)
        ls : _ -> throwError . ExpectedEndOfBlock $ firstLine ls

consumed :: (MonadState (ParseState ann) m, MonadWriter Consumed m) => ann -> m ()
consumed ann = assign parseLocation ann *> tell (Consumed True)

continued :: Parser ann Whitespace
continued = do
  curTk <- currentToken
  case curTk of
    TkContinued nl ann -> do
      Parser $ consumed ann
      Continued nl <$> many space
    _ -> Parser . throwError $ ExpectedContinued curTk

newline :: Parser ann Newline
newline = do
  curTk <- currentToken
  case curTk of
    TkNewline nl ann -> do
      Parser $ consumed ann
      pure nl
    _ -> Parser . throwError $ ExpectedNewline curTk

anySpace :: Parser ann Whitespace
anySpace =
  Space <$ tokenEq (TkSpace ()) <!>
  Tab <$ tokenEq (TkTab ()) <!>
  continued <!>
  Newline <$> newline

space :: Parser ann Whitespace
space =
  Space <$ tokenEq (TkSpace ()) <!>
  Tab <$ tokenEq (TkTab ()) <!>
  continued

parseError :: ParseError ann -> Parser ann a
parseError pe = Parser $ throwError pe

tokenEq :: PyToken b -> Parser ann (PyToken ann)
tokenEq tk = do
  curTk <- currentToken
  unless (liftEq (\_ _ -> True) tk curTk) .
    parseError $ ExpectedToken (() <$ tk) curTk
  Parser $ consumed (pyTokenAnn curTk)
  pure curTk

token :: Parser ann Whitespace -> PyToken b -> Parser ann (PyToken ann, [Whitespace])
token ws tk = do
  curTk <- tokenEq tk
  (,) curTk <$> many ws

identifier :: Parser ann Whitespace -> Parser ann (Ident '[] ann)
identifier ws = do
  curTk <- currentToken
  case curTk of
    TkIdent n ann -> do
      Parser $ consumed ann
      MkIdent ann n <$> many ws
    _ -> Parser . throwError $ ExpectedIdentifier curTk

bool :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
bool ws =
  (\(tk, s) ->
     Bool
       (pyTokenAnn tk)
       (case tk of
          TkTrue{}  -> True
          TkFalse{} -> False
          _         -> error "impossible")
       s) <$>
  (token ws (TkTrue ()) <!> token ws (TkFalse ()))

none :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
none ws = (\(tk, s) -> None (pyTokenAnn tk) s) <$> token ws (TkNone ())

integer :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
integer ws = do
  curTk <- currentToken
  case curTk of
    TkInt n ann -> do
      Parser $ consumed ann
      Int ann n <$> many ws
    _ -> Parser . throwError $ ExpectedInteger curTk

stringOrBytes :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
stringOrBytes ws =
  fmap (\vs -> String (_stringLiteralAnn $ NonEmpty.head vs) vs) . some1 $ do
    curTk <- currentToken
    (case curTk of
       TkString sp qt st val ann ->
         Parser (consumed ann) $>
         StringLiteral ann sp qt st val
       TkBytes sp qt st val ann ->
         Parser (consumed ann) $>
         BytesLiteral ann sp qt st val
       _ -> Parser . throwError $ ExpectedStringOrBytes curTk) <*>
     many ws

between :: Parser ann left -> Parser ann right -> Parser ann a -> Parser ann a
between left right pa = left *> pa <* right

indents :: Parser ann (Indents ann)
indents = Parser $ do
  ctxt <- use parseContext
  ann <- use parseLocation
  case ctxt of
    [] -> throwError $ UnexpectedEndOfInput ann
    current : rest ->
      case current of
        [] -> throwError $ UnexpectedEndOfBlock ann
        Right ll@(Line a is _ _) : rest' -> pure $ Indents is a
        Left l : _ -> throwError $ UnexpectedIndent ann

exprList :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
exprList ws =
  (\a -> maybe a (uncurry $ Tuple (_exprAnnotation a) a)) <$>
  expr ws <*>
  optional
    ((,) <$>
     (snd <$> comma ws) <*>
     optional (commaSep1' ws $ expr ws))

compIf :: Parser ann (CompIf '[] ann)
compIf =
  (\(tk, s) -> CompIf (pyTokenAnn tk) s) <$>
  token anySpace (TkIf ()) <*>
  orTest anySpace

compFor :: Parser ann (CompFor '[] ann)
compFor =
  (\(tk, s) -> CompFor (pyTokenAnn tk) s) <$>
  token anySpace (TkFor ()) <*>
  orExprList anySpace <*>
  (snd <$> token anySpace (TkIn ())) <*>
  orTest anySpace

-- | (',' x)* [',']
commaSepRest :: Parser ann b -> Parser ann ([([Whitespace], b)], Maybe [Whitespace])
commaSepRest x = do
  c <- optional $ snd <$> comma anySpace
  case c of
    Nothing -> pure ([], Nothing)
    Just c' -> do
      e <- optional x
      case e of
        Nothing -> pure ([], Just c')
        Just e' -> first ((c', e') :) <$> commaSepRest x

exprComp :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
exprComp ws =
  (\ex a ->
     case a of
       Nothing -> ex
       Just (cf, rest) ->
         Generator (ex ^. exprAnnotation) $
         Comprehension (ex ^. exprAnnotation) ex cf rest) <$>
  expr ws <*>
  optional ((,) <$> compFor <*> many (Left <$> compFor <!> Right <$> compIf))

exprListComp :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
exprListComp ws = do
  ex <- expr ws
  val <-
    Left <$> compFor <!>
    Right <$> commaSepRest (expr anySpace)
  case val of
    Left cf ->
      Generator (ex ^. exprAnnotation) .
      Comprehension (ex ^. exprAnnotation) ex cf <$>
      many (Left <$> compFor <!> Right <$> compIf)
    Right ([], Nothing) -> pure ex
    Right ([], Just ws) ->
      pure $ Tuple (ex ^. exprAnnotation) ex ws Nothing
    Right ((ws, ex') : cs, mws) ->
      pure $ Tuple (ex ^. exprAnnotation) ex ws . Just $ (ex', cs, mws) ^. _CommaSep1'

orExprList :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
orExprList ws =
  (\a -> maybe a (uncurry $ Tuple (_exprAnnotation a) a)) <$>
  orExpr ws <*>
  optional
    ((,) <$>
     (snd <$> comma ws) <*>
     optional (commaSep1' ws $ orExpr ws))

binOp :: Parser ann (BinOp ann) -> Parser ann (Expr '[] ann) -> Parser ann (Expr '[] ann)
binOp op tm =
  (\t ts ->
      case ts of
        [] -> t
        _ -> foldl (\tm (o, val) -> BinOp (tm ^. exprAnnotation) tm o val) t ts) <$>
  tm <*>
  many ((,) <$> op <*> tm)

orTest :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
orTest ws = binOp orOp andTest
  where
    orOp = (\(tk, ws) -> BoolOr (pyTokenAnn tk) ws) <$> token ws (TkOr ())

    andOp = (\(tk, ws) -> BoolAnd (pyTokenAnn tk) ws) <$> token ws (TkAnd ())
    andTest = binOp andOp notTest

    notTest =
      (\(tk, s) -> Not (pyTokenAnn tk) s) <$> token ws (TkNot ()) <*> notTest <!>
      comparison

    compOp =
      (\(tk, ws) -> maybe (Is (pyTokenAnn tk) ws) (IsNot (pyTokenAnn tk) ws)) <$>
      token ws (TkIs ()) <*> optional (snd <$> token ws (TkNot ())) <!>
      (\(tk, ws) -> NotIn (pyTokenAnn tk) ws) <$>
      token ws (TkNot ()) <*>
      (snd <$> token ws (TkIn ())) <!>
      (\(tk, ws) -> In (pyTokenAnn tk) ws) <$> token ws (TkIn ()) <!>
      (\(tk, ws) -> Equals (pyTokenAnn tk) ws) <$> token ws (TkDoubleEq ()) <!>
      (\(tk, ws) -> Lt (pyTokenAnn tk) ws) <$> token ws (TkLt ()) <!>
      (\(tk, ws) -> LtEquals (pyTokenAnn tk) ws) <$> token ws (TkLte ()) <!>
      (\(tk, ws) -> Gt (pyTokenAnn tk) ws) <$> token ws (TkGt ()) <!>
      (\(tk, ws) -> GtEquals (pyTokenAnn tk) ws) <$> token ws (TkGte ()) <!>
      (\(tk, ws) -> NotEquals (pyTokenAnn tk) ws) <$> token ws (TkBangEq ())
    comparison = binOp compOp $ orExpr ws

yieldExpr :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
yieldExpr ws =
  (\(tk, s) -> either (uncurry $ YieldFrom (pyTokenAnn tk) s) (Yield (pyTokenAnn tk) s)) <$>
  token ws (TkYield ()) <*>
  (fmap Left ((,) <$> (snd <$> token ws (TkFrom ())) <*> expr ws) <!>
   (Right <$> optional (exprList ws)))

expr :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
expr ws =
  (\a -> maybe a (\(b, c, d, e) -> Ternary (a ^. exprAnnotation) a b c d e)) <$>
  orTest ws <*>
  optional
    ((,,,) <$>
     (snd <$> token ws (TkIf ())) <*>
     orTest ws <*>
     (snd <$> token ws (TkElse ())) <*>
     expr ws)

orExpr :: Parser ann Whitespace -> Parser ann (Expr '[] ann)
orExpr ws =
  binOp
    ((\(tk, ws) -> BitOr (pyTokenAnn tk) ws) <$> token ws (TkPipe ()))
    xorExpr
  where
    xorExpr =
      binOp
        ((\(tk, ws) -> BitXor (pyTokenAnn tk) ws) <$> token ws (TkCaret ()))
        andExpr

    andExpr =
      binOp
        ((\(tk, ws) -> BitAnd (pyTokenAnn tk) ws) <$> token ws (TkAmpersand ()))
        shiftExpr

    shiftExpr =
      binOp
        ((\(tk, ws) -> ShiftLeft (pyTokenAnn tk) ws) <$> token ws (TkShiftLeft ()) <!>
         (\(tk, ws) -> ShiftRight (pyTokenAnn tk) ws) <$> token ws (TkShiftRight ()))
        arithExpr

    arithOp =
      (\(tk, ws) -> Plus (pyTokenAnn tk) ws) <$> token ws (TkPlus ()) <!>
      (\(tk, ws) -> Minus (pyTokenAnn tk) ws) <$> token ws (TkMinus ())
    arithExpr = binOp arithOp term

    termOp =
      (\(tk, ws) -> Multiply (pyTokenAnn tk) ws) <$> token ws (TkStar ()) <!>
      (\(tk, ws) -> Divide (pyTokenAnn tk) ws) <$> token ws (TkSlash ()) <!>
      (\(tk, ws) -> Percent (pyTokenAnn tk) ws) <$> token ws (TkPercent ())
    term = binOp termOp factor

    factor =
      (\(tk, s) -> Negate (pyTokenAnn tk) s) <$> token ws (TkMinus ()) <*> factor <!>
      power

    powerOp = (\(tk, ws) -> Exp (pyTokenAnn tk) ws) <$> token ws (TkDoubleStar ())
    power =
      (\a -> maybe a (uncurry $ BinOp (_exprAnnotation a) a)) <$>
      atomExpr <*>
      optional ((,) <$> powerOp <*> factor)

    subscript = do
      mex <- optional $ expr anySpace
      case mex of
        Nothing ->
          SubscriptSlice Nothing <$>
          (snd <$> colon anySpace) <*>
          optional (expr anySpace) <*>
          optional ((,) <$> (snd <$> colon anySpace) <*> optional (expr anySpace))
        Just ex -> do
          mws <- optional $ snd <$> colon anySpace
          case mws of
            Nothing -> pure $ SubscriptExpr ex
            Just ws ->
              SubscriptSlice (Just ex) ws <$>
              optional (expr anySpace) <*>
              optional ((,) <$> (snd <$> colon anySpace) <*> optional (expr anySpace))

    trailer =
      (\a b c -> Deref (_exprAnnotation c) c a b) <$>
      (snd <$> token ws (TkDot ())) <*>
      identifier ws

      <!>

      (\a b c d -> Call (_exprAnnotation d) d a b c) <$>
      (snd <$> token anySpace (TkLeftParen ())) <*>
      optional (commaSep1' anySpace arg) <*>
      (snd <$> token anySpace (TkRightParen ()))

      <!>

      (\a b c d -> Subscript (_exprAnnotation d) d a b c) <$>
      (snd <$> token anySpace (TkLeftBracket ())) <*>
      commaSep1' anySpace subscript <*>
      (snd <$> token anySpace (TkRightBracket ()))

    atomExpr = foldl' (&) <$> atom <*> many trailer

    parens = do
      (tk, s) <- token ws $ TkLeftParen ()
      ex <- yieldExpr ws <!> exprListComp anySpace
      Parens (pyTokenAnn tk) s ex <$> 
        (snd <$> token ws (TkRightParen ()))

    list = do
      (tk, s) <- token ws $ TkLeftBracket ()
      ex <- optional $ expr ws
      (case ex of
        Nothing -> pure $ List (pyTokenAnn tk) s Nothing
        Just ex' -> do
          val <-
            Left <$> compFor <!>
            Right <$> commaSepRest (expr anySpace)
          case val of
            Left cf ->
              ListComp (pyTokenAnn tk) s <$>
              (Comprehension (ex' ^. exprAnnotation)ex' cf <$>
               many (Left <$> compFor <!> Right <$> compIf))
            Right (cs, mws) ->
              pure $ List (pyTokenAnn tk) s (Just $ (ex', cs, mws) ^. _CommaSep1')) <*>
        (snd <$> token ws (TkRightBracket()))

    dictItem =
      (\a -> DictItem (a ^. exprAnnotation) a) <$>
      expr anySpace <*>
      (snd <$> colon anySpace) <*>
      expr anySpace

    dictOrSet = do
      (a, ws1) <- token anySpace (TkLeftBrace ())
      let ann = pyTokenAnn a
      maybeExpr <- optional $ expr anySpace
      (case maybeExpr of
         Nothing -> pure $ Dict ann ws1 Nothing
         Just ex -> do
           maybeColon <- optional $ snd <$> token anySpace (TkColon ())
           case maybeColon of
             Nothing ->
               (\(rest, final) -> Set ann ws1 ((ex, rest, final) ^. _CommaSep1')) <$>
               commaSepRest (expr anySpace)
             Just clws ->
               let
                 firstDictItem = DictItem (ex ^. exprAnnotation) ex clws
               in
                 (\ex2 (rest, final) ->
                    Dict ann ws1 (Just $ (firstDictItem ex2, rest, final) ^. _CommaSep1')) <$>
                 expr anySpace <*>
                 commaSepRest dictItem) <*>
         (snd <$> token ws (TkRightBrace ()))

    atom =
      dictOrSet <!>
      list <!>
      bool ws <!>
      none ws <!>
      integer ws <!>
      stringOrBytes ws <!>
      (\a -> Ident (_identAnnotation a) a) <$> identifier ws <!>
      parens

smallStatement :: Parser ann (SmallStatement '[] ann)
smallStatement =
  returnSt <!>
  passSt <!>
  breakSt <!>
  continueSt <!>
  globalSt <!>
  delSt <!>
  importSt <!>
  raiseSt <!>
  exprOrAssignSt <!>
  yieldSt <!>
  assertSt
  where
    assertSt =
      (\(tk, s) -> Assert (pyTokenAnn tk) s) <$>
      token space (TkAssert ()) <*>
      expr space <*>
      optional ((,) <$> (snd <$> comma space) <*> expr space)

    yieldSt = (\a -> Expr (a ^. exprAnnotation) a) <$> yieldExpr space

    returnSt =
      (\(tkReturn, retSpaces) -> Return (pyTokenAnn tkReturn) retSpaces) <$>
      token space (TkReturn ()) <*>
      optional (exprList space)

    passSt = Pass . pyTokenAnn <$> tokenEq (TkPass ())
    breakSt = Break . pyTokenAnn <$> tokenEq (TkBreak ())
    continueSt = Continue . pyTokenAnn <$> tokenEq (TkContinue ())

    augAssign =
      (\(tk, s) -> PlusEq (pyTokenAnn tk) s) <$> token space (TkPlusEq ()) <!>
      (\(tk, s) -> MinusEq (pyTokenAnn tk) s) <$> token space (TkMinusEq ()) <!>
      (\(tk, s) -> AtEq (pyTokenAnn tk) s) <$> token space (TkAtEq ()) <!>
      (\(tk, s) -> StarEq (pyTokenAnn tk) s) <$> token space (TkStarEq ()) <!>
      (\(tk, s) -> SlashEq (pyTokenAnn tk) s) <$> token space (TkSlashEq ()) <!>
      (\(tk, s) -> PercentEq (pyTokenAnn tk) s) <$> token space (TkPercentEq ()) <!>
      (\(tk, s) -> AmpersandEq (pyTokenAnn tk) s) <$> token space (TkAmpersandEq ()) <!>
      (\(tk, s) -> PipeEq (pyTokenAnn tk) s) <$> token space (TkPipeEq ()) <!>
      (\(tk, s) -> CaretEq (pyTokenAnn tk) s) <$> token space (TkCaretEq ()) <!>
      (\(tk, s) -> ShiftLeftEq (pyTokenAnn tk) s) <$> token space (TkShiftLeftEq ()) <!>
      (\(tk, s) -> ShiftRightEq (pyTokenAnn tk) s) <$> token space (TkShiftRightEq ()) <!>
      (\(tk, s) -> DoubleStarEq (pyTokenAnn tk) s) <$> token space (TkDoubleStarEq ()) <!>
      (\(tk, s) -> DoubleSlashEq (pyTokenAnn tk) s) <$> token space (TkDoubleSlashEq ())

    exprOrAssignSt =
      (\a ->
         maybe
           (Expr (_exprAnnotation a) a)
           (\(x, y) ->
              either
                (\z -> Assign (_exprAnnotation a) a z y)
                (\z -> AugAssign (_exprAnnotation a) a z y)
                x)) <$>
      exprList space <*>
      optional
        ((,) <$>
         (Left . snd <$> token space (TkEq ()) <!>
          Right <$> augAssign) <*>
         exprList space)

    globalSt =
      (\(tk, s) -> Global (pyTokenAnn tk) $ NonEmpty.fromList s) <$>
      token space (TkGlobal ()) <*>
      commaSep1 space (identifier space)

    delSt =
      (\(tk, s) -> Del (pyTokenAnn tk) $ NonEmpty.fromList s) <$>
      token space (TkDel ()) <*>
      commaSep1' space (orExpr space)

    raiseSt =
      (\(tk, s) -> Raise (pyTokenAnn tk) s) <$>
      token space (TkRaise ()) <*>
      optional
        ((,) <$>
         expr space <*>
         optional
           ((,) <$>
            (snd <$> token space (TkFrom ())) <*>
            expr space))

    importSt = importName <!> importFrom
      where
        moduleName =
          makeModuleName <$>
          identifier space <*>
          many
            ((,) <$>
             (snd <$> token space (TkDot ())) <*>
             identifier space)

        importAs ws getAnn p =
          (\a -> ImportAs (getAnn a) a) <$>
          p <*>
          optional
            ((,) <$>
             (NonEmpty.fromList . snd <$> token ws (TkAs ())) <*>
             identifier ws)

        importName =
          (\(tk, s) -> Import (pyTokenAnn tk) $ NonEmpty.fromList s) <$>
          token space (TkImport ()) <*>
          commaSep1 space (importAs space _moduleNameAnn moduleName)

        relativeModuleName =
          RelativeWithName [] <$> moduleName

          <!>

          (\a -> maybe (Relative $ NonEmpty.fromList a) (RelativeWithName a)) <$>
          some (Dot . snd <$> token space (TkDot ())) <*>
          optional moduleName

        importTargets =
          (\(tk, s) -> ImportAll (pyTokenAnn tk) s) <$>
          token space (TkStar ())

          <!>

          (\(tk, s) -> ImportSomeParens (pyTokenAnn tk) s) <$>
          token anySpace (TkLeftParen ()) <*>
          commaSep1' anySpace (importAs anySpace _identAnnotation (identifier anySpace)) <*>
          (snd <$> token space (TkRightParen ()))

          <!>

          (\a -> ImportSome (importAsAnn $ commaSep1Head a) a) <$>
          commaSep1 space (importAs space _identAnnotation (identifier space))

        importFrom =
          (\(tk, s) -> From (pyTokenAnn tk) s) <$>
          token space (TkFrom ()) <*>
          relativeModuleName <*>
          (snd <$> token space (TkImport ())) <*>
          importTargets

sepBy1' :: Parser ann a -> Parser ann sep -> Parser ann (a, [(sep, a)], Maybe sep)
sepBy1' val sep = go
  where
    go =
      (\a b ->
         case b of
           Nothing -> (a, [], Nothing)
           Just (sc, b') ->
             case b' of
               Nothing            -> (a, [], Just sc)
               Just (a', ls, sc') -> (a, (sc, a') : ls, sc')) <$>
      val <*>
      optional ((,) <$> sep <*> optional go)

statement :: Parser ann (Statement '[] ann)
statement =
  (\d (a, b, c) -> SmallStatements d a b c) <$>
  indents <*>
  sepBy1' smallStatement (snd <$> semicolon space) <*>
  (Just <$> eol <!> Nothing <$ eof)

  <!>

  CompoundStatement <$> compoundStatement
  where
    smallst1 =
      (\a b ->
         case b of
           Nothing -> (a, [], Nothing)
           Just (sc, b') ->
             case b' of
               Nothing            -> (a, [], Just sc)
               Just (a', ls, sc') -> (a, (sc, a') : ls, sc')) <$>
      smallStatement <*>
      smallst2

    smallst2 =
      optional ((,) <$> (snd <$> semicolon space) <*> optional smallst1)

comment :: Parser ann Comment
comment = do
  curTk <- currentToken
  case curTk of
    TkComment str ann ->
      Parser (consumed ann) $> Comment str
    _ -> Parser . throwError $ ExpectedComment curTk

suite :: Parser ann (Suite '[] ann)
suite =
  (\(tk, s) -> Suite (pyTokenAnn tk) s) <$>
  colon space <*>
  optional comment <*>
  eol <*>
  fmap Block
    (flip (foldr NonEmpty.cons) <$>
      commentOrIndent <*>
      some1 line) <*
  dedent
  where
    commentOrEmpty =
      (,,) <$>
      (foldOf (indentsValue.folded.indentWhitespaces) <$> indents) <*>
      optional comment <*>
      eol

    commentOrIndent = many (Left <$> commentOrEmpty) <* indent

    line = Left <$> commentOrEmpty <!> Right <$> statement

comma :: Parser ann Whitespace -> Parser ann (PyToken ann, [Whitespace])
comma ws = token ws $ TkComma ()

colon :: Parser ann Whitespace -> Parser ann (PyToken ann, [Whitespace])
colon ws = token ws $ TkColon ()

semicolon :: Parser ann Whitespace -> Parser ann (PyToken ann, [Whitespace])
semicolon ws = token ws $ TkSemicolon ()

commaSep :: Parser ann Whitespace -> Parser ann a -> Parser ann (CommaSep a)
commaSep ws pa =
  (\a -> maybe (CommaSepOne a) (uncurry $ CommaSepMany a)) <$>
  pa <*>
  optional ((,) <$> (snd <$> comma ws) <*> commaSep ws pa)

  <!>

  pure CommaSepNone

commaSep1 :: Parser ann Whitespace -> Parser ann a -> Parser ann (CommaSep1 a)
commaSep1 ws val = go
  where
    go =
      (\a -> maybe (CommaSepOne1 a) (uncurry $ CommaSepMany1 a)) <$>
      val <*>
      optional ((,) <$> (snd <$> comma ws) <*> go)

commaSep1' :: Parser ann Whitespace -> Parser ann a -> Parser ann (CommaSep1' a)
commaSep1' ws pa =
  (\(a, b, c) -> from a b c) <$> sepBy1' pa (snd <$> comma ws)
  where
    from a [] b            = CommaSepOne1' a b
    from a ((b, c) : bs) d = CommaSepMany1' a b $ from c bs d


typeAnnotation :: Parser ann (Type '[] ann)
typeAnnotation =
  do
    a <- reference
    b <- optional ((,,) <$> token anySpace (TkLeftBracket ()) <*> commaSep1 anySpace typeAnnotation <*> token anySpace (TkRightBracket ()))
    pure $ Type (referenceAnnotation a) a ((\(_,a,_) -> a) <$> b)

reference :: Parser ann (Reference '[] ann)
reference = do
  i <- identifier anySpace
  r <- optional (tokenEq (TkDot ()) *> reference)
  case r of
    Just ref -> pure $ Chain i ref 
    Nothing  -> pure $ Id i


param :: Parser ann (Param '[] ann)
param =
  do
    a <- identifier anySpace
    mtype <- optional ((,) <$> (snd <$> token anySpace (TkColon ())) <*> typeAnnotation)
    op <- optional ((,) <$> (snd <$> token anySpace (TkEq ())) <*> expr anySpace)
    case op of
      Nothing     -> pure $ PositionalParam (_identAnnotation a ) a mtype
      Just (w, e) -> pure $ KeywordParam (_identAnnotation a) a mtype w e

  <!>

  (\(a, b) -> StarParam (pyTokenAnn a) b) <$> token anySpace (TkStar ()) <*> identifier anySpace

  <!>

  (\(a, b) -> DoubleStarParam (pyTokenAnn a) b) <$>
  token anySpace (TkDoubleStar ()) <*>
  identifier anySpace

arg :: Parser ann (Arg '[] ann)
arg =
  (do
      e <- exprComp anySpace
      case e of
        Ident _ ident -> do
          eqSpaces <- optional $ snd <$> token anySpace (TkEq ())
          case eqSpaces of
            Nothing -> pure $ PositionalArg (_exprAnnotation e) e
            Just s -> KeywordArg (_exprAnnotation e) ident s <$> expr anySpace
        _ -> pure $ PositionalArg (_exprAnnotation e) e)

  <!>

  (\a -> PositionalArg (_exprAnnotation a) a) <$> expr anySpace

  <!>

  (\(a, b) -> StarArg (pyTokenAnn a) b) <$> token anySpace (TkStar ()) <*> expr anySpace

  <!>

  (\(a, b) -> DoubleStarArg (pyTokenAnn a) b) <$>
  token anySpace (TkDoubleStar ()) <*>
  expr anySpace

compoundStatement :: Parser ann (CompoundStatement '[] ann)
compoundStatement =
  fundef <!>
  ifSt <!>
  whileSt <!>
  trySt <!>
  classSt <!>
  forSt
  where
    fundef =
      (\dec a (tkDef, defSpaces) -> Fundef dec a (pyTokenAnn tkDef) (NonEmpty.fromList defSpaces)) <$>
      maybeDecorator <*>
      indents <*>
      token space (TkDef ()) <*>
      identifier space <*>
      fmap snd (token anySpace $ TkLeftParen ()) <*>
      commaSep anySpace param <*>
      fmap snd (token space $ TkRightParen ()) <*>
      maybeTypeAnn <*>
      suite

    ifSt =
      (\a (tk, s) -> If a (pyTokenAnn tk) s) <$>
      indents <*>
      token space (TkIf ()) <*>
      expr space <*>
      suite <*>
      many
        ((,,,) <$>
         indents <*>
         (snd <$> token space (TkElif ())) <*>
         expr space <*>
         suite) <*>
      optional
        ((,,) <$>
         indents <*>
         (snd <$> token space (TkElse ())) <*>
         suite)

    whileSt =
      (\a (tk, s) -> While a (pyTokenAnn tk) s) <$>
      indents <*>
      token space (TkWhile ()) <*>
      expr space <*>
      suite

    exceptAs =
      (\a -> ExceptAs (_exprAnnotation a) a) <$>
      expr space <*>
      optional ((,) <$> (snd <$> token space (TkAs())) <*> identifier space)

    trySt =
      (\i (tk, s) a d ->
         case d of
           Left (e, f, g) -> TryFinally i (pyTokenAnn tk) s a e f g
           Right (e, f, g) -> TryExcept i (pyTokenAnn tk) s a e f g) <$>
      indents <*>
      token space (TkTry ()) <*>
      suite <*>
      (fmap Left
         ((,,) <$>
          indents <*>
          (snd <$> token space (TkFinally ())) <*>
          suite)

        <!>

        fmap Right
          ((,,) <$>
           some1
             ((,,,) <$>
              indents <*>
              (snd <$> token space (TkExcept ())) <*>
              exceptAs <*>
              suite) <*>
           optional
             ((,,) <$>
              indents <*>
              (snd <$> token space (TkElse ())) <*>
              suite) <*>
           optional
             ((,,) <$>
              indents <*>
              (snd <$> token space (TkFinally ())) <*>
              suite)))

    classSt =
      (\a (tk, s) -> ClassDef a (pyTokenAnn tk) $ NonEmpty.fromList s) <$>
      indents <*>
      token space (TkClass ()) <*>
      identifier space <*>
      optional
        ((,,) <$>
         (snd <$> token anySpace (TkLeftParen ())) <*>
         optional (commaSep1' anySpace arg) <*>
         (snd <$> token space (TkRightParen ()))) <*>
      suite

    forSt =
      (\a (tk, s) -> For a (pyTokenAnn tk) s) <$>
      indents <*>
      token space (TkFor ()) <*>
      orExprList space <*>
      (snd <$> token space (TkIn ())) <*>
      exprList space <*>
      suite <*>
      optional
        ((,,) <$>
         indents <*>
         (snd <$> token space (TkElse ())) <*>
         suite)

    maybeTypeAnn = optional ((,) <$> 
        (snd <$> token space (TkArrow())) <*>
        typeAnnotation)

    parseDecoratorIdentifier :: Parser ann (Ident '[] ann)
    parseDecoratorIdentifier = do
      curTk <- currentToken
      case curTk of
        TkAt s ann -> do
          Parser $ consumed ann
          pure $ MkIdent ann s []
        _ -> Parser . throwError $ ExpectedIdentifier curTk

    maybeDecorator :: Parser ann (Maybe (Decorator '[] ann))
    maybeDecorator = optional (Decorator <$>  indents <*> parseDecoratorIdentifier <*> eol)

module_ :: Parser ann (Module '[] ann)
module_ =
  Module <$>
  many (Left <$> maybeComment <!> Right <$> statement)
  where
    maybeComment =
      (\ws cmt nl -> (ws, cmt, nl)) <$>
      indents <*>
      optional comment <*>
      (Just <$> eol <!> Nothing <$ eof)
