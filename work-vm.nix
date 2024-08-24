{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];
  virtualisation.vmware.guest.enable = true;
  boot.initrd.availableKernelModules =
    [ "ata_piix" "mptspi" "uhci_hcd" "ehci_pci" "ahci" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/d27125c8-7941-4200-ab15-d98967d353da";
    fsType = "ext4";
  };

  boot.initrd.luks.devices."luks-27ddb793-a6f2-4209-badd-63e7dc7d5ca1".device =
    "/dev/disk/by-uuid/27ddb793-a6f2-4209-badd-63e7dc7d5ca1";

  swapDevices =
    [{ device = "/dev/disk/by-uuid/8911731a-9365-486d-9f77-e7b633ebd56e"; }];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.ens33.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  boot.initrd.luks.devices."luks-3c6ce26c-a5ed-4390-8749-40b4cfd3a3ab".device =
    "/dev/disk/by-uuid/3c6ce26c-a5ed-4390-8749-40b4cfd3a3ab";
  # Setup keyfile
  boot.initrd.secrets = { "/boot/crypto_keyfile.bin" = null; };

  boot.loader.grub.enableCryptodisk = true;

  boot.initrd.luks.devices."luks-27ddb793-a6f2-4209-badd-63e7dc7d5ca1".keyFile =
    "/boot/crypto_keyfile.bin";
  boot.initrd.luks.devices."luks-3c6ce26c-a5ed-4390-8749-40b4cfd3a3ab".keyFile =
    "/boot/crypto_keyfile.bin";
}
