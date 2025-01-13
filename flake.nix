{
  description = "My NixOS Configuration";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    playwright = {
      url = "github:pietdevries94/playwright-web-flake/1.48.0";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kolide-launcher = {
      url = "github:/kolide/nix-agent/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, playwright, self, nixpkgs-unstable, kolide-launcher, ... }:
    let
      system = "x86_64-linux";
      overlay = final: prev: {
        inherit (playwright.packages.${system})
          playwright-driver playwright-test;
      };
      pkgs = import nixpkgs {
        inherit system;
      };
      unstable-pkgs = import nixpkgs-unstable { inherit system; config.allowUnfree = true; overlays = [ overlay ]; };
    in {
      nixosConfigurations.ubermouse = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit unstable-pkgs;  };

        modules = [
          ./nixos.nix
          kolide-launcher.nixosModules.kolide-launcher
          home-manager.nixosModules.home-manager
          {
            home-manager.extraSpecialArgs = { inherit unstable-pkgs; };
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            home-manager.users.taylorl = import ./home.nix;
          }
        ];
      };
    };
}
