{ system ? builtins.currentSystem, config, pkgs, lib, unstable-pkgs, ... }:

{
  imports = [ ./i3.nix ./neovim.nix ./zsh.nix ./scriptBins.nix ];
  nixpkgs.config.allowUnfreePredicate = (pkg: true);
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "taylorl";
  home.homeDirectory = "/home/taylorl";

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "24.05";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  home.sessionVariables = {
    EDITOR = "nvim";
    BROWSER = "vivaldi";
    TERMINAL = "alacritty";
  };

  home.packages = with pkgs; [
    # System
    git
    curl
    htop
    i3
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
    meslo-lgs-nf
    lsof
    pstree
    sysstat
    rinetd
    gnuplot

    # Dev
    nodejs_22
    nodePackages."@microsoft/rush"
    nodePackages."http-server"
    nodePackages.pnpm
    shellcheck
    nix-prefetch-git
    git-machete
    git-absorb
    python313
    pdal
    python313Packages.pip
    wasm-pack
    rustup
    jq
    amazon-ecr-credential-helper
    gh
    awscli2
    yarn
    delta
    fx
    axel
    sysbench
    direnv
    nixfmt-classic
    zsh-powerlevel10k
    nixd
    (callPackage ./kart.nix {})

    # Apps
    slack
    vivaldi
    qgis
    firefox
    google-chrome
    qdirstat
  ] ++ [
    unstable-pkgs.playwright-test
    unstable-pkgs.code-cursor
  ];

  fonts.fontconfig = { enable = true; };

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
        mimeType = [ "x-scheme-handler/koordinates" ];
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
      init.defaultBranch = "main";

      gpg = {
        format = "ssh";
      };
      "gpg \"ssh\"" = {
        program = "${lib.getExe' pkgs._1password-gui "op-ssh-sign"}";
      };
      commit = {
        gpgsign = true;
      };
      user = {
        signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwOTjGNXctN6zgV6LazHoOcsd+cT2qFy+H8UOOWm7rm";
      };
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

    plugins = with pkgs.tmuxPlugins; [ yank resurrect ];

    extraConfig = ''
      bind h split-window -v -c "#{pane_current_path}"
      bind v split-window -h -c "#{pane_current_path}"
    '';
  };

  programs.vscode = {
    enable = true; 
    package = unstable-pkgs.vscode-fhs;
  };

  programs.bash = { enable = true; };
  
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;

    nix-direnv.enable = true;
  };

  programs.alacritty = {
    enable = true;
    settings = {
      colors.primary.background = "#1F1626";
      font.normal.family = "MesloLGS NF";
    };
  };
  
  programs.ssh = {
    enable = true;
    extraConfig = ''
      Host *
          IdentityAgent ~/.1password/agent.sock
    '';
  };
}
