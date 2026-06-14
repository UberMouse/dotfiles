{
  lib,
  buildNpmPackage,
  fetchzip,
  playwright-driver,
  playwright-test,
  runtimeShell,
  writeText,
}:
let
  # Wrapper that sets the nix browser env and injects --browser=chromium ONLY
  # for the `open` subcommand. Upstream's `--browser` is an option of `open`
  # alone; injecting it globally (as the old `wrapProgram --add-flags` did)
  # makes every other subcommand abort with "Unknown option: --browser".
  # @ENTRY@ is substituted with the installed CLI entry point in postInstall.
  wrapperScript = writeText "playwright-cli" ''
    #!${runtimeShell}
    export PLAYWRIGHT_BROWSERS_PATH='${playwright-driver.browsers}'
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD='1'

    entry='@ENTRY@'

    # The subcommand is the first positional arg (skip option flags and the
    # value of a space-separated -s/--session global flag).
    cmd=""
    skip=0
    for a in "$@"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$a" in
        -s | --session) skip=1 ;;
        -*) : ;;
        *) cmd="$a"; break ;;
      esac
    done

    # Respect an explicit user-supplied --browser.
    has_browser=0
    for a in "$@"; do
      case "$a" in --browser | --browser=*) has_browser=1 ;; esac
    done

    # --browser=chromium points the `open` command at the nix-provided bundled
    # chromium. Upstream's default is the "chrome" channel, which expects Google
    # Chrome at /opt/google/chrome/chrome (not the nix chromium).
    if [ "$cmd" = open ] && [ "$has_browser" = 0 ]; then
      exec -a "$0" "$entry" --browser=chromium "$@"
    else
      exec -a "$0" "$entry" "$@"
    fi
  '';
in
buildNpmPackage (finalAttrs: {
  pname = "playwright-cli";
  version = "0.1.7";

  src = fetchzip {
    url = "https://registry.npmjs.org/@playwright/cli/-/cli-${finalAttrs.version}.tgz";
    hash = "sha256-irw1CARad6w4/tFbpi8pY4mDaQF191b+jxr8ZSkaQMc=";
  };

  npmDepsHash = "sha256-S0z7i5tU9rP1jBhrCR/yDsboWSmBWFqKHeQ/F4QYvvU=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  # Don't let npm fetch browsers or run any lifecycle scripts.
  npmFlags = [ "--ignore-scripts" ];

  postInstall = ''
    pkgdir=$out/lib/node_modules/@playwright/cli

    # Replace the npm-bundled playwright / playwright-core with the ones from
    # the playwright-web-flake, so the CLI code (which only requires
    # playwright-core/lib/tools/cli-client/program) runs against the exact
    # playwright-core that matches the nix-provided browsers.
    rm -rf $pkgdir/node_modules/playwright $pkgdir/node_modules/playwright-core
    ln -s ${playwright-test}/lib/node_modules/playwright       $pkgdir/node_modules/playwright
    ln -s ${playwright-test}/lib/node_modules/playwright-core  $pkgdir/node_modules/playwright-core

    # Install our own wrapper (see wrapperScript above) in place of the npm bin
    # symlink, then bake in the absolute path to the CLI entry point.
    rm -f $out/bin/playwright-cli
    install -m755 ${wrapperScript} $out/bin/playwright-cli
    sed -i "s|@ENTRY@|$pkgdir/playwright-cli.js|" $out/bin/playwright-cli
  '';

  meta = {
    description = "Official Playwright CLI (@playwright/cli)";
    homepage = "https://playwright.dev";
    license = lib.licenses.asl20;
    mainProgram = "playwright-cli";
  };
})
