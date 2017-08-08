{ mkDerivation, base, charset, deriving-compat, papa, parsers
, pretty, stdenv, text, transformers, trifecta
}:
mkDerivation {
  pname = "hpython";
  version = "0.0.1.0";
  src = ./.;
  libraryHaskellDepends = [
    base charset deriving-compat papa parsers pretty text transformers
    trifecta
  ];
  homepage = "https://github.com/qfpl/hpython";
  description = "Write Python using Haskell";
  license = stdenv.lib.licenses.bsd3;
}