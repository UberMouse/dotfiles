# Detailed plan: automate Changeflow phase progression

## Objective

Implement the approved MVP automation for Changeflow so agent-owned phases can transition and continue without the user manually running `/changeflow advance ...` and typing `go`, while preserving human gates.

## Step 1: Add phase ownership/continuation helpers

**File:** `pi/extensions/changeflow/index.ts`

1. Add a helper to classify states that should trigger automatic agent continuation, e.g.:
   - auto-continue: `research`, `high_level_planning`, `high_level_revision`, `detailed_planning`, `execution_ordering`, `executing`, `qa`
   - do not auto-continue: `high_level_user_review`, `detailed_user_review`, `user_validation`, `done`, `idle`
2. Add a helper that queues the current phase prompt as a follow-up user message:
   - use `phasePrompt(activeWorkflow)` as the message body, or a concise wrapper around it
   - when `ctx.isIdle()` is true, call `pi.sendUserMessage(message)`
   - otherwise call `pi.sendUserMessage(message, { deliverAs: "followUp" })`
3. Guard against duplicate follow-ups where practical:
   - only queue after a successful transition
   - only queue for auto-continuation target states

**Verification:** Reason through all states and confirm user/human gates cannot auto-advance.

## Step 2: Add a transition-and-continue helper

**File:** `pi/extensions/changeflow/index.ts`

1. Add a helper, e.g. `transitionAndMaybeContinue(ctx, event, metadata?)`, that:
   - calls the existing `transition(ctx, event, metadata)`
   - checks whether transition succeeded
   - queues next phase prompt if the new state is auto-continuable
   - returns the transition message
2. Keep existing `transition()` intact for persistence/status updates and for places that must not auto-continue.

**Dependencies:** Step 1.

**Verification:** Invalid transitions should not queue follow-ups. Successful transitions into gate states should not queue follow-ups.

## Step 3: Add a model-callable lifecycle advancement tool

**File:** `pi/extensions/changeflow/index.ts`

1. Register a new tool, likely named `changeflow_advance`.
2. Parameters:
   - `event`: string, lifecycle event to send
   - `note`: optional string, explanation or summary of phase completion
3. Execution behavior:
   - restore active workflow if needed
   - optionally record the note in the workflow context/research artifact or append it to decisions/research notes
   - call `transitionAndMaybeContinue(ctx, params.event)`
   - return the transition message and current state details
4. This tool is intentionally generic to reuse the state machine and avoid adding many phase-specific tools.

**Dependencies:** Step 2.

**Verification:** From `research`, calling with `RESEARCH_COMPLETE` transitions to `high_level_planning` and queues the planning follow-up.

## Step 4: Update phase prompts to use tools, not slash commands

**File:** `pi/extensions/changeflow/index.ts`

Update `phasePrompt()` text:

- Research: replace `/changeflow advance RESEARCH_COMPLETE` with `changeflow_advance` using event `RESEARCH_COMPLETE`.
- Execution ordering: replace `/changeflow advance ORDER_DEFINED` with `changeflow_advance` using event `ORDER_DEFINED`.
- Executing: replace `/changeflow advance EXECUTION_COMPLETE` with `changeflow_advance` using event `EXECUTION_COMPLETE`.
- QA: replace `/changeflow advance QA_COMPLETE` with `changeflow_advance` using event `QA_COMPLETE`.

Keep plan submission instructions pointing at `changeflow_submit_high_level_plan` and `changeflow_submit_detailed_plan`.

**Dependencies:** Step 3.

**Verification:** Search for `/changeflow advance` in phase prompt strings; only README/manual docs should retain it.

## Step 5: Wire existing transition points into continuation helper

**File:** `pi/extensions/changeflow/index.ts`

1. In `changeflow_submit_detailed_plan`, use `transitionAndMaybeContinue(ctx, "DETAILED_PLAN_SUBMITTED")` if detailed user review is not yet implemented/desired to continue later. However current state machine transitions to `detailed_user_review`, a gate, so this will not queue a follow-up.
2. In the Plannotator review-result handler:
   - after approval/rejection transitions, queue continuation for target states `detailed_planning` or `high_level_revision`
   - if `activeCtx` exists, use the continuation helper or call the queue helper after `transition()`
   - if no context exists, persist only; do not attempt to queue without a Pi context
3. Optionally update `/changeflow advance` command to use `transitionAndMaybeContinue()` so manual advances into agent-owned states also remove the need to type `go`.

**Dependencies:** Steps 1–2.

**Verification:** Approving a high-level plan queues detailed planning automatically. Rejecting queues revision automatically.

## Step 6: Update README

**File:** `pi/extensions/changeflow/README.md`

1. Add `changeflow_advance` to the Tools table.
2. Clarify `/changeflow advance` is a manual/debug fallback.
3. Update MVP scope/current behavior to say agent-owned phase transitions can queue the next phase automatically.
4. Add manual verification steps for automated continuation.

**Dependencies:** implementation steps.

**Verification:** README matches behavior and no longer implies normal users must manually advance every phase.

## Step 7: Validate

1. Run TypeScript/package validation if available from the extension directory:
   - inspect package scripts; if none, run a syntax/type check appropriate for Pi extension TypeScript if available
2. Search for stale prompt text:
   - `rg "/changeflow advance|changeflow_advance|followUp" pi/extensions/changeflow`
3. Manual runtime verification after `/reload`:
   - start a workflow
   - complete research with `changeflow_advance`
   - confirm high-level planning starts automatically
   - submit plan, confirm Plannotator gate still waits
   - approve/reject and confirm next agent-owned phase starts automatically

## Ordering

Steps 1–5 must be sequential because later wiring depends on helpers and tool registration. Step 6 can happen after implementation. Step 7 validates all changes.
