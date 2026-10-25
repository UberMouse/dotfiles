{
  lib,
  stdenvNoCC,
  fetchzip,
  versionCheckHook,
}:
# The real ccusage, as upstream's prebuilt linux-x64 binary from the npm
# registry (the `ccusage` npm package is only a node shim that execs this).
# It is static-pie, so it needs no patchelf. It is NOT installed directly: the
# `ccusage` on PATH is the caching wrapper in scriptBins/bins/ccusage.py, which
# asks this binary only for the days it hasn't cached yet.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "ccusage";
  version = "20.0.44";

  src = fetchzip {
    url = "https://registry.npmjs.org/@ccusage/ccusage-linux-x64/-/ccusage-linux-x64-${finalAttrs.version}.tgz";
    hash = "sha256-vdpTmWvubARYLRwDgikod10FzbtXzk0JbyQ/v3485yA=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/ccusage $out/bin/ccusage
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Usage and cost reports from local coding-agent transcripts";
    homepage = "https://github.com/ryoppippi/ccusage";
    changelog = "https://github.com/ryoppippi/ccusage/releases";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "ccusage";
  };
})
