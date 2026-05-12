---
name: pi
version_check: npm view @mariozechner/pi-coding-agent version
version_file: packages/pi-coding-agent/package.nix
changelog_github: badlogic/pi-mono
---

# Update Process

1. Get tarball hash:
   ```bash
   nix-prefetch-url --unpack "https://registry.npmjs.org/@mariozechner/pi-coding-agent/-/pi-coding-agent-${VERSION}.tgz"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Generate package-lock.json:
   ```bash
   cd /tmp && rm -rf pi-update && mkdir pi-update && cd pi-update
   curl -sL "https://registry.npmjs.org/@mariozechner/pi-coding-agent/-/pi-coding-agent-${VERSION}.tgz" | tar -xzf - --strip-components=1
   npm install --package-lock-only
   cp package-lock.json ~/dotfiles/packages/pi-coding-agent/package-lock.json
   ```

3. Edit `packages/pi-coding-agent/package.nix`:
   - `version` → new version
   - `src.hash` → SRI hash from step 1
   - `npmDepsHash` → placeholder: `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`

4. Attempt build — it will fail with correct npmDepsHash:
   ```bash
   sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
   ```

5. Extract correct `npmDepsHash` from error output, update `packages/pi-coding-agent/package.nix`, rebuild.
