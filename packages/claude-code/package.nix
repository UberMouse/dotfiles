{
  lib,
  buildNpmPackage,
  fetchzip,
  writableTmpDirAsHomeHook,
  versionCheckHook,
}:
buildNpmPackage (finalAttrs: {
  pname = "claude-code";
  version = "2.0.69";

  src = fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${finalAttrs.version}.tgz";
    hash = "sha256-iQ+iVv3sY0oxGCZuuatcl2LSWvBfqSA+/RmeFgiMDDY=";
  };

  npmDepsHash = "sha256-jb6AWGbnW5n9P9V8crR25ql0gFsAFY0z0EBnWJodnd4=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  env.AUTHORIZED = "1";

  postInstall = ''
    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --unset DEV
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    license = lib.licenses.unfree;
    maintainers = with lib.maintainers; [
      malo
      markus1189
      omarjatoi
      xiaoxiangmoe
    ];
    mainProgram = "claude";
  };
})
