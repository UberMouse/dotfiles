{
  lib,
  buildNpmPackage,
  nodejs,
  makeWrapper,
}:
buildNpmPackage {
  pname = "rush";
  version = "5.165.0";

  src = ./.;

  npmDepsHash = "sha256-e58+r4KyeFmxXC2du3ulcUUsYtO7h9ySDCYS8CAtshI=";

  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin
    cp -r node_modules $out/lib/node_modules

    makeWrapper ${nodejs}/bin/node $out/bin/rush \
      --add-flags "$out/lib/node_modules/@microsoft/rush/bin/rush"

    makeWrapper ${nodejs}/bin/node $out/bin/rushx \
      --add-flags "$out/lib/node_modules/@microsoft/rush/bin/rushx"

    runHook postInstall
  '';

  meta = {
    description = "Microsoft Rush monorepo manager";
    homepage = "https://rushjs.io";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "rush";
  };
}
