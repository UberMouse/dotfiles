---
name: plannotator
version_check: gh api repos/backnotprop/plannotator/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/plannotator/package.nix
changelog_github: backnotprop/plannotator
---

# Update Process

1. Get the binary hash (SRI, directly):
   ```bash
   nix store prefetch-file --json "https://github.com/backnotprop/plannotator/releases/download/v${VERSION}/plannotator-linux-x64" | jq -r .hash
   ```

2. Edit `packages/plannotator/package.nix`:
   - `version` → new version (without `v` prefix)
   - `src.hash` → hash from step 1

3. Verify in isolation:
   ```bash
   nix build .#plannotator
   ```

4. Update the Claude Code plugin (not flake-managed; touches `~/.claude/plugins/`):
   ```bash
   claude plugin update plannotator@plannotator
   ```
