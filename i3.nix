{ lib, pkgs, ... }:

let
  mod = "Mod4";
  # The VMware HOST's LAN address (DHCP; rediscover with `ip route` on the
  # host if it moves). 8004 = the host-side voice-assistant hotkey listener;
  # the reciprocal VM-inbound port 8003 is opened in nixos.nix's firewall.
  hostIp = "192.168.50.16";
in
{
  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = mod;

      # Bottom bar: run our wrapper as status_command so a worktrees.slice
      # cgroup-usage block renders to the left of the normal i3status output.
      # This mirrors the home-manager default bar verbatim (mode/position/colors/
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
        # Fire the voice-assistant hotkey on the Windows host. VMware grabs
        # the keyboard when the VM has focus, so the host's pynput listener
        # never sees the press — this curl shim plumbs it back over HTTP.
        # Matches the host-side chord (lshift+f3) for muscle-memory parity.
        "Shift+F3" =
          "exec --no-startup-id ${pkgs.curl}/bin/curl -fsS -m 2 -X POST -H 'Content-Type: application/json' -d '{\"kind\":\"short\"}' http://${hostIp}:8004/hotkey";
      };

      startup = [
        { command = "slack"; }
        { command = "vivaldi"; }
        { command = "1password"; }
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
}
