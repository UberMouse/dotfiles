# Detailed plan: Move Changeflow behavior into workflow state meta

## Step 1: Add metadata types

- In `pi/extensions/changeflow/index.ts`, add type aliases/interfaces near the workflow/review types:
  - `PromptKind` for existing prompt variants.
  - `EditPolicy = "artifactsOnly" | "sourceAllowed"`.
  - `PlannotatorMeta` with `action`, optional `artifact`, and optional `mode`.
  - `ReviewGateMeta` with `actor` and `kind`.
  - `SubmissionMeta` with `reviewKind` and `submittedEvent`.
  - `ChangeflowStateMeta` with optional `autoContinue`, `editPolicy`, `prompt`, `reviewGate`, `plannotator`, and `submission`.
  - State config helper type for the canonical `machineDefinition` states.

Verification: TypeScript should still understand the machine definition without broad `any` casts.

## Step 2: Annotate `machineDefinition`

Add `meta: { changeflow: ... }` to each relevant state while preserving transitions exactly:

- `idle`: no contextual behavior, or only a neutral prompt if needed.
- `research`:
  - `autoContinue: true`
  - `editPolicy: "artifactsOnly"`
  - `prompt.kind: "research"`
- `high_level_planning`:
  - `autoContinue: true`
  - `editPolicy: "artifactsOnly"`
  - `prompt.kind: "high_level_planning"`
  - `submission: { reviewKind: "high_level_plan", submittedEvent: "HIGH_LEVEL_PLAN_SUBMITTED" }`
  - `plannotator: { action: "plan-review", artifact: "highLevelPlanPath" }`
- `high_level_revision`: same as high-level planning, with prompt kind either shared or distinct if current wording requires it.
- `high_level_user_review`:
  - `prompt.kind: "high_level_user_review"`
  - `reviewGate: { actor: "human", kind: "high_level_plan" }`
  - `plannotator: { action: "plan-review", artifact: "highLevelPlanPath" }`
- `detailed_planning`:
  - `autoContinue: true`
  - `editPolicy: "artifactsOnly"`
  - `prompt.kind: "detailed_planning"`
  - `submission: { reviewKind: "detailed_plan", submittedEvent: "DETAILED_PLAN_SUBMITTED" }`
  - `plannotator: { action: "plan-review", artifact: "detailedPlanPath" }`
- `detailed_user_review`:
  - `prompt.kind: "detailed_user_review"`
  - `reviewGate: { actor: "human", kind: "detailed_plan" }`
  - `plannotator: { action: "plan-review", artifact: "detailedPlanPath" }`
- `execution_ordering`:
  - `autoContinue: true`
  - `editPolicy: "artifactsOnly"`
  - `prompt.kind: "execution_ordering"`
- `executing`:
  - `autoContinue: true`
  - `editPolicy: "sourceAllowed"`
  - `prompt.kind: "executing"`
- `qa`:
  - `autoContinue: true`
  - `editPolicy: "sourceAllowed"`
  - `prompt.kind: "qa"`
- `user_validation`:
  - `prompt.kind: "user_validation"`
  - `reviewGate: { actor: "human", kind: "qa" }` only if this helps represent the existing human gate; do not wire Plannotator unless supported.
- `done`: no contextual behavior.

Do not add behavior for currently unused agent-review states unless preserving their prompt/review behavior requires it.

Verification: inspect generated `workflow.json` for new workflows if needed; no transition behavior should change.

## Step 3: Implement metadata access helpers

Add helpers below machine setup:

- `canonicalStateConfig(state: WorkflowState)` returns `machineDefinition.states[state]`.
- `stateMeta(state: WorkflowState): ChangeflowStateMeta` returns `canonicalStateConfig(state).meta?.changeflow ?? {}`.
- `currentStateMeta()` returns metadata for `activeWorkflow.state`.
- `statesMatchingMeta(predicate)` iterates `workflowStates` and filters by `stateMeta`.

Use the canonical `machineDefinition` as the source of behavior, not the persisted `activeWorkflow.machineDefinition`.

Verification: helpers are pure and can be exercised by typecheck; no runtime calls depend on a restored workflow's persisted definition.

## Step 4: Refactor auto-continuation

Replace the body of `shouldAutoContinue(state)` with a metadata lookup:

- `return stateMeta(state).autoContinue === true;`

Keep `queuePhaseContinuation` behavior unchanged.

Verification: after transitions into planning/execution states, auto-continuation still queues; transitions into review gates/user validation/done do not.

## Step 5: Refactor edit policy

In the `tool_call` hook, replace:

- `const sourceEditAllowed = activeWorkflow.state === "executing" || activeWorkflow.state === "qa";`

with:

- `const sourceEditAllowed = stateMeta(activeWorkflow.state).editPolicy === "sourceAllowed";`

Keep artifacts-only blocking logic and error message unchanged.

Verification: write/edit outside artifacts remains blocked in research/planning and allowed in executing/qa.

## Step 6: Refactor review state/kind mapping

Change review helper implementations to use metadata:

- `reviewKindForState(state)` returns `stateMeta(state).reviewGate?.kind` when actor is `human`.
- `reviewStateForKind(kind)` scans `workflowStates` for the state whose `reviewGate.kind === kind` and actor is `human`.
- `submittedEventForKind(kind)` scans states with `submission.reviewKind === kind` and returns `submission.submittedEvent`.

Preserve function names/signatures to minimize call-site churn.

Verification: high-level and detailed review submission, result handling, and reconciliation still find the same states/events.

## Step 7: Refactor plan submission allowed states

For `changeflow_submit_high_level_plan` and `changeflow_submit_detailed_plan`, derive allowed states from metadata instead of hard-coded arrays:

- helper `submissionStatesForKind(kind)` returns states where `stateMeta(state).submission?.reviewKind === kind`.
- high-level plan allowed states should become `high_level_planning`, `high_level_revision`.
- detailed plan allowed states should become `detailed_planning`.

Keep the tools themselves separate for now to avoid changing API UX.

Verification: invalid-state errors list the same allowed states as before.

## Step 8: Refactor prompt selection to metadata

Keep the existing prompt text but drive the switch from metadata:

- compute `const promptKind = stateMeta(workflow.state).prompt?.kind;`
- switch on `promptKind` rather than directly on `workflow.state`.
- For high-level planning/revision, use a shared prompt kind if the text remains identical.
- For review gates, keep the same waiting messages.
- Default to the common workflow header.

Verification: compare current prompts for all active states; text should remain semantically identical.

## Step 9: Thread metadata arguments into Plannotator request path

Keep current behavior first, but prepare the call signature:

- Add an optional `plannotator?: PlannotatorMeta` parameter to `requestPlanReview`, or derive it from `reviewStateForKind`/submission metadata.
- Include `mode` in emitted payload only if metadata specifies it.
- Keep `action: "plan-review"` and existing payload fields for high-level/detailed plan reviews.

Verification: TypeScript passes and Plannotator plan-review requests still have the expected existing payload; no code-review/diff behavior is introduced unless meta asks for it.

## Step 10: Update docs

Edit `pi/extensions/changeflow/README.md`:

- Add a section describing state metadata under `meta.changeflow`.
- Include a compact example showing composable metadata for auto-continue + human approval + Plannotator.
- Update design/current behavior notes to say workflow behavior is declared in machine metadata and consumed by helper functions.

Verification: docs match the implemented fields and do not mention legacy fallback behavior.

## Step 11: Validate

Run:

```bash
cd pi/extensions/changeflow && npm run check
```

Optionally run a smoke test manually:

1. Start a throwaway workflow.
2. Confirm `workflow.json` includes `meta.changeflow` on states.
3. Complete research and confirm high-level planning auto-continues.
4. Submit a plan and confirm review gate does not auto-continue.
5. Confirm edit blocking remains controlled by the current state.

## Dependency/order notes

- Steps 1-3 must be done first.
- Steps 4-9 can be implemented after helpers exist; they are mostly independent but should be typechecked together.
- Step 10 should be done after the final metadata shape is known.
- Step 11 is final verification.
