{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
stdenv.mkDerivation rec {
  pname = "plannotator";
  version = "0.25.1";

  src = fetchurl {
    url = "https://github.com/backnotprop/plannotator/releases/download/v${version}/plannotator-linux-x64";
    hash = "sha256-UWJWL7uX91SpyDwNdJ/GLSC6zeUJzV0v7MAEkL2d/m8=";
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
