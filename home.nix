{ config, pkgs, lib, ... }:

{
  nixpkgs.config.allowUnfreePredicate = (pkg: true);
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "taylor";
  home.homeDirectory = "/home/taylor";

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "22.11";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  home.sessionVariables = {
    # Enables loading of .desktop files for nix controlled apps
    XDG_DATA_DIRS = "$HOME/.nix-profile/share:$XDG_DATA_DIRS";
    LD_LIBRARY_PATH = "${lib.makeLibraryPath [ pkgs.libuuid ]}:$LD_LIBRARY_PATH";
  };
  
  home.packages = with pkgs; [
    # System
    git
    curl
    htop
    i3
    powerline-fonts
    gcc
    gnumake
    perl
    openvpn
    fzf
    keychain
    xclip
    libuuid
    rename
    fd
    ripgrep
    bat
    inotify-tools
    
    # Dev
    nodejs-18_x
    nodePackages."@microsoft/rush"  
    nodePackages."http-server"
    nix-prefetch-git
    git-machete
    python310
    python310Packages.pip
      
    # Apps
    slack
    vivaldi
    qgis
  ];
  
  fonts.fontconfig = {
    enable = true;
  };

  xdg = {
    enable = true;

    mimeApps = {
      enable = true;
      
      defaultApplications = {
        "default-web-browser" = [ "vivaldi-stable.desktop" ];
        "x-www-browser" = [ "vivaldi-stable.desktop" ];
        "x-scheme-handler/https" = [ "vivaldi-stable.desktop" ];
        "x-scheme-handler/http" = [ "vivaldi-stable.desktop" ];
      };
    };
  };
  
  programs.git = {
    enable = true;
    userName = "Taylor Lodge";
    userEmail = "taylor.lodge@koordinates.com";
    
    extraConfig = {
      pull.ff = "only";
    };
  };
  
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    
    defaultCommand = "fd";

    tmux.enableShellIntegration = true;
  };
  
  programs.tmux = {
    enable = true;
    clock24 = true;
    mouse = true;
    newSession = true;
    prefix = "C-Space";
    terminal = "screen-256color";
    keyMode = "vi";
    shell = "${pkgs.zsh}/bin/zsh";
    
    plugins = with pkgs.tmuxPlugins; [
      yank
      resurrect
    ];

    extraConfig = ''
      bind h split-window -v -c "#{pane_current_path}"
      bind v split-window -h -c "#{pane_current_path}"
    '';
  };
  
  programs.vscode = {
    enable = true;
  };

  programs.gnome-terminal = {
    enable = true;
    profile.taylor = {
      default = true;
      visibleName = "taylor";
      font = "Roboto Mono for Powerline";
    };
  };

  programs.bash = {
    enable = true;
  };
}
