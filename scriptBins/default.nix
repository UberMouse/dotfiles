{
  pkgs,
  unstable-pkgs,
  ...
}:

let
  inherit (pkgs) lib;

  # Real config file under bins/ (it is configuration, not wiring -- inline it
  # was a fifth of this file); its header carries the mirrored-from-i3status-
  # defaults note and the drift caveat.
  i3statusConf = pkgs.writeText "i3status.conf" (builtins.readFile ./bins/i3status.conf);

  # Bash scripts live as real files under ./bins and are compiled with
  # writeShellApplication (bare commands, tools supplied via runtimeInputs,
  # shellcheck + `bash -n` enforced at build). bashOptions policy: EVERY
  # script gets nounset (it can only ever catch bugs); errexit is opt-IN per
  # script, because several rely on commands failing mid-run (kx-build-slot's
  # slot scan, the tmux has-session guards) and the writeShellApplication
  # default of errexit+pipefail would change their behaviour. inheritPath
  # (default true) keeps the ambient profile PATH appended, so deliberate
  # ambient lookups (rush-pnpm -> the project's node) keep resolving.
  sh =
    {
      name,
      runtimeInputs ? [ ],
      bashOptions,
      text ? builtins.readFile (./bins + "/${name}.sh"),
    }:
    pkgs.writeShellApplication {
      inherit
        name
        runtimeInputs
        bashOptions
        text
        ;
    };

  # ----- 1Password-backed CLI wrappers --------------------------------------
  #
  # Each tool that fetches its token through op-cached is declared ONCE here;
  # the wrapper script, its runtime deps, its per-caller shim AND its
  # home.packages entry (mapAttrsToList at the bottom) all derive from this
  # attrset, so adding a tool is one entry and the shim roster cannot drift
  # from the consumer list (an eval-time assert below pins the explicit
  # roster the lint tripwire reads). The install list used to be
  # hand-maintained beside this claim -- a third opTools entry would have
  # built and installed nothing, silently.
  opTools = {
    bk = {
      pkg = pkgs.buildkite-cli;
      item = "op://Employee/buildkite-api-token/api-token";
      envVar = "BUILDKITE_API_TOKEN";
      extra = ''
        export BUILDKITE_ORGANIZATION_SLUG="koordinates"
      '';
    };
    sentry = {
      pkg = unstable-pkgs.sentry;
      item = "op://Employee/sentry-api-token/api-token";
      envVar = "SENTRY_AUTH_TOKEN";
      extra = ''
        # The token is for Koordinates' self-hosted Sentry; an env token
        # carries no host, so pin it here (otherwise the CLI assumes
        # sentry.io and rejects the matching .sentryclirc). `live2` is a
        # generation-numbered host -- last verified alive 2026-08-07; a
        # live3 cutover makes this silently authenticate against a corpse.
        export SENTRY_URL=https://sentry-live2.kx.gd
        # SENTRY_FORCE_ENV_TOKEN makes the injected token win over any
        # stored OAuth login, so 1Password is the single source of truth.
        export SENTRY_FORCE_ENV_TOKEN=1
      '';
    };
    # Home Assistant, reached through its Nabu Casa remote URL (the VM is not
    # on the home LAN). Personal account, not koordinates: it's the house, not
    # work. The URL is read from 1Password alongside the token rather than
    # written here because this repo is public -- the remote URL is the one
    # address that reaches the instance from anywhere. Both tools read the
    # same item (an API Credential: `credential` = an admin user's long-lived
    # token, `hostname` = https://<id>.ui.nabu.casa) under ONE shared caller:
    # same token, same purpose, so one approval covers both. With a caller
    # each, a cold start cost four prompts (two fields x two tools), and the
    # op-cached cache -- keyed by caller -- could not share between them.
    hass-cli = {
      pkg = pkgs.home-assistant-cli;
      caller = "home-assistant";
      account = "my.1password.com";
      item = "op://Private/home-assistant/credential";
      envVar = "HASS_TOKEN";
      extraReads.HASS_SERVER = "op://Private/home-assistant/hostname";
    };
    # The MCP server Claude Code launches (registered project-scope as
    # `home-assistant` in the repo's .mcp.json, so only sessions in this
    # repo spawn it); packages/ha-mcp explains the uvx pin.
    ha-mcp = {
      pkg = unstable-pkgs.ha-mcp;
      caller = "home-assistant";
      account = "my.1password.com";
      item = "op://Private/home-assistant/credential";
      envVar = "HOMEASSISTANT_TOKEN";
      extraReads.HOMEASSISTANT_URL = "op://Private/home-assistant/hostname";
      # Managed YAML editing (ha_config_set_yaml: backup + validation) and the
      # file tools. Both are beta-gated server-side AND need the companion
      # "HA-MCP File & YAML Tools" component (HACS:
      # homeassistant-ai/ha-mcp-integration) installed in HA; without it the
      # tools never register. The component confines file writes to HA's
      # www, themes, custom_templates and dashboards dirs; config YAML is
      # read-only there and only changes through ha_config_set_yaml -- which
      # writes ONLY an allowlist of YAML-only integration keys (template,
      # rest, command_line, sensor, mqtt, ...). Any other top-level key (it
      # refused a dead `ltss:` block) is still a hand edit for the user.
      extra = ''
        export ENABLE_BETA_FEATURES=true
        export ENABLE_YAML_CONFIG_EDITING=true
        export HAMCP_ENABLE_FILESYSTEM_TOOLS=true
      '';
    };
  };

  # One tiny fork+exec+wait binary PER op-cached consumer. 1Password names its
  # authorization prompt after `op`'s PARENT process (resolved via
  # /proc/<ppid>/exe), so a script caller always surfaced as its interpreter:
  # every prompt read ".../python3.13", and the grant 1Password remembered was
  # pinned to that shared interpreter -- i.e. to every Python script on the box.
  # A named binary per consumer makes the prompt say "op-1p-bk" and confines the
  # grant to that one caller. bins/op-1p-shim.c explains why it forks, not execs.
  #
  # "unknown" is the fallback for any caller that does not pass `--as`, so the
  # prompt still never degrades back to naming the interpreter.
  #
  # These are deliberately NOT on PATH: op-cached-daemon invokes them by
  # absolute store path via @opShimPaths@, and that substituted text is also
  # what keeps them in the daemon's runtime closure.
  #
  # THE N COPIES CANNOT COLLAPSE INTO SYMLINKS to one build, however tempting:
  # 1Password resolves the caller name through /proc/<ppid>/exe, which
  # FOLLOWS symlinks to the real store path -- all the prompts would silently
  # read the same name again and share one grant, which is the exact bug this
  # exists to fix.
  opShimCallers = [
    "bk"
    "sentry"
    "home-assistant"
    "unknown"
  ];
  opShims = lib.genAttrs opShimCallers (
    caller:
    # runCommandCC rather than writeCBin so the shim compiles under
    # -Wall -Wextra -Werror: this is the only C in the repo and no other
    # linter covers it, and a program juggling fork/setsid/waitpid/fds has
    # earned the warnings. (Verified clean 2026-08-07.)
    pkgs.runCommandCC "op-1p-${caller}" { } ''
      mkdir -p $out/bin
      $CC -Wall -Wextra -Werror -O2 -o "$out/bin/op-1p-${caller}" ${./bins/op-1p-shim.c}
    ''
  );
  opShimPaths = builtins.toJSON (lib.mapAttrs (caller: drv: "${drv}/bin/op-1p-${caller}") opShims);

  # Python scripts can't use writeShellApplication, so read the real file and
  # substitute @tokens@ for the store paths they need (interpreter + tools).
  py =
    name: subs:
    pkgs.writeScriptBin name (
      builtins.replaceStrings (map (n: "@${n}@") (builtins.attrNames subs)) (builtins.attrValues subs) (
        builtins.readFile (./bins + "/${name}.py")
      )
    );

  # The op-cached pair, let-bound so consumers can DECLARE the dependency
  # (runtimeInputs / substituted store path) instead of gambling on ambient
  # PATH -- the daemon's WRAPPER_OP comment records what that gamble did to
  # `op`; the same rule now applies one level up.
  op-cached-daemon = py "op-cached-daemon" {
    python3 = "${pkgs.python313}/bin/python3";
    inherit opShimPaths;
  };
  op-cached = py "op-cached" {
    python3 = "${pkgs.python313}/bin/python3";
    opCachedDaemon = "${op-cached-daemon}/bin/op-cached-daemon";
  };

  # Optional opTools fields: `caller` (shim/grant name, default the tool's
  # own), `account` (default koordinates), `extraReads` (more envVar ->
  # op:// pairs, fetched exactly like the token), `extra`.
  opWrapper =
    name: t:
    let
      caller = t.caller or name;
      account = t.account or "koordinates.1password.com";
      reads = {
        ${t.envVar} = t.item;
      }
      // (t.extraReads or { });
    in
    sh {
      inherit name;
      # The real CLI first (the wrapper execs it by bare name; runtimeInputs
      # PREPENDS, so the package wins over this wrapper's own name), then
      # op-cached as a declared sibling dep.
      runtimeInputs = [
        t.pkg
        op-cached
      ];
      bashOptions = [
        "errexit"
        "nounset"
      ];
      text = ''
        ${t.extra or ""}# Assign then export separately so a failing op-cached (errexit)
        # aborts here rather than being masked by export's own exit status
        # (shellcheck SC2155). --as ${caller} picks the
        # op-1p-${caller} shim, so 1Password's prompt names ${caller} rather
        # than the daemon's Python interpreter (see bins/op-1p-shim.c).
        ${lib.concatStrings (
          lib.mapAttrsToList (var: item: ''
            ${var}="$(op-cached read --as ${caller} --account ${account} "${item}")"
            export ${var}
          '') reads
        )}
        exec ${name} "$@"
      '';
    };

  # Field-exact process matcher (the sanctioned replacement for the banned
  # `pgrep -f` — see its header). A named binding rather than an inline list
  # entry so the scripts that depend on it can carry it in runtimeInputs.
  kx-proc-find = sh {
    name = "kx-proc-find";
    runtimeInputs = [ ];
    bashOptions = [ "nounset" ];
  };

  # The shared pool-presence guard (unit-loaded, never cgroup-dir) -- see its
  # header for why the -d form is a trap.
  kx-pool-loaded = sh {
    name = "kx-pool-loaded";
    runtimeInputs = [ pkgs.systemd ];
    bashOptions = [ "nounset" ];
  };

  # Let-bound because the weekly timer below runs it: a systemd unit has no
  # ambient PATH worth trusting, and ExecStart wants the derivation's own
  # store path (the same reason the governor and semaphore units in
  # cgroups.nix pin their scripts rather than naming them).
  wt-reap = sh {
    name = "wt-reap";
    runtimeInputs = [
      pkgs.git
      pkgs.gawk
      pkgs.coreutils
    ];
    bashOptions = [ "nounset" ];
  };

  # Let-bound because claude-agents INVOKES it (command -v guard + call): as
  # an undeclared sibling it resolved by ambient PATH, and "not on PATH"
  # degraded to silently skipping the reattach -- whose documented worst case
  # is the escaped fleet as the largest memory consumer during a stall.
  claude-agents-reattach = sh {
    name = "claude-agents-reattach";
    runtimeInputs = [
      pkgs.systemd
      pkgs.procps
      pkgs.gnugrep
      pkgs.coreutils
      kx-proc-find
      kx-pool-loaded
    ];
    bashOptions = [ "nounset" ];
  };
in
# The lint tripwire reads the opShimCallers literal above; this assert binds
# it to the generator's consumer list so the two can never disagree.
# builtins-only ON PURPOSE: this assert sits in the module's structural
# position, which the module system forces before resolving module args --
# touching `lib` (= pkgs.lib, a module arg) here is an infinite recursion.
assert builtins.all (n: builtins.elem (opTools.${n}.caller or n) opShimCallers) (
  builtins.attrNames opTools
);
{
  home.packages = [
    (sh {
      name = "koordinates-dev-protocol";
      # jq: JSON-escapes the attacker-influenced URL into the request body.
      runtimeInputs = [
        pkgs.curl
        pkgs.jq
      ];
      bashOptions = [ "nounset" ];
    })
    # Voice-assistant chord relay to the VMware host; reads the host's LAN
    # address from machine-local state (~/.config/kx/host-ip) so the public
    # tree carries no addresses.
    (sh {
      name = "kx-host-hotkey";
      runtimeInputs = [
        pkgs.curl
        pkgs.libnotify
      ];
      bashOptions = [ "nounset" ];
    })
    (sh {
      name = "dev-terminal";
      runtimeInputs = [
        pkgs.tmux
        pkgs.coreutils
      ];
      bashOptions = [ "nounset" ];
    })
    (sh {
      name = "scratch-terminal";
      runtimeInputs = [ pkgs.tmux ];
      bashOptions = [
        "errexit"
        "nounset"
      ];
    })
    (sh {
      name = "rush-logs";
      runtimeInputs = [
        pkgs.jq
        pkgs.perl
        pkgs.bat
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.fzf
      ];
      bashOptions = [
        "errexit"
        "nounset"
      ];
    })
    (sh {
      name = "rush-pnpm";
      runtimeInputs = [ pkgs.coreutils ];
      bashOptions = [
        "errexit"
        "nounset"
      ];
    })
    (sh {
      name = "autosquash-branch";
      runtimeInputs = [ pkgs.git ];
      bashOptions = [
        "errexit"
        "nounset"
      ];
    })
    (sh {
      name = "wt-cgroup-status";
      runtimeInputs = [
        pkgs.gawk
        pkgs.coreutils
        # flock: the SEM line counts queued jobs by probing their queue
        # markers, which is safe on a marker in a way it never is on a slot
        # (sem_waiting says why). Undeclared, the probe would die inside its
        # own `2>/dev/null` and every queue would read as empty.
        pkgs.util-linux
      ];
      bashOptions = [ "nounset" ];
    })
    # Worktree lifecycle, not the cgroup pool -- the pool budgets what a
    # worktree may consume while it runs, this reclaims what it left behind.
    # Deliberately NOT errexit: every git probe it makes (rev-list against a
    # detached HEAD, `worktree remove` on a corrupt admin dir) is allowed to
    # fail into a decision, and the writeShellApplication errexit default
    # would turn each of those into a fatal instead.
    wt-reap
    # Client half of the build admission semaphore (controller lives in
    # cgroups.nix). Deliberately NOT errexit: the slot scan relies on
    # `flock -n` failing on a busy slot, which is the normal path, not an
    # error.
    (sh {
      name = "kx-build-slot";
      # No gawk: --help extraction is pure bash now, in line with the script's
      # own depend-on-nothing rule (probe_pids' grep story).
      runtimeInputs = [
        pkgs.util-linux
        pkgs.coreutils
      ];
      bashOptions = [ "nounset" ];
    })
    kx-proc-find
    kx-pool-loaded
    # The documented recovery command for a wedged build ("run cgroup-thaw-all
    # by hand") -- the script is a service asset under scripts/, so this is
    # its on-PATH face. CGLIB is pinned to the shared lib's store path here
    # for the same reason the governor unit pins it in Environment=: this
    # copy lands in a store bin dir with no cgroup-lib.sh sibling, so the
    # dirname fallback never resolves and the hand-run recovery command was
    # warning and using a divergent inline glob copy on every invocation.
    (sh {
      name = "cgroup-thaw-all";
      text = ''
        CGLIB="''${CGLIB:-${../scripts/cgroup-lib.sh}}"
        export CGLIB
      ''
      + builtins.readFile ../scripts/cgroup-thaw-all.sh;
      runtimeInputs = [ pkgs.coreutils ];
      bashOptions = [ "nounset" ];
    })
    (sh {
      name = "claude-agents";
      runtimeInputs = [
        pkgs.systemd
        pkgs.coreutils
        kx-proc-find
        kx-pool-loaded
        claude-agents-reattach
        unstable-pkgs.claude-code
      ];
      bashOptions = [ "nounset" ];
    })
    (sh {
      name = "claude-usage";
      runtimeInputs = [
        pkgs.curl
        pkgs.jq
        pkgs.gnugrep
        pkgs.gawk
        pkgs.coreutils
        unstable-pkgs.claude-code
      ];
      bashOptions = [ "nounset" ];
    })
    claude-agents-reattach

    op-cached-daemon
    op-cached
    (py "wt-cgroup-i3status" {
      python3 = "${pkgs.python313}/bin/python3";
      i3status = "${pkgs.i3status}/bin/i3status";
      i3statusConf = "${i3statusConf}";
      # THE page-cache correction (scripts/cgroup-mem.py), shared with the
      # build-semaphore controller, which gets the same file as
      # KX_CGROUP_MEM_LIB in cgroups.nix. The bar and the semaphore MUST agree
      # on what "pool memory in use" means -- they disagreed for as long as
      # both read memory.current raw, and the bar showing a full pool while
      # builds were being refused is what that looked like from outside.
      memlib = "${../scripts/cgroup-mem.py}";
    })
    # `ccusage` on PATH is this caching wrapper; the real binary
    # (packages/ccusage) is reachable only through it, so the two can't
    # collide in the profile.
    (py "ccusage" {
      python3 = "${pkgs.python313}/bin/python3";
      ccusage = "${unstable-pkgs.ccusage}/bin/ccusage";
    })
  ]
  ++ lib.mapAttrsToList opWrapper opTools;

  # Weekly worktree reap. The disk did not fill because anything failed; it
  # filled because nothing was ever reclaiming worktrees, and the ~2.5G each
  # accumulates faster than it is noticed (79 of them inside 6 days). A
  # calendar is the right trigger BECAUSE the reaper's own criterion is
  # already conservative -- it removes only worktrees that add no commits and
  # carry no changes, so firing it often costs nothing and firing it rarely
  # is how this happened.
  #
  # --yes, not an interactive prompt: nobody is at a terminal. --no-size is
  # implied by the non-dry-run path (the du pass over ~80 node_modules trees
  # dominates the runtime and its output would go to the journal unread).
  systemd.user.services.wt-reap = {
    Unit.Description = "Reap agent worktrees holding no commits and no changes";
    Service = {
      Type = "oneshot";
      ExecStart = "${wt-reap}/bin/wt-reap --yes";
      # Bulk unlink of ~80 node_modules trees; stay out of the way of
      # anything interactive.
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.user.timers.wt-reap = {
    Unit.Description = "Weekly worktree reap";
    Install.WantedBy = [ "timers.target" ];
    Timer = {
      OnCalendar = "weekly";
      # The box is a VM that is not always up at the nominal hour; without
      # this the timer silently skips the weeks it was off -- which is the
      # same "looks configured, reclaims nothing" failure this whole change
      # exists to fix.
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
