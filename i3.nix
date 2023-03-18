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
        { command = "slack"; }
        { command = "vivaldi"; }
        { command = "code"; }
        { command = "gnome-terminal -e tmux"; }
        { command = "setxkbmap -layout us"; }
      ];
      
      assigns = {
        "1: web" = [{ class="^Vivaldi-stable$"; }];
        "2: slack" = [{ class="^Slack$"; }];
        "3: dev" = [{ class="^Code$"; }];
        "5: rimu" = [{ class="^Koordinates$"; }];
      }; 
    };
    
    extraConfig = ''
        for_window [class="^Chromium-browser$"] move to workspace number 4
        for_window [class="^Koordinates$" window_role="devtools"] move to workspace number 6
    '';
  };
}
