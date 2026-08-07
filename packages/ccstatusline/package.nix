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
  version = "2.2.27";

  src = fetchzip {
    url = "https://registry.npmjs.org/ccstatusline/-/ccstatusline-${finalAttrs.version}.tgz";
    hash = "sha256-wP0YxvKYF+ZxmhVrkWiYgXrLryNB+8N9GEIuSJ9RtXY=";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/ccstatusline $out/bin
    cp dist/ccstatusline.js $out/lib/ccstatusline/

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
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "ccstatusline";
  };
})
