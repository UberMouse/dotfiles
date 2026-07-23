{ pkgs, unstable-pkgs, unstable-small-pkgs, ... }:

let
  # Mirror of i3status's compiled-in default config (the same modules the bar
  # showed before) but with output_format forced to i3bar, so i3status emits
  # COLORED JSON blocks. The wt-cgroup-i3status wrapper passes those blocks
  # through untouched and prepends the worktree block. Without this, i3status
  # run behind the wrapper's pipe auto-detects "not i3bar" and drops to
  # uncoloured plain text.
  i3statusConf = pkgs.writeText "i3status.conf" ''
    general {
            colors = true
            interval = 5
            output_format = "i3bar"
    }

    order += "ipv6"
    order += "wireless _first_"
    order += "ethernet _first_"
    order += "battery all"
    order += "disk /"
    order += "cpu_usage"
    order += "load"
    order += "memory"
    order += "tztime local"

    wireless _first_ {
            format_up = "W: (%quality at %essid) %ip"
            format_down = "W: down"
    }

    ethernet _first_ {
            format_up = "E: %ip (%speed)"
            format_down = "E: down"
    }

    battery all {
            format = "%status %percentage %remaining"
    }

    disk "/" {
            format = "%avail"
    }

    cpu_usage {
            format = "CPU %usage"
            degraded_threshold = 60
            max_threshold = 85
    }

    load {
            format = "%1min"
    }

    memory {
            format = "%used | %available"
            threshold_degraded = "1G"
            format_degraded = "MEMORY < %available"
    }

    tztime local {
            format = "%Y-%m-%d %H:%M:%S"
    }
  '';

  # Bash scripts live as real files under ./bins and are compiled with
  # writeShellApplication (bare commands, tools supplied via runtimeInputs,
  # shellcheck + `bash -n` enforced at build). bashOptions is set PER SCRIPT to
  # exactly match the `set` flags each script historically ran with: several
  # deliberately run WITHOUT errexit (they rely on commands failing mid-run),
  # so the writeShellApplication default of errexit+nounset+pipefail would
  # change their behaviour. inheritPath (default true) keeps the ambient profile
  # PATH appended, so sibling-script calls (bk -> op-cached, rush-pnpm -> node)
  # keep resolving exactly as before.
  sh = { name, runtimeInputs ? [ ], bashOptions, excludeShellChecks ? [ ] }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs bashOptions excludeShellChecks;
      text = builtins.readFile (./bins + "/${name}.sh");
    };

  # Python scripts can't use writeShellApplication, so read the real file and
  # substitute @tokens@ for the store paths they need (interpreter + tools).
  py = name: subs:
    pkgs.writeScriptBin name (
      builtins.replaceStrings
        (map (n: "@${n}@") (builtins.attrNames subs))
        (builtins.attrValues subs)
        (builtins.readFile (./bins + "/${name}.py"))
    );
in
{
  home.packages = [
    (sh { name = "koordinates-dev-protocol"; runtimeInputs = [ pkgs.curl ]; bashOptions = [ ]; })
    (sh { name = "dev-terminal"; runtimeInputs = [ pkgs.tmux pkgs.coreutils ]; bashOptions = [ ]; })
    (sh { name = "scratch-terminal"; runtimeInputs = [ pkgs.tmux ]; bashOptions = [ "errexit" ]; })
    (sh {
      name = "rush-logs";
      runtimeInputs = [ pkgs.jq pkgs.perl pkgs.bat pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.fzf ];
      bashOptions = [ "errexit" ];
    })
    (sh { name = "rush-pnpm"; runtimeInputs = [ pkgs.coreutils ]; bashOptions = [ "errexit" ]; })
    (sh { name = "bk"; runtimeInputs = [ pkgs.buildkite-cli ]; bashOptions = [ "errexit" ]; })
    (sh { name = "sentry"; runtimeInputs = [ unstable-pkgs.sentry ]; bashOptions = [ "errexit" ]; })
    (sh { name = "autosquash-branch"; runtimeInputs = [ pkgs.git ]; bashOptions = [ "errexit" ]; })
    (sh { name = "wt-cgroup-status"; runtimeInputs = [ pkgs.gawk pkgs.coreutils ]; bashOptions = [ "nounset" ]; })
    (sh {
      name = "claude-agents";
      runtimeInputs = [ pkgs.systemd unstable-small-pkgs.claude-code ];
      bashOptions = [ "nounset" ];
    })
    (sh {
      name = "claude-usage";
      runtimeInputs = [ pkgs.curl pkgs.jq pkgs.gnugrep pkgs.gawk pkgs.coreutils unstable-small-pkgs.claude-code ];
      bashOptions = [ "nounset" ];
    })

    (py "op-cached-daemon" { python3 = "${pkgs.python313}/bin/python3"; })
    (py "op-cached" { python3 = "${pkgs.python313}/bin/python3"; })
    (py "wt-cgroup-i3status" {
      python3 = "${pkgs.python313}/bin/python3";
      i3status = "${pkgs.i3status}/bin/i3status";
      i3statusConf = "${i3statusConf}";
    })
  ];
}
