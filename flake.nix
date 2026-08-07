{
  description = "My NixOS Configuration";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Two channels only. unstable-small existed solely for a fresher
    # claude-code, but claude-code's version is pinned by our own manifest
    # override (packages/default.nix) -- the channel's freshness was buying
    # nothing while costing a third nixpkgs eval and weekly lock churn.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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

  outputs =
    {
      nixpkgs,
      home-manager,
      playwright,
      self,
      nixpkgs-unstable,
      kolide-launcher,
      ...
    }:
    let
      system = "x86_64-linux";
      # Custom packages are auto-discovered from packages/*/package.nix (plus
      # the claude-code manifest override) -- see packages/default.nix. The
      # overlay is the single declaration site; `packages` below derives its
      # attr list from the same source, so the two cannot drift.
      custom = import ./packages { inherit (nixpkgs) lib; };
      overlay =
        final: prev:
        {
          inherit (playwright.packages.${system})
            playwright-driver
            playwright-test
            ;
        }
        // custom.overlay final prev;
      unstable-pkgs = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
        overlays = [ overlay ];
      };
    in
    {
      nixosConfigurations.ubermouse = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit unstable-pkgs self; };

        modules = [
          # Hardware first, generic policy second: nixos.nix stays reusable for
          # a future second host whose nixosConfiguration differs only here.
          ./work-vm.nix
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

      # treefmt wrapping nixfmt-rfc-style: `nix fmt` formats the whole tree.
      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt-tree;

      # The custom packages, buildable in isolation: `nix build .#claude-code`
      # verifies a version/hash bump in seconds instead of a full system
      # switch. The attr list comes from the overlay's own discovery, and
      # every package resolves from the SAME channel the system installs
      # from -- when claude-code came from unstable here but unstable-small
      # in home.nix, this command verified a different derivation than the
      # one that ran (identical only by coincidence of the two channels'
      # revs).
      packages.${system} = nixpkgs.lib.genAttrs custom.names (n: unstable-pkgs.${n});

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

                # Repo-specific tripwires. Each of these encodes a rule that was
                # once broken silently (see CLAUDE.md's standing traps):
                #  1. pgrep -f is banned (kx-proc-find is the replacement)
                #  2. /home/taylorl literals in nix (one allowed definition)
                #  3. the pool cgroup path must carry the KX_POOL override
                #  4. every repo path CLAUDE.md names must exist (docs-liveness)
                python3 ${./scripts/lint-tripwires.py}
                touch $out
              '';
        };
    };
}
