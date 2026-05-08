# High-level plan: migrate Changeflow state machine to XState

## Goal

Replace Changeflow's ad hoc transition reducer with XState v5 while preserving current workflow behavior, persistence, and Plannotator integration.

## Scope

Primary files:

- `pi/extensions/changeflow/index.ts`
- `pi/extensions/changeflow/README.md`

Validation:

- `cd pi/extensions/changeflow && npm run check`
- optional local Node smoke test for XState snapshot restoration/transition behavior

## Approach

1. Import and instantiate XState
   - Add `createMachine`, `createActor`, and relevant types from `xstate`.
   - Build a single `changeflowMachine` from the existing `machineDefinition`.
   - Keep `machineDefinition` serializable for workflow artifacts/documentation.

2. Replace the ad hoc reducer
   - Remove the derived `transitions` table.
   - Rework `applyTransition()` to:
     - create/start an actor for the active workflow,
     - verify the event is valid before sending it,
     - send `{ type: normalizedEvent }`,
     - update `activeWorkflow.state` from `actor.getSnapshot().value`,
     - persist `activeWorkflow.machineSnapshot` from `actor.getPersistedSnapshot()`.
   - Preserve existing user-facing invalid-event messages and feedback metadata handling.

3. Use XState persisted snapshots going forward
   - Change `Workflow.machineSnapshot` to store an XState persisted snapshot shape.
   - New workflows should initialize `machineSnapshot` from an XState actor already transitioned to `research`.
   - Loaded workflows are expected to have XState-compatible snapshots after this migration; no special legacy snapshot compatibility layer is required.

4. Preserve existing extension behavior
   - `transition()` should still save workflow JSON, append the session pointer, and update the status bar.
   - `transitionAndMaybeContinue()` should still queue only after successful transitions.
   - Plannotator review result handling should keep using the same transition path.
   - Tool state guards and pre-execution write restrictions should remain unchanged.

5. Update documentation
   - Rewrite the README's "XState direction" section to describe the completed migration rather than a planned next step.
   - Remove/adjust wording that says the reducer is used to avoid importing XState when dependencies are absent.
   - Update suggested next iterations to remove "Install/use XState and replace the reducer."

## Risks

- XState snapshot typings are broader than the simple `WorkflowState` union, so state extraction should validate/cast carefully.
- Invalid events must not silently no-op; current error behavior should be preserved.
- Existing pre-migration workflow artifacts may need to be restarted or manually regenerated if their snapshots are not XState-compatible.

## Verification

- Run `npm run check` in `pi/extensions/changeflow`.
- Smoke-test that `research --RESEARCH_COMPLETE--> high_level_planning` updates both `state` and `machineSnapshot` to an XState persisted snapshot.
- Smoke-test restoring from an XState persisted snapshot transitions correctly.
- Manually verify README text matches implementation.