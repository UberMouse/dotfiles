# High-level plan: Fix stale Changeflow/Plannotator review loop

## Goal

Address the problem described in `pi/extensions/changeflow/issues.md`: stale queued Changeflow phase prompts can cause the agent to resubmit plans and reopen Plannotator reviews, while missed Plannotator review results can leave Changeflow stuck at a human review gate.

## Approach

1. **Stop embedding stale phase snapshots in queued follow-ups**
   - Change `queuePhaseContinuation()` in `pi/extensions/changeflow/index.ts` to send only a minimal continuation message such as `Continue the current Changeflow phase.`
   - Rely on the existing `before_agent_start` hook to inject fresh `phasePrompt(activeWorkflow)` from persisted state.

2. **Add state guards for submission tools**
   - Add a small reusable guard/helper for invalid-state tool results.
   - `changeflow_submit_high_level_plan` should only proceed from `high_level_planning` or `high_level_revision`.
   - `changeflow_submit_detailed_plan` should only proceed from `detailed_planning`.
   - Invalid calls should return `isError: true` and must not write artifacts, save paths, request reviews, or transition state.

3. **Add duplicate/pending review protection**
   - Before opening a high-level Plannotator review, detect whether the workflow is already in `high_level_user_review` with an incomplete high-level review record.
   - Return a helpful message instead of opening a second review.
   - This is mostly a defense-in-depth complement to the state guard.

4. **Add Plannotator review-status reconciliation**
   - Add a helper that finds incomplete review records for the active workflow and asks Plannotator for `review-status` via the existing `plannotator:request` event API.
   - If Plannotator reports a review as `completed`, update the persisted review record and apply the same `USER_APPROVED` / `USER_REJECTED` transition path used by live `plannotator:review-result` events.
   - Run reconciliation on `session_start` and `before_agent_start` so completed reviews are picked up after reloads or missed live events.
   - Keep reconciliation safe/idempotent: ignore missing/pending statuses, skip reviews already completed, and only transition when the current workflow state accepts the event.

## Files likely to change

- `pi/extensions/changeflow/index.ts`
  - Minimal continuation follow-up.
  - Submission state guards.
  - Pending review detection.
  - Review-status request/reconciliation helper.
  - Refactor live review-result handling if useful to share code with reconciliation.

Optional documentation update if behavior changes need to be captured:

- `pi/extensions/changeflow/README.md`
  - Mention minimal continuation behavior and review-status reconciliation in the Plannotator integration section.

## Reuse opportunities

- Reuse `transitions`, `transitionSucceeded()`, `transitionAndMaybeContinue()`, `saveWorkflow()`, and persisted `context.reviews` instead of introducing a new state system.
- Reuse Plannotator’s existing `review-status` action on `plannotator:request`; do not import Plannotator internals.
- Reuse the existing live `plannotator:review-result` logic for completed review processing where practical.

## Risks and mitigations

- **Risk:** Reconciliation could transition from an unexpected state.
  - **Mitigation:** Use existing transition validation; if `USER_APPROVED`/`USER_REJECTED` is invalid from the current state, do not force state changes.
- **Risk:** `before_agent_start` reconciliation is async and could delay turns.
  - **Mitigation:** Bound Plannotator requests with the same short timeout pattern used by `requestPlanReview()`.
- **Risk:** Duplicate review detection could block intentional retries.
  - **Mitigation:** Only block when there is an incomplete high-level review and the workflow is at the high-level user review gate; existing `/changeflow review-plan` can still be adjusted if explicit retry behavior is needed.

## Verification

- Run `cd pi/extensions/changeflow && npm run check`.
- Manually inspect that `queuePhaseContinuation()` no longer embeds `phasePrompt(activeWorkflow)`.
- Confirm invalid submission states return errors without writing or opening Plannotator.
- If feasible, test a completed review in `~/.pi/plannotator-review-status.json` and verify Changeflow advances on session/agent start.
