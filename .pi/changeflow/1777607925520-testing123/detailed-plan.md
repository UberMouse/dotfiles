# Detailed plan: harden Changeflow ↔ Plannotator integration

## Goal

Implement the approved high-level plan for hardening the MVP Plannotator integration in Changeflow.

## Step-by-step plan

### 1. Harden review-result correlation

- Locate the `pi.events.on(REVIEW_RESULT_CHANNEL, ...)` handler in `pi/extensions/changeflow/index.ts`.
- Replace the current correlation check that only accepts review IDs present in `pendingReviewToWorkflow`.
- Allow a review result when either:
  - `pendingReviewToWorkflow` contains the `reviewId`, or
  - `activeWorkflow.context.reviews` contains a review with that `reviewId`.
- Keep ignoring unrelated review IDs from other extensions/workflows.
- Dependency: none.
- Verification: simulate/reason through a reload case where `pendingReviewToWorkflow` is empty but persisted reviews contain the ID.

### 2. Route approval/rejection through transition events

- In the same review-result handler, stop directly assigning:
  - `activeWorkflow.state = "detailed_planning"`
  - `activeWorkflow.state = "high_level_revision"`
- Instead call `transition(activeCtx, "USER_APPROVED")` or `transition(activeCtx, "USER_REJECTED", { feedback })` when a live context exists.
- If no live context exists, fall back to a small helper that applies the same transition table and saves later, or defer state application until the next active context is available.
- Preserve feedback in `activeWorkflow.context.latestFeedback`.
- Dependency: step 1.
- Verification: reject a plan and confirm state becomes `high_level_revision`; approve a plan and confirm state becomes `detailed_planning`.

### 3. Improve Plannotator unavailable/timeout behavior

- Update `requestPlanReview()` return messages for timeout/unavailable/error cases.
- Make it explicit that:
  - the plan was saved
  - workflow state was not advanced to user review
  - the user can retry with `/changeflow review-plan`
- Ensure unavailable/error cases do not append a pending review record and do not transition state.
- Dependency: none.
- Verification: reason/test with Plannotator unavailable and confirm workflow remains in high-level planning or revision.

### 4. Tighten pre-execution write restrictions

- Update the `tool_call` handler in `pi/extensions/changeflow/index.ts`.
- Before `executing` or `qa`, allow `write`/`edit` only when the resolved path is under `activeWorkflow.artifactsDir`.
- Remove the broad allowance for arbitrary `.md`/`.mdx` files anywhere in the repo.
- Ensure Changeflow tools still write artifacts directly because tool event blocking only applies to model-called `write`/`edit`, not extension-internal `writeFileSync`.
- Dependency: none.
- Verification: model-called writes to arbitrary markdown should be blocked before execution; Changeflow submit tools should still save plans.

### 5. Update README documentation

- In `pi/extensions/changeflow/README.md`, update MVP scope/design notes to say pre-execution writes are restricted to the workflow artifacts directory.
- Add a manual Plannotator integration verification section covering:
  - start workflow
  - advance to planning
  - submit plan
  - reject and verify revision
  - approve and verify detailed planning
  - retry when unavailable
  - reload/restart pending-review recovery behavior
- Dependency: implementation steps 1-4.
- Verification: README accurately matches code behavior.

### 6. Run lightweight validation

- Run a TypeScript-oriented sanity check if available, or at minimum inspect the extension for syntax issues.
- Since this is a Pi extension loaded by jiti, verify imports remain safe and no new dependency is introduced.
- Optionally run `pi /reload` manually after applying configuration.
- Dependency: steps 1-5.

## Execution order

Steps 1 and 3 can be done independently.
Step 4 can be done independently.
Step 2 depends on step 1 because it modifies the same review-result handler.
Step 5 should happen after implementation behavior is decided.
Step 6 is last.

## Verification checklist

- [ ] Review-result correlation works from in-memory pending map.
- [ ] Review-result correlation works from persisted `activeWorkflow.context.reviews`.
- [ ] Approval transitions through `USER_APPROVED`.
- [ ] Rejection transitions through `USER_REJECTED` and persists feedback.
- [ ] Plannotator timeout/unavailable leaves workflow in planning/revision and says retry with `/changeflow review-plan`.
- [ ] Pre-execution model writes outside `activeWorkflow.artifactsDir` are blocked.
- [ ] Changeflow tool submissions still write plan artifacts.
- [ ] README documents the final behavior.
