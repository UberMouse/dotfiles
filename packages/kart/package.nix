{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  openssl_3,
  libz,
  libffi,
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

  # Hand-maintained against the release bundle's NEEDED entries; a kart
  # release that gains a new .so lands here (autoPatchelf fails the build and
  # names it). openssl_3 is an explicit major pin: the bundle's cryptography/
  # libgit2 are built against OpenSSL 3's ABI. stdenv.cc.cc.lib already
  # provides libgcc_s.so.1 alongside libstdc++ (a separate libgcc entry here
  # was redundant).
  buildInputs = [
    openssl_3
    libz
    libffi
    stdenv.cc.cc.lib
    unixodbc
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/kart $out/bin
    cp -r kart/* $out/share/kart/
    makeWrapper $out/share/kart/kart $out/bin/kart

    runHook postInstall
  '';

  # The strongest smoke test of the seven custom packages: kart's version
  # banner also prints its GDAL/PROJ/PDAL versions, so this exercises the
  # patchelf'd plugin loading, not just process start. Without it, a version
  # bump on this hand-maintained buildInputs list is accepted with zero
  # evidence the binary runs (autoPatchelf only catches UNRESOLVABLE NEEDED
  # entries -- a lib resolved to a wrong version fails at runtime only).
  doInstallCheck = true;
  # Hand-rolled rather than versionCheckHook: kart normally routes every
  # invocation through a background helper daemon, which SEGFAULTS (before
  # printing anything) without HOME, and versionCheckHook gives no hook to
  # provide one -- its failure output is just "did not find version", which
  # is undiagnosable. Disabling the helper also makes the check exercise the
  # binary directly instead of a daemon the sandbox can't host.
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME=$TMPDIR KART_USE_HELPER=0
    banner="$($out/bin/kart --version)"
    printf '%s\n' "$banner"
    if [ "''${banner#*${finalAttrs.version}}" = "$banner" ]; then
      echo "ERROR: kart --version output does not contain ${finalAttrs.version}" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  meta = {
    description = "Distributed version control for geospatial and tabular data";
    homepage = "https://kartproject.org";
    changelog = "https://github.com/koordinates/kart/releases";
    license = lib.licenses.gpl2Only;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "kart";
  };
})
