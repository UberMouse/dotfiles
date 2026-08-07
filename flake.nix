{
  description = "My NixOS Configuration";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-unstable-small.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    playwright = {
      # Pentusha's fork — pinned to 1.62.1 (auto-update 2026-08-02).
      # Upstream pietdevries94 is still behind at 1.61.1 (no 1.62 yet); the fork
      # carries the build fixes (libbacktrace in webkit buildInputs,
      # postPatch sed guards, missing bundle package-lock.json handling).
      # Switch back to pietdevries94 once it ships 1.62.
      url = "github:Pentusha/playwright-web-flake/74974b957d10ad871afb721a06688bd09eb0bbda";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kolide-launcher = {
      # Runs as a root system service, so track a deliberate rev rather than
      # whatever `main` is on flake-update day. Bump by replacing the rev.
      url = "github:kolide/nix-agent/72a0cfaa328f87589a420fa9f2994418f9a46ebd";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, playwright, self, nixpkgs-unstable, nixpkgs-unstable-small, kolide-launcher, ... }:
    let
      system = "x86_64-linux";
      overlay = final: _prev: {
        inherit (playwright.packages.${system})
          playwright-driver playwright-test;
        claude-code = final.callPackage ./packages/claude-code/package.nix {};
        playwright-cli = final.callPackage ./packages/playwright-cli/package.nix {};
        plannotator = final.callPackage ./packages/plannotator/package.nix {};
        ccstatusline = final.callPackage ./packages/ccstatusline/package.nix {};
        rush = final.callPackage ./packages/rush/package.nix {};
        sentry = final.callPackage ./packages/sentry/package.nix {};
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
        specialArgs = { inherit unstable-pkgs unstable-small-pkgs self; };

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

      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;

      # The custom packages, buildable in isolation: `nix build .#claude-code`
      # verifies a version/hash bump in seconds instead of a full system switch.
      packages.${system} = {
        inherit (unstable-pkgs)
          claude-code
          playwright-cli
          plannotator
          ccstatusline
          rush
          sentry
          ;
      };

      checks.${system} =
        let
          checkPkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Builds the full system closure without switching: "did I break my
          # desktop?" as a command instead of a live experiment.
          toplevel = self.nixosConfigurations.ubermouse.config.system.build.toplevel;

          # The deterministic half of the semaphore tests (client side; no
          # controller, no clock). The controller suite is wall-clock timed and
          # stays out of the sandbox — run it via scripts/run-tests.sh.
          kx-build-slot-test =
            checkPkgs.runCommand "kx-build-slot-test"
              {
                nativeBuildInputs = with checkPkgs; [
                  python313
                  bashInteractive
                  util-linux
                  coreutils
                  procps
                  gawk
                  gnugrep
                  gnused
                ];
              }
              ''
                mkdir -p work/scriptBins && cd work
                cp -r ${./scripts} scripts
                cp -r ${./scriptBins/bins} scriptBins/bins
                chmod -R +w .
                python3 scripts/kx-build-slot.test.py
                touch $out
              '';

          lint =
            checkPkgs.runCommand "lint"
              {
                nativeBuildInputs = with checkPkgs; [
                  statix
                  deadnix
                  shellcheck
                  python313
                ];
              }
              ''
                cd ${self}
                statix check .
                deadnix --fail .
                shellcheck scripts/*.sh
                export PYTHONPYCACHEPREFIX=$TMPDIR/pycache
                python3 -m py_compile scripts/*.py scriptBins/bins/*.py
                touch $out
              '';
        };
    };
}
