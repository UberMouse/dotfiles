---
name: ccstatusline
version_check: npm view ccstatusline version
version_file: packages/ccstatusline/package.nix
changelog_github: sirmalloc/ccstatusline
---

# Update Process

1. Get tarball hash:
   ```bash
   nix-prefetch-url --unpack "https://registry.npmjs.org/ccstatusline/-/ccstatusline-${VERSION}.tgz"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Edit `packages/ccstatusline/package.nix`:
   - `version` → new version
   - `src.hash` → SRI hash from step 1

3. Verify in isolation:
   ```bash
   nix build .#ccstatusline && ./result/bin/ccstatusline --help >/dev/null
   ```
