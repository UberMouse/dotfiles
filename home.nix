{ system ? builtins.currentSystem, config, pkgs, lib, unstable-pkgs
, unstable-small-pkgs, ... }:

{
  imports = [ ./i3.nix ./neovim.nix ./zsh.nix ./scriptBins.nix ];
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

  home.packages = with pkgs;
    [
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
      maim
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
      nautilus
      dunst
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
      direnv
      nixfmt
      zsh-powerlevel10k
      nixd
      (callPackage ./kart.nix { })
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
    ] ++ [
      unstable-pkgs.gh
      unstable-pkgs.playwright-test
      unstable-pkgs.playwright-cli
      unstable-pkgs.plannotator
      unstable-pkgs.ccstatusline
      unstable-pkgs.pi-coding-agent
      unstable-pkgs.rush

      unstable-small-pkgs.code-cursor-fhs
      unstable-small-pkgs.claude-code
    ];

  home.file.".claude/CLAUDE.md".source = ./claude/CLAUDE.md;

  home.file.".pi/agent/extensions".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/pi/extensions";
  home.file.".pi/agent/skills".source = ./pi/skills;
  home.file.".pi/agent/prompts".source = ./pi/prompts;
  home.file.".pi/agent/themes".source = ./pi/themes;
  home.file.".pi/agent/settings.json".text = builtins.toJSON {
    defaultProvider = "openai-codex";
    defaultModel = "gpt-5.5";
    defaultThinkingLevel = "medium";
    packages = [
      "npm:pi-web-access@0.10.6"
      "npm:@plannotator/pi-extension@0.23.1"
      "npm:pi-mermaid@0.3.0"
    ];
  };

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
      user.signingKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwOTjGNXctN6zgV6LazHoOcsd+cT2qFy+H8UOOWm7rm";
      pull.rebase = "true";
      merge.conflictstyle = "zdiff3";
      rebase.autosquash = "true";
      rerere.enabled = "true";
      core.pager = "delta";
      diff.algorithm = "histogram";
      init.defaultBranch = "main";
      gpg.format = "ssh";
      "gpg \"ssh\"".program =
        "${lib.getExe' pkgs._1password-gui "op-ssh-sign"}";
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

  programs.vscode = {
    enable = false;
    package = unstable-pkgs.vscode-fhs;
  };

  programs.bash = { enable = true; };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;

    nix-direnv.enable = true;

    config.whitelist.prefix = [ "/home/taylorl/code/kawaka" ];
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
        geometry = "300x50-20+20";
        indicate_hidden = true;
        shrink = false;
        transparency = 10;
        notification_height = 0;
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
        startup_notification = false;
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

  # Claude Code worktree build-daemon resource pool (monorepo-jobs).
  #
  # Global resource pool shared by every worktree's build work. The
  # worktree-setup hook places each worktree's `mj watch` daemon -- and adopts
  # the whole Claude session (claude-<name>.scope) via cgroup ancestry -- into
  # that worktree's OWN slice (worktrees-<name>.slice), a child of this pool, so
  # EVERYTHING the session spawns (Grep tool, MCP, subagents, builds) is budgeted.
  # cgroup v2 hierarchy enforces:
  #   * this pool's caps are a hard ceiling on the WHOLE subtree (all worktrees
  #     combined) -> the OS always keeps headroom;
  #   * each worktree slice's equal weight shares this pool fairly (one busy
  #     worktree gets it all; several busy split it evenly; idle ones cost
  #     nothing), and a worktree's daemon + ad-hoc runs share its single share.
  #
  # Machine-specific policy for this 16-core / 27 GiB host. To re-budget, change
  # ONLY the two numbers below. The committed hook hardcodes no numbers of its
  # own and no-ops entirely if this slice is absent.
  systemd.user.slices.worktrees = {
    Unit = {
      Description = "Claude Code worktree build-daemon resource pool (monorepo-jobs)";
      Documentation = "file:.claude/hooks/worktree-setup.sh";
    };
    Slice = {
      # Hard CPU ceiling on the whole subtree: 12 of 16 cores. Leaves 4 cores
      # for the OS, editor, and browser no matter how many worktrees are
      # building at once.
      CPUAccounting = true;
      CPUQuota = "1200%";

      # Soft memory throttle. This 27 GiB host is memory-OVERSUBSCRIBED when a
      # browser + N parallel worktree builds run (fleet working set ~14 GiB), so
      # this one number seesaws between two failure modes and neither fully wins:
      #   * too HIGH (16G): a peak exhausts global RAM, the kernel reclaims and
      #     swaps out Xorg -> brief whole-machine FREEZE (memory PSI full ~25%,
      #     cpu PSI full 0% -- CPU is never the problem);
      #   * too LOW (12G): the pool sits at its ceiling in perpetual reclaim-
      #     throttle, every allocation gets a penalty delay -> everything CRAWLS
      #     (memory PSI full ~32%, high breached 1700+ times).
      # 16G keeps the pool fast (its ~14G working set fits without reclaim churn
      # -- lowering it to 12G caused perpetual throttle). The FREEZE is now
      # prevented instead by desktop memory.min protection (see nixos.nix:
      # user.slice / user-<uid>.slice / the graphical session scope), which
      # guarantees the desktop's RAM so the pool -- never Xorg -- absorbs reclaim
      # (it swaps its own cold node heaps to fast zram). MemoryMax=18G is a
      # runaway backstop: a pathological fleet gets one OOM-killed build
      # (contained in-pool; earlyoom already prefers build workers) rather than
      # the whole box swapping to death. cgroup-pressure-monitor.service captures
      # forensics + auto-diagnoses each remaining stall so we tune from data.
      MemoryAccounting = true;
      MemoryHigh = "16G";
      MemoryMax = "18G";

      # Hard write cap on the pool's disk I/O. This host's I/O scheduler is
      # mq-deadline, which IGNORES io.weight (only BFQ honours it) -- so an
      # ABSOLUTE io.max is the only thing that actually bounds a parallel-build
      # I/O storm (an io PSI full ~42% stall was traced to exactly this: builds
      # saturating the virtual-disk queue while Xorg waits behind them). Validated
      # live that this throttles BUFFERED writes too (ext4 cgroup-writeback),
      # which is what builds do -- unlike io.weight. 200 MB/s leaves virtual-disk
      # queue headroom; io.latency=50ms on the graphical session scope (nixos.nix)
      # gives Xorg's I/O priority on top. sda is SSD-backed on the host (the VM
      # misreports rotational=1). Tune from cgroup-pressure-monitor snapshots.
      IOAccounting = true;
      IOWriteBandwidthMax = "/dev/sda 200M";
    };
  };

  # Memory/IO pressure monitor. Watches system PSI and, whenever the machine
  # actually stalls (full-avg10 >= 20%), captures a forensic snapshot (per-cgroup
  # memory, top procs by RSS, pool stats, swap) + a desktop alert so a transient
  # freeze/slowdown can be investigated after the fact -- a `ps` run after the
  # event shows nothing. Runs in the user session (NOT worktrees.slice) so it can
  # always capture even while the pool is throttled. Because the machine is
  # memory-oversubscribed this is how we tune MemoryHigh from data, not guesses.
  #
  # CGPM_INVESTIGATE=1 makes each stall also spawn a headless, DIAGNOSE-ONLY
  # `claude -p` (Opus) that reads the snapshot (inlined, no tools) and writes a
  # root-cause analysis + notifies -- "ping Claude on hang". It never touches the
  # system. Snapshots, analyses + events.log land in ~/.local/state/cgroup-pressure/.
  systemd.user.services.cgroup-pressure-monitor = {
    Unit.Description = "cgroup v2 memory/IO pressure monitor (forensic snapshots + claude diagnosis on stall)";
    Install.WantedBy = [ "default.target" ];
    Service = {
      # User services get a bare PATH; give the script the tools it shells out to
      # (incl. claude + git for the auto-diagnosis).
      Environment = [
        "PATH=${lib.makeBinPath [
          pkgs.coreutils pkgs.procps pkgs.gawk pkgs.gnused
          pkgs.util-linux pkgs.findutils pkgs.libnotify
          pkgs.git unstable-small-pkgs.claude-code
        ]}"
        "CGPM_INVESTIGATE=1"
        "CGPM_CLAUDE=${unstable-small-pkgs.claude-code}/bin/claude"
        "CGPM_MODEL=opus"
        "CGPM_INVESTIGATE_COOLDOWN=1800"
      ];
      ExecStart = "${pkgs.bash}/bin/bash ${./scripts/cgroup-pressure-monitor.sh}";
      Restart = "always";
      RestartSec = 10;
      Nice = 10;
    };
  };
}
