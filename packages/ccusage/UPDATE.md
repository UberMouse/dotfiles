---
name: ccusage
version_check: npm view @ccusage/ccusage-linux-x64 version
version_file: packages/ccusage/package.nix
changelog_github: ryoppippi/ccusage
---

# Update Process

Prebuilt static linux-x64 binary from the `@ccusage/ccusage-linux-x64` npm
tarball (`fetchzip`). Check the native package's version, not the `ccusage`
shim's: the shim is published alongside it, but the binary is what we fetch.

1. Bump version + tarball hash in one step:
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} ccusage
   ```

2. Verify in isolation (the derivation runs `ccusage --version` as an install
   check):
   ```bash
   nix build --no-link .#ccusage
   ```
