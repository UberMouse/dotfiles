{
  lib,
  buildNpmPackage,
  fetchzip,
  jq,
  python3,
  pkg-config,
}:
buildNpmPackage (finalAttrs: {
  pname = "grackle";
  version = "0.108.0";

  src = fetchzip {
    url = "https://registry.npmjs.org/@grackle-ai/cli/-/cli-${finalAttrs.version}.tgz";
    hash = "sha256-gfs/idTIJvb4RpNogh4G7YNDx6bhNXViszpc1p9Qy9Q=";
  };

  npmDepsHash = "sha256-VviTWwTfQaHAlDz/fHabHg8o397q59efk1Md5SChMjs=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
    # Strip devDependencies — @grackle-ai/heft-rig is not published to npm
    ${jq}/bin/jq 'del(.devDependencies)' package.json > package2.json && mv package2.json package.json
  '';

  dontNpmBuild = true;

  # Skip postinstall scripts — onnxruntime-node tries to download binaries from GitHub
  npmFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [ python3 pkg-config ];

  # Rebuild better-sqlite3 native addon (skipped by --ignore-scripts above)
  postInstall = ''
    cd $out/lib/node_modules/@grackle-ai/cli
    npm rebuild better-sqlite3
  '';

  meta = {
    description = "Control plane for AI coding agents — configure once, supervise by exception";
    homepage = "https://github.com/nick-pape/grackle";
    license = lib.licenses.mit;
    mainProgram = "grackle";
  };
})
