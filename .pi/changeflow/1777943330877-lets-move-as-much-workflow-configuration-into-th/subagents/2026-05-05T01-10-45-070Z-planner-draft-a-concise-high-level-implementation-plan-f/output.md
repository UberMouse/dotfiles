## High-level implementation plan

### Goal
Move Changeflow workflow-specific configuration out of hardcoded helper switches/maps and into each state’s `meta.changeflow`, making the state machine the single source of truth.

### Current evidence
- `pi/extensions/changeflow/index.ts`
  - `machineDefinition.states.*.meta.changeflow` already contains some workflow config: `autoContinue`, `editPolicy`, `prompt.kind`, `reviewGate`, `plannotator`, `submission`.
  - `phasePrompt()` still hardcodes phase prompt bodies by `prompt.kind`.
  - `allowedSubagentRoles()` hardcodes role permissions by workflow state.
  - Submission state lookup is partially metadata-driven via `submission.reviewKind` / `submittedEvent`.
- `pi/extensions/changeflow/subagents.ts`
  - `changeflowSubagentRoles` hardcodes role names, descriptions, tools, models/thinking, and system prompts.

### Proposed implementation

1. **Extend `ChangeflowStateMeta` in `pi/extensions/changeflow/index.ts`**
   - Add metadata fields such as:
     - `prompt?: { text: string }` or `prompt?: { kind: PromptKind; instructions: string }`
     - `allowedSubagentRoles?: ChangeflowSubagentRole[]`
   - Keep existing fields like `submission`, `reviewGate`, `plannotator`, `editPolicy`.

2. **Populate per-state metadata in `machineDefinition`**
   - Move phase-specific instruction text from `phasePrompt()` switch into the corresponding state’s `meta.changeflow.prompt`.
   - Move role permissions from `allowedSubagentRoles()` into each state’s `meta.changeflow.allowedSubagentRoles`.
   - Example:
     - `research`: `allowedSubagentRoles: ["scout"]`
     - `high_level_planning`: `["planner", "reviewer"]`
     - `executing`: `["worker", "reviewer"]`
     - states without delegation: omit or use `[]`.

3. **Simplify `phasePrompt()`**
   - Keep common workflow/orchestrator prefix generation.
   - Replace the switch with metadata lookup:
     - `const instructions = stateMeta(workflow.state).prompt?.instructions`
     - Return `common + instructions` when present.
   - Preserve latest feedback and artifact directory behavior.

4. **Replace `allowedSubagentRoles()` switch**
   - Implement as:
     - `return stateMeta(state).allowedSubagentRoles ?? []`
   - Keep existing validation flow in `changeflow_run_subagent`.

5. **Evaluate subagent role config location**
   - Short-term: keep `changeflowSubagentRoles` in `subagents.ts` because it is role runtime config, not per-workflow state config.
   - Optional follow-up: define a top-level `changeflow` machine-level metadata object for reusable role config, then pass it into `runChangeflowSubagent`.
   - Risk: XState state `meta` is state-scoped; role definitions may not naturally belong there unless duplicated or placed in machine-level config.

### Likely files
- `pi/extensions/changeflow/index.ts`
  - Type updates
  - `machineDefinition` metadata updates
  - `phasePrompt()` refactor
  - `allowedSubagentRoles()` refactor
- `pi/extensions/changeflow/subagents.ts`
  - Probably unchanged initially
  - Possible later refactor if role configs are also externalized

### Dependencies / ordering
1. Extend metadata types first.
2. Populate metadata in `machineDefinition`.
3. Refactor consumers (`phasePrompt`, `allowedSubagentRoles`).
4. Remove now-unused `PromptKind` if prompt lookup no longer needs it.
5. Run validation.

### Risks
- Prompt text changes could alter workflow behavior subtly.
- Missing `allowedSubagentRoles` metadata could accidentally disable subagents for a phase.
- Duplicating large prompt strings inside `machineDefinition` may reduce readability.
- Moving subagent runtime config into state metadata may create duplication if several states share the same role definitions.

### Verification
- Typecheck/build the extension.
- Start a Changeflow workflow and confirm:
  - research prompt renders correctly
  - high-level/detailed planning prompts render correctly
  - review waiting prompts render correctly
  - subagent role validation matches current behavior
- Grep to confirm hardcoded switches are removed or reduced:
  - `phasePrompt`
  - `allowedSubagentRoles`
  - `prompt.kind`
- Smoke test invalid subagent role error still lists allowed roles.