{ config, lib, pkgs, ... }:

let 
  mod = "Mod4";
in {
  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = mod;

      keybindings = lib.mkOptionDefault {
	
      };
      
      startup = [
        { command = "xautolock -time 5 -locker i3lock"; notification = false; }
        { command = "slack"; }
        { command = "vivaldi"; }
        { command = "1password"; }
      ];
      
      assigns = {
        "1: web" = [{ class="^Vivaldi-stable$"; }];
        "2: slack" = [{ class="^Slack$"; }];
        "3: dev" = [{ class="^Cursor$"; }];
        "5: rimu" = [{ class="^Koordinates$"; }];
        "6: 1password" = [{ class="^1Password$"; }];
      }; 
    };
    
    extraConfig = ''
        exec --no-startup-id "i3-msg 'workspace \"3: dev\"; append_layout /home/taylorl/dotfiles/i3-workspaces/dev.json'"
        exec cursor
        exec alacritty -e tmux

        for_window [class="^Chromium-browser$"] move to workspace number 4
        for_window [class="^Koordinates$" window_role="devtools"] move to workspace number 6
    '';
  };
}
