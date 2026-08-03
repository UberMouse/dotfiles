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

    # Browser LAUNCH takes a slot from the machine-global build semaphore. It is
    # the only subcommand gated here, and that is a deliberate line:
    #
    #   * `open` forks a chromium, which is a large, spiky allocation and the
    #     one thing several agents can plausibly do at the same instant. Making
    #     those launches queue is exactly what the semaphore is for.
    #   * every other subcommand (goto/click/snapshot/eval/...) drives a browser
    #     that is ALREADY running. Gating them would queue cheap operations
    #     behind heft typechecks for no memory benefit, and would badly hurt
    #     agent latency.
    #   * the launched browser OUTLIVES this process, so a slot held across
    #     `open` could never represent its resident memory anyway. That memory is
    #     accounted for the honest way instead: a resident browser shows up as
    #     worktrees.slice memory pressure, and the controller is pressure-
    #     adaptive, so it tightens for browsers automatically without anyone
    #     having to model them. See scripts/build-semaphore-controller.py.
    #
    # Re-invoking THIS wrapper under kx-build-slot (rather than wrapping $entry
    # directly) keeps the `exec -a "$0"` argv[0] fixup below intact -- prefixing
    # the exec would otherwise apply -a to kx-build-slot instead of the CLI.
    # kx-build-slot exports KX_BUILD_SLOT_HELD, so the re-entry falls straight
    # through this branch rather than looping.
    #
    # Soft dependency on purpose: if kx-build-slot is not installed (or the
    # controller was never started) this is a no-op and the CLI behaves exactly
    # as it did before. The semaphore is a scheduling hint, never a requirement.
    if [ "$cmd" = open ] && [ -z "''${KX_BUILD_SLOT_HELD:-}" ] \
       && command -v kx-build-slot >/dev/null 2>&1; then
      exec kx-build-slot --label playwright-open -- "$0" "$@"
    fi

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
  version = "0.1.17";

  src = fetchzip {
    url = "https://registry.npmjs.org/@playwright/cli/-/cli-${finalAttrs.version}.tgz";
    hash = "sha256-VxrappuH7YJejG5W9ght27EUXwlppWRdOPTVsYfP1ek=";
  };

  npmDepsHash = "sha256-B6t59yhBIBMvI5XN8t2uUq96+Gsu6QVkvdb//DrgL10=";

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
