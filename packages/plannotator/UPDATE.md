---
name: plannotator
version_check: gh api repos/backnotprop/plannotator/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/plannotator/package.nix
changelog_github: backnotprop/plannotator
---

# Update Process

1. Bump version + binary hash in one step:
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} plannotator
   ```

2. Verify in isolation (the derivation runs `plannotator --version` as an
   install check):
   ```bash
   nix build --no-link .#plannotator
   ```

3. Update the Claude Code plugin (not flake-managed; touches `~/.claude/plugins/`):
   ```bash
   claude plugin update plannotator@plannotator
   ```
