{
  description = "My NixOS Configuration";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-unstable-small.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    playwright = {
      # Pentusha's fork — pinned to 1.59.1 (auto-update 2026-04-11).
      # Upstream pietdevries94 is stuck on 1.59.0 and is missing `hyphen` from
      # webkit's buildInputs, so autoPatchelf fails on libhyphen.so.0.
      # Switch back to pietdevries94 once it merges a fix.
      url = "github:Pentusha/playwright-web-flake/7dc3142cbecb769843182d18eb851338a550c209";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kolide-launcher = {
      url = "github:/kolide/nix-agent/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, playwright, self, nixpkgs-unstable, nixpkgs-unstable-small, kolide-launcher, ... }:
    let
      system = "x86_64-linux";
      overlay = final: prev: {
        inherit (playwright.packages.${system})
          playwright-driver playwright-test;
        claude-code = final.callPackage ./packages/claude-code/package.nix {};
        playwright-cli = final.callPackage ./packages/playwright-cli/package.nix {};
        plannotator = final.callPackage ./packages/plannotator/package.nix {};
        grackle = final.callPackage ./packages/grackle/package.nix {};
        monodex = final.callPackage ./packages/monodex/package.nix {};
      };
      pkgs = import nixpkgs {
        inherit system;
      };
      unstable-pkgs = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
        overlays = [ overlay ];
      };
      unstable-small-pkgs = import nixpkgs-unstable-small { inherit system; config.allowUnfree = true; overlays = [ overlay ]; };
    in {
      nixosConfigurations.ubermouse = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit unstable-pkgs unstable-small-pkgs;  };

        modules = [
          ./nixos.nix
          kolide-launcher.nixosModules.kolide-launcher
          home-manager.nixosModules.home-manager
          {
            home-manager.extraSpecialArgs = { inherit unstable-pkgs unstable-small-pkgs; };
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            home-manager.users.taylorl = import ./home.nix;
          }
        ];
      };
    };
}
