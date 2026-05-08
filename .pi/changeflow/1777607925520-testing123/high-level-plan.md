# High-level plan: harden Changeflow ↔ Plannotator integration

## Context

This workflow is an experiment to validate and harden the MVP Changeflow extension's integration with the Plannotator Pi extension. Changeflow already uses Plannotator's shared event API to request human review of high-level plans, but the current implementation has a few reliability and lifecycle gaps.

Plannotator is pinned in `home.nix` as `npm:@plannotator/pi-extension@0.19.4` and should be loaded by Pi through `~/.pi/agent/settings.json` after applying the NixOS/home-manager configuration.

## Approach

Make the existing high-level plan review path more robust without expanding the workflow's scope. The goal is to keep this as an MVP integration hardening pass, not a full workflow engine rewrite.

The main changes should be:

1. Recover Plannotator review results after reload/restart by matching `reviewId` against persisted `activeWorkflow.context.reviews`, not only the in-memory `pendingReviewToWorkflow` map.
2. Route Plannotator approval/rejection through Changeflow's transition/event model instead of directly assigning `activeWorkflow.state`.
3. Make Plannotator unavailable/timeout behavior clearer and explicitly retryable.
4. Tighten planning-phase write restrictions so pre-execution writes/edits are limited to files under the active workflow artifacts directory, instead of allowing arbitrary markdown files anywhere in the repository.
5. Add basic manual verification instructions to the extension README.

## Files likely to change

- `pi/extensions/changeflow/index.ts`
  - harden review-result correlation
  - route review approvals/rejections through lifecycle events
  - improve user-facing review request failure messages
  - tighten planning-phase write/edit restrictions to `activeWorkflow.artifactsDir`
- `pi/extensions/changeflow/README.md`
  - document the Plannotator integration test path
  - document expected behavior for approve/reject/retry cases
  - document the tightened artifact-only write policy before execution/QA
- Possibly `home.nix`
  - only if the pinned Plannotator package line needs adjustment after validation

## Reuse

Existing code to reuse:

- `requestPlanReview()` in `pi/extensions/changeflow/index.ts`
  - already emits `plannotator:request` with `action: "plan-review"`
- `pi.events.on(REVIEW_RESULT_CHANNEL, ...)` in `pi/extensions/changeflow/index.ts`
  - already receives Plannotator review results
- `transition()` in `pi/extensions/changeflow/index.ts`
  - should become the path used by review results instead of direct state assignment
- `activeWorkflow.context.reviews`
  - already persists review IDs and can be used to recover after reload/restart

## Risks / tradeoffs

- The MVP still uses a lightweight reducer rather than XState proper. This plan should not introduce XState yet.
- Plannotator review startup is asynchronous; there may still be edge cases around browser review sessions completed after Pi exits entirely.
- If Plannotator is not installed or has not loaded, Changeflow should fail gracefully and leave the plan available for retry.
- Tightening pre-execution writes to the artifacts directory means agents must use Changeflow tools/artifact paths for planning notes instead of creating ad hoc markdown files elsewhere in the repo.

## Verification

Manual verification should cover:

1. Start Pi after applying the pinned Plannotator package config.
2. Start a Changeflow workflow.
3. Advance from research to high-level planning.
4. Submit a high-level plan with `changeflow_submit_high_level_plan`.
5. Confirm Plannotator opens a browser review.
6. Reject with feedback and confirm Changeflow enters `high_level_revision` with feedback persisted.
7. Resubmit a revised plan.
8. Approve and confirm Changeflow enters `detailed_planning`.
9. Reload Pi during or after a pending review and confirm review results can still be correlated if the review ID exists in persisted workflow context.
10. Temporarily disable/unload Plannotator or use a session where it is unavailable and confirm Changeflow reports a retryable failure rather than corrupting workflow state.
11. During research/planning, attempt to write a markdown file outside the workflow artifacts directory and confirm it is blocked.
12. During research/planning, submit plans through Changeflow tools and confirm artifact writes under `.pi/changeflow/<workflow-id>/` still work.

## Non-goals for this pass

- No SDK reviewer sub-agents.
- No detailed plan Plannotator review yet.
- No code-review/QA Plannotator integration yet.
- No real XState actor migration yet.
- No parallel execution or git worktree isolation yet.
