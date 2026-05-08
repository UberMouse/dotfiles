# Execution order

This change should be implemented mostly sequentially because type definitions and metadata shape changes affect later refactors.

1. **Subagent override support** (`subagents.ts`)
   - Add override type/input field and config merge helper.
   - No source behavior should change without overrides.

2. **Metadata type expansion and machine metadata** (`index.ts`)
   - Remove `PromptKind`/`prompt.kind` entirely per review feedback; do not keep compatibility kind.
   - Add prompt instruction text and subagent allowed role/override metadata.

3. **Prompt and role lookup refactors** (`index.ts`)
   - Replace `phasePrompt` switch with metadata instruction assembly.
   - Replace `allowedSubagentRoles` switch with metadata lookup.
   - Pass state role override into subagent runner.

4. **Remaining metadata cleanup** (`index.ts`)
   - Convert execution-order submit guard/event to metadata if straightforward.
   - Preserve transition semantics.

5. **Documentation update** (`README.md`)
   - Document new fields and remove `prompt.kind` docs.

6. **Validation**
   - Run `cd pi/extensions/changeflow && npm run check`.

No parallel source-editing subagents are needed for this MVP.