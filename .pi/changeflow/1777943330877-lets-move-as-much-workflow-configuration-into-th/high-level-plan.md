# High-level plan: metadata-driven Changeflow configuration

## Goal
Make the Changeflow state machine definition the primary source of workflow configuration by moving phase-specific hardcoded behavior into serializable `meta.changeflow` properties wherever practical. This includes phase prompts/instructions, allowed subagent roles, and per-phase/per-role subagent model/effort/prompt/tool overrides.

## Approach

1. **Extend state metadata types in `pi/extensions/changeflow/index.ts`**
   - Add serializable metadata fields for:
     - prompt content/instructions instead of only `prompt.kind`
     - allowed subagent roles for the current state
     - subagent role overrides/config scoped to a phase
     - lifecycle submission behavior where still hardcoded, e.g. execution ordering event/path if appropriate
   - Preserve existing fields (`autoContinue`, `editPolicy`, `reviewGate`, `submission`, `plannotator`) and keep all metadata JSON-serializable because it is persisted in workflow files.

2. **Move phase prompt bodies into `machineDefinition` metadata**
   - Replace the large `phasePrompt()` switch with generic prompt assembly:
     - common workflow header/orchestrator instructions
     - feedback/artifact context
     - metadata-provided phase instructions
   - Keep shared boilerplate in code if useful, but phase-specific text should live in each state’s `meta.changeflow`.

3. **Move allowed subagent roles into metadata**
   - Replace `allowedSubagentRoles(state)` switch with metadata lookup.
   - Add role arrays to agent-owned states such as `research`, planning states, `execution_ordering`, `executing`, and `qa`.
   - Keep review/wait states with no roles by default.

4. **Support metadata-driven subagent configuration**
   - Keep default role definitions in `pi/extensions/changeflow/subagents.ts` as reusable defaults.
   - Add a merge path so `index.ts` can resolve phase metadata overrides and pass effective subagent config to `runChangeflowSubagent`.
   - Support at least model, thinking/effort level, tools, and system prompt overrides while maintaining current safety defaults.

5. **Reduce remaining state-name checks where metadata already describes behavior**
   - Inspect direct checks like execution-order submission and convert them to metadata-driven lookups when the state machine can express the behavior clearly.
   - Avoid over-abstracting one-off lifecycle mechanics if metadata would make the code less readable.

6. **Update documentation**
   - Update `pi/extensions/changeflow/README.md` State metadata and Subagent orchestration sections to document new metadata fields and defaults/override behavior.

## Files likely to change
- `pi/extensions/changeflow/index.ts`
- `pi/extensions/changeflow/subagents.ts`
- `pi/extensions/changeflow/README.md`

## Risks / considerations
- Metadata is persisted into `.pi/changeflow/<workflow-id>/workflow.json`; new config must stay serializable.
- Prompt text in metadata can make `machineDefinition` larger, so structure/readability matters.
- Subagent overrides must not accidentally loosen safety constraints in non-execution phases.
- Existing workflows may contain older persisted machine definitions, but runtime currently uses the canonical in-code `machineDefinition` for helpers/transitions, so compatibility risk is moderate.

## Verification
- Run `cd pi/extensions/changeflow && npm run check`.
- Manually inspect that phase prompts still include correct instructions for research/planning/execution/QA/review waits.
- Confirm subagent role validation still blocks invalid roles and allows expected roles per phase.
- Confirm subagent metadata includes requested model/config when overrides are specified.