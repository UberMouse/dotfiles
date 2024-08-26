{ pkgs, ... }:
let
  pname = "kart";
  version = "0.15.2";
  system = "x86_64-linux";
  file = "Kart-${version}-linux-x86_64";

  src = pkgs.fetchurl {
    name = "kart.tar.gz";
    url =
      "https://github.com/koordinates/kart/releases/download/v${version}/${file}.tar.gz";
    hash = "sha256-oUoeD1fLyCI1x9UhxnT5/3iya+myA0M6AB+yDCM6V+o=";
  };
in pkgs.stdenv.mkDerivation {
  inherit pname version src system file;

  # Required for compilation
  nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.gnutar pkgs.makeWrapper ];

  # Required for runtime
  buildInputs = [
    pkgs.openssl_3_2
    pkgs.libz
    pkgs.libffi
    pkgs.stdenv.cc.cc.lib
    pkgs.libgcc
    pkgs.unixODBC
  ];

  unpackPhase = ''
    mkdir -p unpacked
    tar -xvf $src -C unpacked
  '';

  installPhase = ''
    mkdir -p $out/share/kart
    cp -r unpacked/$file/kart/* $out/share/kart
    mkdir -p $out/bin
    makeWrapper $out/share/kart/kart $out/bin/kart
  '';
}