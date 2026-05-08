# Detailed implementation plan: migrate Changeflow to XState

## Step 1: Update imports and snapshot typing

- In `pi/extensions/changeflow/index.ts`, import `createActor`, `createMachine`, and `type Snapshot` from `xstate`.
- Change `Workflow.machineSnapshot` from the current simplified `{ value, context }` shape to `Snapshot<unknown>`.
- Add a narrow helper type or helper function for extracting/validating `WorkflowState` from XState actor snapshots if TypeScript requires it.

Verification:
- TypeScript should still compile after import/type changes once later steps are complete.

## Step 2: Instantiate the XState machine

- Keep the existing serializable `machineDefinition` object.
- Add `const changeflowMachine = createMachine(machineDefinition);` after the definition.
- Remove the derived `transitions` object entirely.

Verification:
- Search confirms no references to `transitions` remain after Step 3.

## Step 3: Replace `applyTransition()` with XState actor execution

- Normalize the incoming event as today.
- Create and start an actor from `changeflowMachine` using `activeWorkflow.machineSnapshot`.
- Before sending the event, use the current actor snapshot's `can({ type: normalized })` to preserve invalid-event behavior.
- If invalid, return `Event ${normalized} is not valid from state ${activeWorkflow.state}.`.
- Send `{ type: normalized }`.
- Read `actor.getSnapshot().value`, validate it is one of the known `WorkflowState` strings, and assign it to `activeWorkflow.state`.
- If metadata feedback exists, keep assigning `activeWorkflow.context.latestFeedback` as today.
- Assign `activeWorkflow.machineSnapshot = actor.getPersistedSnapshot()`.
- Return the same success message format: `Changeflow transitioned ${previous} --${normalized}--> ${next}.`

Verification:
- Invalid lifecycle event still returns the existing invalid-event message and does not save/queue via `transitionSucceeded()`.

## Step 4: Initialize new workflows with an XState snapshot

- Add a small helper, e.g. `initialWorkflowSnapshot(): Snapshot<unknown>`, that starts an actor at `idle`, sends `START`, and returns the persisted snapshot for `research`.
- Use this helper in `/changeflow start` for the initial `machineSnapshot` instead of `{ value: 'research', context: { workflowId: id } }`.
- Keep `state: 'research'` unchanged.

Verification:
- Starting a workflow persists an XState snapshot containing fields like `status`, `value`, `historyValue`, `context`, and `children`.

## Step 5: Update save/session persistence

- In `saveWorkflow()`, stop overwriting `workflow.machineSnapshot` with the legacy simplified shape.
- Continue writing the workflow JSON and appending the session entry.
- Keep including `machineSnapshot` in the session entry, but it should now be the XState persisted snapshot.

Verification:
- `saveWorkflow()` no longer creates `{ value, context: { workflowId } }` snapshots.

## Step 6: Update documentation

- In `pi/extensions/changeflow/README.md`, replace the "XState direction" section with a current-state section explaining that Changeflow now executes transitions through XState v5 actors and persists XState snapshots.
- Remove text saying the reducer exists so Pi can load without `node_modules`.
- Update suggested next iterations to remove the XState migration item and renumber/rephrase the rest.

Verification:
- README no longer describes reducer migration as future work.

## Step 7: Validate

Run:

```bash
cd pi/extensions/changeflow
npm run check
```

Optional smoke checks:

- Use a local Node script or temporary TypeScript reasoning to confirm `research --RESEARCH_COMPLETE--> high_level_planning` updates persisted snapshot value.
- Confirm an invalid event from a state returns the existing invalid-event message.

## Execution order

Steps should be done sequentially because later steps depend on the type/import and actor helper changes from earlier steps.