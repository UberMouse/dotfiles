{
  lib,
  stdenvNoCC,
  bun,
  nodejs,
  fetchFromGitHub,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:
# Built from source -- not upstream's release binary -- so ./patches/ can
# customise it. The recipe mirrors upstream's .github/workflows/release.yml
# (`bun install --frozen-lockfile` -> build:viewer-pin (see viewerPin), build:review,
# build:hook -> `bun build --compile`); when a bump breaks the build, diff
# that workflow first. Upstream pins the same bun this overlay's unstable base
# ships; a version skew there is the second thing to check.
#
# Only the binary is built here. The Claude Code plugin (commands, hooks)
# still installs from the marketplace into ~/.claude/plugins and just runs
# `plannotator` off PATH.
let
  # The dependency tree, as a fixed-output derivation (bun install needs the
  # network). It is fed the UNPATCHED source on purpose: editing a patch then
  # never re-runs the install. A patch that touches a package.json or bun.lock
  # must be applied here too, or the main build will run against the old
  # tree.
  #
  # --filter limits it to the workspaces the binary is built from (and the
  # packages/* they import) -- 1.5G instead of 2.1G for the whole monorepo.
  # Host os/cpu only: this package is x86_64-linux and nothing else.
  node_modules =
    finalAttrs:
    stdenvNoCC.mkDerivation {
      pname = "${finalAttrs.pname}-node_modules";
      inherit (finalAttrs) version src;

      impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [
        "GIT_PROXY_COMMAND"
        "SOCKS_SERVER"
      ];

      nativeBuildInputs = [
        bun
        writableTmpDirAsHomeHook
      ];

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild

        export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
        bun install \
          --filter './' \
          --filter './apps/hook' \
          --filter './apps/review' \
          --filter './apps/inbox' \
          --filter './apps/guides-show' \
          --filter './packages/*' \
          --frozen-lockfile \
          --ignore-scripts \
          --no-progress

        runHook postBuild
      '';

      # Every node_modules dir, at its path in the tree. bun's isolated
      # linker uses only relative symlinks, so the tree is relocatable.
      installPhase = ''
        runHook preInstall

        mkdir -p $out
        find . -type d -name node_modules -prune -exec cp -R --parents {} $out \;

        runHook postInstall
      '';

      # Fixup would patch shebangs to store paths, which a fixed-output
      # derivation may not reference.
      dontFixup = true;

      outputHash = "sha256-GxUKMmZ3bYxg8zIJl//GfqzLsBK75t0WKz6g37Zv81A=";
      outputHashMode = "recursive";
    };

  # node_modules into a source tree, runnable. nodejs because upstream's CI
  # has it: the workspace scripts run vite and friends through
  # `#!/usr/bin/env node` shebangs.
  withNodeModules = {
    nativeBuildInputs = [
      bun
      nodejs
      writableTmpDirAsHomeHook
    ];

    configurePhase = ''
      runHook preConfigure

      cp -R "$node_modules"/. .
      chmod -R u+w .
      patchShebangs $(find . -type d -name node_modules -prune)

      runHook postConfigure
    '';
  };

  # The guides.show viewer pin (packages/core/guide-viewer-manifest.ts, a
  # generated file): the hashes of the viewer bundle that exported guides
  # load FROM guides.show. It only resolves if it names files upstream
  # published, i.e. a build of upstream's unpatched viewer -- which this
  # reproduces byte for byte (checked against the 0.28.65 release binary:
  # viewer.E_CsZeVB.js / viewer.buMy3y0a.css). Built from the UNPATCHED
  # source so no patch can move it: the viewer bundle compiles review-editor
  # and guide-viewer code too, and a pin from a patched tree would point
  # exported guides at files guides.show doesn't have. (They then show
  # upstream's viewer, not ours -- the only one guides.show can serve.)
  viewerPin =
    finalAttrs:
    stdenvNoCC.mkDerivation (
      withNodeModules
      // {
        pname = "${finalAttrs.pname}-viewer-pin";
        inherit (finalAttrs) version src node_modules;

        buildPhase = ''
          runHook preBuild
          bun run build:viewer-pin
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          cp packages/core/guide-viewer-manifest.ts $out
          runHook postInstall
        '';
      }
    );
in
stdenvNoCC.mkDerivation (
  finalAttrs:
  withNodeModules
  // {
    pname = "plannotator";
    version = "0.28.65";

    src = fetchFromGitHub {
      owner = "backnotprop";
      repo = "plannotator";
      tag = "v${finalAttrs.version}";
      hash = "sha256-iuIzGkWmeKcedcthI5XzdEZoDmDvxdg1PzzvvzfiPIs=";
    };

    # Our customisations: plain `git format-patch` output against the pinned
    # tag, applied in filename order. See UPDATE.md for making and rebasing
    # them.
    patches = lib.filter (lib.hasSuffix ".patch") (lib.filesystem.listFilesRecursive ./patches);

    node_modules = node_modules finalAttrs;
    viewerPin = viewerPin finalAttrs;

    # Upstream's build:viewer-pin step, replaced by the unpatched pin above.
    buildPhase = ''
      runHook preBuild

      install -m644 "$viewerPin" packages/core/guide-viewer-manifest.ts
      bun run build:review
      bun run build:hook

      bun build apps/hook/server/index.ts \
        --compile \
        --no-compile-autoload-bunfig \
        --define '__CLI_VERSION__="${finalAttrs.version}"' \
        --define __PLANNOTATOR_RELEASE__=true \
        --outfile plannotator

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      install -Dm755 plannotator $out/bin/plannotator

      runHook postInstall
    '';

    # A bun --compile binary is the bun runtime with the bundle appended:
    # stripping cuts the bundle off.
    dontStrip = true;

    doInstallCheck = true;
    nativeInstallCheckInputs = [ versionCheckHook ];
    versionCheckProgramArg = "--version";

    meta = {
      description = "Code review and annotation tool for Claude Code";
      homepage = "https://github.com/backnotprop/plannotator";
      changelog = "https://github.com/backnotprop/plannotator/releases";
      license = with lib.licenses; [
        mit
        asl20
      ];
      sourceProvenance = with lib.sourceTypes; [ fromSource ];
      platforms = [ "x86_64-linux" ];
      mainProgram = "plannotator";
    };
  }
)
