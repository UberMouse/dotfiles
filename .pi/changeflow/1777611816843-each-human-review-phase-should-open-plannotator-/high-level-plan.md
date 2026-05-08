# High-level plan: open Plannotator for every Changeflow human review gate

## Goal

Make the detailed plan human review gate behave like the high-level plan gate: submitting a detailed plan should open Plannotator, persist a pending review record, and only transition onward after the human approves/rejects in Plannotator.

## Approach

1. **Generalize plan review helpers in `pi/extensions/changeflow/index.ts`**
   - Replace high-level-specific helpers with reusable helpers parameterized by review kind/state where practical.
   - Support both `high_level_plan` and `detailed_plan` review records using Plannotator's existing `plan-review` action.

2. **Update detailed plan submission behavior**
   - Keep `changeflow_submit_detailed_plan` restricted to `detailed_planning`.
   - Write `detailed-plan.md` and save `context.detailedPlanPath`.
   - Request a Plannotator `plan-review` for the detailed plan.
   - Only transition with `DETAILED_PLAN_SUBMITTED` after Plannotator accepts the review request and returns a `reviewId`.
   - Record the review with kind `detailed_plan`.

3. **Make review result handling gate-aware**
   - Reuse `USER_APPROVED` / `USER_REJECTED` transitions from the current workflow state.
   - Update notification text so it reflects whether the completed review was high-level or detailed.
   - Preserve existing behavior where approval queues the next agent-owned phase (`detailed_planning` after high-level approval, `execution_ordering` after detailed approval) and rejection queues the relevant revision/planning phase.

4. **Extend duplicate-review protection and reconciliation**
   - Prevent duplicate Plannotator windows for pending detailed reviews, analogous to high-level reviews.
   - Reconcile missed `review-status` results for both `high_level_user_review` and `detailed_user_review`.

5. **Improve phase prompts and docs**
   - Add an explicit `detailed_user_review` prompt saying Changeflow is waiting for detailed plan review in Plannotator.
   - Update `pi/extensions/changeflow/README.md` to document detailed plan review behavior and manual verification steps.

## Files likely to change

- `pi/extensions/changeflow/index.ts`
- `pi/extensions/changeflow/README.md`

## Reuse opportunities

- Reuse Plannotator shared event API action `plan-review` for detailed plans.
- Reuse existing `applyReviewResult()` transition mechanics, `review-status` recovery, and pending review records.
- Reuse existing state guards and artifact paths.

## Risks and mitigations

- **Risk:** A detailed review result could be applied while the workflow is in the wrong state.
  - **Mitigation:** Keep transition validity checks through XState; invalid `USER_APPROVED`/`USER_REJECTED` transitions already fail.
- **Risk:** Duplicate or stale Plannotator review windows.
  - **Mitigation:** Generalize pending-review duplicate checks for both high-level and detailed review gates.
- **Risk:** Regressing high-level review behavior while generalizing helpers.
  - **Mitigation:** Keep helper semantics equivalent and run TypeScript validation.

## Verification

- Run `cd pi/extensions/changeflow && npm run check`.
- Search for high-level-only wording/helpers and confirm detailed review is covered.
- Manual smoke test path:
  1. Submit high-level plan and approve in Plannotator.
  2. Submit detailed plan and confirm Plannotator opens.
  3. Approve detailed plan and confirm workflow advances to `execution_ordering` with automatic continuation.
  4. Reject detailed plan and confirm workflow returns to `detailed_planning` with feedback.