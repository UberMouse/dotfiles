{
  lib,
  buildNpmPackage,
  nodejs,
  makeWrapper,
  versionCheckHook,
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

  # regen: nix run nixpkgs#prefetch-npm-deps -- packages/rush/package-lock.json
  # (UPDATE.md step 3) -- the one value every version bump must recompute.
  npmDepsHash = "sha256-2i8WkQM9r5leZUHgpNd0yKU8ODiRveJe7ONwFfvnsFI=";

  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin
    # Bypasses npmInstallHook, so no `npm prune --omit=dev` runs. Fine today:
    # package.json has exactly one dependency and no devDependencies, so
    # there is nothing to prune -- revisit if that ever changes.
    cp -r node_modules $out/lib/node_modules

    makeWrapper ${nodejs}/bin/node $out/bin/rush \
      --add-flags "$out/lib/node_modules/@microsoft/rush/bin/rush"

    makeWrapper ${nodejs}/bin/node $out/bin/rushx \
      --add-flags "$out/lib/node_modules/@microsoft/rush/bin/rushx"

    runHook postInstall
  '';

  # `rush --version` prints "Rush Multi-Project Build Tool <version>", which
  # is enough for versionCheckHook and proves the node wrapper + module
  # resolution actually work after a bump.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Microsoft Rush monorepo manager";
    homepage = "https://rushjs.io";
    changelog = "https://github.com/microsoft/rushstack/blob/main/apps/rush/CHANGELOG.md";
    license = lib.licenses.mit;
    # Prebuilt JS from the npm registry, not built from source here.
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
    platforms = lib.platforms.all;
    mainProgram = "rush";
  };
}
