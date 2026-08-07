{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  versionCheckHook,
}:
# The new Sentry CLI (getsentry/cli) — a bun-compiled single-file binary,
# distinct from nixpkgs' `sentry-cli` (the older getsentry/sentry-cli, 2.x).
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "sentry";
  version = "0.40.0";

  src = fetchurl {
    url = "https://github.com/getsentry/cli/releases/download/${finalAttrs.version}/sentry-linux-x64";
    hash = "sha256-Hy9k7IuyPO1JahA5d8tU5ytJuDSVzzDDytSH3O/XDBY=";
  };

  dontUnpack = true;
  dontBuild = true;
  # bun-compiled binary: stripping breaks the embedded runtime
  dontStrip = true;

  nativeBuildInputs = [ autoPatchelfHook ];
  # libstdc++.so.6 / libgcc_s.so.1 for the bun runtime
  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall

    install -Dm755 $src $out/bin/sentry

    runHook postInstall
  '';

  # A hash bump is otherwise accepted with zero evidence the binary runs;
  # `sentry --version` exercises the patchelf'd bun runtime end to end.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Sentry command-line interface (getsentry/cli)";
    homepage = "https://github.com/getsentry/cli";
    changelog = "https://github.com/getsentry/cli/releases";
    # Functional Source License v1.1 (Apache 2.0 future license) — source-available,
    # treated as unfree by nixpkgs (no fsl11Apache2 license attr exists).
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "sentry";
  };
})
