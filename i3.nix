{ config, lib, pkgs, ... }:

let 
  mod = "Mod4";
in {
  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = mod;

      keybindings = lib.mkOptionDefault {
        "${mod}+t" = "scratchpad show";
        "${mod}+Shift+s" = "exec --no-startup-id maim -s | xclip -selection clipboard -t image/png";
        # Fire the voice-assistant hotkey on the Windows host. VMware grabs
        # the keyboard when the VM has focus, so the host's pynput listener
        # never sees the press — this curl shim plumbs it back over HTTP.
        # Matches the host-side chord (lshift+f3) for muscle-memory parity.
        "Shift+F3" = "exec --no-startup-id ${pkgs.curl}/bin/curl -fsS -m 2 -X POST -H 'Content-Type: application/json' -d '{\"kind\":\"short\"}' http://192.168.50.16:8004/hotkey";
      };
      
      startup = [
        { command = "slack"; }
        { command = "vivaldi"; }
        { command = "1password"; }
      ];
      
      assigns = {
        "1: web" = [{ class="^Vivaldi-stable$"; }];
        "2: slack" = [{ class="^Slack$"; }];
        "3: dev" = [{ class="^Cursor$"; }];
        "5: rimu" = [{ class="^Koordinates$"; }];
      }; 
    };
    
    extraConfig = ''
        exec --no-startup-id "i3-msg 'workspace \"3: dev\"; split v; append_layout /home/taylorl/dotfiles/i3-workspaces/dev.json'"
        exec alacritty -e dev-terminal

        for_window [class="^Chromium-browser$"] move to workspace number 4
        for_window [class="^Koordinates$" window_role="devtools"] move to workspace number 6

        # Scratchpad terminal
        exec --no-startup-id alacritty --class scratchpad-terminal -e scratch-terminal
        for_window [class="^scratchpad-terminal$"] move to scratchpad
    '';
  };
}
