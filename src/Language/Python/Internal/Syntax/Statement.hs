{-# language TemplateHaskell #-}
{-# language DataKinds, KindSignatures #-}
{-# language MultiParamTypeClasses, FlexibleInstances #-}
{-# language DeriveFunctor, DeriveFoldable, DeriveTraversable, DeriveGeneric #-}
{-# language TypeFamilies #-}
{-# language LambdaCase #-}
{-# language UndecidableInstances #-}
module Language.Python.Internal.Syntax.Statement where

import Control.Lens.Getter ((^.), getting)
import Control.Lens.Lens (lens)
import Control.Lens.Plated (Plated(..), gplate)
import Control.Lens.Prism (_Just, _Right)
import Control.Lens.Setter ((.~), over, mapped)
import Control.Lens.TH (makeLenses, makeWrapped)
import Control.Lens.Traversal (Traversal, traverseOf)
import Control.Lens.Tuple (_2, _3, _4)
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

newtype Block v a
  = Block
  { unBlock
    :: NonEmpty
         (Either
            ([Whitespace], Newline)
            (Statement v a))
  } deriving (Eq, Show, Functor, Foldable, Traversable)

class HasBlocks s where
  _Blocks :: Traversal (s v a) (s '[] a) (Block v a) (Block '[] a)

instance HasBlocks Suite where
  _Blocks f (SuiteOne a b c d) = pure $ SuiteOne a b (coerce c) d
  _Blocks f (SuiteMany a b c e) = SuiteMany a b c <$> f e

instance HasBlocks CompoundStatement where
  _Blocks f (Fundef a decos idnt ws1 name ws2 params ws3 t s) =
    Fundef a (coerce decos) idnt ws1 (coerce name) ws2 (coerce params) ws3 (coerce t) <$> _Blocks f s
  _Blocks f (If idnt a ws1 e1 s elifs b') =
    If idnt a ws1 (coerce e1) <$>
    _Blocks f s <*>
    traverse (\(a, b, c, d) -> (,,,) a b (coerce c) <$> _Blocks f d) elifs <*>
    traverseOf (traverse._3._Blocks) f b'
  _Blocks f (While idnt a ws1 e1 s) =
    While idnt a ws1 (coerce e1) <$> _Blocks f s
  _Blocks fun (TryExcept idnt a b c d e f) =
    TryExcept idnt a (coerce b) <$>
    _Blocks fun c <*>
    traverse (\(a, b, c, d) -> (,,,) a b (coerce c) <$> _Blocks fun d) d <*>
    traverseOf (traverse._3._Blocks) fun e <*>
    traverseOf (traverse._3._Blocks) fun f
  _Blocks fun (TryFinally idnt a b c d e f) =
    TryFinally idnt a b <$>
    _Blocks fun c <*>
    pure d <*>
    pure e <*>
    _Blocks fun f
  _Blocks fun (For idnt a b c d e f g) =
    For idnt a b (coerce c) d (coerce e) <$>
    _Blocks fun f <*>
    (traverse._3._Blocks) fun g
  _Blocks fun (ClassDef a decos idnt b c d e) =
    ClassDef a (coerce decos) idnt b (coerce c) (coerce d) <$> _Blocks fun e
  _Blocks fun (With a b c d e) = With a b c (coerce d) <$> _Blocks fun e

instance HasStatements Block where
  _Statements = _Wrapped.traverse._Right

instance HasStatements Suite where
  _Statements f (SuiteOne a b c d) = pure $ SuiteOne a b (coerce c) d
  _Statements f (SuiteMany a b c e) = SuiteMany a b c <$> _Statements f e

data Statement (v :: [*]) a
  = SmallStatements
      (Indents a)
      (SmallStatement v a)
      [([Whitespace], SmallStatement v a)]
      (Maybe [Whitespace])
      (Either (Maybe Comment) Newline)
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
      Fundef idnt a decos ws1 b ws2 c ws3 t s ->
        Fundef idnt a decos ws1 b ws2 c ws3 t <$> _Statements fun s
      If idnt a ws1 b s elifs sts' ->
        If idnt a ws1 b <$>
        _Statements fun s <*>
        (traverse._4._Statements) fun elifs <*>
        (traverse._3._Statements) fun sts'
      While idnt a ws1 b s ->
        While idnt a ws1 b <$> _Statements fun s
      TryExcept idnt a b c d e f ->
        TryExcept idnt a b <$> _Statements fun c <*>
        (traverse._4._Statements) fun d <*>
        (traverse._3._Statements) fun e <*>
        (traverse._3._Statements) fun f
      TryFinally idnt a b c d e f ->
        TryFinally idnt a b <$> _Statements fun c <*> pure d <*>
        pure e <*> _Statements fun f
      For idnt a b c d e f g ->
        For idnt a b c d e <$>
        _Statements fun f <*>
        (traverse._3._Statements) fun g
      ClassDef idnt a decos b c d e ->
        ClassDef idnt a decos b c d <$> _Statements fun e
      With a b c d e -> With a b c (coerce d) <$> _Statements fun e

instance HasExprs Statement where
  _Exprs f (SmallStatements idnt s ss a c) =
    SmallStatements idnt <$>
    _Exprs f s <*>
    (traverse._2._Exprs) f ss <*>
    pure a <*>
    pure c
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

data AugAssign a
  = PlusEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | MinusEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | StarEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | AtEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | SlashEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | PercentEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | AmpersandEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | PipeEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | CaretEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | ShiftLeftEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | ShiftRightEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | DoubleStarEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  | DoubleSlashEq
  { _augAssignAnn :: a
  , _augAssignWhitespace :: [Whitespace]
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance HasTrailingWhitespace (AugAssign a) where
  trailingWhitespace =
    lens _augAssignWhitespace (\a b -> a { _augAssignWhitespace = b })

data SmallStatement (v :: [*]) a
  = Return a [Whitespace] (Maybe (Expr v a))
  | Expr a (Expr v a)
  | Assign a (Expr v a) (NonEmpty ([Whitespace], Expr v a))
  | AugAssign a (Expr v a) (AugAssign a) (Expr v a)
  | Pass a
  | Break a
  | Continue a
  | Global a (NonEmpty Whitespace) (CommaSep1 (Ident v a))
  | Nonlocal a (NonEmpty Whitespace) (CommaSep1 (Ident v a))
  | Del a (NonEmpty Whitespace) (CommaSep1' (Expr v a))
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
  | Assert a
      [Whitespace]
      (Expr v a)
      (Maybe ([Whitespace], Expr v a))
  deriving (Eq, Show, Functor, Foldable, Traversable, Generic)

instance Plated (SmallStatement '[] a) where; plate = gplate

instance HasExprs SmallStatement where
  _Exprs f (Assert a b c d) = Assert a b <$> f c <*> traverseOf (traverse._2) f d
  _Exprs f (Raise a ws x) =
    Raise a ws <$>
    traverse
      (\(b, c) -> (,) <$> f b <*> traverseOf (traverse._2) f c)
      x
  _Exprs f (Return a ws e) = Return a ws <$> traverse f e
  _Exprs f (Expr a e) = Expr a <$> f e
  _Exprs f (Assign a e1 es) = Assign a <$> f e1 <*> traverseOf (traverse._2) f es
  _Exprs f (AugAssign a e1 as e2) = AugAssign a <$> f e1 <*> pure as <*> f e2
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

data Suite v a
  -- ':' <space> smallstatement
  = SuiteOne a [Whitespace] (SmallStatement v a) Newline
  | SuiteMany a
      -- ':' <spaces> [comment] <newline>
      [Whitespace] Newline
      -- <block>
      (Block v a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

data WithItem v a
  = WithItem
  { _withItemAnn :: a
  , _withItemValue :: Expr v a
  , _withItemBinder :: Maybe ([Whitespace], Expr v a)
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Decorator v a
  = Decorator
  { _decoratorAnn :: a
  , _decoratorIndents :: Indents a
  , _decoratorWhitespaceLeft :: [Whitespace]
  , _decoratorExpr :: Expr v a
  , _decoratorNewline :: Newline
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CompoundStatement (v :: [*]) a
  -- ^ ( '@' <identifier>)?
  --   'def' <spaces> <ident> '(' <spaces> stuff ')' <spaces> ( '->' <type>)? :' <spaces> <newline>
  --   <block>
  = Fundef a
      [Decorator v a]
      (Indents a)
      (NonEmpty Whitespace) (Ident v a)
      [Whitespace] (CommaSep (Param v a))
      [Whitespace] (Maybe ([Whitespace], Type v a))
      (Suite v a)
  -- ^ 'if' <spaces> <expr> ':' <spaces> <newline>
  --   <block>
  --   [ 'else' <spaces> ':' <spaces> <newline>
  --     <block>
  --   ]
  | If
      (Indents a) a
      [Whitespace] (Expr v a) (Suite v a)
      [(Indents a, [Whitespace], Expr v a, Suite v a)]
      (Maybe (Indents a, [Whitespace], Suite v a))
  -- ^ 'if' <spaces> <expr> ':' <spaces> <newline>
  --   <block>
  --   ('elif' <spaces> <expr> ':' <spaces> <newline> <block>)*
  --   ['else' <spaces> ':' <spaces> <newline> <block>]
  | While
      (Indents a) a
      [Whitespace] (Expr v a) (Suite v a)
  -- ^ 'try' <spaces> ':' <spaces> <newline> <block>
  --   ( 'except' <spaces> exceptAs ':' <spaces> <newline> <block> )+
  --   [ 'else' <spaces> ':' <spaces> <newline> <block> ]
  --   [ 'finally' <spaces> ':' <spaces> <newline> <block> ]
  | TryExcept
      (Indents a) a
      [Whitespace] (Suite v a)
      (NonEmpty (Indents a, [Whitespace], ExceptAs v a, Suite v a))
      (Maybe (Indents a, [Whitespace], Suite v a))
      (Maybe (Indents a, [Whitespace], Suite v a))
  -- ^ 'try' <spaces> ':' <spaces> <newline> <block>
  --   'finally' <spaces> ':' <spaces> <newline> <block>
  | TryFinally
      (Indents a) a
      [Whitespace] (Suite v a)
      (Indents a) [Whitespace] (Suite v a)
  -- ^ 'for' <spaces> expr 'in' <spaces> expr ':' <spaces> <newline> <block>
  --   [ 'else' <spaces> ':' <spaces> <newline> <block> ]
  | For
      (Indents a) a
      [Whitespace] (Expr v a) [Whitespace] (Expr v a) (Suite v a)
      (Maybe (Indents a, [Whitespace], Suite v a))
  -- ^ 'class' <spaces> ident [ '(' <spaces> [ args ] ')' <spaces>] ':' <spaces> <newline>
  --   <block>
  | ClassDef a
      [Decorator v a]
      (Indents a)
      (NonEmpty Whitespace) (Ident v a)
      (Maybe ([Whitespace], Maybe (CommaSep1' (Arg v a)), [Whitespace]))
      (Suite v a)
  -- ^ 'with' <spaces> with_item (',' <spaces> with_item)* ':' <spaces> <newline> <block>
  | With
      (Indents a) a
      [Whitespace] (CommaSep1 (WithItem v a)) (Suite v a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

instance HasExprs ExceptAs where
  _Exprs f (ExceptAs ann e a) = ExceptAs ann <$> f e <*> pure (coerce a)

instance HasExprs Block where
  _Exprs = _Wrapped.traverse._Right._Exprs

instance HasExprs Suite where
  _Exprs f (SuiteOne a b c d) = SuiteOne a b <$> _Exprs f c <*> pure d
  _Exprs f (SuiteMany a b c e) = SuiteMany a b c <$> _Exprs f e

instance HasExprs WithItem where
  _Exprs f (WithItem a b c) = WithItem a <$> f b <*> traverseOf (traverse._2) f c

instance HasExprs Decorator where
  _Exprs fun (Decorator a b c d e) =
    Decorator a b c <$>
    _Exprs fun d <*> pure e

instance HasExprs CompoundStatement where
  _Exprs f (Fundef a decos idnt ws1 name ws2 params ws3 t s) =
    Fundef a <$>
    traverse (_Exprs f) decos <*>
    pure idnt <*>
    pure ws1 <*>
    pure (coerce name) <*>
    pure ws2 <*>
    (traverse._Exprs) f params <*>
    pure ws3 <*> pure (coerce t) <*>
    _Exprs f s
  _Exprs fun (If idnt a ws1 e s elifs sts') =
    If idnt a ws1 <$>
    fun e <*>
    _Exprs fun s <*>
    traverse
      (\(a, b, c, d) -> (,,,) a b <$> fun c <*> _Exprs fun d)
      elifs <*>
    (traverse._3._Exprs) fun sts'
  _Exprs f (While idnt a ws1 e s) =
    While idnt a ws1 <$> f e <*> _Exprs f s
  _Exprs fun (TryExcept idnt a b c d e f) =
    TryExcept idnt a b <$> _Exprs fun c <*>
    traverse (\(a, b, c, d) -> (,,,) a b <$> _Exprs fun c <*> _Exprs fun d) d <*>
    (traverse._3._Exprs) fun e <*>
    (traverse._3._Exprs) fun f
  _Exprs fun (TryFinally idnt a b c d e f) =
    TryFinally idnt a b <$> _Exprs fun c <*> pure d <*>
    pure e <*> _Exprs fun f
  _Exprs fun (For idnt a b c d e f g) =
    For idnt a b <$> fun c <*> pure d <*> fun e <*>
    _Exprs fun f <*>
    (traverse._3._Exprs) fun g
  _Exprs fun (ClassDef a decos idnt b c d e) =
    ClassDef a <$>
    traverse (_Exprs fun) decos <*>
    pure idnt <*>
    pure b <*>
    pure (coerce c) <*>
    (traverse._2.traverse.traverse._Exprs) fun d <*>
    _Exprs fun e
  _Exprs fun (With a b c d e) = With a b c <$> traverseOf (traverse._Exprs) fun d <*> _Exprs fun e

makeWrapped ''Block
makeLenses ''ExceptAs
