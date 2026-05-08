# Detailed implementation plan: metadata-driven Changeflow configuration

## Execution order
Implement sequentially. The type/config changes in `subagents.ts` should happen before `index.ts` calls them, then docs and validation.

## Step 1 — Add subagent config override support in `pi/extensions/changeflow/subagents.ts`

**Goal:** Keep default role definitions reusable, but let `index.ts` pass phase-specific metadata overrides.

**Tasks:**
1. Export a `ChangeflowSubagentConfigOverride` type containing optional:
   - `tools?: string[]`
   - `model?: string`
   - `thinking?: ChangeflowSubagentConfig["thinking"]`
   - `systemPrompt?: string`
2. Add `configOverride?: ChangeflowSubagentConfigOverride` to `ChangeflowSubagentRunInput`.
3. Add a resolver/merge helper, e.g. `resolveSubagentConfig(role, override)`, that merges the default `changeflowSubagentRoles[role]` with override fields.
4. In `runChangeflowSubagent`, replace direct `const config = changeflowSubagentRoles[input.role]` with the resolved config.
5. Ensure metadata JSON still records the effective `tools`, `model`, and requested model.

**Verification:** Typecheck after Step 2/3; inspect that no default behavior changes when no override is passed.

## Step 2 — Extend Changeflow metadata types in `pi/extensions/changeflow/index.ts`

**Goal:** Represent phase-specific workflow behavior in serializable state metadata.

**Tasks:**
1. Import the new override type from `subagents.ts`.
2. Replace or extend `prompt?: { kind: PromptKind }` with metadata that can carry actual phase instructions, e.g.:
   - `prompt?: { instructions?: string }`
   - optionally keep `kind` temporarily only if needed for compatibility, but implementation should consume `instructions`.
3. Add subagent metadata fields, e.g.:
   - `subagents?: { allowedRoles?: ChangeflowSubagentRole[]; roleOverrides?: Partial<Record<ChangeflowSubagentRole, ChangeflowSubagentConfigOverride>> }`
4. Optionally add a generic state submission metadata shape for execution ordering if it improves readability, e.g. artifact path/event/tool mapping. Do not over-abstract if it adds complexity.
5. Remove obsolete `PromptKind` if no longer used.

**Verification:** Types compile locally after machine metadata is updated.

## Step 3 — Move phase prompt instructions into `machineDefinition` metadata

**Goal:** Remove the hardcoded `phasePrompt()` switch.

**Tasks:**
1. For each state with phase instructions, set `meta.changeflow.prompt.instructions` to the current phase-specific text:
   - `research`
   - `high_level_planning`
   - `high_level_user_review`
   - `high_level_revision`
   - `detailed_planning`
   - `detailed_user_review`
   - `execution_ordering`
   - `executing`
   - `qa`
   - `user_validation`
2. Keep common workflow header and shared orchestrator instructions assembled in code, since they are not phase-specific workflow configuration.
3. Refactor `phasePrompt(workflow)` to:
   - build common header
   - append `stateMeta(workflow.state).prompt?.instructions` when present
   - otherwise return common header only
4. Ensure high-level revision can reuse high-level planning instructions by repeating metadata or via a small constant before the machine definition. Prefer readability and serializability of final metadata.

**Verification:** Compare generated prompt behavior conceptually against the old switch: each phase should still instruct the agent to use the right tool/event.

## Step 4 — Move allowed subagent roles into `machineDefinition` metadata

**Goal:** Replace `allowedSubagentRoles()` state switch with metadata lookup.

**Tasks:**
1. Add `subagents.allowedRoles` to relevant states:
   - `research`: `["scout"]`
   - `high_level_planning`, `high_level_revision`, `detailed_planning`: `["planner", "reviewer"]`
   - `execution_ordering`: `["planner"]`
   - `executing`: `["worker", "reviewer"]`
   - `qa`: `["reviewer", "qa"]`
2. Leave review/wait states without allowed roles.
3. Replace `allowedSubagentRoles(state)` switch with:
   - `return stateMeta(state).subagents?.allowedRoles ?? []`
4. In `changeflow_run_subagent`, resolve any role override for the requested role from current state metadata and pass it to `runChangeflowSubagent`.

**Verification:** Invalid role error messages should still report the metadata-derived allowed roles.

## Step 5 — Add example model/thinking/prompt/tool overrides in metadata if appropriate

**Goal:** Demonstrate the requested capability without changing all default behavior unnecessarily.

**Tasks:**
1. Add at least one harmless metadata override if desired, such as a state-local `systemPrompt` for a role that preserves safety rules, or leave overrides empty but fully supported by type/API.
2. If adding examples, choose non-dangerous overrides that do not broaden tools in artifacts-only phases.
3. Avoid hardcoding a model unless the repository has a known desired model. The feature should allow specifying model/effort rather than force a new default.

**Verification:** Subagent metadata should record effective config; no safety regression from defaults.

## Step 6 — Reduce remaining state-name checks where metadata clearly fits

**Goal:** Move additional workflow config out of hardcoded phase checks when it improves clarity.

**Tasks:**
1. Review `index.ts` direct state checks after Steps 3–4.
2. Convert the execution-order submission guard if straightforward by adding metadata to `execution_ordering`, for example `submission` or a dedicated `executionOrder` field with `submittedEvent: "ORDER_DEFINED"` and artifact name.
3. Keep lifecycle-critical or simple checks as code if metadata would obscure behavior.
4. Do not change transition semantics.

**Verification:** Execution ordering still saves `execution-order.md` and transitions with `ORDER_DEFINED`.

## Step 7 — Update `pi/extensions/changeflow/README.md`

**Goal:** Document the new metadata-driven configuration surface.

**Tasks:**
1. Update “State metadata” supported fields to include:
   - prompt instructions/body
   - subagent allowed roles
   - per-role subagent overrides for tools/model/thinking/systemPrompt
2. Update the example metadata block to show these fields.
3. Update “Subagent orchestration MVP” to explain default role configs in `subagents.ts` plus per-phase metadata overrides.
4. If execution-order metadata is added, document it briefly.

**Verification:** README matches actual field names.

## Step 8 — Validate

**Commands:**
```bash
cd pi/extensions/changeflow
npm run check
```

**Manual checks:**
1. Inspect `phasePrompt()` output paths conceptually: current state prompt should include common Changeflow context plus metadata instructions.
2. Confirm source edit blocking still keys off `editPolicy` metadata.
3. Confirm subagent role validation uses `subagents.allowedRoles` metadata.
4. Confirm `runChangeflowSubagent` still uses default configs when no override exists.
5. Confirm any override is merged per role and does not mutate `changeflowSubagentRoles` defaults.

## Risks and mitigations
- **Large machine definition:** Use concise multiline constants or carefully formatted metadata to preserve readability while keeping persisted values serializable.
- **Safety regression:** Defaults stay conservative; metadata role lists should not allow `worker` before `executing`; overrides should not broaden tools in planning/research.
- **Compatibility:** Runtime helpers already use canonical in-code `machineDefinition`, so older workflow files should continue to transition with current behavior.
- **Type complexity:** Keep override types narrow and avoid function-valued metadata.