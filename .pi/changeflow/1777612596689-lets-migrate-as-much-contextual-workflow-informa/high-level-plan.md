# High-level plan: Move Changeflow behavior into workflow state meta

## Goal

Refactor Changeflow so contextual workflow behavior is declared on workflow state definitions as composable, argument-bearing metadata instead of being scattered through state-name conditionals.

Examples of behavior to express in metadata:

- whether a phase auto-continues
- whether source edits are allowed or restricted to artifacts
- whether a state is a human approval gate
- whether Plannotator should be opened or reconciled, and with which artifact/action/mode
- which prompt template/instructions apply to the state

## Proposed approach

1. **Define a typed metadata model**
   - Add a `ChangeflowStateMeta` type and namespace it under `meta.changeflow` on XState state nodes.
   - Keep it serializable so it can remain in persisted `workflow.json` machine definitions.
   - Model fields as composable objects rather than one large enum, e.g.:
     - `autoContinue?: boolean`
     - `editPolicy?: "artifactsOnly" | "sourceAllowed"`
     - `prompt?: { kind: ... }`
     - `reviewGate?: { actor: "human" | "agent"; kind: ReviewRecord["kind"] }`
     - `plannotator?: { action: "plan-review" | "code-review"; artifact?: "highLevelPlanPath" | "detailedPlanPath"; mode?: string }`
     - `submission?: { reviewKind: ...; submittedEvent: ... }` if useful for plan submission states

2. **Annotate the existing machine definition**
   - Preserve the current lifecycle and transitions.
   - Add metadata matching today’s behavior:
     - auto-continue: `research`, `high_level_planning`, `high_level_revision`, `detailed_planning`, `execution_ordering`, `executing`, `qa`
     - edit policy `sourceAllowed`: `executing`, `qa`
     - edit policy `artifactsOnly`: all pre-execution agent phases
     - human/Plannotator review gates:
       - `high_level_user_review` → high-level plan review
       - `detailed_user_review` → detailed plan review
     - prompt kinds for each phase.

3. **Centralize metadata access**
   - Add helpers such as:
     - `stateMeta(state: WorkflowState): ChangeflowStateMeta`
     - `currentStateMeta(): ChangeflowStateMeta`
     - `statesWithMeta(predicate)` or explicit helper lookups where reverse maps are needed.
   - Read metadata from the canonical in-code `machineDefinition`. Existing persisted workflow files do not need special legacy behavior; if their stored `machineDefinition` lacks meta, runtime behavior should still come from the canonical definition.

4. **Replace hard-coded state-name logic with metadata-driven helpers**
   - `shouldAutoContinue` reads `meta.autoContinue`.
   - `tool_call` edit blocking reads `meta.editPolicy`.
   - `reviewKindForState` reads `meta.reviewGate`.
   - `reviewStateForKind` derives from states whose metadata declares that review kind.
   - `phasePrompt` uses `meta.prompt.kind` to choose/compose instructions, reducing direct state switches.
   - Plan submission tools use metadata-derived allowed states/submission behavior where practical.

5. **Keep Plannotator behavior compatible but prepare for arguments/modes**
   - Extend Plannotator request handling to accept metadata-derived action/artifact/mode values.
   - Keep current plan-review payload behavior unchanged initially.
   - Structure the implementation so adding diff/code-review modes later is a metadata change plus a request payload adapter, not another state-name conditional.

6. **Update docs and persisted examples**
   - Update `pi/extensions/changeflow/README.md` to describe workflow state metadata and how behavior composes.
   - Clarify that runtime behavior is driven from the canonical machine metadata in code.
   - Keep manual verification steps aligned with current behavior.

## Files likely to change

- `pi/extensions/changeflow/index.ts`
  - Add metadata types and helpers.
  - Annotate `machineDefinition` states.
  - Refactor auto-continue, edit policy, review mapping, and prompt selection to consume metadata.
- `pi/extensions/changeflow/README.md`
  - Document the metadata model and behavior mapping.

## Reuse opportunities

- Reuse XState v5 state `meta` support; no new dependency required.
- Reuse existing Plannotator integration (`requestPlanReview`, `requestReviewStatus`, review-result listener).
- Reuse current prompt text and transitions to avoid changing runtime behavior while refactoring structure.

## Risks and mitigations

- **Metadata shape could become too broad too early.** Mitigate by implementing the fields required by current behavior while allowing argument objects for future Plannotator modes.
- **Changing review mapping can break Plannotator correlation.** Preserve existing review kinds/events and verify pending review reconciliation still works.
- **Prompt refactor could accidentally alter agent behavior.** Keep prompt text semantically identical in this change.

## Verification

- Run `cd pi/extensions/changeflow && npm run check`.
- Start or resume a workflow and verify:
  - research/planning phases auto-continue as before
  - review gates do not auto-continue
  - source edits are blocked before execution/QA and allowed during execution/QA
  - high-level and detailed plan submissions still open Plannotator and transition to the correct review gate
  - review approval/rejection transitions still queue the correct next phase
