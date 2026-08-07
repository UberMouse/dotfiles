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
  # Lists the pids of resident playwright CLI daemons, one per line. Handed to
  # kx-build-slot as --resident-probe so the slot taken by `open` is held for
  # as long as the browser that `open` leaves behind.
  #
  # A daemon is `node .../playwright-core/lib/entry/cliDaemon.js <session>`,
  # detached and reparented to init, and it owns the chromium as a child -- so
  # its lifetime IS the browser's and waiting on it needs no other bookkeeping.
  #
  # WHY /proc AND NOT `pgrep -f cliDaemon.js`. -f matches the pattern against
  # the FULL command line of every process, so the pgrep matches itself, and so
  # does any grep, editor or shell that happens to hold the string. Measured on
  # 2026-08-07: six "daemons" reported against four real ones, the extras being
  # the probe's own pipeline. Because a self-match gets a different pid on each
  # run, it appears in the AFTER list and never the BEFORE one -- it always
  # looks freshly spawned, so every single `open` would fork a keeper for a
  # process that no longer exists and log a RESIDENT line that is simply false.
  # Testing argv[1] for an exact suffix cannot match a pattern-shaped argument.
  daemonProbe = writeText "kx-pw-daemons" ''
    #!${runtimeShell}
    for c in /proc/[0-9]*/cmdline; do
      # argv is NUL-separated; field 2 is the script path node was invoked with.
      #
      # The redirection is inside the group so the GROUP's stderr swallows it.
      # `tr ... 2>/dev/null` would not: a process that exits between the glob and
      # the read makes the redirect itself fail, and that error is printed by the
      # shell before tr is ever started. Harmless but noisy, and noise in a probe
      # is how a probe stops being read.
      a1=$( { tr '\0' '\n' < "$c" | sed -n 2p; } 2>/dev/null ) || continue
      case "$a1" in
        */entry/cliDaemon.js)
          p=''${c#/proc/}
          printf '%s\n' "''${p%/cmdline}"
          ;;
      esac
    done
  '';

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

    # Browser RESIDENCY takes a slot from the machine-global build semaphore --
    # not merely the launch, but the whole lifetime of the browser the launch
    # leaves behind. `open` is the only subcommand gated here, and that is a
    # deliberate line:
    #
    #   * `open` forks a chromium, which is a large, spiky allocation and the
    #     one thing several agents can plausibly do at the same instant. Making
    #     those launches queue is exactly what the semaphore is for.
    #   * every other subcommand (goto/click/snapshot/eval/...) drives a browser
    #     that is ALREADY running. Gating them would queue cheap operations
    #     behind heft typechecks for no memory benefit, and would badly hurt
    #     agent latency.
    #
    # THE SLOT IS HELD UNTIL THE BROWSER GOES AWAY, via --resident-probe. An
    # earlier version of this file released it as soon as `open` returned, on
    # the argument that a resident browser shows up as worktrees.slice pressure
    # and the controller, being pressure-adaptive, would tighten for it without
    # anyone having to model it. That is true but LAGGING: it tightens after the
    # browser has already caused the stall. On 2026-08-07 four resident sessions
    # (daemon + chromium + renderers, ~1.2 GB) sat entirely outside the
    # semaphore's accounting while it reported 1/1 -- correct by its own books,
    # and wrong about the machine. Holding the slot makes the tenant visible
    # BEFORE it hurts, which is the whole point of admission control.
    #
    # --resident additionally makes the launch wait for the controller's LOAD
    # TEST, not merely for a free slot. The floor keeps one slot free whenever no
    # build is running, and a browser taking that slot raises the floor, freeing
    # the next -- twelve got in that way on a pool at 15.5G of 16G with psi10=40%
    # before this flag existed. Waiting on the load test is what makes a browser
    # answer to memory the way a heft typecheck does.
    #
    # This is safe only because the controller raises its floor by the number of
    # resident-held slots; without that, browsers would eat the admission pool
    # and every build would sit out its timeout and then run UNGATED, which is
    # strictly worse than not gating at all. See the RESIDENCY note in
    # scriptBins/bins/kx-build-slot.sh and Semaphore.resident() plus the
    # floor_dyn block in scripts/build-semaphore-controller.py -- the three
    # have to agree.
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
      exec kx-build-slot --label playwright-open --resident \
        --resident-probe '@PROBE@' -- "$0" "$@"
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

    # The residency probe (daemonProbe above) matches */entry/cliDaemon.js in
    # argv[1] -- an INTERNAL playwright-core path. If a playwright bump moves or
    # renames it, the probe returns nothing, no keeper forks, and browsers
    # escape semaphore accounting with no error anywhere. Fail the BUILD
    # instead of degrading silently at runtime.
    if [ ! -e "$pkgdir/node_modules/playwright-core/lib/entry/cliDaemon.js" ]; then
      echo "ERROR: playwright-core no longer ships lib/entry/cliDaemon.js;" >&2
      echo "the kx-pw-daemons residency probe would silently match nothing." >&2
      echo "Update daemonProbe in this file to the new daemon entry path."   >&2
      exit 1
    fi

    # Install our own wrapper (see wrapperScript above) in place of the npm bin
    # symlink, then bake in the absolute path to the CLI entry point.
    # The resident-daemon probe. libexec, not bin: it is an implementation
    # detail of the semaphore handoff, not a command anyone should be running.
    install -Dm755 ${daemonProbe} $out/libexec/kx-pw-daemons

    rm -f $out/bin/playwright-cli
    install -m755 ${wrapperScript} $out/bin/playwright-cli
    sed -i "s|@ENTRY@|$pkgdir/playwright-cli.js|" $out/bin/playwright-cli
    sed -i "s|@PROBE@|$out/libexec/kx-pw-daemons|" $out/bin/playwright-cli
  '';

  meta = {
    description = "Official Playwright CLI (@playwright/cli)";
    homepage = "https://playwright.dev";
    license = lib.licenses.asl20;
    mainProgram = "playwright-cli";
  };
})
