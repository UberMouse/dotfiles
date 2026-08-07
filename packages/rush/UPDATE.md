---
name: rush
version_check: npm view @microsoft/rush version
version_file: packages/rush/package.json
# The overlay attr is `rushjs` (plain `rush` would shadow GNU Rush) -- this is
# what `nix build .#<flake_attr>` must use; the default (= name) would fail.
flake_attr: rushjs
changelog_github: microsoft/rushstack
---

# Update Process

`rush` (flake attr `rushjs`) is built from a local `package.json` that pins
`@microsoft/rush` and is installed via `buildNpmPackage`. The pin in
`package.json` is the ONLY version location — `package.nix` derives its
`version` from it. The current version is the value of
`dependencies."@microsoft/rush"`.

1. Bump the pin in `packages/rush/package.json`:
   - `dependencies."@microsoft/rush"` → new version

2. Regenerate the lock file:
   ```bash
   cd ~/dotfiles/packages/rush && npm install --package-lock-only
   ```

3. Compute the new `npmDepsHash` directly from the lock file (no build-fail
   round trip):
   ```bash
   nix run nixpkgs#prefetch-npm-deps -- packages/rush/package-lock.json
   ```
   Put the printed hash in `packages/rush/package.nix` → `npmDepsHash`.

4. Verify in isolation (the derivation runs `rush --version` as an install
   check):
   ```bash
   nix build --no-link .#rushjs
   ```
