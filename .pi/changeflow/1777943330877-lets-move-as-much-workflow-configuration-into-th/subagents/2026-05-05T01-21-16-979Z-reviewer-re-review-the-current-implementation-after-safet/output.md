Re-review findings:

- **High / blocking: prior tool-broadening issue is only partially fixed.**  
  `pi/extensions/changeflow/subagents.ts:165-172` filters override tools to the base role allowlist, which prevents adding `edit/write` to read-only roles. However, if an override supplies `tools: []` or only invalid tool names, `config.tools` becomes empty. Then `runChangeflowSubagent` skips `--tools` entirely at `subagents.ts:272`, and Pi defaults to all built-in tools (`read,bash,edit,write,grep,find,ls`). That re-broadens tools and bypasses the intended safety boundary.

  **Action:** ensure empty narrowed toolsets do not omit the allowlist. Either:
  - pass `--no-tools` when `config.tools.length === 0`, or
  - reject empty/invalid override toolsets and fall back to the base allowlist.

- **Prior prompt replacement issue appears addressed.**  
  `systemPrompt` overrides are now appended after the base role safety prompt rather than replacing it (`subagents.ts:167-169`). That fixes the direct replacement concern.

Validation run:

- `cd pi/extensions/changeflow && npm run check` passes.

Conclusion: **not ready yet** due to the remaining empty-tools override escape hatch.