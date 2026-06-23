{
  description = "My NixOS Configuration";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-unstable-small.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    playwright = {
      # Pentusha's fork — pinned to 1.60.0 (auto-update 2026-06-02).
      # Upstream pietdevries94 is still stuck on 1.59.1 (no 1.60 yet); the fork
      # carries the 1.60.0 build fixes (libbacktrace in webkit buildInputs,
      # postPatch sed guards, missing bundle package-lock.json handling).
      # Switch back to pietdevries94 once it ships 1.60.
      url = "github:Pentusha/playwright-web-flake/0e70c8bbf456d3cace47eb2d10a6d2ae99fd26fe";
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
        monodex = final.callPackage ./packages/monodex/package.nix {};
        ccstatusline = final.callPackage ./packages/ccstatusline/package.nix {};
        pi-coding-agent = final.callPackage ./packages/pi-coding-agent/package.nix {};
        rush = final.callPackage ./packages/rush/package.nix {};
        sentry = final.callPackage ./packages/sentry/package.nix {};
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
