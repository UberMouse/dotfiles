# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, unstable-pkgs, self, ... }:

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
    };
  };

  # Enable automatic login for the user.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "taylorl";
  
  services.tailscale.enable = true;
  services.kolide-launcher.enable = true;

  # Kill memory-hungry dev processes before system grinds to a halt
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    enableNotifications = true;
    extraArgs = [
      "--prefer" "(tsgo --lsp|jest-worker)"
    ];
  };

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
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?

}
