# High-level plan: dynamically loadable Changeflow workflows

## Goal
Refactor Changeflow so the current hardcoded workflow becomes the default dynamically selected workflow definition, while allowing multiple workflow definitions to be registered/loaded and selected when starting a workflow. If no workflow is specified, behavior should remain equivalent to today.

## Approach

1. **Introduce a workflow definition abstraction**
   - Create a small serializable/runtime wrapper around the XState machine config: definition ID/name, initial event (currently `START`), machine config, and initial artifact templates.
   - Move the existing `machineDefinition` into the default definition (e.g. `changeflow.mvp`).

2. **Add a workflow registry/loader**
   - Provide built-in registration for the current default workflow.
   - Add a loading path for additional definitions (likely project-local files under the Changeflow extension/config area).
   - Keep definitions JSON-serializable where persisted, and reject invalid/duplicate IDs clearly.

3. **Persist and resolve selected definitions per workflow instance**
   - Add a selected workflow definition ID to the persisted `Workflow` record.
   - Refactor helpers that currently use module-level `machineDefinition`/`changeflowMachine` to resolve the definition for `activeWorkflow`.
   - Use the selected definition for transitions, state metadata, prompts, subagent permissions, edit policy, submissions, reviews, and initial snapshots.

4. **Preserve default behavior**
   - `/changeflow start <description>` should still use the current workflow without requiring extra arguments.
   - Existing workflows without a definition ID should be treated as using the default current workflow.

5. **Add workflow selection UX**
   - Extend `/changeflow start` parsing to accept an explicit workflow ID, for example `--workflow <id>`.
   - Add discoverability, such as `/changeflow workflows` or expanded status output showing the selected definition.
   - Invalid workflow IDs should fail before creating artifacts.

6. **Update types to support multiple machines**
   - Move away from assuming the fixed current `WorkflowState` union everywhere a selected definition could vary.
   - Derive valid states from the selected definition’s `states` keys for metadata lookup and validation.
   - Keep constrained unions for stable concepts like review kinds and subagent roles.

7. **Document configuration and selection**
   - Update `pi/extensions/changeflow/README.md` with how the default workflow is defined, how additional workflows are loaded, and how to select one.

## Files likely to change
- `pi/extensions/changeflow/index.ts`
- New workflow-definition/registry module(s), likely under `pi/extensions/changeflow/`
- `pi/extensions/changeflow/README.md`
- `pi/extensions/changeflow/tsconfig.json` if new TypeScript files are added

## Risks
- XState snapshots are tied to the machine definition; persisted workflows must always resolve the same definition ID.
- Making states dynamic can weaken TypeScript guarantees, so runtime validation should be explicit.
- Loader design should avoid executing untrusted arbitrary code unless clearly documented as an extension-level trust boundary.
- Default behavior must not regress for existing `/changeflow start <description>` usage.

## Verification
- Run `cd pi/extensions/changeflow && npm run check`.
- Confirm default start path still produces the same lifecycle and prompts.
- Confirm explicit workflow selection persists the selected definition ID and uses its metadata/transitions.
- Confirm invalid workflow IDs fail clearly and do not create partial workflow artifacts.
- Confirm restore/reload resolves the persisted definition and transitions still work.