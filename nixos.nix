# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, unstable-pkgs, self, ... }:

{
  imports = [ # Include the results of the hardware scan.
    ./work-vm.nix
  ];

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  networking.hostName = "nixos"; # Define your hostname.
  networking.extraHosts = ''
    127.0.0.1 my.dev.kx.gd
    127.0.0.1 wp.dev.kx.gd
  '';

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.download-buffer-size = 134217728; # 128 MB (default is 64 MB)

  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
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
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;
  
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
      "--avoid" "^(vivaldi-bin|slack|\\.claude-wrapped|tabby|zsh|tmux: server|sshd|Xorg|i3|gnome-shell|systemd)$"
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
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
  };
  # =========================================================================

  # Workaround for GNOME autologin: https://github.com/NixOS/nixpkgs/issues/103746#issuecomment-945091229
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    #  wget
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

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # 8003: claude-voice-assistant wrapper daemon (Windows host orchestrator -> VM).
  networking.firewall.allowedTCPPorts = [ 8003 ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
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
  systemd.slices.user.sliceConfig = {
    MemoryAccounting = true;
    MemoryMin = "6G";
  };
  systemd.slices."user-".sliceConfig = {
    MemoryAccounting = true;
    MemoryMin = "6G";
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
        [ -n "$uid" ] && systemctl set-property --runtime "user-$uid.slice" MemoryMin=6G 2>/dev/null || true
        # MemoryMin: desktop RAM never reclaimed. IOLatencyTargetSec: Xorg's disk
        # I/O jumps the queue -- if the session's I/O latency exceeds 50ms the
        # kernel throttles the competing build pool -- so a parallel-build I/O
        # storm (mq-deadline shares one queue) can't stall the desktop.
        systemctl set-property --runtime "session-$s.scope" MemoryMin=6G "IOLatencyTargetSec=/dev/sda 50ms" 2>/dev/null || true
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
