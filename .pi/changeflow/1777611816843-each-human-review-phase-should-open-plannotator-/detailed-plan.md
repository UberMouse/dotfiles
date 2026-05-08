# Detailed plan: open Plannotator for detailed Changeflow review

Implement sequentially; most edits touch `pi/extensions/changeflow/index.ts` and later steps depend on helper names/types introduced earlier.

## 1. Introduce reusable review-kind helpers

**File:** `pi/extensions/changeflow/index.ts`

- Add a small formatter for review kinds, e.g. `reviewKindLabel(kind: ReviewRecord["kind"]): string` returning `"high-level plan"`, `"detailed plan"`, etc.
- Replace `pendingHighLevelReview()` with a generic `pendingReview(kind: ReviewRecord["kind"]): ReviewRecord | undefined`.
- Add a helper that maps human review state to expected review kind, e.g.:
  - `high_level_user_review` -> `high_level_plan`
  - `detailed_user_review` -> `detailed_plan`
  - otherwise `undefined`

**Verification:** TypeScript accepts the helper signatures and no behavior has changed yet.

## 2. Generalize Plannotator plan review request

**File:** `pi/extensions/changeflow/index.ts`

- Rename or adapt `requestPlanReview(ctx, planContent, planFilePath?)` to accept a review kind:
  - `requestPlanReview(ctx, kind, planContent, planFilePath?)`.
- Use `pendingReview(kind)` for duplicate checks.
- Only block duplicates when the active workflow is at the corresponding user-review state and that kind has an incomplete review.
- Keep the existing Plannotator event request unchanged:
  - channel `plannotator:request`
  - action `plan-review`
  - payload `{ planContent, planFilePath, origin: "changeflow" }`
- When Plannotator returns a `reviewId`, record `kind` in `activeWorkflow.context.reviews` instead of always recording `high_level_plan`.
- Choose the transition event based on kind:
  - `high_level_plan` -> `HIGH_LEVEL_PLAN_SUBMITTED`
  - `detailed_plan` -> `DETAILED_PLAN_SUBMITTED`
- Return messages using the kind label, e.g. `Opened Plannotator detailed plan review (...)`.

**Verification:** Existing high-level submit path should still transition to `high_level_user_review`; detailed submit path can now transition to `detailed_user_review` only after Plannotator starts.

## 3. Update high-level submission and `/changeflow review-plan`

**File:** `pi/extensions/changeflow/index.ts`

- Update `changeflow_submit_high_level_plan` to call `requestPlanReview(ctx, "high_level_plan", params.markdown, path)`.
- Update `/changeflow review-plan` to use `pendingReview("high_level_plan")` and call the generalized helper with `"high_level_plan"`.
- Preserve the allowed states for this command/tool: `high_level_planning` and `high_level_revision`.

**Verification:** Search for `pendingHighLevelReview` to ensure it is removed/replaced.

## 4. Update detailed plan submission to request Plannotator

**File:** `pi/extensions/changeflow/index.ts`

- Keep `changeflow_submit_detailed_plan` allowed only from `detailed_planning`.
- Continue writing `detailed-plan.md` and setting `activeWorkflow.context.detailedPlanPath`.
- Save the workflow before opening Plannotator, consistent with high-level submission.
- Replace the direct `transitionAndMaybeContinue(ctx, "DETAILED_PLAN_SUBMITTED")` with `await requestPlanReview(ctx, "detailed_plan", params.markdown, path)`.
- Return text such as `Detailed plan saved to <path>. Opened Plannotator detailed plan review (...)`.

**Verification:** The detailed submission no longer auto-transitions without a Plannotator `reviewId`.

## 5. Make review result handling kind-aware

**File:** `pi/extensions/changeflow/index.ts`

- In `applyReviewResult()`, after finding the `review`, derive `const kindLabel = reviewKindLabel(review?.kind ?? expectedReviewKindForState(activeWorkflow.state) ?? "high_level_plan")` or equivalent.
- Keep using `USER_APPROVED` / `USER_REJECTED`; XState remains the authority for whether the event is valid from the current state.
- Update notifications so high-level review approval says it is entering detailed planning, while detailed review approval says it is entering execution ordering. A generic notification based on the resulting state is also acceptable.
- Ensure rejection notification for detailed review makes clear it is returning to detailed planning.

**Verification:** Review completion from `detailed_user_review` should transition to `execution_ordering` on approve or `detailed_planning` on reject, and queue continuation because both target states are agent-owned.

## 6. Generalize review-status reconciliation

**File:** `pi/extensions/changeflow/index.ts`

- Replace the current `reconcilePendingReviews()` high-level-only state check with logic that:
  - gets the expected review kind from current state,
  - returns if the current state is not a human Plannotator review state,
  - queries incomplete reviews of that kind,
  - calls `applyReviewResult(status, ctx, { reconciled: true })` when Plannotator reports completion,
  - stops if the workflow leaves the original review state.

**Verification:** Both `high_level_user_review` and `detailed_user_review` can recover missed Plannotator result events after session/agent start.

## 7. Add explicit detailed review phase prompt

**File:** `pi/extensions/changeflow/index.ts`

- Add a `case "detailed_user_review"` in `phasePrompt()`.
- Message should mirror high-level review wording: waiting for human detailed plan review in Plannotator; do not proceed until review result is received.

**Verification:** No human review state falls through to the generic prompt unexpectedly.

## 8. Update README documentation

**File:** `pi/extensions/changeflow/README.md`

- Update tool table entry for `changeflow_submit_detailed_plan` to say it saves a detailed plan and requests Plannotator human review.
- Update Plannotator integration/current behavior sections to include both high-level and detailed plan reviews.
- Update manual verification steps to explicitly confirm detailed plan submission opens Plannotator and that approval advances to `execution_ordering`.

**Verification:** `rg "high-level|detailed|Plannotator|changeflow_submit_detailed_plan" pi/extensions/changeflow/README.md` reflects the new behavior.

## 9. Validate

Run:

```bash
cd pi/extensions/changeflow
npm run check
git diff --check
```

Optional manual smoke test:

1. Start a Changeflow workflow.
2. Submit/approve high-level plan in Plannotator.
3. Submit detailed plan and verify Plannotator opens.
4. Approve detailed plan and verify transition to `execution_ordering` plus queued continuation.
5. In a second run, reject detailed plan and verify transition back to `detailed_planning` with feedback.