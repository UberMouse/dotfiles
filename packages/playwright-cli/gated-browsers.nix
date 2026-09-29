{
  lib,
  playwright-driver,
  runCommand,
  runtimeShell,
  writeText,
}:
let
  # THE GAP THIS CLOSES. `playwright-cli open` is gated in package.nix, but an
  # agent that writes its own script -- `require(<kawaka's playwright>)` then
  # `chromium.launch()` -- never touches the CLI: playwright spawns the browser
  # straight out of PLAYWRIGHT_BROWSERS_PATH. Caught live 2026-09-30: a
  # `timeout 2400 node gallery-overflow.cjs` from an agent's job tmp dir holding
  # a chrome-headless-shell with no kx-build-slot anywhere in its ancestry.
  # Every such script resolves a DIFFERENT playwright copy (whichever worktree's
  # node_modules it found), so the one place they all meet is the browser
  # executable itself -- and that is what gets wrapped here.
  #
  # Accounted as a plain BUILD job, not a resident: the wrapper is the browser's
  # parent for its whole life (playwright spawns it detached, so wrapper and
  # browser share a process group and its kill(-pid) takes both), so the slot is
  # held for exactly as long as the browser lives and returned when the script
  # closes it or dies. No keeper, no marker, no floor raise -- a script browser
  # is transient work, not a tenant someone left behind.
  #
  # Already-gated callers pass straight through on KX_BUILD_SLOT_HELD
  # (kx-build-slot's fail-open 2): kawaka's gated test shards and the daemon a
  # gated `playwright-cli open` spawns both inherit it, so nothing double-gates.
  #
  # --timeout 150 sits under playwright's DEFAULT_PLAYWRIGHT_LAUNCH_TIMEOUT
  # (180 s in playwright-core 1.63). A queued launch must fail OPEN before
  # playwright gives up on it; at kx-build-slot's default 600 s every queued
  # script would die with "Timeout 180000ms exceeded" instead of running late.
  # A script that passes its own shorter launch({timeout}) can still hit that --
  # the gate cannot see the caller's deadline.
  wrapper = writeText "pw-browser-gate" ''
    #!${runtimeShell}
    real='@REAL@'
    if [ -z "''${KX_BUILD_SLOT_HELD:-}" ] && command -v kx-build-slot >/dev/null 2>&1; then
      # Label with the driving script's name (node's argv[1]), which is what a
      # CAP-WAIT/TIMEOUT line in the semaphore log needs to be actionable. Pure
      # bash: this runs under whatever PATH the agent's script had.
      who=""
      if mapfile -d "" -t pargv < "/proc/$PPID/cmdline" 2>/dev/null; then
        who="''${pargv[1]:-}"
        who="''${who##*/}"
      fi
      exec kx-build-slot --label "pw-browser:''${who:-@ENGINE@}" \
        --timeout "''${KX_PW_BROWSER_SLOT_TIMEOUT:-150}" -- "$real" "$@"
    fi
    exec "$real" "$@"
  '';

  # <browser dir glob> : <launch executable relative to it>. The paths are
  # playwright-core's registry layout; a bump that moves one fails the build
  # below rather than letting that engine escape the gate silently.
  engines = {
    "chromium-*" = "chrome-linux64/chrome";
    "chromium_headless_shell-*" = "chrome-headless-shell-linux64/chrome-headless-shell";
    "firefox-*" = "firefox/firefox";
    "webkit-*" = "pw_run.sh";
  };
in
runCommand "playwright-browsers-gated" { } ''
  src=${playwright-driver.browsers}
  mkdir -p $out
  # Everything not rewritten below (ffmpeg, markers) is a plain symlink.
  for e in "$src"/*; do ln -s "$(readlink -f "$e")" "$out/$(basename "$e")"; done

  ${lib.concatStrings (
    lib.mapAttrsToList (glob: exe: ''
      matches=( "$src"/${glob} )
      if [ "''${#matches[@]}" -ne 1 ] || [ ! -e "''${matches[0]}/${exe}" ]; then
        echo "ERROR: expected exactly one ${glob} holding ${exe}; got: ''${matches[*]}" >&2
        echo "An unwrapped engine launches outside the build semaphore." >&2
        exit 1
      fi
      d=$(basename "''${matches[0]}")
      real=$(readlink -f "''${matches[0]}/${exe}")
      # A real directory of symlinks, so the one executable can be replaced.
      # The browser still resolves its resources from its own store path
      # (/proc/self/exe, or $0 for the script launchers), since the wrapper
      # execs the REAL path.
      rm "$out/$d"
      cp -rs "$(readlink -f "''${matches[0]}")" "$out/$d"
      chmod -R u+w "$out/$d"
      rm "$out/$d/${exe}"
      sed -e "s|@REAL@|$real|" -e "s|@ENGINE@|${lib.removeSuffix "-*" glob}|" \
        ${wrapper} > "$out/$d/${exe}"
      chmod 555 "$out/$d/${exe}"
      if grep -qE '@(REAL|ENGINE)@' "$out/$d/${exe}"; then
        echo "ERROR: token substitution failed in $d/${exe}" >&2
        exit 1
      fi
    '') engines
  )}
''
