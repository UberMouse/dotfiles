# Auto-discovery for the custom packages: every packages/<dir>/package.nix
# becomes an overlay attr, so adding a package is ONE directory instead of
# three edit sites (overlay + packages output + this comment's predecessor).
# Before this file, `nix build .#newpkg` failing while `nixos-rebuild`
# worked was the standard forgot-one-site symptom.
#
# Dirs WITHOUT a package.nix are naturally skipped: playwright/ and
# kolide-launcher/ are check-only UPDATE.md specs for flake inputs, and
# claude-code/ carries only a version manifest (below).
{ lib }:
let
  hasPkg = n: builtins.pathExists (./. + "/${n}/package.nix");
  dirs = lib.filterAttrs (n: t: t == "directory" && hasPkg n) (builtins.readDir ./.);
  # nixpkgs' `rush` is GNU Rush, a restricted login shell. Overlaying that
  # name replaced an unrelated package globally, so ours is `rushjs`.
  attrName = n: if n == "rush" then "rushjs" else n;
  discovered = lib.mapAttrs' (
    n: _: lib.nameValuePair (attrName n) (./. + "/${n}/package.nix")
  ) dirs;
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
      # manifest overridden -- ./claude-code/manifest.json is the verbatim
      # upstream manifest for the pinned version, refreshed weekly (see
      # ./claude-code/UPDATE.md). This replaced a 74-line hand-maintained
      # clone of the nixpkgs package that pinned the same versions against
      # a legacy GCS bucket upstream had already migrated off.
      #
      # (The clone also carried `--unset DEV`, which turned out to be
      # fossilized nixpkgs packaging from the 2.0.x era, not a local need --
      # DEV is set nowhere on this box, and nixpkgs dropped the flag too.)
      claude-code = prev.claude-code.override {
        manifest = lib.importJSON ./claude-code/manifest.json;
      };
    };
}
