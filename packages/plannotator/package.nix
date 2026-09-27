{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  versionCheckHook,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "plannotator";
  version = "0.27.21";

  src = fetchurl {
    url = "https://github.com/backnotprop/plannotator/releases/download/v${finalAttrs.version}/plannotator-linux-x64";
    hash = "sha256-mxtKO58JL+gX6/Aqp2OLGAsfW0UVIPWA4xSVrMryMwU=";
  };

  dontUnpack = true;
  dontBuild = true;
  # prebuilt single-file binary: stripping breaks the embedded runtime
  dontStrip = true;

  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall

    install -Dm755 $src $out/bin/plannotator

    runHook postInstall
  '';

  # A hash bump is otherwise accepted with zero evidence the binary runs.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Code review and annotation tool for Claude Code";
    homepage = "https://github.com/backnotprop/plannotator";
    changelog = "https://github.com/backnotprop/plannotator/releases";
    license = lib.licenses.asl20;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "plannotator";
  };
})
