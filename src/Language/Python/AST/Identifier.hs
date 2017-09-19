{-# language DeriveFoldable #-}
{-# language DeriveFunctor #-}
{-# language DeriveTraversable #-}
{-# language TemplateHaskell #-}
module Language.Python.AST.Identifier where

import Papa
import Data.Deriving
import Data.Text (Text)

data Identifier a
  = Identifier
  { _identifier_value :: Text
  , _identifier_ann :: a
  } deriving (Eq, Show, Functor, Foldable, Traversable, Ord)

deriveEq1 ''Identifier
deriveShow1 ''Identifier
makeLenses ''Identifier
