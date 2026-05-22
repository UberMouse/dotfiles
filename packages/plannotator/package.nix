{ lib, stdenv, fetchurl, autoPatchelfHook }:
stdenv.mkDerivation rec {
  pname = "plannotator";
  version = "0.19.20";

  src = fetchurl {
    url = "https://github.com/backnotprop/plannotator/releases/download/v${version}/plannotator-linux-x64";
    hash = "sha256-KM8VxQLaROkQgqup2a0zAs17NoLOo7fPHwiEVtkP2S8=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    install -Dm755 $src $out/bin/plannotator
  '';

  meta = with lib; {
    description = "Code review and annotation tool for Claude Code";
    homepage = "https://github.com/backnotprop/plannotator";
    platforms = [ "x86_64-linux" ];
  };
}
