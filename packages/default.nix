# Auto-discovery for the custom packages: every packages/<dir>/package.nix
# becomes an overlay attr, so adding a package is ONE directory instead of
# three edit sites (overlay + packages output + this comment's predecessor).
# Before this file, `nix build .#newpkg` failing while `nixos-rebuild`
# worked was the standard forgot-one-site symptom.
#
# Dirs WITHOUT a package.nix are naturally skipped: playwright/ is a
# check-only UPDATE.md spec for a flake input, and claude-code/ carries only
# a version manifest (below).
{ lib, stable-pkgs }:
let
  hasPkg = n: builtins.pathExists (./. + "/${n}/package.nix");
  dirs = lib.filterAttrs (n: t: t == "directory" && hasPkg n) (builtins.readDir ./.);
  # nixpkgs' `rush` is GNU Rush, a restricted login shell. Overlaying that
  # name replaced an unrelated package globally, so ours is `rushjs`.
  attrName = n: if n == "rush" then "rushjs" else n;
  discovered = lib.mapAttrs' (n: _: lib.nameValuePair (attrName n) (./. + "/${n}/package.nix")) dirs;
in
{
  # Attr names the flake's `packages` output should expose -- derived from
  # the overlay's contents so the two can never drift.
  names = lib.attrNames discovered ++ [ "claude-code" ];

  overlay =
    final: prev:
    lib.mapAttrs (_: path: final.callPackage path { }) discovered
    // {
      # nixpkgs' own claude-code derivation (wrapper env, alsa-lib, install
      # check, canonical downloads.claude.ai CDN), with ONLY the version
      # manifest overridden -- ./claude-code/manifest.zst.json is the verbatim
      # upstream manifest for the pinned version, refreshed weekly (see
      # ./claude-code/UPDATE.md).
      #
      # It must be the ZSTD manifest (binary "claude.zst"): upstream's
      # installPhase runs `unzstd` on the fetched artifact, so the plain
      # uncompressed manifest downloads a raw binary and the build dies with
      # "zstd: unsupported format" -- which is how the 2026-09-07 nixpkgs bump
      # broke this override.
      #
      # This replaced a 74-line hand-maintained clone of the nixpkgs package
      # that pinned the same versions against a legacy GCS bucket upstream had
      # already migrated off.
      #
      # (The clone also carried `--unset DEV`, which turned out to be
      # fossilized nixpkgs packaging from the 2.0.x era, not a local need --
      # DEV is set nowhere on this box, and nixpkgs dropped the flag too.)
      #
      # alsa-lib comes from STABLE, not this overlay's unstable base: the
      # nixpkgs wrapper PREFIXES it onto LD_LIBRARY_PATH, and every process
      # an agent launches inherits that. Unstable's libasound needs unstable's
      # glibc, so any stable-built binary that links libasound -- the
      # playwright browsers (their flake follows stable), ffmpeg -- loaded it
      # over its own RUNPATH and died with "GLIBC_2.43 not found" (2026-10-05,
      # chrome-headless-shell under a Claude session; fine in a plain
      # terminal). glibc is backward-compatible, so the older libasound is
      # safe inside claude itself, while stable's is one every stable-built
      # child can load.
      claude-code = prev.claude-code.override {
        manifest = lib.importJSON ./claude-code/manifest.zst.json;
        inherit (stable-pkgs) alsa-lib;
      };
    };
}
