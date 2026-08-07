---
name: claude-code
version_check: npm view @anthropic-ai/claude-code version
version_file: packages/claude-code/package.nix
changelog_url: https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
---

# Update Process

1. Get the source hash (SRI, directly):
   ```bash
   nix store prefetch-file --json "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${VERSION}/linux-x64/claude" | jq -r .hash
   ```

2. Edit `packages/claude-code/package.nix`:
   - `version` → new version
   - `src.hash` → hash from step 1

3. Verify in isolation (the derivation also runs `claude --version` as an
   install check):
   ```bash
   nix build .#claude-code
   ```
