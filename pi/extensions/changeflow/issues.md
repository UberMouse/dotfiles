# Changeflow issues

## Stale queued phase prompt can reopen Plannotator reviews

Observed during the TypeScript dev-environment workflow:

- A high-level plan was submitted and opened in Plannotator.
- The plan was approved, but Changeflow stayed in `high_level_user_review`.
- Repeated approvals appeared to reopen Plannotator instead of progressing the workflow.

Likely causes:

1. `changeflow_advance` queues a follow-up containing a full `phasePrompt(activeWorkflow)` snapshot.
   - If that queued message is stale or duplicated, the agent can receive old `high_level_planning` instructions even after the workflow has moved to `high_level_user_review`.
   - The agent may then call `changeflow_submit_high_level_plan` again, opening a new Plannotator review.
2. `changeflow_submit_high_level_plan` does not guard against being called from invalid states.
   - It should only be valid from `high_level_planning` or `high_level_revision`.
3. `changeflow_submit_detailed_plan` also lacks a state guard.
   - It should only be valid from `detailed_planning`.
4. Plannotator review completion can be persisted in `~/.pi/plannotator-review-status.json` without Changeflow correlating it back to the active workflow.
   - Pending Changeflow reviews may need explicit status reconciliation via Plannotator's `review-status` request action.

Potential fixes:

1. Queue only a minimal continuation message, e.g. `Continue the current Changeflow phase.`
   - Let `before_agent_start` inject fresh phase context for the current persisted state.
   - Do not embed a full phase prompt snapshot in queued follow-ups.
2. Add state guards to Changeflow submission tools:
   - `changeflow_submit_high_level_plan`: allow only `high_level_planning` and `high_level_revision`.
   - `changeflow_submit_detailed_plan`: allow only `detailed_planning`.
3. Add idempotency/duplicate protection around high-level plan review requests:
   - If already in `high_level_user_review` with a pending high-level review, do not open another review.
4. Add review-status reconciliation:
   - On session start or before agent start, ask Plannotator for `review-status` for pending review IDs.
   - If status is completed, apply the same `USER_APPROVED` / `USER_REJECTED` transition path used by live review-result events.
