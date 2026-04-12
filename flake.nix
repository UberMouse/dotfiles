{
  description = "My NixOS Configuration";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-unstable-small.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    playwright = {
      url = "github:pietdevries94/playwright-web-flake/1.58.2";
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
        agent-browser = final.callPackage ./packages/agent-browser/package.nix {};
        plannotator = final.callPackage ./packages/plannotator/package.nix {};
      };
      pkgs = import nixpkgs {
        inherit system;
      };
      unstable-pkgs = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
        overlays = [ overlay ];
      };
      cursor-hash-fix = final: prev: {
        code-cursor = prev.code-cursor.overrideAttrs (old: {
          src = prev.appimageTools.extract {
            pname = "cursor";
            version = old.version;
            src = prev.fetchurl {
              url = "https://downloads.cursor.com/production/475871d112608994deb2e3065dfb7c6b0baa0c54/linux/x64/Cursor-3.0.16-x86_64.AppImage";
              hash = "sha256-dN8tFSppIpO/P0Thst5uaNzlmfWZDh0Y81Lx1BuSYt0=";
            };
          };
        });
      };
      unstable-small-pkgs = import nixpkgs-unstable-small { inherit system; config.allowUnfree = true; overlays = [ overlay cursor-hash-fix ]; };
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
