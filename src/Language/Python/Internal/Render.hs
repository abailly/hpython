{-# language GeneralizedNewtypeDeriving, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# language FlexibleInstances, MultiParamTypeClasses #-}
{-# language LambdaCase #-}
module Language.Python.Internal.Render
  ( RenderOutput, showRenderOutput, singleton, cons
  , showQuoteType, showStringPrefix, showToken
  , showModule, showStatement, showExpr
  , renderModule, renderStatement, renderExpr
  , bracket, renderWhitespace, renderCommaSep, renderCommaSep1, renderCommaSep1'
  , renderIdent, renderComment, renderModuleName, renderDot, renderRelativeModuleName
  , renderImportAs, renderImportTargets, renderSmallStatement, renderCompoundStatement
  , renderBlock, renderIndent, renderIndents, renderExceptAs, renderArg, renderParam
  , renderBinOp
  )
where

import Control.Lens.Getter (view)
import Control.Lens.Setter (over)
import Control.Lens.Traversal (Traversal')
import Control.Lens.Wrapped (_Wrapped)
import Control.Lens.Plated (rewrite)
import Data.Char (ord)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, maybe)
import Data.Semigroup (Semigroup(..))

import Language.Python.Internal.Syntax
import Language.Python.Internal.Token (PyToken(..), QuoteType(..))

newtype RenderOutput
  = RenderOutput
  { unRenderOutput :: [PyToken ()]
  } deriving (Eq, Show, Semigroup, Monoid)

singleton :: PyToken () -> RenderOutput
singleton a = RenderOutput [a]

cons :: PyToken () -> RenderOutput -> RenderOutput
cons a (RenderOutput b) = RenderOutput $ a : b
infixr 5 `cons`

showRenderOutput :: RenderOutput -> String
showRenderOutput =
  foldMap showToken .
  correctNewlines .
  unRenderOutput
  where
    correctNewlines =
      rewrite $
      \case
        TkNewline CR () : TkNewline LF () : rest ->
          Just $ TkNewline CRLF () : TkNewline LF () : rest
        TkContinued CR () : TkNewline LF () : rest ->
          Just $ TkContinued CRLF () : TkNewline LF () : rest
        _ -> Nothing

showStringPrefix :: StringPrefix -> String
showStringPrefix sp =
  case sp of
    Prefix_r -> "r"
    Prefix_R -> "R"
    Prefix_u -> "u"
    Prefix_U -> "U"
    Prefix_b -> "b"
    Prefix_B -> "B"
    Prefix_br -> "br"
    Prefix_Br -> "Br"
    Prefix_bR -> "bR"
    Prefix_BR -> "BR"
    Prefix_rb -> "rb"
    Prefix_rB -> "rB"
    Prefix_Rb -> "Rb"
    Prefix_RB -> "RB"

showQuoteType :: QuoteType -> String
showQuoteType qt =
  case qt of
    DoubleQuote -> "\""
    SingleQuote -> "\'"

showToken :: PyToken a -> String
showToken t =
  case t of
    TkIf{} -> "if"
    TkElse{} -> "else"
    TkWhile{} -> "while"
    TkDef{} -> "def"
    TkReturn{} -> "return"
    TkPass{} -> "pass"
    TkBreak{} -> "break"
    TkContinue{} -> "continue"
    TkTrue{} -> "True"
    TkFalse{} -> "False"
    TkNone{} -> "None"
    TkOr{} -> "or"
    TkAnd{} -> "and"
    TkIs{} -> "is"
    TkNot{} -> "not"
    TkGlobal{} -> "global"
    TkNonlocal{} -> "nonlocal"
    TkDel{} -> "del"
    TkImport{} -> "import"
    TkFrom{} -> "from"
    TkAs{} -> "as"
    TkRaise{} -> "raise"
    TkTry{} -> "try"
    TkExcept{} -> "except"
    TkFinally{} -> "finally"
    TkClass{} -> "class"
    TkFor{} -> "for"
    TkIn{} -> "in"
    TkInt i _ -> show i
    TkFloat i i' _ -> show i <> foldMap (("." <>) . show) i'
    TkIdent s _ -> s
    TkShortString sp qt s _ ->
      let
        quote = showQuoteType qt
      in
        foldMap showStringPrefix sp <>
        quote <>
        foldMap renderChar s <>
        quote
    TkLongString sp qt s _ ->
      let
        quote = showQuoteType qt >>= replicate 3
      in
        foldMap showStringPrefix sp <>
        quote <>
        foldMap renderChar s <>
        quote
    TkSpace{} -> " "
    TkTab{} -> "\t"
    TkNewline nl _ ->
      case nl of
        CR -> "\r"
        LF -> "\n"
        CRLF -> "\r\n"
    TkLeftBracket{} -> "["
    TkRightBracket{} -> "]"
    TkLeftParen{} -> "("
    TkRightParen{} -> ")"
    TkLeftBrace{} -> "{"
    TkRightBrace{} -> "}"
    TkLt{} -> "<"
    TkLte{} -> "<="
    TkEq{} -> "="
    TkDoubleEq{}-> "=="
    TkGt{} -> ">"
    TkGte{} -> ">="
    TkContinued nl _ ->
      "\\" <>
      case nl of
        CR -> "\r"
        LF -> "\n"
        CRLF -> "\r\n"
    TkColon{} -> ":"
    TkSemicolon{} -> ";"
    TkComma{} -> ","
    TkDot{} -> "."
    TkPlus{} -> "+"
    TkMinus{} -> "-"
    TkComment s _ -> "#" <> s
    TkStar{} -> "*"
    TkDoubleStar{} -> "**"
    TkSlash{} -> "/"
    TkDoubleSlash{} -> "//"
    TkPercent{} -> "%"
    TkShiftLeft{} -> "<<"
    TkShiftRight{} -> ">>"

bracket :: RenderOutput -> RenderOutput
bracket a = TkLeftParen () `cons` a <> singleton (TkRightParen ())

bracketTuple :: Expr v a -> RenderOutput
bracketTuple e =
  case e of
    Tuple{} -> bracket $ renderExpr e
    _ -> renderExpr e

escapeChars :: [(Char, Char)]
escapeChars =
  [ ('\\', '\\')
  , ('"', '"')
  , ('\a', 'a')
  , ('\b', 'b')
  , ('\f', 'f')
  , ('\n', 'n')
  , ('\r', 'r')
  , ('\t', 't')
  , ('\v', 'v')
  ]

intToHex :: Int -> String
intToHex n = go n []
  where
    go 0 = (++"0")
    go 1 = (++"1")
    go 2 = (++"2")
    go 3 = (++"3")
    go 4 = (++"4")
    go 5 = (++"5")
    go 6 = (++"6")
    go 7 = (++"7")
    go 8 = (++"8")
    go 9 = (++"9")
    go 10 = (++"A")
    go 11 = (++"B")
    go 12 = (++"C")
    go 13 = (++"D")
    go 14 = (++"E")
    go 15 = (++"F")
    go b = let (q, r) = quotRem b 16 in go r . go q

renderChar :: Char -> String
renderChar c
  | Just c' <- lookup c escapeChars = ['\\', c']
  | otherwise =
      let
        shown = show c
      in
        case shown of
          '\'' : '\\' : _ ->
            let
              hex = intToHex (ord c)
            in
              "\\U" ++ replicate (8 - length hex) '0' ++ hex
          _ -> [c]

data Lines a
  = NoLines
  | OneLine a
  | ManyLines a Newline (Lines a)
  deriving (Eq, Show, Functor, Foldable, Traversable)
listToLines :: Newline -> [a] -> Lines a
listToLines _ [] = NoLines
listToLines _ [a] = OneLine a
listToLines nl (a:as) = ManyLines a nl $ listToLines nl as

firstLine :: Traversal' (Lines a) a
firstLine f NoLines = pure NoLines
firstLine f (OneLine a) = OneLine <$> f a
firstLine f (ManyLines a nl ls) = (\a' -> ManyLines a' nl ls) <$> f a

endWith :: Newline -> Lines a -> Lines a
endWith nl NoLines = NoLines
endWith nl (OneLine a) = ManyLines a nl NoLines
endWith nl (ManyLines a nl' as) =
  ManyLines
    a
    (case as of; NoLines -> nl; _ -> nl')
    (case as of; NoLines -> NoLines; _ -> endWith nl as)

renderLines :: (a -> RenderOutput) -> Lines a -> RenderOutput
renderLines _ NoLines = mempty
renderLines f (OneLine a) = f a
renderLines f (ManyLines a nl ls) = f a <> singleton (renderNewline nl) <> renderLines f ls

instance Semigroup a => Semigroup (Lines a) where
  NoLines <> a = a
  OneLine a <> NoLines = OneLine a
  OneLine a <> OneLine b = OneLine (a <> b)
  OneLine a <> ManyLines b nl ls = ManyLines (a <> b) nl ls
  ManyLines a nl ls <> b = ManyLines a nl (ls <> b)

instance Semigroup a => Monoid (Lines a) where
  mempty = NoLines
  mappend = (<>)

renderWhitespace :: Whitespace -> RenderOutput
renderWhitespace Space = singleton $ TkSpace ()
renderWhitespace Tab = singleton $ TkTab ()
renderWhitespace (Continued nl ws) = TkContinued nl () `cons` foldMap renderWhitespace ws
renderWhitespace (Newline nl) = singleton $ TkNewline nl ()

renderNewline :: Newline -> PyToken ()
renderNewline nl = TkNewline nl ()

renderCommaSep :: (a -> RenderOutput) -> CommaSep a -> RenderOutput
renderCommaSep _ CommaSepNone = mempty
renderCommaSep f (CommaSepOne a) = f a
renderCommaSep f (CommaSepMany a ws2 c) =
  f a <>
  singleton (TkComma ()) <>
  foldMap renderWhitespace ws2 <>
  renderCommaSep f c

renderCommaSep1 :: (a -> RenderOutput) -> CommaSep1 a -> RenderOutput
renderCommaSep1 f (CommaSepOne1 a) = f a
renderCommaSep1 f (CommaSepMany1 a ws2 c) =
  f a <>
  singleton (TkComma ()) <>
  foldMap renderWhitespace ws2 <>
  renderCommaSep1 f c

renderCommaSep1' :: (a -> RenderOutput) -> CommaSep1' a -> RenderOutput
renderCommaSep1' f (CommaSepOne1' a b) =
  f a <>
  foldMap (\x -> TkComma () `cons` foldMap renderWhitespace x) b
renderCommaSep1' f (CommaSepMany1' a ws2 c) =
  f a <>
  singleton (TkComma ()) <>
  foldMap renderWhitespace ws2 <>
  renderCommaSep1' f c

renderIdent :: Ident v a -> RenderOutput
renderIdent (MkIdent _ a b) = TkIdent a () `cons` foldMap renderWhitespace b

renderComment :: Comment -> PyToken ()
renderComment (Comment s) = TkComment s ()

renderExpr :: Expr v a -> RenderOutput
renderExpr (Not _ ws e) =
  TkNot () `cons`
  foldMap renderWhitespace ws <>
  case e of
    BinOp _ _ BoolAnd{} _ -> bracket $ renderExpr e
    BinOp _ _ BoolOr{} _ -> bracket $ renderExpr e
    _ -> bracketTuple e
renderExpr (Parens _ ws1 e ws2) =
  bracket (foldMap renderWhitespace ws1 <> renderExpr e) <>
  foldMap renderWhitespace ws2
renderExpr (Bool _ b ws) =
  (if b then TkTrue () else TkFalse ()) `cons`
  foldMap renderWhitespace ws
renderExpr (Negate _ ws expr) =
  TkMinus () `cons`
  foldMap renderWhitespace ws <>
  case expr of
    BinOp _ _ Exp{} _ -> renderExpr expr
    BinOp{} -> bracket $ renderExpr expr
    _ -> renderExpr expr
renderExpr (String _ prefix strType b ws) =
  (case strType of
      ShortSingle -> TkShortString prefix SingleQuote b ()
      ShortDouble -> TkShortString prefix DoubleQuote b ()
      LongSingle -> TkLongString prefix SingleQuote b ()
      LongDouble -> TkLongString prefix DoubleQuote b ()) `cons`
  foldMap renderWhitespace ws
renderExpr (Int _ n ws) = TkInt n () `cons` foldMap renderWhitespace ws
renderExpr (Ident _ name) = renderIdent name
renderExpr (List _ ws1 exprs ws2) =
  TkLeftBracket () `cons`
  foldMap renderWhitespace ws1 <>
  foldMap
    (renderCommaSep1' bracketTuple)
    exprs <>
  singleton (TkRightBracket ()) <> foldMap renderWhitespace ws2
renderExpr (Call _ expr ws args ws2) =
  (case expr of
     Int _ n _ | n < 0 -> bracket $ renderExpr expr
     BinOp{} -> bracket $ renderExpr expr
     Tuple{} -> bracket $ renderExpr expr
     Not{} -> bracket $ renderExpr expr
     _ -> renderExpr expr) <>
  bracket (foldMap renderWhitespace ws <> renderCommaSep renderArg args) <>
  foldMap renderWhitespace ws2
renderExpr (Deref _ expr ws name) =
  (case expr of
    Int{} -> bracket $ renderExpr expr
    BinOp{} -> bracket $ renderExpr expr
    Tuple{} -> bracket $ renderExpr expr
    Not{} -> bracket $ renderExpr expr
    _ -> renderExpr expr) <>
  singleton (TkDot ()) <>
  foldMap renderWhitespace ws <>
  renderIdent name
renderExpr (None _ ws) = TkNone () `cons` foldMap renderWhitespace ws
renderExpr (BinOp _ e1 op e2) =
  (if shouldBracketLeft op e1 then bracket else id) (renderExpr e1) <>
  renderBinOp op <>
  (if shouldBracketRight op e2 then bracket else id) (renderExpr e2)
renderExpr (Tuple _ a ws c) =
  bracketTuple a <> singleton (TkComma ()) <> foldMap renderWhitespace ws <>
  foldMap
    (renderCommaSep1' bracketTuple)
    c

renderModuleName :: ModuleName v a -> RenderOutput
renderModuleName (ModuleNameOne _ s) = renderIdent s
renderModuleName (ModuleNameMany _ n ws2 rest) =
  renderIdent n <> singleton (TkDot ()) <> foldMap renderWhitespace ws2 <>
  renderModuleName rest

renderDot :: Dot -> RenderOutput
renderDot (Dot ws) = TkDot () `cons` foldMap renderWhitespace ws

renderRelativeModuleName :: RelativeModuleName v a -> RenderOutput
renderRelativeModuleName (RelativeWithName ds mn) =
  foldMap renderDot ds <> renderModuleName mn
renderRelativeModuleName (Relative ds) =
  foldMap renderDot ds

renderImportAs :: (e a -> RenderOutput) -> ImportAs e v a -> RenderOutput
renderImportAs f (ImportAs _ ea m) =
  f ea <>
  foldMap (\(a, b) -> TkAs () `cons` foldMap renderWhitespace a <> renderIdent b) m

renderImportTargets :: ImportTargets v a -> RenderOutput
renderImportTargets (ImportAll _ ws) = TkStar () `cons` foldMap renderWhitespace ws
renderImportTargets (ImportSome _ ts) =
  renderCommaSep1 (renderImportAs renderIdent) ts
renderImportTargets (ImportSomeParens _ ws1 ts ws2) =
  bracket
    (foldMap renderWhitespace ws1 <> renderCommaSep1' (renderImportAs renderIdent) ts) <>
  foldMap renderWhitespace ws2

renderSmallStatement :: SmallStatement v a -> RenderOutput
renderSmallStatement (Raise _ ws x) =
  TkRaise () `cons` foldMap renderWhitespace ws <>
  foldMap
    (\(b, c) ->
       bracketTuple b <>
       foldMap
         (\(d, e) ->
            TkFrom () `cons` foldMap renderWhitespace d <>
            bracketTuple e)
         c)
    x
renderSmallStatement (Return _ ws expr) =
  TkReturn () `cons` foldMap renderWhitespace ws <> renderExpr expr
renderSmallStatement (Expr _ expr) = renderExpr expr
renderSmallStatement (Assign _ lvalue ws2 rvalue) =
  renderExpr lvalue <> singleton (TkEq ()) <>
  foldMap renderWhitespace ws2 <> renderExpr rvalue
renderSmallStatement (Pass _) = singleton $ TkPass ()
renderSmallStatement (Continue _) = singleton $ TkContinue ()
renderSmallStatement (Break _) = singleton $ TkBreak ()
renderSmallStatement (Global _ ws ids) =
  TkGlobal () `cons` foldMap renderWhitespace ws <> renderCommaSep1 renderIdent ids
renderSmallStatement (Nonlocal _ ws ids) =
  TkNonlocal () `cons` foldMap renderWhitespace ws <> renderCommaSep1 renderIdent ids
renderSmallStatement (Del _ ws ids) =
  TkDel () `cons` foldMap renderWhitespace ws <> renderCommaSep1 renderIdent ids
renderSmallStatement (Import _ ws ns) =
  TkImport () `cons` foldMap renderWhitespace ws <>
  renderCommaSep1 (renderImportAs renderModuleName) ns
renderSmallStatement (From _ ws1 name ws3 ns) =
  TkFrom () `cons` foldMap renderWhitespace ws1 <>
  renderRelativeModuleName name <>
  singleton (TkImport ()) <> foldMap renderWhitespace ws3 <>
  renderImportTargets ns

renderBlock :: Block v a -> Lines RenderOutput
renderBlock =
  foldMap
    (either
       (\(x, y, z) ->
          OneLine $
          foldMap renderWhitespace x <>
          maybe mempty (singleton . renderComment) y
          <> singleton (renderNewline z))
        renderStatement) .
  view _Wrapped

renderCompoundStatement :: CompoundStatement v a -> Lines RenderOutput
renderCompoundStatement (Fundef idnt _ ws1 name ws2 params ws3 ws4 nl body) =
  ManyLines firstLine nl restLines
  where
    firstLine =
      renderIndents idnt <>
      singleton (TkDef ()) <> foldMap renderWhitespace ws1 <> renderIdent name <>
      bracket (foldMap renderWhitespace ws2 <> renderCommaSep renderParam params) <>
      foldMap renderWhitespace ws3 <> singleton (TkColon ()) <> foldMap renderWhitespace ws4
    restLines = renderBlock body
renderCompoundStatement (If idnt _ ws1 expr ws3 nl body body') =
  ManyLines firstLine nl restLines
  where
    firstLine =
      renderIndents idnt <>
      singleton (TkIf ()) <> foldMap renderWhitespace ws1 <>
      bracketTuple expr <>
      singleton (TkColon ()) <> foldMap renderWhitespace ws3
    restLines = renderBlock body <> fromMaybe mempty elseLines
    elseLines =
      ManyLines <$>
      fmap
        (\(idnt, ws4, ws5, _, _) ->
           renderIndents idnt <>
           singleton (TkElse ()) <> foldMap renderWhitespace ws4 <>
           singleton (TkColon ()) <> foldMap renderWhitespace ws5)
        body' <*>
      fmap (\(_, _, _, nl2, _) -> nl2) body' <*>
      fmap (\(_, _, _, _, body'') -> renderBlock body'') body'
renderCompoundStatement (While idnt _ ws1 expr ws3 nl body) =
  ManyLines
    (renderIndents idnt <>
     singleton (TkWhile ()) <> foldMap renderWhitespace ws1 <> bracketTuple expr <>
     singleton (TkColon ()) <> foldMap renderWhitespace ws3)
    nl
    (renderBlock body)
renderCompoundStatement (TryExcept idnt _ a b c d e f g) =
  ManyLines
    (renderIndents idnt <>
     singleton (TkTry ()) <> foldMap renderWhitespace a <>
     singleton (TkColon ()) <> foldMap renderWhitespace b)
    c
    (renderBlock d) <>
  foldMap
    (\(idnt, ws1, eas, ws2, nl, bl) ->
       ManyLines
         (renderIndents idnt <>
          singleton (TkExcept ()) <> foldMap renderWhitespace ws1 <>
          renderExceptAs eas <>
          singleton (TkColon ()) <> foldMap renderWhitespace ws2)
         nl
         (renderBlock bl))
    e <>
  foldMap
    (\(idnt, ws1, ws2, nl, bl) ->
       ManyLines
         (renderIndents idnt <>
          singleton (TkElse ()) <> foldMap renderWhitespace ws1 <>
          singleton (TkColon ()) <> foldMap renderWhitespace ws2)
         nl
         (renderBlock bl))
    f <>
  foldMap
    (\(idnt, ws1, ws2, nl, bl) ->
       ManyLines
         (renderIndents idnt <>
          singleton (TkFinally ()) <> foldMap renderWhitespace ws1 <>
          singleton (TkColon ()) <> foldMap renderWhitespace ws2)
         nl
         (renderBlock bl))
    g
renderCompoundStatement (TryFinally idnt _ a b c d idnt2 e f g h) =
  ManyLines
    (renderIndents idnt <>
     singleton (TkTry ()) <> foldMap renderWhitespace a <>
     singleton (TkColon ()) <> foldMap renderWhitespace b)
    c
    (renderBlock d) <>
  ManyLines
    (renderIndents idnt2 <>
     singleton (TkFinally ()) <> foldMap renderWhitespace e <>
     singleton (TkColon ()) <> foldMap renderWhitespace f)
    g
    (renderBlock h)
renderCompoundStatement (For idnt _ a b c d e f g h) =
  ManyLines
    (renderIndents idnt <>
     singleton (TkFor ()) <> foldMap renderWhitespace a <> renderExpr b <>
     singleton (TkIn ()) <> foldMap renderWhitespace c <> renderExpr d <>
     singleton (TkColon ()) <> foldMap renderWhitespace e)
    f
    (renderBlock g) <>
  foldMap
    (\(idnt, x, y, z, w) ->
       ManyLines
         (renderIndents idnt <>
          singleton (TkElse ()) <> foldMap renderWhitespace x <>
          singleton (TkColon ()) <> foldMap renderWhitespace y)
         z
         (renderBlock w))
    h
renderCompoundStatement (ClassDef idnt _ a b c d e f) =
  ManyLines
    (renderIndents idnt <>
     singleton (TkClass ()) <> foldMap renderWhitespace a <>
     renderIdent b <>
     foldMap
       (\(x, y, z) ->
          bracket (foldMap renderWhitespace x <> foldMap (renderCommaSep1 renderArg) y) <>
          foldMap renderWhitespace z)
       c <>
     singleton (TkColon ()) <> foldMap renderWhitespace d)
    e
    (renderBlock f)

renderIndent :: Indent -> RenderOutput
renderIndent (MkIndent ws) = foldMap renderWhitespace $ toList ws

renderStatement :: Statement v a -> Lines RenderOutput
renderStatement (CompoundStatement c) = renderCompoundStatement c
renderStatement (SmallStatements idnts s ss sc nl) =
  over firstLine (renderIndents idnts <>) .
  f $
  renderSmallStatement s <>
  foldMap
    (\(b, c) ->
       TkSemicolon () `cons`
       foldMap renderWhitespace b <>
       renderSmallStatement c)
    ss <>
  foldMap
    (\b -> TkSemicolon () `cons` foldMap renderWhitespace b)
    sc
  where
    f a =
      case nl of
        Nothing -> OneLine a
        Just nl' -> ManyLines a nl' NoLines

renderExceptAs :: ExceptAs v a -> RenderOutput
renderExceptAs (ExceptAs _ e f) =
  bracketTuple e <>
  foldMap (\(a, b) -> TkAs () `cons` foldMap renderWhitespace a <> renderIdent b) f

renderArg :: Arg v a -> RenderOutput
renderArg (PositionalArg _ expr) = bracketTuple expr
renderArg (KeywordArg _ name ws2 expr) =
  renderIdent name <> singleton (TkEq ()) <>
  foldMap renderWhitespace ws2 <>
  bracketTuple expr
renderArg (StarArg _ ws expr) =
  TkStar () `cons`
  foldMap renderWhitespace ws <>
  bracketTuple expr
renderArg (DoubleStarArg _ ws expr) =
  TkDoubleStar () `cons`
  foldMap renderWhitespace ws <>
  bracketTuple expr

renderParam :: Param v a -> RenderOutput
renderParam (PositionalParam _ name) =
  renderIdent name
renderParam (StarParam _ ws name) =
  TkStar () `cons` foldMap renderWhitespace ws <> renderIdent name
renderParam (DoubleStarParam _ ws name) =
  TkDoubleStar () `cons` foldMap renderWhitespace ws <> renderIdent name
renderParam (KeywordParam _ name ws2 expr) =
  renderIdent name <> singleton (TkEq ()) <>
  foldMap renderWhitespace ws2 <> renderExpr expr

renderBinOp :: BinOp a -> RenderOutput
renderBinOp (Is _ ws) = TkIs () `cons` foldMap renderWhitespace ws
renderBinOp (Plus _ ws) = TkPlus () `cons` foldMap renderWhitespace ws
renderBinOp (Minus _ ws) = TkMinus () `cons` foldMap renderWhitespace ws
renderBinOp (Multiply _ ws) = TkStar () `cons` foldMap renderWhitespace ws
renderBinOp (Divide _ ws) = TkSlash () `cons` foldMap renderWhitespace ws
renderBinOp (Exp _ ws) = TkDoubleStar () `cons` foldMap renderWhitespace ws
renderBinOp (BoolAnd _ ws) = TkAnd () `cons` foldMap renderWhitespace ws
renderBinOp (BoolOr _ ws) = TkOr () `cons` foldMap renderWhitespace ws
renderBinOp (Equals _ ws) = TkDoubleEq () `cons` foldMap renderWhitespace ws

renderIndents :: Indents a -> RenderOutput
renderIndents (Indents is _) = foldMap renderIndent is

renderModule :: Module v a -> RenderOutput
renderModule (Module ms) =
  foldMap
    (either
       (\(a, b, c) ->
          renderIndents a <>
          maybe mempty (singleton . renderComment) b <>
          maybe mempty (singleton . renderNewline) c)
       (renderLines id . renderStatement))
    ms

showModule :: Module v a -> String
showModule = showRenderOutput . renderModule

showStatement :: Statement v a -> String
showStatement = showRenderOutput . renderLines id . renderStatement

showExpr :: Expr v a -> String
showExpr = showRenderOutput . renderExpr
