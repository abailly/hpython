{-# language DataKinds #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language FlexibleContexts #-}
{-# language PolyKinds #-}
{-# language TypeOperators #-}
{-# language TypeSynonymInstances, FlexibleInstances #-}
{-# language TemplateHaskell, TypeFamilies, MultiParamTypeClasses #-}
{-# language RankNTypes #-}
{-# language LambdaCase #-}
module Language.Python.Validate.Syntax where

import Control.Applicative ((<|>), liftA2)
import Control.Lens.Cons (_Cons, snoc)
import Control.Lens.Fold ((^..), (^?), folded, toListOf)
import Control.Lens.Getter ((^.))
import Control.Lens.Prism (_Right)
import Control.Lens.Review ((#))
import Control.Lens.Setter ((.~))
import Control.Lens.TH (makeLenses, makeWrapped)
import Control.Lens.Tuple (_2, _3)
import Control.Lens.Traversal (traverseOf)
import Control.Lens.Wrapped (_Wrapped)
import Control.Monad (when)
import Control.Monad.State (State, put, modify, get, evalState)
import Control.Monad.Reader (ReaderT, local, ask, runReaderT)
import Data.Char (isAscii)
import Data.Coerce (coerce)
import Data.Foldable (toList, traverse_)
import Data.Bitraversable (bitraverse)
import Data.Functor.Compose (Compose(..))
import Data.List (intersect, union)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Maybe (isJust)
import Data.Semigroup (Semigroup(..))
import Data.Type.Set (Nub, Member)
import Data.Validate (Validate(..))

import qualified Data.List.NonEmpty as NonEmpty

import Language.Python.Internal.Optics
import Language.Python.Internal.Syntax
import Language.Python.Validate.Indentation
import Language.Python.Validate.Syntax.Error

deleteBy' :: (a -> b -> Bool) -> a -> [b] -> [b]
deleteBy' _ _ [] = []
deleteBy' eq a (b:bs) = if a `eq` b then bs else b : deleteBy' eq a bs

deleteFirstsBy' :: (a -> b -> Bool) -> [a] -> [b] -> [a]
deleteFirstsBy' eq = foldl (flip (deleteBy' (flip eq)))

data Syntax

data SyntaxContext
  = SyntaxContext
  { _inLoop :: Bool
  , _inFunction :: Maybe [String]
  , _inGenerator :: Bool
  , _inParens :: Bool
  }
makeLenses ''SyntaxContext

newtype ValidateSyntax e a
  = ValidateSyntax
  { unValidateSyntax
    :: Compose
         (ReaderT SyntaxContext (State [String]))
         (Validate [e])
         a
  } deriving (Functor, Applicative)

runValidateSyntax :: SyntaxContext -> [String] -> ValidateSyntax e a -> Validate [e] a
runValidateSyntax ctxt nlscope =
  flip evalState nlscope .
  flip runReaderT ctxt . getCompose .
  unValidateSyntax

syntaxContext :: ValidateSyntax e SyntaxContext
syntaxContext =
  ValidateSyntax . Compose . fmap pure $ ask

nonlocals :: ValidateSyntax e [String]
nonlocals =
  ValidateSyntax . Compose . fmap pure $ get

bindValidateSyntax :: ValidateSyntax e a -> (a -> ValidateSyntax e b) -> ValidateSyntax e b
bindValidateSyntax v f =
  ValidateSyntax . Compose $ do
    a <- getCompose $ unValidateSyntax v
    case a of
      Failure e -> pure $ Failure e
      Success a -> getCompose . unValidateSyntax $ f a

localSyntaxContext
  :: (SyntaxContext -> SyntaxContext)
  -> ValidateSyntax e a
  -> ValidateSyntax e a
localSyntaxContext f v =
  ValidateSyntax . Compose $
  local f (getCompose $ unValidateSyntax v)

modifyNonlocals :: ([String] -> [String]) -> ValidateSyntax e ()
modifyNonlocals f =
  ValidateSyntax . Compose . fmap pure $ modify f

localNonlocals :: ([String] -> [String]) -> ValidateSyntax e a -> ValidateSyntax e a
localNonlocals f v =
  ValidateSyntax . Compose $ do
    before <- get
    modify f
    res <- getCompose $ unValidateSyntax v
    put before
    pure res

syntaxErrors :: [e] -> ValidateSyntax e a
syntaxErrors es = ValidateSyntax . Compose . pure $ Failure es

initialSyntaxContext :: SyntaxContext
initialSyntaxContext =
  SyntaxContext
  { _inLoop = False
  , _inFunction = Nothing
  , _inGenerator = False
  , _inParens = False
  }

isIdentifier :: String -> Bool
isIdentifier s =
  case s ^? _Cons of
    Nothing -> False
    Just (x, xs) -> isIdentifierStart x && all isIdentifierChar xs

validateIdent
  :: ( AsSyntaxError e v ann
     , Member Indentation v
     )
  => Ident v ann
  -> ValidateSyntax e (Ident (Nub (Syntax ': v)) ann)
validateIdent (MkIdent a name ws)
  | not (all isAscii name) = syntaxErrors [_BadCharacter # (a, name)]
  | null name = syntaxErrors [_EmptyIdentifier # a]
  | name `elem` reservedWords = syntaxErrors [_IdentifierReservedWord # (a, name)]
  | otherwise = pure $ MkIdent a name ws

validateWhitespace
  :: (AsSyntaxError e v a, Foldable f)
  => a
  -> f Whitespace
  -> ValidateSyntax e (f Whitespace)
validateWhitespace ann ws =
  syntaxContext `bindValidateSyntax` \ctxt ->
  if _inParens ctxt
  then pure ws
  else if any (\case; Newline{} -> True; _ -> False) ws
  then syntaxErrors [_UnexpectedNewline # ann]
  else if continuedBad ws
  then syntaxErrors [_CommentAfterBackslash # ann]
  else pure ws
  where
    continuedBad :: Foldable f => f Whitespace -> Bool
    continuedBad =
      any $ \case
        Continued a ws -> isJust (_commentBefore a) || continuedBad ws
        _ -> False

validateComprehensionSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Comprehension v a
  -> ValidateSyntax e (Comprehension (Nub (Syntax ': v)) a)
validateComprehensionSyntax (Comprehension a b c d) =
  Comprehension a <$>
  validateExprSyntax b <*>
  validateCompForSyntax c <*>
  traverse (bitraverse validateCompForSyntax validateCompIfSyntax) d
  where
    validateCompForSyntax
      :: ( AsSyntaxError e v a
        , Member Indentation v
        )
      => CompFor v a
      -> ValidateSyntax e (CompFor (Nub (Syntax ': v)) a)
    validateCompForSyntax (CompFor a b c d e) =
      (\c' -> CompFor a b c' d) <$>
      (if canAssignTo c
        then validateExprSyntax c
        else syntaxErrors [_CannotAssignTo # (a, c)]) <*>
      validateExprSyntax e

    validateCompIfSyntax
      :: ( AsSyntaxError e v a
        , Member Indentation v
        )
      => CompIf v a
      -> ValidateSyntax e (CompIf (Nub (Syntax ': v)) a)
    validateCompIfSyntax (CompIf a b c) =
      CompIf a b <$> validateExprSyntax c

validateStringLiteralSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => StringLiteral a
  -> ValidateSyntax e (StringLiteral a)
validateStringLiteralSyntax (StringLiteral a b c d e f) =
  StringLiteral a b c d e <$> validateWhitespace a f
validateStringLiteralSyntax (BytesLiteral a b c d e f) =
  BytesLiteral a b c d e <$> validateWhitespace a f

validateDictItemSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => DictItem v a
  -> ValidateSyntax e (DictItem (Nub (Syntax ': v)) a)
validateDictItemSyntax (DictItem a b c d) =
  (\b' -> DictItem a b' c) <$>
  validateExprSyntax b <*>
  validateExprSyntax d

validateSubscriptSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Subscript v a
  -> ValidateSyntax e (Subscript (Nub (Syntax ': v)) a)
validateSubscriptSyntax (SubscriptExpr e) = SubscriptExpr <$> validateExprSyntax e
validateSubscriptSyntax (SubscriptSlice a b c d) =
  (\a' -> SubscriptSlice a' b) <$>
  traverse validateExprSyntax a <*>
  traverse validateExprSyntax c <*>
  traverseOf (traverse._2.traverse) validateExprSyntax d

validateExprSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Expr v a
  -> ValidateSyntax e (Expr (Nub (Syntax ': v)) a)
validateExprSyntax (Lambda a b c d e) =
  let
    paramIdents = c ^.. folded.unvalidated.paramName.identValue
  in
    Lambda a <$>
    validateWhitespace a b <*>
    validateParamsSyntax c <*>
    validateWhitespace a d <*>
    localSyntaxContext
      (\ctxt ->
          ctxt
          { _inLoop = False
          , _inFunction =
              fmap
                (`union` paramIdents)
                (_inFunction ctxt) <|>
              Just paramIdents
          })
      (validateExprSyntax e)
validateExprSyntax (Yield a b c) =
  Yield a <$>
  validateWhitespace a b <*
  (syntaxContext `bindValidateSyntax` \ctxt ->
      case _inFunction ctxt of
        Nothing
          | _inGenerator ctxt -> pure ()
          | otherwise -> syntaxErrors [_YieldOutsideFunction # a]
        Just{} -> pure ()) <*>
  traverse validateExprSyntax c
validateExprSyntax (YieldFrom a b c d) =
  YieldFrom a <$>
  validateWhitespace a b <*>
  validateWhitespace a c <*
  (syntaxContext `bindValidateSyntax` \ctxt ->
      case _inFunction ctxt of
        Nothing
          | _inGenerator ctxt -> pure ()
          | otherwise -> syntaxErrors [_YieldOutsideFunction # a]
        Just{} -> pure ()) <*>
  validateExprSyntax d
validateExprSyntax (Ternary a b c d e f) =
  (\b' d' f' -> Ternary a b' c d' e f') <$>
  validateExprSyntax b <*>
  validateExprSyntax d <*>
  validateExprSyntax f
validateExprSyntax (Subscript a b c d e) =
  (\b' d' -> Subscript a b' c d' e) <$>
  validateExprSyntax b <*>
  traverse validateSubscriptSyntax d
validateExprSyntax (Not a ws e) =
  Not a <$>
  validateWhitespace a ws <*>
  validateExprSyntax e
validateExprSyntax (Parens a ws1 e ws2) =
  Parens a ws1 <$>
  localSyntaxContext (inParens .~ True) (validateExprSyntax e) <*>
  validateWhitespace a ws2
validateExprSyntax (Bool a b ws) = pure $ Bool a b ws
validateExprSyntax (UnOp a op expr) = UnOp a op <$> validateExprSyntax expr
validateExprSyntax (String a strLits) =
  if
    all (\case; StringLiteral{} -> True; _ -> False) strLits ||
    all (\case; BytesLiteral{} -> True; _ -> False) strLits
  then
    String a <$> traverse validateStringLiteralSyntax strLits
  else
    syntaxErrors [_Can'tJoinStringAndBytes # a]
validateExprSyntax (Int a n ws) = pure $ Int a n ws
validateExprSyntax (Float a n ws) = pure $ Float a n ws
validateExprSyntax (Ident a name) = Ident a <$> validateIdent name
validateExprSyntax (List a ws1 exprs ws2) =
  List a ws1 <$>
  localSyntaxContext
    (inParens .~ True)
    (traverseOf (traverse.traverse) validateExprSyntax exprs) <*>
  validateWhitespace a ws2
validateExprSyntax (ListComp a ws1 comp ws2) =
  ListComp a ws1 <$>
  localSyntaxContext
    (inParens .~ True)
    (validateComprehensionSyntax comp) <*>
  validateWhitespace a ws2
validateExprSyntax (Generator a comp) =
  Generator a <$>
  localSyntaxContext
    (\ctxt -> ctxt { _inGenerator = True })
    (validateComprehensionSyntax comp)
validateExprSyntax (Deref a expr ws1 name) =
  Deref a <$>
  validateExprSyntax expr <*>
  validateWhitespace a ws1 <*>
  validateIdent name
validateExprSyntax (Call a expr ws args ws2) =
  Call a <$>
  validateExprSyntax expr <*>
  localSyntaxContext (inParens .~ True) (validateWhitespace a ws) <*>
  localSyntaxContext (inParens .~ True) (traverse validateArgsSyntax args) <*>
  validateWhitespace a ws2
validateExprSyntax (None a ws) = pure $ None a ws
validateExprSyntax (BinOp a e1 op e2) =
  BinOp a <$>
  validateExprSyntax e1 <*>
  pure op <*>
  validateExprSyntax e2
validateExprSyntax (Tuple a b ws d) =
  Tuple a <$>
  validateExprSyntax b <*>
  validateWhitespace a ws <*>
  traverseOf (traverse.traverse) validateExprSyntax d
validateExprSyntax (Dict a b c d) =
  Dict a b <$>
  localSyntaxContext
    (inParens .~ True)
    (traverseOf (traverse.traverse) validateDictItemSyntax c) <*>
  validateWhitespace a d
validateExprSyntax (Set a b c d) =
  Set a b <$>
  localSyntaxContext
    (inParens .~ True)
    (traverse validateExprSyntax c) <*>
  validateWhitespace a d

validateBlockSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Block v a
  -> ValidateSyntax e (Block (Nub (Syntax ': v)) a)
validateBlockSyntax = traverseOf (_Wrapped.traverse._Right) validateStatementSyntax

validateSuiteSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Suite v a
  -> ValidateSyntax e (Suite (Nub (Syntax ': v)) a)
validateSuiteSyntax (SuiteMany a b c e) =
  SuiteMany a <$>
  validateWhitespace a b <*>
  pure c <*>
  validateBlockSyntax e
validateSuiteSyntax (SuiteOne a b c d) =
  SuiteOne a <$>
  validateWhitespace a b <*>
  validateSmallStatementSyntax c <*>
  pure d

validateDecoratorSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Decorator v a
  -> ValidateSyntax e (Decorator (Nub (Syntax ': v)) a)
validateDecoratorSyntax (Decorator a b c d e) =
  Decorator a b <$>
  validateWhitespace a c <*>
  isDecoratorValue d <*>
  pure e
  where
    isDecoratorValue e@Ident{} = pure $ coerce e
    isDecoratorValue e@(Call _ a _ _ _) | someDerefs a = pure $ coerce e
      where
        someDerefs Ident{} = True
        someDerefs (Deref _ a _ _) = someDerefs a
        someDerefs _ = False
    isDecoratorValue _ = syntaxErrors [_MalformedDecorator # a]

validateCompoundStatementSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => CompoundStatement v a
  -> ValidateSyntax e (CompoundStatement (Nub (Syntax ': v)) a)
validateCompoundStatementSyntax (Fundef a decos idnts ws1 name ws2 params ws3 body) =
  let
    paramIdents = params ^.. folded.unvalidated.paramName.identValue
  in
    (\decos' -> Fundef a decos' idnts ws1) <$>
    traverse validateDecoratorSyntax decos <*>
    validateIdent name <*>
    pure ws2 <*>
    validateParamsSyntax params <*>
    pure ws3 <*>
    localNonlocals id
      (localSyntaxContext
         (\ctxt ->
            ctxt
            { _inLoop = False
            , _inFunction =
                fmap
                  (`union` paramIdents)
                  (_inFunction ctxt) <|>
                Just paramIdents
            })
         (validateSuiteSyntax body))
validateCompoundStatementSyntax (If idnts a ws1 expr body elifs body') =
  If idnts a <$>
  validateWhitespace a ws1 <*>
  validateExprSyntax expr <*>
  validateSuiteSyntax body <*>
  traverse
    (\(a, b, c, d) ->
       (\c' -> (,,,) a b c') <$>
       validateExprSyntax c <*>
       validateSuiteSyntax d)
    elifs <*>
  traverseOf (traverse._3) validateSuiteSyntax body'
validateCompoundStatementSyntax (While idnts a ws1 expr body) =
  While idnts a <$>
  validateWhitespace a ws1 <*>
  validateExprSyntax expr <*>
  localSyntaxContext (\ctxt -> ctxt { _inLoop = True}) (validateSuiteSyntax body)
validateCompoundStatementSyntax (TryExcept idnts a b e f k l) =
  TryExcept idnts a <$>
  validateWhitespace a b <*>
  validateSuiteSyntax e <*>
  traverse
    (\(idnts, f, g, j) ->
       (,,,) idnts <$>
       validateWhitespace a f <*>
       validateExceptAsSyntax g <*>
       validateSuiteSyntax j)
    f <*>
  traverse
    (\(idnts, x, w) ->
       (,,) idnts <$>
       validateWhitespace a x <*>
       validateSuiteSyntax w)
    k <*>
  traverse
    (\(idnts, x, w) ->
       (,,) idnts <$>
       validateWhitespace a x <*>
       validateSuiteSyntax w)
    l
validateCompoundStatementSyntax (TryFinally idnts a b e idnts2 f i) =
  TryFinally idnts a <$>
  validateWhitespace a b <*>
  validateSuiteSyntax e <*> pure idnts2 <*>
  validateWhitespace a f <*>
  validateSuiteSyntax i
validateCompoundStatementSyntax (For idnts a b c d e h i) =
  For idnts a <$>
  validateWhitespace a b <*>
  (if canAssignTo c
   then validateExprSyntax c
   else syntaxErrors [_CannotAssignTo # (a, c)]) <*>
  validateWhitespace a d <*>
  validateExprSyntax e <*>
  localSyntaxContext (\c -> c { _inLoop = True }) (validateSuiteSyntax h) <*>
  traverse
    (\(idnts, x, w) ->
       (,,) idnts <$>
       validateWhitespace a x <*>
       validateSuiteSyntax w)
    i
validateCompoundStatementSyntax (ClassDef a decos idnts b c d g) =
  (\decos' -> ClassDef a decos' idnts) <$>
  traverse validateDecoratorSyntax decos <*>
  validateWhitespace a b <*>
  validateIdent c <*>
  traverse
    (\(x, y, z) ->
       (,,) <$>
       validateWhitespace a x <*>
       traverse
         (localSyntaxContext (inParens .~ True) . validateArgsSyntax)
         y <*>
       validateWhitespace a z)
    d <*>
  validateSuiteSyntax g
validateCompoundStatementSyntax (With a b c d e) =
  With a b c <$>
  traverse
    (\(WithItem a b c) ->
        WithItem a <$>
        validateExprSyntax b <*>
        traverse
          (\(ws, b) -> (,) <$> validateWhitespace a ws <*> validateExprSyntax b)
          c)
    d <*>
  validateSuiteSyntax e

validateExceptAsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => ExceptAs v a
  -> ValidateSyntax e (ExceptAs (Nub (Syntax ': v)) a)
validateExceptAsSyntax (ExceptAs ann e f) =
  ExceptAs ann <$>
  validateExprSyntax e <*>
  traverse (\(a, b) -> (,) <$> validateWhitespace ann a <*> validateIdent b) f

validateImportAs
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => (t a -> ValidateSyntax e (t' a))
  -> ImportAs t v a
  -> ValidateSyntax e (ImportAs t' (Nub (Syntax ': v)) a)
validateImportAs v (ImportAs x a b) =
  ImportAs x <$>
  v a <*>
  traverse
    (\(c, d) ->
       (,) <$>
       (c <$ validateWhitespace x (NonEmpty.toList c)) <*>
       validateIdent d)
    b

validateImportTargets
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => ImportTargets v a
  -> ValidateSyntax e (ImportTargets (Nub (Syntax ': v)) a)
validateImportTargets (ImportAll a ws) = ImportAll a <$> validateWhitespace a ws
validateImportTargets (ImportSome a cs) =
  ImportSome a <$> traverse (validateImportAs validateIdent) cs
validateImportTargets (ImportSomeParens a ws1 cs ws2) =
  localSyntaxContext
    (inParens .~ True)
    (ImportSomeParens a <$>
     validateWhitespace a ws1 <*>
     traverse (validateImportAs validateIdent) cs) <*>
  validateWhitespace a ws2

validateSmallStatementSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => SmallStatement v a
  -> ValidateSyntax e (SmallStatement (Nub (Syntax ': v)) a)
validateSmallStatementSyntax (Assert a b c d) =
  Assert a <$>
  validateWhitespace a b <*>
  validateExprSyntax c <*>
  traverseOf (traverse._2) validateExprSyntax d
validateSmallStatementSyntax (Raise a ws f) =
  Raise a <$>
  validateWhitespace a ws <*>
  traverse
    (\(b, c) ->
       (,) <$>
       validateExprSyntax b <*>
       traverse
         (\(d, e) ->
            (,) <$>
            validateWhitespace a d <*>
            validateExprSyntax e)
         c)
    f
validateSmallStatementSyntax (Return a ws expr) =
  syntaxContext `bindValidateSyntax` \sctxt ->
    case _inFunction sctxt of
      Just{} ->
        Return a <$>
        validateWhitespace a ws <*>
        traverse validateExprSyntax expr
      _ -> syntaxErrors [_ReturnOutsideFunction # a]
validateSmallStatementSyntax (Expr a expr) =
  Expr a <$>
  validateExprSyntax expr
validateSmallStatementSyntax (Assign a lvalue rs) =
  syntaxContext `bindValidateSyntax` \sctxt ->
    let
      assigns =
        if isJust (_inFunction sctxt)
        then
          (lvalue : (snd <$> NonEmpty.init rs)) ^..
          folded.unvalidated.assignTargets.identValue
        else []
    in
      Assign a <$>
      (if canAssignTo lvalue
        then validateExprSyntax lvalue
        else syntaxErrors [_CannotAssignTo # (a, lvalue)]) <*>
      ((\a b -> case a of; [] -> pure b; a : as -> a :| (snoc as b)) <$>
       traverse
         (\(ws, b) ->
            (,) <$>
            validateWhitespace a ws <*>
            (if canAssignTo b
              then validateExprSyntax lvalue
              else syntaxErrors [_CannotAssignTo # (a, b)]))
         (NonEmpty.init rs) <*>
       (\(ws, b) -> (,) <$> validateWhitespace a ws <*> validateExprSyntax b)
         (NonEmpty.last rs)) <*
      modifyNonlocals (assigns ++)
validateSmallStatementSyntax (AugAssign a lvalue aa rvalue) =
  AugAssign a <$>
  (if canAssignTo lvalue
    then case lvalue of
      Ident{} -> validateExprSyntax lvalue
      Deref{} -> validateExprSyntax lvalue
      Subscript{} -> validateExprSyntax lvalue
      _ -> syntaxErrors [_CannotAugAssignTo # (a, lvalue)]
    else syntaxErrors [_CannotAssignTo # (a, lvalue)]) <*>
  pure aa <*>
  validateExprSyntax rvalue
validateSmallStatementSyntax p@Pass{} = pure $ coerce p
validateSmallStatementSyntax (Break a) =
  syntaxContext `bindValidateSyntax` \sctxt ->
    if _inLoop sctxt
    then pure $ Break a
    else syntaxErrors [_BreakOutsideLoop # a]
validateSmallStatementSyntax (Continue a) =
  syntaxContext `bindValidateSyntax` \sctxt ->
    if _inLoop sctxt
    then pure $ Continue a
    else syntaxErrors [_ContinueOutsideLoop # a]
validateSmallStatementSyntax (Global a ws ids) =
  Global a ws <$> traverse validateIdent ids
validateSmallStatementSyntax (Nonlocal a ws ids) =
  syntaxContext `bindValidateSyntax` \sctxt ->
  nonlocals `bindValidateSyntax` \nls ->
  (case deleteFirstsBy' (\a -> (==) (a ^. unvalidated.identValue)) (ids ^.. folded) nls of
     [] -> pure ()
     ids -> traverse_ (\e -> syntaxErrors [_NoBindingNonlocal # e]) ids) *>
  case _inFunction sctxt of
    Nothing -> syntaxErrors [_NonlocalOutsideFunction # a]
    Just params ->
      case intersect params (ids ^.. folded.unvalidated.identValue) of
        [] -> Nonlocal a ws <$> traverse validateIdent ids
        bad -> syntaxErrors [_ParametersNonlocal # (a, bad)]
validateSmallStatementSyntax (Del a ws ids) =
  Del a ws <$> traverse validateExprSyntax ids
validateSmallStatementSyntax (Import a ws mns) =
  Import a ws <$> traverse (pure . coerce) mns
validateSmallStatementSyntax (From a ws1 mn ws2 ts) =
  From a ws1 (coerce mn) <$>
  validateWhitespace a ws2 <*>
  validateImportTargets ts

validateStatementSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Statement v a
  -> ValidateSyntax e (Statement (Nub (Syntax ': v)) a)
validateStatementSyntax (CompoundStatement c) =
  CompoundStatement <$> validateCompoundStatementSyntax c
validateStatementSyntax (SmallStatements idnts s ss sc nl) =
  SmallStatements idnts <$>
  validateSmallStatementSyntax s <*>
  traverseOf (traverse._2) validateSmallStatementSyntax ss <*>
  pure sc <*>
  pure nl

canAssignTo :: Expr v a -> Bool
canAssignTo None{} = False
canAssignTo UnOp{} = False
canAssignTo Int{} = False
canAssignTo Call{} = False
canAssignTo BinOp{} = False
canAssignTo Bool{} = False
canAssignTo (Parens _ _ a _) = canAssignTo a
canAssignTo String{} = False
canAssignTo (List _ _ a _) = all (all canAssignTo) a
canAssignTo (Tuple _ a _ b) = all canAssignTo $ a : toListOf (folded.folded) b
canAssignTo _ = True

validateArgsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => CommaSep1' (Arg v a)
  -> ValidateSyntax e (CommaSep1' (Arg (Nub (Syntax ': v)) a))
validateArgsSyntax e = fmap coerce e <$ go [] False False (toList e)
  where
    go
      :: (AsSyntaxError e v a, Member Indentation v)
      => [String]
      -- ^ Have we seen a keyword argument?
      -> Bool
      -- ^ Have we seen a **argument?
      -> Bool
      -> [Arg v a]
      -> ValidateSyntax e [Arg (Nub (Syntax ': v)) a]
    go _ _ _ [] = pure []
    go names False False (PositionalArg a expr : args) =
      liftA2 (:)
        (PositionalArg a <$> validateExprSyntax expr)
        (go names False False args)
    go names seenKeyword seenUnpack (PositionalArg a expr : args) =
      when seenKeyword (syntaxErrors [_PositionalAfterKeywordArg # (a, expr)]) *>
      when seenUnpack (syntaxErrors [_PositionalAfterKeywordUnpacking # (a, expr)]) *>
      go names seenKeyword seenUnpack args
    go names seenKeyword False (StarArg a ws expr : args) =
      liftA2 (:)
        (StarArg a <$> validateWhitespace a ws <*> validateExprSyntax expr)
        (go names seenKeyword False args)
    go names seenKeyword seenUnpack (StarArg a ws expr : args) =
      when seenKeyword (syntaxErrors [_PositionalAfterKeywordArg # (a, expr)]) *>
      when seenUnpack (syntaxErrors [_PositionalAfterKeywordUnpacking # (a, expr)]) *>
      go names seenKeyword seenUnpack args
    go names _ seenUnpack (KeywordArg a name ws2 expr : args)
      | _identValue name `elem` names =
          syntaxErrors [_DuplicateArgument # (a, _identValue name)] <*>
          validateIdent name <*>
          go names True seenUnpack args
      | otherwise =
          liftA2 (:)
            (KeywordArg a <$>
             validateIdent name <*>
             pure ws2 <*>
             validateExprSyntax expr)
            (go (_identValue name:names) True seenUnpack args)
    go names seenKeyword _ (DoubleStarArg a ws expr : args) =
      liftA2 (:)
        (DoubleStarArg a <$>
         validateWhitespace a ws <*>
         validateExprSyntax expr)
        (go names seenKeyword True args)

validateParamsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => CommaSep (Param v a)
  -> ValidateSyntax e (CommaSep (Param (Nub (Syntax ': v)) a))
validateParamsSyntax e = coerce e <$ go [] False (toList e)
  where
    go _ _ [] = pure []
    go names False (PositionalParam a name : params)
      | _identValue name `elem` names =
          syntaxErrors [_DuplicateArgument # (a, _identValue name)] <*>
          validateIdent name <*>
          go (_identValue name:names) False params
      | otherwise =
          liftA2
            (:)
            (PositionalParam a <$> validateIdent name)
            (go (_identValue name:names) False params)
    go names seen (StarParam a ws name : params)
      | _identValue name `elem` names =
          syntaxErrors [_DuplicateArgument # (a, _identValue name)] <*>
          validateIdent name <*>
          go (_identValue name:names) seen params
      | otherwise =
          liftA2
            (:)
            (StarParam a ws <$> validateIdent name)
            (go (_identValue name:names) seen params)
    go names True (PositionalParam a name : params) =
      let
        name' = _identValue name
        errs =
            [_DuplicateArgument # (a, name') | name' `elem` names] <>
            [_PositionalAfterKeywordParam # (a, name')]
      in
        syntaxErrors errs <*> go (name':names) True params
    go names _ (KeywordParam a name ws2 expr : params)
      | _identValue name `elem` names =
          syntaxErrors [_DuplicateArgument # (a, _identValue name)] <*> go names True params
      | otherwise =
          liftA2 (:)
            (KeywordParam a <$>
             validateIdent name <*>
             pure ws2 <*>
             validateExprSyntax expr)
            (go (_identValue name:names) True params)
    go names _ [DoubleStarParam a ws name]
      | _identValue name `elem` names =
          syntaxErrors [_DuplicateArgument # (a, _identValue name)]
      | otherwise =
          fmap pure $ DoubleStarParam a ws <$> validateIdent name
    go names _ (DoubleStarParam a ws name : _) =
      (if _identValue name `elem` names
       then syntaxErrors [_DuplicateArgument # (a, _identValue name)]
       else pure ()) *>
      syntaxErrors [_UnexpectedDoubleStarParam # (a, _identValue name)]

validateModuleSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Module v a
  -> ValidateSyntax e (Module (Nub (Syntax ': v)) a)
validateModuleSyntax =
  traverseOf (_Wrapped.traverse._Right) validateStatementSyntax

makeWrapped ''ValidateSyntax
