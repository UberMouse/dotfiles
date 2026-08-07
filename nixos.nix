{ pkgs, self, ... }:

{
  imports = [ # Include the results of the hardware scan.
    ./work-vm.nix
  ];

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  networking.hostName = "nixos";
  networking.extraHosts = ''
    127.0.0.1 my.dev.kx.gd
    127.0.0.1 wp.dev.kx.gd
  '';

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.download-buffer-size = 134217728; # 128 MB (default is 64 MB)

  # Record the flake rev the system was built from (readable via
  # `nixos-version --configuration-revision`).
  system.configurationRevision = self.rev or self.dirtyRev or null;

  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Pacific/Auckland";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_NZ.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_NZ.UTF-8";
    LC_IDENTIFICATION = "en_NZ.UTF-8";
    LC_MEASUREMENT = "en_NZ.UTF-8";
    LC_MONETARY = "en_NZ.UTF-8";
    LC_NAME = "en_NZ.UTF-8";
    LC_NUMERIC = "en_NZ.UTF-8";
    LC_PAPER = "en_NZ.UTF-8";
    LC_TELEPHONE = "en_NZ.UTF-8";
    LC_TIME = "en_NZ.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver = {
    enable = true;
    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [
        i3lock
      ];
    };
    
    # Start authentication agent for i3
    displayManager.sessionCommands = ''
      ${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1 &
    '';
  };

  services.displayManager = { defaultSession = "none+i3"; };
  
  # Screen locker
  programs.xss-lock = {
    enable = true;
    lockerCommand = "${pkgs.i3lock}/bin/i3lock -c 000000";
  };
  
  # Fixes #!/bin/bash -> #!/usr/bin/env bash
  services.envfs.enable = true;

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  # services.xserver.desktopManager.gnome.enable = true; # Disabled - using i3 only

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "nz";
    variant = "";
  };

  # Setup Staff VPN
  services.openvpn.servers.staffVPN.config = '' config /root/nixos/openvpn/staff.conf '';

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Enable gnome keyring for secure storage (needed by 1Password and other apps)
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.gdm.enableGnomeKeyring = true;
  
  # Enable polkit for authentication dialogs
  security.polkit.enable = true;

  # Passwordless sudo via 1Password SSH agent (like passwordless SSH)
  security.pam.rssh = {
    enable = true;
    settings = {
      auth_key_file = "/etc/sudo-keys/$user";
      ssh_agent_addr = "/home/$user/.1password/agent.sock";
    };
  };
  security.pam.services.sudo.rssh = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.taylorl = {
    isNormalUser = true;
    description = "Taylor Lodge";
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.zsh;
    # home-manager manages zsh so this check doesn't work
    ignoreShellProgramCheck = true;
  };

  fonts.packages = with pkgs; [
    nerd-fonts.meslo-lg
  ];

  programs = {
    nix-ld.enable = true;
    
    _1password.enable = true;
    _1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "taylorl" ];
    };
  };

  # Enable automatic login for the user.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "taylorl";
  
  services.tailscale.enable = true;
  services.kolide-launcher.enable = true;

  # === Out-of-memory protection ============================================
  # Primary: nohang (PSI-driven). Acts on memory *pressure* while RAM still
  # has headroom, so the worst hog is SIGTERMed BEFORE the box thrashes into
  # swap (load >60, <2 GB free). Thresholds + victim rules (protect Vivaldi/
  # Slack/Claude/shells, prefer jest workers & headless Playwright Chromium)
  # live in ./nohang/nohang.conf.
  # nohang landed in nixpkgs stable in 26.05, so use the upstream services.nohang
  # module — its systemd hardening is exactly what we mirrored by hand before.
  # configPath points at our tuned config; the package defaults to the stable
  # pkgs.nohang (0.3.0), which matches the config keys in ./nohang/nohang.conf.
  services.nohang = {
    enable = true;
    configPath = ./nohang/nohang.conf;
  };

  # Backstop: earlyoom. Free-memory based (no PSI), so it can only fire once
  # memory AND swap are both nearly gone. With nohang doing the early work this
  # is now a pure last resort (e.g. if nohang itself ever dies). avoid/prefer
  # mirror nohang (earlyoom matches process name / comm only, 15 chars).
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 3;
    freeSwapThreshold = 3;
    enableNotifications = true;
    extraArgs = [
      "--avoid" "^(vivaldi-bin|slack|\\.claude-wrapped|zsh|tmux: server|sshd|Xorg|i3|gnome-shell|systemd)$"
      "--prefer" "^(jest-worker|headless_shell|chrome)$"
    ];
  };

  # === Swap / memory-pressure tuning =======================================
  # Compressed RAM swap (zstd) as the PRIMARY swap, ahead of the slow encrypted
  # disk swap partition (priority -2). Absorbs memory bursts fast with no disk
  # IO or dm-crypt overhead, which is what was driving system load into the 60s.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50; # zram capacity = 50% of RAM (~13.5 GiB uncompressed)
    priority = 100; # used before the disk swap fallback
  };

  boot.kernel.sysctl = {
    # zram is fast and random-access, so favour it over evicting file cache and
    # disable swap read-ahead (the standard zram tuning).
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    # Reclaim earlier/more aggressively so kswapd keeps ahead of allocation
    # spikes instead of dropping into slow direct reclaim (the load spikes).
    #
    # 125 -> 300 (2026-07-21): six desktop stalls between 07-17 and 07-20 all
    # showed the SAME signature in ~/.local/state/cgroup-pressure -- on-disk swap
    # 0 B and desktop memory.current BELOW its 8G memory.min (so its pages were
    # never evicted: memory.min held), but global free RAM collapsed to
    # 172-244 MiB and the desktop stalled in *direct* reclaim on every new page
    # fault. memory.min guarantees the pages you already hold; it cannot
    # manufacture free ones. At wsf=125 on a 27 GiB box kswapd only aims to keep
    # ~750 MiB free, which a parallel build fleet outruns in seconds. 300 raises
    # that target to ~2 GiB, so reclaim happens in kswapd's background thread
    # BEFORE an allocating task has to do it inline. Preferred over lowering the
    # pool's MemoryHigh because that knob seesaws between whole-machine freeze
    # (20G) and perpetual reclaim-throttle crawl (12G) -- see home.nix -- whereas
    # a bigger free buffer costs nothing at idle and no build throughput.
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 300;
    # Headroom for atomic/order-N allocations under the same storms. 66 MiB is
    # the kernel's auto-sized default for this box and is thin once the free
    # buffer above is being actively worked.
    "vm.min_free_kbytes" = 262144; # 256 MiB (was auto: 67584 = 66 MiB)

    # Writeback smoothing. write() only dirties page cache and returns; the disk
    # write happens later, and these two numbers decide when. The ratio defaults
    # (10%/20% of *dirtyable* memory -- free + reclaimable cache, so multiple GB
    # on this box) let a build pile up gigabytes of dirty pages before writeback
    # even STARTS, then dump them in one burst that owns the virtual disk queue;
    # the desktop's next mmap fault (font, .so, browser cache) waits behind it.
    # That is the 2026-07-21 09:55 stall: a worktree wrote 2.35 GB and the
    # desktop hit io.pressure full avg10 29.5% while the pool's own 200 MB/s
    # io.max never bit. io.max throttles WRITEBACK, but dirty pages accumulate in
    # RAM regardless of it, and ext4's jbd2 journal traffic is charged to the
    # root cgroup, not the writer's -- so neither escape route is the pool's to
    # cap. Absolute *_bytes (not ratios) bound the burst regardless of RAM: worst
    # case ~5 s of queue drain instead of ~25 s.
    #
    # TRADEOFF: a shorter window also means fewer writes get coalesced, and
    # short-lived temp files that used to be created+deleted while still dirty
    # (zero disk I/O) now actually hit the platter -- and /tmp here is on the
    # root ext4, not tmpfs. If builds slow measurably, raise the BACKGROUND
    # threshold to 512M-1G and keep dirty_bytes at 1G: the hard ceiling is what
    # protects the desktop, the background one is what costs throughput.
    "vm.dirty_background_bytes" = 268435456; # 256 MiB: start flushing early
    "vm.dirty_bytes" = 1073741824; # 1 GiB: hard ceiling on dirty pages
  };
  # =========================================================================

  # Workaround for GNOME autologin: https://github.com/NixOS/nixpkgs/issues/103746#issuecomment-945091229
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    vim
    curl
    git
  ];

  environment.etc = {
    "1password/custom_allowed_browsers" = {
      text = ''
        vivaldi-bin
        wavebox
      '';
      mode = "0755";
    };
    "sudo-keys/taylorl" = {
      text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA1L9W0vC2KwMVNQpxMo+iS0xg8W/8XVVS2x6RZHIJwT";
      mode = "0644";
    };
  };

  # Preserve SSH_AUTH_SOCK through sudo for 1Password SSH agent auth
  security.sudo.extraConfig = ''
    Defaults env_keep += "SSH_AUTH_SOCK"
  '';

  nix.gc.automatic = true;
  nix.gc.options = "--delete-older-than 21d";

  # 8003: claude-voice-assistant wrapper daemon (Windows host orchestrator -> VM).
  networking.firewall.allowedTCPPorts = [ 8003 ];

  # === Keep the desktop responsive under heavy worktree build load =========
  # The cgroup pool (worktrees.slice, in home-manager) caps CPU and soft-caps
  # memory, but a ~14G build fleet + browser on 27G is memory-OVERSUBSCRIBED:
  # when RAM runs low the kernel's GLOBAL reclaim can swap out Xorg/i3, freezing
  # the whole machine on the next input (measured: system 'memory full' PSI ~=
  # 25-90%, cpu full ~= 0). Fix: GUARANTEE the graphical session's RAM with
  # memory.min so it is never reclaimed -- all the memory pain then falls on the
  # pool, which swaps its own cold node heaps to fast zram instead of the desktop.
  #
  # memory.min is only effective if the WHOLE ancestor chain grants it (a child's
  # protection is capped by its parent's), so set it on user.slice and every
  # user-<uid>.slice. The pool (worktrees.slice) keeps memory.min=0, so it claims
  # none of the guarantee and stays the reclaim target; the session scope claims
  # it (below). Pairs with earlyoom (avoids Xorg/i3, prefers build workers) as the
  # last resort.
  #
  # 8G (raised from 6G): the first desktop-gated pressure event (2026-07-17 14:31)
  # showed the pool bloating to 15G/16G-high let global reclaim brush the desktop's
  # pages ABOVE its 6G floor -- desktop mem PSI touched 15.87% (mild; no disk swap,
  # desktop stayed at 6.6G). The desktop resident set is ~6.6G, so a 6G floor left
  # ~0.6G exposed to reclaim scanning. An 8G floor puts the WHOLE desktop working
  # set under the untouchable band -> global reclaim can't reach it, the pool eats
  # all reclaim to zram. Surgical: does NOT throttle pool builds (memory.high stays
  # 16G); costs the pool ~2G of box headroom before it becomes the sole reclaim
  # target. Tune further from the next (harder) desktop event.
  systemd.slices.user.sliceConfig = {
    MemoryAccounting = true;
    MemoryMin = "8G";
  };
  systemd.slices."user-".sliceConfig = {
    MemoryAccounting = true;
    MemoryMin = "8G";
  };

  # The graphical session lives in a TRANSIENT session-<N>.scope (system-owned,
  # so home-manager/user units can't touch it and the number changes per login).
  # Reassert memory.min on taylorl's x11/wayland session scope at boot and every
  # 5 min. --runtime avoids piling persistent drop-ins per session number.
  systemd.services.desktop-memory-protect = {
    description = "Guarantee the graphical session's RAM (memory.min) + disk I/O priority (io.latency) vs heavy background load";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.systemd pkgs.gawk ];
    script = ''
      set -u
      # memory.min only bites if the WHOLE ancestor chain grants it. user.slice
      # is set statically, but the per-uid user-<uid>.slice is a TEMPLATE INSTANCE
      # whose drop-in only applies on (re)instantiation -- daemon-reload does NOT
      # push it onto the already-running slice -- and the session scope is
      # transient. Assert both live here so the chain is never silently broken.
      loginctl list-sessions --no-legend | awk '{print $1}' | while read -r s; do
        [ -n "$s" ] || continue
        u=$(loginctl show-session "$s" -p Name --value 2>/dev/null)
        t=$(loginctl show-session "$s" -p Type --value 2>/dev/null)
        uid=$(loginctl show-session "$s" -p User --value 2>/dev/null)
        [ "$u" = "taylorl" ] || continue
        case "$t" in x11|wayland) ;; *) continue ;; esac
        # MemoryMin: desktop RAM is never reclaimed (whole ancestor chain).
        # 8G (was 6G): keeps the full ~6.6G desktop working set under the
        # untouchable band so global reclaim from a 15G pool can't brush it.
        [ -n "$uid" ] && systemctl set-property --runtime "user-$uid.slice" MemoryMin=8G 2>/dev/null || true
        systemctl set-property --runtime "session-$s.scope" MemoryMin=8G 2>/dev/null || true
        # io.latency: Xorg's disk I/O jumps the queue -- when the session's I/O
        # latency exceeds 50ms the kernel throttles the competing build pool, so a
        # parallel-build storm (mq-deadline shares one queue) can't stall the
        # desktop. systemd 260 has NO runtime IOLatencyTargetSec property
        # ("Unknown assignment"), so write the cgroup file directly (we are root;
        # the io controller is enabled on the session scope). 8:0=sda, 50000us=50ms.
        scope="/sys/fs/cgroup/user.slice/user-$uid.slice/session-$s.scope"
        [ -w "$scope/io.latency" ] && echo "8:0 target=50000" > "$scope/io.latency" 2>/dev/null || true
      done
    '';
  };
  systemd.timers.desktop-memory-protect = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "45s";
      OnUnitActiveSec = "5min";
    };
  };

  system.stateVersion = "24.05"; # Did you read the comment?

}
