{-# language TemplateHaskell #-}
{-# language DataKinds, KindSignatures #-}
{-# language MultiParamTypeClasses, FlexibleInstances #-}
{-# language DeriveFunctor, DeriveFoldable, DeriveTraversable, DeriveGeneric #-}
{-# language TypeFamilies #-}
{-# language LambdaCase #-}
{-# language UndecidableInstances #-}
module Language.Python.Internal.Syntax.Statement where

import Control.Lens.Getter ((^.), getting)
import Control.Lens.Lens (Lens, Lens', lens)
import Control.Lens.Plated (Plated(..), gplate)
import Control.Lens.Prism (_Just, _Right)
import Control.Lens.Setter ((.~), over, mapped)
import Control.Lens.TH (makeLenses, makeWrapped)
import Control.Lens.Traversal (Traversal, traverseOf)
import Control.Lens.Tuple (_2, _5, _6)
import Control.Lens.Wrapped (_Wrapped)
import Data.Coerce (coerce)
import Data.Function ((&))
import Data.List.NonEmpty (NonEmpty)
import GHC.Generics (Generic)

import Language.Python.Internal.Syntax.CommaSep
import Language.Python.Internal.Syntax.Comment
import Language.Python.Internal.Syntax.Expr
import Language.Python.Internal.Syntax.Ident
import Language.Python.Internal.Syntax.ModuleNames
import Language.Python.Internal.Syntax.Whitespace

-- | 'Traversal' over all the statements in a term
class HasStatements s where
  _Statements :: Traversal (s v a) (s '[] a) (Statement v a) (Statement '[] a)

data Type (v :: [*]) a 
  = Type
  {  _typeAnn :: a
  ,  _typeName :: Ident v a 
  ,  _typeParams :: Maybe (CommaSep1 (Type v a))
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Param (v :: [*]) a
  = PositionalParam
  { _paramAnn :: a
  , _paramName :: Ident v a
    -- : spaces type
  , _patamType :: Maybe ([Whitespace], Type v a)
  }
  | KeywordParam
  { _paramAnn :: a
  , _paramName :: Ident v a
  -- : spaces type
  , _patamType :: Maybe ([Whitespace], Type v a)
  -- = spaces
  , _unsafeKeywordParamWhitespaceRight :: [Whitespace]
  , _unsafeKeywordParamExpr :: Expr v a
  }
  | StarParam
  { _paramAnn :: a
  -- '*' spaces
  , _unsafeStarParamWhitespace :: [Whitespace]
  , _paramName :: Ident v a
  }
  | DoubleStarParam
  { _paramAnn :: a
  -- '**' spaces
  , _unsafeDoubleStarParamWhitespace :: [Whitespace]
  , _paramName :: Ident v a
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

paramAnn :: Lens' (Param v a) a
paramAnn = lens _paramAnn (\s a -> s { _paramAnn = a})

paramName :: Lens (Param v a) (Param '[] a) (Ident v a) (Ident v a)
paramName = lens _paramName (\s a -> coerce $ s { _paramName = a})

instance HasExprs Param where
  _Exprs f (KeywordParam a name t ws2 expr) =
    KeywordParam a (coerce name) <$> (pure $ coerce t) <*> pure ws2 <*> f expr
  _Exprs _ p@PositionalParam{} = pure $ coerce p
  _Exprs _ p@StarParam{} = pure $ coerce p
  _Exprs _ p@DoubleStarParam{} = pure $ coerce p

newtype Block v a
  = Block
  { unBlock
    :: NonEmpty
         (Either
            ([Whitespace], Maybe Comment, Newline)
            (Statement v a))
  } deriving (Eq, Show, Functor, Foldable, Traversable)

class HasBlocks s where
  _Blocks :: Traversal (s v a) (s '[] a) (Block v a) (Block '[] a)

instance HasBlocks CompoundStatement where
  _Blocks f (Fundef idnt a ws1 name ws2 params ws3 ws4 nl b) =
    Fundef idnt a ws1 (coerce name) ws2 (coerce params) ws3 ws4 nl <$> coerce (f b)
  _Blocks f (If idnt a ws1 e1 ws3 nl b b') =
    If idnt a ws1 (coerce e1) ws3 nl <$>
    coerce (f b) <*>
    traverseOf (traverse._5) (coerce . f) b'
  _Blocks f (While idnt a ws1 e1 ws3 nl b) =
    While idnt a ws1 (coerce e1) ws3 nl <$> coerce (f b)
  _Blocks fun (TryExcept idnt a b c d e f g h) =
    TryExcept idnt a (coerce b) (coerce c) (coerce d) <$>
    fun e <*>
    -- (coerce f) downcasts the ExceptAs
    (traverse._6) fun (coerce f) <*>
    (traverse._5) fun g <*>
    (traverse._5) fun h
  _Blocks fun (TryFinally idnt a b c d e idnt2 f g h i) =
    TryFinally idnt a (coerce b) (coerce c) (coerce d) <$> fun e <*> pure idnt2 <*>
    pure (coerce f) <*> pure (coerce g) <*> pure (coerce h) <*> fun i
  _Blocks fun (For idnt a b c d e f g h i) =
    For idnt a b (coerce c) d (coerce e) f g <$>
    fun h <*>
    (traverse._5) fun i
  _Blocks fun (ClassDef idnt a b c d e f g) =
    ClassDef idnt a b (coerce c) (coerce d) e f <$> fun g

instance HasStatements Block where
  _Statements = _Wrapped.traverse._Right

data Statement (v :: [*]) a
  = SmallStatements
      (Indents a)
      (SmallStatement v a)
      [([Whitespace], SmallStatement v a)]
      (Maybe [Whitespace])
      (Maybe Newline)
  | CompoundStatement
      (CompoundStatement v a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance HasBlocks Statement where
  _Blocks f (CompoundStatement c) = CompoundStatement <$> _Blocks f c
  _Blocks _ (SmallStatements idnt a b c d) =
    pure $ SmallStatements idnt (coerce a) (over (mapped._2) coerce b) c d

instance Plated (Statement '[] a) where
  plate _ s@SmallStatements{} = pure s
  plate fun (CompoundStatement s) =
    CompoundStatement <$>
    case s of
      Fundef idnt a ws1 b ws2 c ws3 ws4 nl sts ->
        Fundef idnt a ws1 b ws2 c ws3 ws4 nl <$> _Statements fun sts
      If idnt a ws1 b ws3 nl sts sts' ->
        If idnt a ws1 b ws3 nl <$>
        _Statements fun sts <*>
        (traverse._5._Statements) fun sts'
      While idnt a ws1 b ws3 nl sts ->
        While idnt a ws1 b ws3 nl <$> _Statements fun sts
      TryExcept idnt a b c d e f g h ->
        TryExcept idnt a b c d <$> _Statements fun e <*>
        (traverse._6._Statements) fun f <*>
        (traverse._5._Statements) fun g <*>
        (traverse._5._Statements) fun h
      TryFinally idnt a b c d e idnt2 f g h i ->
        TryFinally idnt a b c d <$> _Statements fun e <*> pure idnt2 <*>
        pure f <*> pure g <*> pure h <*> _Statements fun i
      For idnt a b c d e f g h i ->
        For idnt a b c d e f g <$>
        _Statements fun h <*>
        (traverse._5._Statements) fun i
      ClassDef idnt a b c d e f g ->
        ClassDef idnt a b c d e f <$> _Statements fun g

instance HasExprs Statement where
  _Exprs f (SmallStatements idnt s ss a b) =
    SmallStatements idnt <$>
    _Exprs f s <*>
    (traverse._2._Exprs) f ss <*>
    pure a <*>
    pure b
  _Exprs f (CompoundStatement c) = CompoundStatement <$> _Exprs f c

data ImportAs e v a
  = ImportAs a (e a) (Maybe (NonEmpty Whitespace, Ident v a))
  deriving (Eq, Show, Functor, Foldable, Traversable)

importAsAnn :: ImportAs e v a -> a
importAsAnn (ImportAs a _ _) = a

instance HasTrailingWhitespace (e a) => HasTrailingWhitespace (ImportAs e v a) where
  trailingWhitespace =
    lens
      (\(ImportAs _ a b) ->
         maybe (a ^. getting trailingWhitespace) (^. _2.trailingWhitespace) b)
      (\(ImportAs x a b) ws ->
         ImportAs
           x
           (maybe (a & trailingWhitespace .~ ws) (const a) b)
           (b & _Just._2.trailingWhitespace .~ ws))

data ImportTargets v a
  = ImportAll a [Whitespace]
  | ImportSome a (CommaSep1 (ImportAs (Ident v) v a))
  | ImportSomeParens
      a
      -- ( spaces
      [Whitespace]
      -- imports as
      (CommaSep1' (ImportAs (Ident v) v a))
      -- ) spaces
      [Whitespace]
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance HasTrailingWhitespace (ImportTargets v a) where
  trailingWhitespace =
    lens
      (\case
          ImportAll _ ws -> ws
          ImportSome _ cs -> cs ^. trailingWhitespace
          ImportSomeParens _ _ _ ws -> ws)
      (\ts ws ->
         case ts of
           ImportAll a _ -> ImportAll a ws
           ImportSome a cs -> ImportSome a (cs & trailingWhitespace .~ ws)
           ImportSomeParens x a b _ -> ImportSomeParens x a b ws)

data SmallStatement (v :: [*]) a
  = Return a [Whitespace] (Expr v a)
  | Expr a (Expr v a)
  | Assign a (Expr v a) [Whitespace] (Expr v a)
  | Pass a
  | Break a
  | Continue a
  | Global a (NonEmpty Whitespace) (CommaSep1 (Ident v a))
  | Nonlocal a (NonEmpty Whitespace) (CommaSep1 (Ident v a))
  | Del a (NonEmpty Whitespace) (CommaSep1 (Ident v a))
  | Import
      a
      (NonEmpty Whitespace)
      (CommaSep1 (ImportAs (ModuleName v) v a))
  | From
      a
      [Whitespace]
      (RelativeModuleName v a)
      [Whitespace]
      (ImportTargets v a)
  | Raise a
      [Whitespace]
      (Maybe (Expr v a, Maybe ([Whitespace], Expr v a)))
  deriving (Eq, Show, Functor, Foldable, Traversable, Generic)

instance Plated (SmallStatement '[] a) where; plate = gplate

instance HasExprs SmallStatement where
  _Exprs f (Raise a ws x) =
    Raise a ws <$>
    traverse
      (\(b, c) -> (,) <$> f b <*> traverseOf (traverse._2) f c)
      x
  _Exprs f (Return a ws e) = Return a ws <$> f e
  _Exprs f (Expr a e) = Expr a <$> f e
  _Exprs f (Assign a e1 ws2 e2) = Assign a <$> f e1 <*> pure ws2 <*> f e2
  _Exprs _ p@Pass{} = pure $ coerce p
  _Exprs _ p@Break{} = pure $ coerce p
  _Exprs _ p@Continue{} = pure $ coerce p
  _Exprs _ p@Global{} = pure $ coerce p
  _Exprs _ p@Nonlocal{} = pure $ coerce p
  _Exprs _ p@Del{} = pure $ coerce p
  _Exprs _ p@Import{} = pure $ coerce p
  _Exprs _ p@From{} = pure $ coerce p

data ExceptAs v a
  = ExceptAs
  { _exceptAsAnn :: a
  , _exceptAsExpr :: Expr v a
  , _exceptAsName :: Maybe ([Whitespace], Ident v a)
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CompoundStatement (v :: [*]) a
  -- ^ 'def' <spaces> <ident> '(' <spaces> stuff ')' <spaces> ':' <spaces> <newline>
  --   <block>
  = Fundef
      (Indents a) a
      (NonEmpty Whitespace) (Ident v a)
      [Whitespace] (CommaSep (Param v a))
      [Whitespace] [Whitespace] Newline
      (Block v a)
  -- ^ 'if' <spaces> <expr> ':' <spaces> <newline>
  --   <block>
  --   [ 'else' <spaces> ':' <spaces> <newline>
  --     <block>
  --   ]
  | If
      (Indents a) a
      [Whitespace] (Expr v a) [Whitespace] Newline
      (Block v a)
      (Maybe (Indents a, [Whitespace], [Whitespace], Newline, Block v a))
  -- ^ 'if' <spaces> <expr> ':' <spaces> <newline>
  --   <block>
  | While
      (Indents a) a
      [Whitespace] (Expr v a) [Whitespace] Newline
      (Block v a)
  -- ^ 'try' <spaces> ':' <spaces> <newline> <block>
  --   ( 'except' <spaces> exceptAs ':' <spaces> <newline> <block> )+
  --   [ 'else' <spaces> ':' <spaces> <newline> <block> ]
  --   [ 'finally' <spaces> ':' <spaces> <newline> <block> ]
  | TryExcept
      (Indents a) a
      [Whitespace] [Whitespace] Newline (Block v a)
      (NonEmpty (Indents a, [Whitespace], ExceptAs v a, [Whitespace], Newline, Block v a))
      (Maybe (Indents a, [Whitespace], [Whitespace], Newline, Block v a))
      (Maybe (Indents a, [Whitespace], [Whitespace], Newline, Block v a))
  -- ^ 'try' <spaces> ':' <spaces> <newline> <block>
  --   'finally' <spaces> ':' <spaces> <newline> <block>
  | TryFinally
      (Indents a) a
      [Whitespace] [Whitespace] Newline (Block v a)
      (Indents a) [Whitespace] [Whitespace] Newline (Block v a)
  -- ^ 'for' <spaces> expr 'in' <spaces> expr ':' <spaces> <newline> <block>
  --   [ 'else' <spaces> ':' <spaces> <newline> <block> ]
  | For
      (Indents a) a
      [Whitespace] (Expr v a) [Whitespace] (Expr v a) [Whitespace] Newline
      (Block v a)
      (Maybe (Indents a, [Whitespace], [Whitespace], Newline, Block v a))
  -- ^ 'class' <spaces> ident [ '(' <spaces> [ args ] ')' <spaces>] ':' <spaces> <newline>
  --   <block>
  | ClassDef
      (Indents a) a
      (NonEmpty Whitespace) (Ident v a)
      (Maybe ([Whitespace], Maybe (CommaSep1 (Arg v a)), [Whitespace])) [Whitespace] Newline
      (Block v a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance HasExprs ExceptAs where
  _Exprs f (ExceptAs ann e a) = ExceptAs ann <$> f e <*> pure (coerce a)

instance HasExprs Block where
  _Exprs = _Wrapped.traverse._Right._Exprs

instance HasExprs CompoundStatement where
  _Exprs f (Fundef idnt a ws1 name ws2 params ws3 ws4 nl sts) =
    Fundef idnt a ws1 (coerce name) ws2 <$>
    (traverse._Exprs) f params <*>
    pure ws3 <*>
    pure ws4 <*>
    pure nl <*>
    _Exprs f sts
  _Exprs f (If idnt a ws1 e ws3 nl sts sts') =
    If idnt a ws1 <$>
    f e <*>
    pure ws3 <*>
    pure nl <*>
    _Exprs f sts <*>
    (traverse._5._Exprs) f sts'
  _Exprs f (While idnt a ws1 e ws3 nl sts) =
    While idnt a ws1 <$>
    f e <*>
    pure ws3 <*>
    pure nl <*>
    _Exprs f sts
  _Exprs fun (TryExcept idnt a b c d e f g h) =
    TryExcept idnt a b c d <$> _Exprs fun e <*>
    -- (coerce f) downcasts the ExceptAs
    (traverse._6._Exprs) fun (coerce f) <*>
    (traverse._5._Exprs) fun g <*>
    (traverse._5._Exprs) fun h
  _Exprs fun (TryFinally idnt a b c d e idnt2 f g h i) =
    TryFinally idnt a b c d <$> _Exprs fun e <*> pure idnt2 <*>
    pure f <*> pure g <*> pure h <*> _Exprs fun i
  _Exprs fun (For idnt a b c d e f g h i) =
    For idnt a b <$> fun c <*> pure d <*> fun e <*>
    pure f <*> pure g <*> _Exprs fun h <*>
    (traverse._5._Exprs) fun i
  _Exprs fun (ClassDef idnt a b c d e f g) =
    ClassDef idnt a b (coerce c) <$>
    (traverse._2.traverse.traverse._Exprs) fun d <*> pure e <*> pure f <*>
    _Exprs fun g

makeWrapped ''Block
makeLenses ''ExceptAs
