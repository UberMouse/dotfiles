{
  description = "Home Manager configuration of taylor";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    playwright.url = "github:pietdevries94/playwright-web-flake/1.41.0";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, playwright, ... }:
    let
      system = "x86_64-linux";
      overlay = final: prev: {
        inherit (playwright.packages.${system})
          playwright-driver
          playwright-test;
      };
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
    in {
      homeConfigurations.taylor = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

        # Specify your home configuration modules here, for example,
        # the path to your home.nix.
        modules = [
          ./home.nix
          ./i3.nix
          ./neovim.nix
          ./zsh.nix
          ./scriptBins.nix
        ];
      };
    };
}
