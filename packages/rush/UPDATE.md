---
name: rush
version_check: npm view @microsoft/rush version
version_file: packages/rush/package.nix
changelog_github: microsoft/rushstack
---

# Update Process

`rush` is built from a local `package.json` that pins `@microsoft/rush` and is
installed via `buildNpmPackage` (no `src` tarball — `src = ./.`). Updating means
bumping the pinned dependency, regenerating the lock, and refreshing
`npmDepsHash`.

1. Bump the pinned dependency in `packages/rush/package.json`:
   - `dependencies."@microsoft/rush"` → new version

2. Regenerate the lock file:
   ```bash
   cd ~/dotfiles/packages/rush && npm install --package-lock-only
   ```

3. Edit `packages/rush/package.nix`:
   - `version` → new version
   - `npmDepsHash` → placeholder: `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`

4. Attempt build — it will fail printing the correct `npmDepsHash`:
   ```bash
   sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
   ```

5. Extract the correct `npmDepsHash` from the error output, update
   `packages/rush/package.nix`, and rebuild.
