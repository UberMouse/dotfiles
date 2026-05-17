---
name: plannotator
version_check: curl -fsSL "https://api.github.com/repos/backnotprop/plannotator/releases/latest" | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//'
version_file: packages/plannotator/package.nix
changelog_github: backnotprop/plannotator
---

# Update Process

1. Get binary hash:
   ```bash
   nix-prefetch-url "https://github.com/backnotprop/plannotator/releases/download/v${VERSION}/plannotator-linux-x64"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Edit `packages/plannotator/package.nix`:
   - `version` → new version (without `v` prefix)
   - `src.hash` → SRI hash from step 1

3. Edit `home.nix` line ~128:
   - Update `npm:@plannotator/pi-extension@X.Y.Z` to match the new version

4. Update the Claude Code plugin (not flake-managed; touches `~/.claude/plugins/`):
   ```bash
   claude plugin update plannotator@plannotator
   ```
