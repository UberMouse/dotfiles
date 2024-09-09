{
  description = "My NixOS Configuration";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    playwright.url = "github:pietdevries94/playwright-web-flake/1.47.0";
    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, playwright, self, nixpkgs-unstable, ... }:
    let
      system = "x86_64-linux";
      overlay = final: prev: {
        inherit (playwright.packages.${system})
          playwright-driver playwright-test;
      };
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
      unstable-pkgs = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
    in {
      nixosConfigurations.ubermouse = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit unstable-pkgs; };

        modules = [
          ./nixos.nix

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
