{
  lib,
  buildNpmPackage,
  nodejs,
  makeWrapper,
}:
buildNpmPackage {
  pname = "rush";
  # The pin in package.json is the single source of truth: it is what npm
  # actually resolves, so deriving the derivation version from it means the two
  # can never drift (they used to be maintained by hand in both files).
  version = (lib.importJSON ./package.json).dependencies."@microsoft/rush";

  # Only the two files npm needs. `src = ./.` made every edit to UPDATE.md (or
  # this file itself) invalidate the build.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
    ];
  };

  npmDepsHash = "sha256-2i8WkQM9r5leZUHgpNd0yKU8ODiRveJe7ONwFfvnsFI=";

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
