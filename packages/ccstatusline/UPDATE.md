---
name: ccstatusline
version_check: npm view ccstatusline version
version_file: packages/ccstatusline/package.nix
changelog_github: sirmalloc/ccstatusline
---

# Update Process

1. Bump version + src hash in one step (no URLs to keep in sync with
   `package.nix` — nix-update reads them from the derivation):
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} ccstatusline
   ```

2. Verify in isolation (the derivation runs `ccstatusline --version` as an
   install check, so a build IS the smoke test):
   ```bash
   nix build --no-link .#ccstatusline
   ```
