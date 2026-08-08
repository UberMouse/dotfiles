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
      inputs.nixpkgs.follows = "nixpkgs";
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
      # Host identity (username) comes from the same single-declaration file
      # as the hardware facts: the string used to be restated here, in
      # home.nix and in nixos.nix independently, so a rename half-applied --
      # this site would still point home-manager at the old user.
      facts = import ./host-facts.nix;
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

            home-manager.users.${facts.user} = import ./home.nix;
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

          # Every deterministic suite, discovered by glob (a hardcoded list is
          # how a new suite silently never runs) — including the controller
          # MACHINERY suite, which runs main() in a thread with a stepping
          # sleep stub (flock and /proc/locks work in the sandbox). Its
          # genuinely host-only checks (kernel signal delivery, flock drop on
          # real process death) are opted into by run-tests.sh via
          # KX_TEST_HOST_ONLY and SKIP loudly here.
          script-tests =
            checkPkgs.runCommand "script-tests"
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
                  # claude-usage.test.py runs the real script, which parses
                  # its fixtures with jq.
                  jq
                ];
              }
              ''
                mkdir -p work/scriptBins && cd work
                cp -r ${./scripts} scripts
                cp -r ${./scriptBins/bins} scriptBins/bins
                chmod -R +w .
                export PYTHONDONTWRITEBYTECODE=1
                for t in scripts/*.test.py; do
                  echo "== $t"
                  python3 "$t"
                done
                touch $out
              '';

          lint =
            checkPkgs.runCommand "lint"
              {
                nativeBuildInputs = with checkPkgs; [
                  statix
                  deadnix
                  shellcheck
                  ruff
                  python313
                ];
              }
              ''
                cd ${self}
                statix check .
                deadnix --fail .
                shellcheck scripts/*.sh
                # ruff is the semantic layer py_compile lacks (undefined
                # names, unused imports); config in ruff.toml. --no-cache:
                # ${self} is a read-only store path.
                ruff check --no-cache scripts/ scriptBins/bins/
                export PYTHONPYCACHEPREFIX=$TMPDIR/pycache
                python3 -m py_compile scripts/*.py scriptBins/bins/*.py

                # Repo-specific tripwires. Each check encodes a rule that was
                # once broken silently (see CLAUDE.md's standing traps and the
                # per-check comments in the script): pgrep/pkill -f, compgen,
                # /home/taylorl literals, KX_POOL overrides, occupancy-guard
                # shape, docs-liveness, spec/fetcher pairing, op-shim roster.
                python3 ${./scripts/lint-tripwires.py}
                touch $out
              '';

          # claude-agents.sh / claude-agents-reattach.sh find the cc-daemon by
          # matching its argv signature (`daemon run --origin`) via
          # kx-proc-find. If a claude-code release renames that argv, the
          # reattach silently no-ops forever and the agent fleet escapes the
          # pool -- forensics have already caught the escaped fleet as the
          # single largest memory consumer during a stall. Assert the literal
          # is still in the shipped bundle (as the JS array form it actually
          # appears in), so the rebuild that bumps claude-code past a rename
          # fails loudly instead. The second signature those scripts match
          # (`*monorepo-jobs* --daemon-run`) belongs to the koordinates
          # monorepo's own daemon and cannot be pinned from this repo; its
          # runtime breadcrumb (REATTACH-EMPTY / DAEMON-WAIT log lines) is
          # the only tripwire possible there.
          claude-daemon-argv =
            checkPkgs.runCommand "claude-daemon-argv" { nativeBuildInputs = [ checkPkgs.gnugrep ]; }
              ''
                grep -r -a -q -F '"daemon","run","--origin"' ${unstable-pkgs.claude-code}/bin/ || {
                  echo 'claude-code no longer contains the daemon-spawn argv literal' >&2
                  echo '"daemon","run","--origin" -- the kx-proc-find signature in' >&2
                  echo 'claude-agents.sh / claude-agents-reattach.sh has drifted; fix both.' >&2
                  exit 1
                }
                touch $out
              '';

          # `nix flake check` must fail on an unformatted tree, or the
          # formatter output is advisory and the next whole-tree reformat
          # commit (plus .git-blame-ignore-revs entry) is only a matter of
          # time. The tree is copied because --fail-on-change still WRITES
          # the formatted result before erroring, and ${self} is read-only.
          formatting =
            checkPkgs.runCommand "formatting" { nativeBuildInputs = [ self.formatter.${system} ]; }
              ''
                cp -r ${self} tree
                chmod -R +w tree
                cd tree
                treefmt --tree-root=. --fail-on-change --no-cache
                touch $out
              '';
        };
    };
}
