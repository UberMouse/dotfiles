{
  config,
  pkgs,
  lib,
  unstable-pkgs,
  ...
}:

{
  imports = [
    ./i3.nix
    ./neovim.nix
    ./zsh.nix
    ./scriptBins
    ./cgroups.nix
  ];
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

  home.packages =
    with pkgs;
    [
      # System
      htop
      gcc
      gnumake
      perl
      openvpn
      xclip
      maim
      rename
      fd
      ripgrep
      bat
      inotify-tools
      unixtools.ifconfig
      tree
      lsof
      pstree
      sysstat
      gnuplot
      nautilus
      libnotify

      # Dev
      nodejs_24

      http-server
      pnpm
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
      awscli2
      yarn
      delta
      fx
      axel
      sysbench
      nixfmt
      nixd
      uv
      ngrok

      # Apps
      slack
      vivaldi
      qgis
      firefox
      google-chrome
      qdirstat
      libreoffice
    ]
    ++ [
      unstable-pkgs.gh
      unstable-pkgs.kart
      unstable-pkgs.playwright-test
      unstable-pkgs.playwright-cli
      unstable-pkgs.plannotator
      unstable-pkgs.ccstatusline
      unstable-pkgs.rushjs
      unstable-pkgs.claude-code
    ];

  home.file.".claude/CLAUDE.md".source = ./claude/CLAUDE.md;

  fonts.fontconfig = {
    enable = true;
  };

  xdg = {
    enable = true;
    mime.enable = true;

    mimeApps = {
      enable = true;

      defaultApplications = {
        # No "default-web-browser"/"x-www-browser" keys: those are not MIME
        # types, so xdg-mime silently ignored them -- the scheme-handler and
        # text/html lines below are what actually route URLs.
        "x-scheme-handler/https" = [ "vivaldi-stable.desktop" ];
        "x-scheme-handler/http" = [ "vivaldi-stable.desktop" ];
        "text/html" = [ "vivaldi-stable.desktop" ];
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
    settings = {
      user.name = "Taylor Lodge";
      user.email = "taylor.lodge@koordinates.com";
      user.signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwOTjGNXctN6zgV6LazHoOcsd+cT2qFy+H8UOOWm7rm";
      pull.rebase = "true";
      merge.conflictstyle = "zdiff3";
      rebase.autosquash = "true";
      rerere.enabled = "true";
      core.pager = "delta";
      diff.algorithm = "histogram";
      # Skip whole-tree mechanical reformat commits in blame (repo-relative
      # path: only takes effect in repos that ship the file, like dotfiles).
      blame.ignoreRevsFile = ".git-blame-ignore-revs";
      # Repo-scoped hooks for the dotfiles checkout only: pre-push runs the
      # cheap flake checks (see hooks/pre-push). Declared here rather than
      # in .git/hooks so it survives a clone -- machine-local git state not
      # surviving clones is how 144 MiB of transcripts once got committed.
      "includeIf \"gitdir:~/dotfiles/\"".path = "${pkgs.writeText "dotfiles-hooks.gitconfig" ''
        [core]
        	hooksPath = ~/dotfiles/hooks
      ''}";
      init.defaultBranch = "main";
      gpg.format = "ssh";
      "gpg \"ssh\"".program = "${lib.getExe' pkgs._1password-gui "op-ssh-sign"}";
      commit.gpgsign = true;
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

    plugins = with pkgs.tmuxPlugins; [ yank ];

    extraConfig = ''
      set -g extended-keys on

      bind h split-window -v -c "#{pane_current_path}"
      bind v split-window -h -c "#{pane_current_path}"

      # Send the same command to all panes/windows/sessions
      bind E command-prompt -p "Command:" \
             "run \"tmux list-panes -a -F '##{session_name}:##{window_index}.##{pane_index}' \
                    | xargs -I PANE tmux send-keys -t PANE '%1' Enter\""
    '';
  };

  programs.bash = {
    enable = true;
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;

    nix-direnv.enable = true;

    config.whitelist.prefix = [ "${config.home.homeDirectory}/code/kawaka" ];
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
    enableDefaultConfig = false;
    settings."*" = {
      IdentityAgent = "~/.1password/agent.sock";
    };
  };

  services.dunst = {
    enable = true;
    settings = {
      global = {
        monitor = 0;
        follow = "mouse";
        # dunst 1.7+ geometry syntax. The old `geometry`/`shrink`/
        # `notification_height` keys were removed upstream and silently
        # ignored for years -- the size/position below is what
        # "300x50-20+20" always meant.
        width = 300;
        height = 50;
        origin = "top-right";
        offset = "20x20";
        indicate_hidden = true;
        transparency = 10;
        separator_height = 2;
        padding = 8;
        horizontal_padding = 8;
        frame_width = 2;
        frame_color = "#89b4fa";
        separator_color = "frame";
        sort = true;
        idle_threshold = 120;
        font = "MesloLGS NF 10";
        line_height = 0;
        markup = "full";
        format = "<b>%s</b>\\n%b";
        alignment = "left";
        show_age_threshold = 60;
        word_wrap = true;
        ellipsize = "middle";
        ignore_newline = false;
        stack_duplicates = true;
        hide_duplicate_count = false;
        show_indicators = true;
        icon_position = "left";
        max_icon_size = 32;
        sticky_history = true;
        history_length = 20;
        browser = "vivaldi";
        always_run_script = true;
        title = "Dunst";
        class = "Dunst";
        verbosity = "mesg";
        corner_radius = 5;
      };
      urgency_low = {
        background = "#1F1626";
        foreground = "#cdd6f4";
        timeout = 10;
      };
      urgency_normal = {
        background = "#1F1626";
        foreground = "#cdd6f4";
        timeout = 10;
      };
      urgency_critical = {
        background = "#1F1626";
        foreground = "#f38ba8";
        frame_color = "#f38ba8";
        timeout = 0;
      };
    };
  };

}
