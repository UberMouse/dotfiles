# Detailed implementation plan: dynamically loadable Changeflow workflows

## Revision note
Updated per review feedback: workflow machine definitions should be typed using XState's config types rather than re-creating parallel machine config types. Any local types should describe Changeflow-specific wrapper metadata only.

## Execution model
Implement sequentially. First extract the existing workflow definition without behavior changes, then add registry/selection, then docs/validation.

## Step 1 — Create workflow definition types/module using XState config types

**Goal:** Make the current workflow machine a named definition while relying on XState's own machine config typing.

**Tasks:**
1. Add a new module, e.g. `pi/extensions/changeflow/workflows.ts` or `workflow-definitions.ts`.
2. Import XState machine config typing from `xstate` (for example `type MachineConfig`/appropriate XState v5 config type available from the installed package) instead of defining a parallel `WorkflowMachineConfig` shape.
3. Keep local types limited to Changeflow-specific concepts, e.g.:
   - `type WorkflowState = string` if needed for persisted dynamic state values.
   - `type ChangeflowWorkflowDefinition = { id: string; name?: string; description?: string; initialEvent?: string; machineDefinition: <XState machine config type>; artifactTemplates?: ArtifactTemplate[] }`.
   - `type ArtifactTemplate = { path: string; content: string }`.
4. Reuse/export existing `ChangeflowStateMeta` and `ChangeflowStateConfig` only where needed to type `meta.changeflow`; do not duplicate XState's top-level config model.
5. Keep definition data serializable: no functions inside machine definitions, metadata, or artifact templates.

**Verification:** Typecheck the new wrapper types against `createMachine(definition.machineDefinition)`.

## Step 2 — Move the existing MVP machine into the default definition

**Goal:** Preserve the current workflow as the default dynamically selected definition.

**Tasks:**
1. Move the existing `phaseInstructions` and `machineDefinition` into the new workflow definition module.
2. Export a built-in definition with ID `changeflow.mvp` matching the existing machine ID.
3. Include `initialEvent: "START"` so new snapshots enter `research` as today.
4. Include initial artifact templates equivalent to current startup writes:
   - `research.md`: `# Research: {description}\n\n`
   - `high-level-plan.md`: `# High-level plan: {description}\n\n`
5. Update `index.ts` imports to consume the default definition through the new abstraction.

**Verification:** Default definition's states, transitions, and `meta.changeflow` metadata match the pre-change current machine.

## Step 3 — Add a workflow definition registry

**Goal:** Resolve workflow definitions by ID and expose the default when none is specified.

**Tasks:**
1. Implement helpers such as:
   - `DEFAULT_WORKFLOW_DEFINITION_ID = "changeflow.mvp"`
   - `createWorkflowRegistry(ctx)` / `loadWorkflowDefinitions(ctx)`
   - `getWorkflowDefinition(id?: string)`
   - `listWorkflowDefinitions()`
2. Register the built-in default definition first.
3. Validate definitions at registration/load time using the XState config object:
   - Definition ID is non-empty and unique.
   - `machineDefinition.initial` exists in `machineDefinition.states`.
   - Every transition target references an existing state.
   - Optional `initialEvent` is valid from the initial state.
4. Implement the first external loading mechanism. Prefer safe JSON definitions under `.pi/changeflow/workflows/*.json` for this change, rather than executing arbitrary TypeScript. If TS module loading is chosen instead, document the trust boundary clearly.
5. If no external files exist, registry should still return only the default definition.

**Verification:** Invalid/duplicate definitions are skipped or reported clearly; default registry is always available.

## Step 4 — Persist selected definition ID on workflow instances

**Goal:** Ensure every workflow instance can be restored with the same selected machine.

**Tasks:**
1. Add `workflowDefinitionId: string` (or `definitionId`) to the persisted `Workflow` type.
2. For new workflows, set it to the selected definition ID.
3. For restored older workflows missing the field, default to `DEFAULT_WORKFLOW_DEFINITION_ID`.
4. Continue persisting `machineDefinition` for inspectability/backward compatibility, but treat the selected registry definition as canonical for runtime.
5. Add the definition ID to `CUSTOM_ENTRY` session persistence data and status output.

**Verification:** Existing `.pi/changeflow/*/workflow.json` files can still restore as default.

## Step 5 — Refactor machine/metadata helpers to use selected definitions

**Goal:** Remove single hardcoded `changeflowMachine` and `machineDefinition` assumptions.

**Tasks:**
1. Replace module-level `const changeflowMachine = createMachine(machineDefinition)` with a resolver/cache per definition:
   - `machineForDefinition(definition)` or a `Map<definitionId, machine>`.
2. Replace helpers with definition-aware versions:
   - `workflowDefinition(workflow)`
   - `stateConfig(definition, state)` using `definition.machineDefinition.states[state]`
   - `stateMeta(definitionOrWorkflow, state)` reading `meta.changeflow`
   - `statesMatchingMeta(definition, predicate)` derived from `Object.keys(definition.machineDefinition.states)`
   - `toWorkflowState(definition, value)` runtime-checking state strings against the selected definition
   - `initialWorkflowSnapshot(definition)` using `definition.initialEvent ?? "START"`
3. Update consumers:
   - `saveWorkflow`
   - `applyTransition`
   - `shouldAutoContinue`
   - `phasePrompt`
   - `reviewStateForKind`
   - `reviewKindForState`
   - `submittedEventForKind`
   - `submissionStatesForKind`
   - `allowedSubagentRoles`
   - edit-policy enforcement
   - execution-order submission
4. Keep review/submission behavior metadata-driven so alternative workflows can opt into the same tools by setting metadata.

**Verification:** Grep for direct use of old module-level machine/definition and remove or justify all remaining uses.

## Step 6 — Add workflow selection parsing and commands

**Goal:** Let users specify a workflow when starting, while preserving current default syntax.

**Tasks:**
1. Implement parsing for `/changeflow start` supporting:
   - Current default: `/changeflow start <description>`
   - Explicit workflow: `/changeflow start --workflow <definitionId> <description>`
   - Optional short alias: `-w <definitionId>` if straightforward.
2. If an unknown workflow ID is provided, notify the user and do not create the workflow directory/artifacts.
3. Add `/changeflow workflows` to list registered definitions with ID, name, and default marker.
4. Update `/changeflow status` to include the selected workflow definition ID.
5. Keep `/changeflow advance`, `/changeflow review-plan`, and `/changeflow clear` unchanged except for using definition-aware helpers.

**Verification:** Manual parser cases: default description, explicit workflow, missing workflow ID, invalid workflow ID, missing description.

## Step 7 — Use definition-provided artifact templates during start

**Goal:** Avoid hardcoded artifact initialization in `/changeflow start`.

**Tasks:**
1. Replace the two hardcoded startup `writeFileSync` calls with a loop over `definition.artifactTemplates`.
2. Provide simple template interpolation for at least `{description}` and `{title}`.
3. Ensure the default definition writes the same `research.md` and `high-level-plan.md` content as before.
4. If a definition has no templates, still create the workflow directory and `workflow.json`.

**Verification:** Default workflow artifact files remain identical to current behavior.

## Step 8 — Update docs

**Goal:** Document how multiple workflow definitions are defined and selected.

**Tasks:**
1. Update `pi/extensions/changeflow/README.md` sections for:
   - lifecycle source / workflow definitions
   - commands table (`/changeflow workflows`, `--workflow` on start)
   - workflow definition format using XState machine config
   - artifact templates
2. Document default behavior: no workflow specified means `changeflow.mvp`.
3. Document external loading location/format and validation rules.
4. Document compatibility: older workflows without `workflowDefinitionId` default to `changeflow.mvp`.

**Verification:** README matches actual names, paths, and command syntax.

## Step 9 — Validate and inspect

**Commands:**
```bash
cd pi/extensions/changeflow
npm run check
```

**Manual/inspection checks:**
1. Start path without explicit workflow still uses `changeflow.mvp` and enters `research`.
2. Start path with `--workflow changeflow.mvp` behaves the same.
3. Invalid workflow ID fails before artifact creation.
4. `workflow.json` includes the selected definition ID.
5. `phasePrompt()` includes metadata instructions from the selected definition.
6. `changeflow_submit_*`, `changeflow_submit_execution_order`, and `changeflow_run_subagent` derive allowed states/roles/events/artifact names from the selected definition.
7. Restore/session start defaults old workflows to `changeflow.mvp` and resolves selected definitions for newer workflows.

## Dependencies and ordering
- Steps 1–2 must precede helper refactors.
- Step 3 registry should be in place before workflow persistence/selection changes.
- Step 5 is the main risky refactor; keep it small and typecheck frequently.
- Steps 6–8 depend on the registry and selected definition field.

## Risks and mitigations
- **Snapshot/definition mismatch:** Persist definition ID and use registry definition consistently; default old workflows explicitly.
- **Dynamic states reduce static typing:** Validate states and transition targets at registry load time; derive state lists from XState config definitions.
- **External loader trust:** Prefer JSON definitions for initial implementation or clearly document TS module trust if using code loading.
- **Behavior regression:** Keep `changeflow.mvp` data identical and verify default start path/typecheck.