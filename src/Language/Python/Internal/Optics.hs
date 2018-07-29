{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE PolyKinds         #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}

module Language.Python.Internal.Optics where

import           Control.Lens.Fold               (Fold)
import           Control.Lens.Getter             (Getter, to)
import           Control.Lens.Prism              (Prism, prism, _Left, _Right)
import           Control.Lens.Setter             ((.~))
import           Control.Lens.TH                 (makeLenses)
import           Control.Lens.Traversal          (Traversal, Traversal',
                                                  failing, traverseOf)
import           Control.Lens.Tuple              (_3, _4)
import           Control.Lens.Wrapped            (_Wrapped)
import           Data.Coerce                     (Coercible, coerce)
import           Data.Function                   ((&))
import           Data.List.NonEmpty
import           Language.Python.Internal.Syntax

class Validated (s :: [*] -> * -> *) where
  unvalidated :: Getter (s v a) (s '[] a)
  default unvalidated :: Coercible (s v a) (s '[] a) =>
    Getter (s v a) (s '[] a)
  unvalidated = to coerce

instance Validated Expr

instance Validated Statement

instance Validated Block

instance Validated Ident

instance Validated Param

instance Validated Suite

data KeywordParam v a = MkKeywordParam
  { _kpAnn             :: a
  , _kpName            :: Ident v a
  , _kpType            :: Maybe ([Whitespace], Type v a)
  , _kpWhitespaceRight :: [Whitespace]
  , _kpExpr            :: Expr v a
  } deriving (Eq, Show)

makeLenses ''KeywordParam

_KeywordParam ::
     Prism (Param v a) (Param '[] a) (KeywordParam v a) (KeywordParam '[] a)
_KeywordParam =
  prism
    (\(MkKeywordParam a b d t e) -> KeywordParam a b d t e)
    (\case
       (coerce -> KeywordParam a b d t e) -> Right (MkKeywordParam a b d t e)
       (coerce -> a) -> Left a)

_Fundef ::
     Prism (Statement v a) (Statement '[] a) ( Indents a
                                             , a
                                             , NonEmpty Whitespace
                                             , Ident v a
                                             , [Whitespace]
                                             , CommaSep (Param v a)
                                             , [Whitespace]
                                             , Suite v a) ( Indents a
                                                          , a
                                                          , NonEmpty Whitespace
                                                          , Ident '[] a
                                                          , [Whitespace]
                                                          , CommaSep (Param '[] a)
                                                          , [Whitespace]
                                                          , Suite '[] a)
_Fundef =
  prism
    (\(idnt, a, b, c, d, e, f, g) ->
       CompoundStatement (Fundef idnt a b c d e f g))
    (\case
       (coerce -> CompoundStatement (Fundef idnt a b c d e f g)) ->
         Right (idnt, a, b, c, d, e, f, g)
       (coerce -> a) -> Left a)

_Call ::
     Prism (Expr v a) (Expr '[] a) ( a
                                   , Expr v a
                                   , [Whitespace]
                                   , Maybe (CommaSep1' (Arg v a))
                                   , [Whitespace]) ( a
                                                   , Expr '[] a
                                                   , [Whitespace]
                                                   , Maybe (CommaSep1' (Arg '[] a))
                                                   , [Whitespace])
_Call =
  prism
    (\(a, b, c, d, e) -> Call a b c d e)
    (\case
       (coerce -> Call a b c d e) -> Right (a, b, c, d, e)
       (coerce -> a) -> Left a)

_Ident :: Prism (Expr v a) (Expr '[] a) (a, Ident v a) (a, Ident '[] a)
_Ident =
  prism
    (\(a, b) -> Ident a b)
    (\case
       (coerce -> Ident a b) -> Right (a, b)
       (coerce -> a) -> Left a)

_Indent :: HasIndents s => Traversal' (s '[] a) [Whitespace]
_Indent = _Indents . indentsValue . traverse . indentWhitespaces

noIndents :: HasIndents s => Fold (s '[] a) (s '[] a)
noIndents f s = f $ s & _Indents . indentsValue .~ []

class HasIndents s where
  _Indents :: Traversal' (s '[] a) (Indents a)

instance HasIndents Statement where
  _Indents f (SmallStatements idnt a b c d) =
    (\idnt' -> SmallStatements idnt' a b c d) <$> f idnt
  _Indents f (CompoundStatement c) = CompoundStatement <$> _Indents f c

instance HasIndents Block where
  _Indents = _Statements . _Indents

instance HasIndents Suite where
  _Indents f (Suite a b c d e) = Suite a b c d <$> _Indents f e

instance HasIndents CompoundStatement where
  _Indents fun s =
    case s of
      Fundef idnt a b c d e f g ->
        (\idnt' -> Fundef idnt' a b c d e f) <$> fun idnt <*> _Indents fun g
      If idnt a b c d elifs e ->
        (\idnt' -> If idnt' a b c) <$> fun idnt <*> _Indents fun d <*>
        traverse
          (\(idnt, a, b, c) ->
             (\idnt' -> (,,,) idnt' a b) <$> fun idnt <*> _Indents fun c)
          elifs <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$> fun idnt <*> _Indents fun b)
          e
      While idnt a b c d ->
        (\idnt' -> While idnt' a b c) <$> fun idnt <*> _Indents fun d
      TryExcept idnt a b c d e f ->
        (\idnt' -> TryExcept idnt' a b) <$> fun idnt <*> _Indents fun c <*>
        traverse
          (\(idnt, a, b, c) ->
             (\idnt' -> (,,,) idnt' a b) <$> fun idnt <*> _Indents fun c)
          d <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$> fun idnt <*> _Indents fun b)
          e <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$> fun idnt <*> _Indents fun b)
          f
      TryFinally idnt a b c idnt2 d e ->
        (\idnt' c' idnt2' -> TryFinally idnt' a b c' idnt2' d) <$> fun idnt <*>
        _Indents fun c <*>
        fun idnt2 <*>
        _Indents fun e
      For idnt a b c d e f g ->
        (\idnt' -> For idnt' a b c d e) <$> fun idnt <*> _Indents fun f <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$> fun idnt <*> _Indents fun b)
          g
      ClassDef idnt a b c d e ->
        (\idnt' -> ClassDef idnt' a b c d) <$> fun idnt <*> _Indents fun e

class HasNewlines s where
  _Newlines :: Traversal' (s v a) Newline

instance HasNewlines Block where
  _Newlines f (Block b) = Block <$> (traverse . _Right . _Newlines) f b

instance HasNewlines Suite where
  _Newlines f (Suite a b c d e) = Suite a b c <$> f d <*> _Newlines f e

instance HasNewlines CompoundStatement where
  _Newlines fun s =
    case s of
      Fundef idnt ann ws1 name ws2 params ws3 s ->
        Fundef idnt ann ws1 name ws2 params ws3 <$> _Newlines fun s
      If idnt ann ws1 cond s elifs els ->
        If idnt ann ws1 cond <$> _Newlines fun s <*>
        traverseOf (traverse . _4 . _Newlines) fun elifs <*>
        traverseOf (traverse . _3 . _Newlines) fun els
      While idnt ann ws1 cond s -> While idnt ann ws1 cond <$> _Newlines fun s
      TryExcept idnt a b c f k l ->
        TryExcept idnt a b <$> _Newlines fun c <*>
        traverseOf (traverse . _4 . _Newlines) fun f <*>
        traverseOf (traverse . _3 . _Newlines) fun k <*>
        traverseOf (traverse . _3 . _Newlines) fun l
      TryFinally idnt a b c idnt2 f g ->
        TryFinally idnt a b <$> _Newlines fun c <*> pure idnt2 <*> pure f <*>
        _Newlines fun g
      For idnt a b c d e f g ->
        For idnt a b c d e <$> _Newlines fun f <*>
        (traverse . _3 . _Newlines) fun g
      ClassDef idnt a b c d e ->
        ClassDef idnt a b (coerce c) (coerce d) <$> _Newlines fun e

instance HasNewlines Statement where
  _Newlines f (CompoundStatement c) = CompoundStatement <$> _Newlines f c
  _Newlines f (SmallStatements idnts s ss sc nl) =
    SmallStatements idnts s ss sc <$> traverse f nl

instance HasNewlines Module where
  _Newlines =
    _Wrapped . traverse . failing (_Left . _3 . traverse) (_Right . _Newlines)

assignTargets :: Traversal (Expr v a) (Expr '[] a) (Ident v a) (Ident '[] a)
assignTargets f e =
  case e of
    List a b c d ->
      (\c' -> List a b c' d) <$> (traverse . traverse . assignTargets) f c
    Parens a b c d -> (\c' -> Parens a b c' d) <$> assignTargets f c
    Ident a b -> Ident a <$> f b
    Tuple a b c d ->
      (\b' d' -> Tuple a b' c d') <$> assignTargets f b <*>
      (traverse . traverse . assignTargets) f d
    Yield {} -> pure $ coerce e
    YieldFrom {} -> pure $ coerce e
    Ternary {} -> pure $ coerce e
    ListComp {} -> pure $ coerce e
    Deref {} -> pure $ coerce e
    Subscript {} -> pure $ coerce e
    Call {} -> pure $ coerce e
    None {} -> pure $ coerce e
    BinOp {} -> pure $ coerce e
    Negate {} -> pure $ coerce e
    Int {} -> pure $ coerce e
    Bool {} -> pure $ coerce e
    String {} -> pure $ coerce e
    Not {} -> pure $ coerce e
    Dict {} -> pure $ coerce e
    Set {} -> pure $ coerce e
    Generator {} -> pure $ coerce e
