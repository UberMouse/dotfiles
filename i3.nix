{ lib, ... }:

let
  mod = "Mod4";
in
{
  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = mod;

      # Bottom bar: run our wrapper as status_command so a worktrees.slice
      # cgroup-usage block renders to the left of the normal i3status output.
      # This mirrors the home-manager default bar verbatim (mode, position, colors,
      # tray) and only swaps statusCommand -- specifying `bars` at all resets the
      # whole block to per-field defaults, so the styling must be restated here.
      bars = [
        {
          mode = "dock";
          hiddenState = "hide";
          position = "bottom";
          workspaceButtons = true;
          workspaceNumbers = true;
          statusCommand = "wt-cgroup-i3status";
          fonts = {
            names = [ "monospace" ];
            size = 8.0;
          };
          trayOutput = "primary";
          colors = {
            background = "#000000";
            statusline = "#ffffff";
            separator = "#666666";
            focusedWorkspace = {
              border = "#4c7899";
              background = "#285577";
              text = "#ffffff";
            };
            activeWorkspace = {
              border = "#333333";
              background = "#5f676a";
              text = "#ffffff";
            };
            inactiveWorkspace = {
              border = "#333333";
              background = "#222222";
              text = "#888888";
            };
            urgentWorkspace = {
              border = "#2f343a";
              background = "#900000";
              text = "#ffffff";
            };
            bindingMode = {
              border = "#2f343a";
              background = "#900000";
              text = "#ffffff";
            };
          };
        }
      ];

      keybindings = lib.mkOptionDefault {
        "${mod}+t" = "scratchpad show";
        "${mod}+Shift+s" = "exec --no-startup-id maim -s | xclip -selection clipboard -t image/png";
        # Fire the voice-assistant hotkey on the Windows host. The script
        # reads the host's LAN address from ~/.config/kx/host-ip
        # (machine-local, deliberately untracked -- this repo is public);
        # see scriptBins/bins/kx-host-hotkey.sh.
        "Shift+F3" = "exec --no-startup-id kx-host-hotkey";
      };

      startup = [
        { command = "slack"; }
        { command = "vivaldi"; }
        # 1password is NOT started here: it is a supervised user service below.
        # Tray app that may never map a window: without --no-startup-id i3
        # waits on a startup notification that never comes (busy cursor).
        {
          command = "whatpulse";
          notification = false;
        }
      ];

      assigns = {
        "1: web" = [ { class = "^Vivaldi-stable$"; } ];
        "2: slack" = [ { class = "^Slack$"; } ];
        "5: rimu" = [ { class = "^Koordinates$"; } ];
      };
    };

    extraConfig = ''
      exec --no-startup-id "i3-msg 'workspace \"3: dev\"; split v; append_layout ${./i3-workspaces/dev.json}'"
      exec alacritty -e dev-terminal

      for_window [class="^Chromium-browser$"] move to workspace number 4
      for_window [class="^Koordinates$" window_role="devtools"] move to workspace number 6

      # Scratchpad terminal
      exec --no-startup-id alacritty --class scratchpad-terminal -e scratch-terminal
      for_window [class="^scratchpad-terminal$"] move to scratchpad
    '';
  };

  # 1Password is supervised rather than an i3 `startup` entry because it EXITS
  # BY DESIGN whenever an inotify watch sees its store directory change
  # ("Application binary and/or it's directory was moved or replaced,
  # exiting.") -- and nix-optimise's hardlink dedup is exactly such a change.
  # The optimise timer catches up a few minutes after boot, so the first boot
  # after a 1Password bump re-links its libs under the running app and takes
  # the SSH agent (git signing, ssh, pam sudo) down with it. Observed
  # 2026-10-13: dedup at 09:00:29, exit at 09:00:31. Restart=always (not
  # on-failure: the exit code of that path is unverified) brings it back; the
  # cost is that a tray Quit relaunches too -- stop the unit instead.
  # /run/current-system/sw/bin, not a store path, so a restart after an
  # upgrade picks up the new version. --silent: start to the tray, so a
  # relaunch doesn't steal focus; the agent prompts to unlock on first use.
  systemd.user.services."1password" = {
    Unit = {
      Description = "1Password (supervised: exits when nix-optimise relinks its files)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = "/run/current-system/sw/bin/1password --silent";
      Restart = "always";
      RestartSec = 2;
    };
  };
}
