{
  lib,
  stdenvNoCC,
  fetchzip,
  nodejs,
  makeWrapper,
  versionCheckHook,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "ccstatusline";
  version = "2.2.32";

  src = fetchzip {
    url = "https://registry.npmjs.org/ccstatusline/-/ccstatusline-${finalAttrs.version}.tgz";
    hash = "sha256-mz7dVziadgxDdF+BjlITkeVu4MoVSc29xN3nuDiSqD8=";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/ccstatusline $out/bin
    # The whole dist directory, not just the entry point: since 2.2.32 the
    # bundle is split into content-hashed chunks the entry imports by
    # relative path.
    cp -r dist/. $out/lib/ccstatusline/

    makeWrapper ${nodejs}/bin/node $out/bin/ccstatusline \
      --add-flags "$out/lib/ccstatusline/ccstatusline.js"

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "A customizable status line formatter for Claude Code CLI";
    homepage = "https://github.com/sirmalloc/ccstatusline";
    changelog = "https://github.com/sirmalloc/ccstatusline/releases";
    license = lib.licenses.mit;
    # Prebuilt dist JS from the npm registry, not built from source here.
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
    platforms = lib.platforms.all;
    mainProgram = "ccstatusline";
  };
})
