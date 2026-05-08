# Detailed plan: Fix stale Changeflow/Plannotator review loop

## Execution order

All implementation steps are sequential because most edits touch `pi/extensions/changeflow/index.ts` and later steps depend on helper functions introduced earlier.

## Step 1: Inspect exact implementation anchors

**Files:**
- `pi/extensions/changeflow/index.ts`
- `pi/extensions/changeflow/README.md` if documentation is updated

**Tasks:**
- Re-read the relevant sections around:
  - `PlannotatorResponse` and review result types.
  - `queuePhaseContinuation()`.
  - `requestPlanReview()`.
  - `changeflow_submit_high_level_plan`.
  - `changeflow_submit_detailed_plan`.
  - `before_agent_start` and `session_start` hooks.
  - `pi.events.on(REVIEW_RESULT_CHANNEL, ...)`.
- Decide final insertion points for new helpers to keep the single-file extension readable.

**Verification:**
- No source changes yet; know exact snippets to edit.

## Step 2: Add Plannotator review-status types

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- Add a `PlannotatorReviewStatusResult` type near existing Plannotator types:
  - `{ status: "pending" }`
  - `({ status: "completed" } & PlannotatorReviewResultEvent)`
  - `{ status: "missing" }`
- This mirrors Plannotator’s event API without importing Plannotator internals.

**Verification:**
- TypeScript can represent review-status responses for the generic `PlannotatorResponse<T>` helper.

## Step 3: Add shared review-result application helper

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- Extract the common logic from the live `REVIEW_RESULT_CHANNEL` handler into a helper, for example:
  - `applyReviewResult(ctx, result, options?)`
- Responsibilities:
  - Validate `activeWorkflow` exists.
  - Find the persisted review record by `result.reviewId`.
  - Update `approved`, `feedback`, and `completedAt` if not already completed.
  - Apply `USER_APPROVED` or `USER_REJECTED` using `transitionAndMaybeContinue()` when a context exists, otherwise `applyTransition()`.
  - Delete `pendingReviewToWorkflow` entry for the review ID.
  - Save workflow when transition succeeds and a context is available.
  - Notify the user for live review results, but allow reconciliation calls to suppress or use different notification text.
- Preserve existing correlation behavior: live events should still accept either an in-memory `pendingReviewToWorkflow` match or a persisted review record.

**Verification:**
- Existing live review-result behavior is unchanged, just routed through the helper.

## Step 4: Add review-status request helper

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- Add an async helper, for example `requestReviewStatus(reviewId: string)`, that emits on `REQUEST_CHANNEL`:
  - `action: "review-status"`
  - `payload: { reviewId }`
  - 5 second timeout, following the pattern in `requestPlanReview()`.
- Return `undefined` for timeout/unhandled/error responses; return the handled `PlannotatorReviewStatusResult` otherwise.
- Keep the helper local and dependency-free.

**Verification:**
- Typecheck validates the request/response typing.

## Step 5: Add pending review lookup and reconciliation helper

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- Add a helper to identify incomplete reviews relevant to the current gate, initially high-level plan reviews:
  - `kind === "high_level_plan"`
  - no `completedAt`
  - active workflow state is `high_level_user_review` for transition safety.
- Add `reconcilePendingReviews(ctx)`:
  - Return early when no active workflow.
  - Iterate pending reviews.
  - Call `requestReviewStatus(review.id)`.
  - If status is `completed`, pass it to the shared review-result helper with reconciliation-friendly notifications.
  - Ignore `pending`, `missing`, timeout, unavailable, and invalid statuses.
  - Be idempotent: do not reapply completed reviews and do not force invalid transitions.

**Verification:**
- A missing/pending review leaves workflow state unchanged.
- A completed review follows the existing approval/rejection transition path.

## Step 6: Run reconciliation at safe lifecycle points

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- In `session_start`, after `restoreWorkflow(ctx)` and status setup, call `await reconcilePendingReviews(ctx)` when there is an active workflow.
- In `before_agent_start`, after restoring workflow and before returning `phasePrompt(activeWorkflow)`, call `await reconcilePendingReviews(ctx)`.
- Ensure the returned prompt uses the post-reconciliation state.

**Verification:**
- If reconciliation advances `high_level_user_review` to `detailed_planning`, `before_agent_start` injects detailed-planning instructions instead of stale review-gate instructions.

## Step 7: Make queued phase continuation minimal

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- Change `queuePhaseContinuation()` from embedding `phasePrompt(activeWorkflow)` to only sending a minimal message, e.g.:
  - `Continue the current Changeflow phase.`
- Keep existing idle vs follow-up delivery behavior.
- Do not change `shouldAutoContinue()` in this fix unless typecheck or tests reveal an issue.

**Verification:**
- Source no longer contains a queued follow-up template that embeds `phasePrompt(activeWorkflow)`.
- Fresh phase instructions still come from `before_agent_start`.

## Step 8: Add submit-tool state guards

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- Add a small helper for invalid state tool results, for example:
  - `invalidStateResult(toolName, allowedStates)` returning content/details/isError.
- In `changeflow_submit_high_level_plan`:
  - After active workflow restoration/check, allow only `high_level_planning` and `high_level_revision`.
  - On invalid state, return an error before writing `high-level-plan.md` or calling `requestPlanReview()`.
- In `changeflow_submit_detailed_plan`:
  - Allow only `detailed_planning`.
  - On invalid state, return an error before writing `detailed-plan.md` or transitioning.

**Verification:**
- Invalid calls do not modify plan artifacts and do not open Plannotator.
- Valid calls retain current behavior.

## Step 9: Add duplicate pending high-level review protection

**File:** `pi/extensions/changeflow/index.ts`

**Tasks:**
- Add a helper like `pendingHighLevelReview()` that returns an incomplete high-level review record for the active workflow.
- In `requestPlanReview()` or just before calling it from high-level submission/review command paths:
  - If state is already `high_level_user_review` and such a review exists, do not emit another `plan-review` request.
  - Return a helpful message containing the pending review ID.
- This is defense-in-depth; the state guard should prevent model-initiated duplicate high-level submission from the review state.
- Consider `/changeflow review-plan`: decide whether it should respect the duplicate check as well. Preferred: yes, to avoid accidental duplicate browser windows during a pending gate.

**Verification:**
- A pending high-level review gate cannot open duplicate Plannotator reviews through either tool or `/changeflow review-plan`.

## Step 10: Update documentation if behavior changed materially

**File:** `pi/extensions/changeflow/README.md`

**Tasks:**
- Update the Plannotator integration/current behavior section to mention:
  - queued continuations are intentionally minimal and fresh context is injected by `before_agent_start`;
  - pending review IDs can be reconciled with Plannotator `review-status` on session/agent start.
- Keep documentation concise.

**Verification:**
- README matches implemented behavior.

## Step 11: Typecheck and fix compile errors

**Command:**

```bash
cd pi/extensions/changeflow && npm run check
```

**Tasks:**
- Fix any TypeScript errors caused by new helper return types, async calls, or event result typing.
- Preserve strict typing; avoid `any` unless absolutely necessary for event payload boundaries.

**Verification:**
- `npm run check` exits successfully.

## Step 12: Focused manual review

**Files:**
- `pi/extensions/changeflow/index.ts`
- `pi/extensions/changeflow/README.md` if changed

**Tasks:**
- Inspect final diff for:
  - no stale `phasePrompt(activeWorkflow)` embedded in queued follow-ups;
  - high-level submit guard before file writes/review request;
  - detailed submit guard before file writes/transition;
  - reconciliation uses existing transition validation and is idempotent;
  - no source edits outside approved scope.

**Verification:**
- Diff aligns with approved high-level plan and `issues.md`.
