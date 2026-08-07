{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  openssl_3,
  libz,
  libffi,
  libgcc,
  unixodbc,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "kart";
  version = "0.15.2";

  src = fetchurl {
    url = "https://github.com/koordinates/kart/releases/download/v${finalAttrs.version}/Kart-${finalAttrs.version}-linux-x86_64.tar.gz";
    hash = "sha256-oUoeD1fLyCI1x9UhxnT5/3iya+myA0M6AB+yDCM6V+o=";
  };

  sourceRoot = "Kart-${finalAttrs.version}-linux-x86_64";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    openssl_3
    libz
    libffi
    stdenv.cc.cc.lib
    libgcc
    unixodbc
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/kart $out/bin
    cp -r kart/* $out/share/kart/
    makeWrapper $out/share/kart/kart $out/bin/kart

    runHook postInstall
  '';

  meta = {
    description = "Distributed version control for geospatial and tabular data";
    homepage = "https://kartproject.org";
    license = lib.licenses.gpl2Only;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "kart";
  };
})
