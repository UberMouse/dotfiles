{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Host identity + bootloader target live here with the rest of the hardware
  # config (moved from nixos.nix 2026-08-07): a second host differs in exactly
  # these values, and the bootloader config was previously split across two
  # files (device/useOSProber generic-side, enableCryptodisk below).
  networking.hostName = "ubermouse";
  boot.loader.grub.enable = true;
  boot.loader.grub.device = (import ./host-facts.nix).rootDisk;
  boot.loader.grub.useOSProber = true;

  virtualisation.vmware.guest.enable = true;

  # File exchange with the Windows host via VMware Shared Folders (HGFS):
  # every share enabled under the host's VM Settings > Options > Shared
  # Folders appears, live and two-way, as a subdirectory of ~/host. Mounted
  # per-user rather than as a fileSystems entry so the files belong to the
  # session user without a uid in the mount options -- the uid isn't declared
  # anywhere (NixOS allocates it), so a system mount would need it hand-copied.
  # libfuse calls the setuid fusermount3 wrapper by absolute path, so no PATH
  # plumbing is needed for an unprivileged mount. NTFS carries no unix owner,
  # so without uid=/gid= every file lists as root:root (writable regardless,
  # mode 777); %U/%G are systemd's own specifiers for the unit's user, so the
  # ids still aren't written down.
  #
  # With Shared Folders off on the host, vmhgfs-fuse exits "Error -107 cannot
  # open connection"; the retry means enabling them there is the only step,
  # no restart needed here. on-failure, not always: a deliberate
  # `fusermount3 -u` exits cleanly and stays unmounted.
  systemd.user.services.hgfs = {
    description = "VMware shared folders from the host, at ~/host";
    wantedBy = [ "default.target" ];
    unitConfig.ConditionVirtualization = "vmware";
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/host";
      ExecStart = "${lib.getExe' config.virtualisation.vmware.guest.package "vmhgfs-fuse"} .host:/ %h/host -f -o auto_unmount,uid=%U,gid=%G";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "mptspi"
    "uhci_hcd"
    "ehci_pci"
    "ahci"
    "sd_mod"
    "sr_mod"
  ];
  boot.kernelModules = [ "kvm-amd" ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/d27125c8-7941-4200-ab15-d98967d353da";
    fsType = "ext4";
  };

  boot.initrd.luks.devices = {
    "luks-27ddb793-a6f2-4209-badd-63e7dc7d5ca1" = {
      device = "/dev/disk/by-uuid/27ddb793-a6f2-4209-badd-63e7dc7d5ca1";
      keyFile = "/boot/crypto_keyfile.bin";
    };
    "luks-3c6ce26c-a5ed-4390-8749-40b4cfd3a3ab" = {
      device = "/dev/disk/by-uuid/3c6ce26c-a5ed-4390-8749-40b4cfd3a3ab";
      keyFile = "/boot/crypto_keyfile.bin";
    };
  };
  boot.initrd.secrets = {
    "/boot/crypto_keyfile.bin" = null;
  };
  boot.loader.grub.enableCryptodisk = true;

  swapDevices = [ { device = "/dev/disk/by-uuid/8911731a-9365-486d-9f77-e7b633ebd56e"; } ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
