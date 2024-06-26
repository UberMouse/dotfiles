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
  home.stateVersion = "23.05";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  home.sessionVariables = {
    # Enables loading of .desktop files for nix controlled apps
    XDG_DATA_DIRS = "$HOME/.nix-profile/share:$XDG_DATA_DIRS";
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    KAWAKA_SKIP_PLAYWRIGHT_FIREFOX = "1";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1"; 
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
    unixtools.ifconfig
    glibc
    libuuid
    tree
    xautolock
    
    # Dev
    nodejs_20
    nodePackages."@microsoft/rush"  
    nodePackages."http-server"
    nodePackages."@githubnext/github-copilot-cli"
    nodePackages.pnpm
    nix-prefetch-git
    git-machete
    git-absorb
    python310
    pdal
    python310Packages.pip
    playwright-test
    wasm-pack
    rustup
    jq
    amazon-ecr-credential-helper
    gh
    awscli2
    yarn
    delta
    fx
      
    # Apps
    slack
    vivaldi
    qgis
    firefox
    chromium
    qdirstat
  ];
  
  fonts.fontconfig = {
    enable = true;
  };
  
  xdg = {
    enable = true;
    mime.enable = true;

    mimeApps = {
      enable = true;
      
      defaultApplications = {
        "default-web-browser" = [ "vivaldi-stable.desktop" ];
        "x-www-browser" = [ "vivaldi-stable.desktop" ];
        "x-scheme-handler/https" = [ "vivaldi-stable.desktop" ];
        "x-scheme-handler/http" = [ "vivaldi-stable.desktop" ];
        "x-scheme-handler/koordinates" = [ "koordinates-dev-protocol.desktop" ];
      };
    };

    desktopEntries = {
      koordinates-dev-protocol = {
        type = "Application";
        name = "Koordinates dev protocol handler";
        exec = "koordinates-dev-protocol %u";
        mimeType = ["x-scheme-handler/koordinates"];
      };
    };
  };
  
  programs.git = {
    enable = true;
    userName = "Taylor Lodge";
    userEmail = "taylor.lodge@koordinates.com";
    
    extraConfig = {
      pull.rebase = "true";
      merge.conflictstyle = "zdiff3";
      rebase.autosquash = "true";
      rerere.enabled = "true";
      core.pager = "delta";
      diff.algorithm = "histogram";
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
    profile = {
      "b1dcc9dd-5262-4d8d-a863-c897e6d979b9" = {
        default = true;
        visibleName = "taylor";
        font = "Source Code Pro for Powerline 10";
      };
    };
  };

  programs.bash = {
    enable = true;
  };
}
