---
name: ha-mcp
version_check: curl -fsSL https://pypi.org/pypi/ha-mcp/json | jq -r .info.version
version_file: packages/ha-mcp/package.nix
changelog_github: homeassistant-ai/ha-mcp
---

# Update Process

`package.nix` is a uvx launcher, not a source build: there is no hash. The
pin is TWO values that move together -- the `version = "X.Y.Z"` binding and
the `excludeNewer = "YYYY-MM-DD"` binding (which freezes the transitive
dependency resolution). Bumping one without the other either fails to
resolve (an `excludeNewer` older than the release) or silently leaves the
deps frozen at the previous bump's date.

1. Set both bindings in `packages/ha-mcp/package.nix`:
   ```bash
   sed -i -E \
     -e 's/(version = )"[^"]*"/\1"${VERSION}"/' \
     -e "s/(excludeNewer = )\"[^\"]*\"/\1\"$(date -u +%F)\"/" \
     packages/ha-mcp/package.nix
   ```

2. Build the launcher:
   ```bash
   nix build --no-link .#ha-mcp
   ```

3. Smoke test. The build only proves the wrapper script is valid; this proves
   the pinned release resolves under nixpkgs' python and the server boots.
   Expect `ha-mcp` and `${VERSION}` in the server info, plus a non-zero tool
   count (a dummy URL is fine, since tools/list doesn't contact Home Assistant):
   ```bash
   { printf '%s\n' \
       '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
       '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
       '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 8; } \
   | HOMEASSISTANT_URL=http://127.0.0.1:9 HOMEASSISTANT_TOKEN=dummy \
     timeout 60 "$(nix build --no-link --print-out-paths .#ha-mcp)/bin/ha-mcp" 2>/dev/null \
   | jq -c 'if .id==1 then .result.serverInfo.version else (.result.tools|length) end'
   ```

4. Read the changelog for breaking changes to tool names. Claude Code
   permission allowlists in `~/.claude/settings.json` key on
   `mcp__home-assistant__<tool>`, so a renamed tool goes back to prompting.
