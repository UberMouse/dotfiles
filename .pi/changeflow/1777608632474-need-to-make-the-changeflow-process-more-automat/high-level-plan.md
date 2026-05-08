# High-level plan: automate Changeflow phase progression

## Goal

Make Changeflow feel controlled by Pi rather than by the user manually running `/changeflow advance ...` and typing `go` after each phase. Human approval gates should remain explicit, but agent-owned phases should advance through Changeflow tools and automatically queue the next phase prompt.

## Approach

1. **Centralize post-transition continuation**
   - Add a helper in `pi/extensions/changeflow/index.ts` that performs a transition, persists state/status, and, when the next state is agent-owned, queues a follow-up user message with the current `phasePrompt()`.
   - Do not auto-continue into waiting/gate states such as `high_level_user_review`, `detailed_user_review`, `user_validation`, or `done`.

2. **Replace model-facing slash-command instructions with tools**
   - Add either a generic `changeflow_advance` tool or phase-specific completion tools.
   - Preferred MVP: a generic tool with parameters `{ event, note? }`, because it reuses the existing state machine and keeps the extension small.
   - Update phase prompts to tell the model to call the tool, not `/changeflow advance ...`.

3. **Auto-continue after existing tool transitions**
   - Update `changeflow_submit_detailed_plan` so after `DETAILED_PLAN_SUBMITTED` it can continue or stop appropriately based on target state.
   - Update high-level Plannotator review result handling so approval queues detailed planning and rejection queues high-level revision, removing the need for the user to type `go` after review.

4. **Preserve manual escape hatch**
   - Keep `/changeflow advance <event>` for debugging/experimentation.
   - It can optionally use the same transition helper, but should not remove manual control.

5. **Documentation**
   - Update `pi/extensions/changeflow/README.md` to describe the automated flow and clarify that `/changeflow advance` is a manual/debug fallback.

## Likely files to change

- `pi/extensions/changeflow/index.ts`
  - Add auto-continuation helper.
  - Add lifecycle advancement tool.
  - Update phase prompts.
  - Call continuation helper from Plannotator result handler and existing transition tools.
- `pi/extensions/changeflow/README.md`
  - Update commands/tools/lifecycle documentation.

## Reuse opportunities

- Reuse existing `transition()`, `applyTransition()`, `phasePrompt()`, `saveWorkflow()`, and status updates.
- Reuse Pi’s documented `pi.sendUserMessage(..., { deliverAs: "followUp" })` behavior, already used in `/changeflow start`.
- Reuse the persisted workflow state and existing state machine instead of introducing XState in this change.

## Risks

- Automation loops if Changeflow queues follow-ups for gate states or repeatedly queues for the same state.
- Queue timing issues if `sendUserMessage` is called while the agent is streaming without `deliverAs`.
- Over-automation could bypass human review if target states are classified incorrectly.

## Verification

- Start a workflow and confirm research instructions tell the model to use the Changeflow tool instead of `/changeflow advance`.
- Complete research via the tool and confirm Pi automatically starts high-level planning without typing `go`.
- Submit a high-level plan and confirm it still enters Plannotator review without auto-continuing past the gate.
- Approve/reject in Plannotator and confirm Changeflow queues the next appropriate agent-owned phase automatically.
- Complete later agent-owned phases with the tool and confirm automatic continuation until `user_validation`.
- Confirm `/changeflow advance <event>` still works as a manual fallback.
