---
name: kart
version_check: gh api repos/koordinates/kart/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/kart/package.nix
changelog_github: koordinates/kart
---

# Update Process

Prebuilt linux-x86_64 tarball from GitHub Releases, patchelf'd against the
runtime libs listed in `package.nix`.

1. Bump version + tarball hash in one step:
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} kart
   ```

2. Verify in isolation (the derivation runs `kart --version` as an install
   check — the banner exercises GDAL/PROJ/PDAL plugin loading, so a passing
   build is a real smoke test):
   ```bash
   nix build --no-link .#kart
   ```
   If autoPatchelf fails on a new missing library, add it to `buildInputs`
   (the list is hand-maintained; the comment above it explains the pins).
