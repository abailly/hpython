{-# language RankNTypes #-}
module Language.Python.Printer.ArgsList where

import Prelude (error)
import Papa hiding (Sum)
import Data.Functor.Sum
import Text.PrettyPrint hiding ((<>), comma, colon)

import Language.Python.AST.ArgsList
import Language.Python.Printer.Combinators
import Language.Python.Printer.Symbols

argsListArg
  :: (forall x. name x -> Doc)
  -> (forall x. f x -> Doc)
  -> ArgsListArg name f a
  -> Doc
argsListArg renderName f (ArgsListArg l r _) =
  renderName l <>
  foldMapF (beforeF (betweenWhitespace' . const $ char '=') f) r

argsListStarPart
  :: (forall x. name x -> Doc)
  -> (forall x. f x -> Doc)
  -> ArgsListStarPart name f a
  -> Doc
argsListStarPart renderName f e =
  case e of
    ArgsListStarPartEmpty _ -> mempty
    ArgsListStarPart h t r _ ->
      beforeF (betweenWhitespace' . const $ text "*") renderName h <>
      foldMapF
        (beforeF
          (betweenWhitespace' comma)
          (argsListArg renderName f)) t <>
      foldMapF
        (beforeF
          (betweenWhitespace' comma)
          (argsListDoublestarArg renderName)) r

argsListDoublestarArg
  :: (forall x. name x -> Doc)
  -> ArgsListDoublestarArg name test a
  -> Doc
argsListDoublestarArg renderName (ArgsListDoublestarArg a _) =
  text "**" <>
  betweenWhitespace'F renderName a

argsList
  :: HasName name
  => (forall x. name x -> Doc)
  -> (forall x. f x -> Doc)
  -> ArgsList name f a
  -> Doc
argsList renderName f e =
  Just e &
    (outside _ArgsListAll .~
       (\(h, t, r, _) ->
         argsListArg renderName f h <>
         foldMapF
           (beforeF
             (betweenWhitespace' comma)
             (argsListArg renderName f)) t <>
         foldMapF
           (beforeF
             (betweenWhitespace' comma)
             (foldMapF $ starOrDouble renderName f)) r) $
     outside _ArgsListArgsKwargs .~
       (\(a, _) -> starOrDouble renderName f a) $
     error "incomplete pattern")
  where
    starOrDouble
      :: (forall x. name x -> Doc)
      -> (forall x. f x -> Doc)
      -> Sum (ArgsListStarPart name f) (ArgsListDoublestarArg name f) a
      -> Doc
    starOrDouble renderName' f' =
      sumElim
        (argsListStarPart renderName' f')
        (argsListDoublestarArg renderName')
