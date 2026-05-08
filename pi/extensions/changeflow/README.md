# Changeflow Pi Extension

Changeflow is an experimental Pi workflow-orchestrator extension for persistent, state-machine-driven code changes.

This directory captures the MVP scaffold for the idea discussed in-session: a persisted context container for a change, scaling from a small scoped patch to a larger change made of smaller reviewed steps.

## Goal

Turn a vague change request into a durable workflow instance with:

- persistent change context on disk
- a state-machine lifecycle
- phase-specific Pi prompt injection
- phase-specific tool restrictions
- review/approval gates
- Plannotator-backed human review when plans or code need annotation
- eventual sub-agent support for plan audits, step enrichment, execution review, and QA

## Current MVP scope

The scaffold intentionally starts smaller than the full vision:

1. Create/resume one active workflow per Pi session/project.
2. Persist workflow state to `.pi/changeflow/<workflow-id>/workflow.json`.
3. Persist a pointer/snapshot into the Pi session via `pi.appendEntry()`.
4. Load named workflow definitions, defaulting to the built-in `changeflow.mvp` definition when none is specified.
5. Inject phase instructions with `before_agent_start`.
6. Provide workflow tools for recording research, submitting plans, and advancing lifecycle events.
7. Automatically queue the next agent-owned phase after successful transitions while preserving human gates.
8. Use Plannotator's shared event API for high-level plan review when available.
9. Block model-initiated writes/edits outside the active workflow artifacts directory before execution/QA.

True XState execution, SDK-spawned sub-agents, dependency-aware parallel execution, and git worktree isolation are planned next iterations. The current subagent MVP uses isolated `pi --mode json` subprocesses behind a Changeflow-specific runner abstraction so the implementation can later swap to SDK sessions or package-backed infrastructure.

## Commands

| Command | Description |
| --- | --- |
| `/changeflow start <description>` | Start a new workflow from a change description using the default `changeflow.mvp` definition |
| `/changeflow start --workflow <id> <description>` | Start a new workflow using a named workflow definition |
| `/changeflow workflows` | List loaded workflow definitions |
| `/changeflow status` | Show the active workflow state, selected definition, and artifact paths |
| `/changeflow advance <event>` | Manually send a lifecycle event for debugging/experimentation |
| `/changeflow review-plan` | Send the current high-level plan to Plannotator |
| `/changeflow clear` | Clear the active workflow pointer for the session |

Aliases are intentionally not added yet while the UX is still changing.

## Tools

The runtime exposes generic workflow tools. Workflow-specific behavior is encoded in trusted TypeScript workflow modules.

| Tool | Purpose |
| --- | --- |
| `changeflow_send_event` | Send a typed event to the active XState machine |
| `changeflow_get_state` | Inspect current state, pending main-agent task, edit policy, and artifacts |
| `changeflow_read_artifact` | Read a file under the workflow artifact directory |
| `changeflow_write_artifact` | Write a file under the workflow artifact directory |
| `changeflow_complete_main_task` | Complete a machine-invoked main-agent actor task |

## Lifecycle

The MVP machine is deliberately linear with explicit review loops:

```text
idle
research
high_level_planning
high_level_agent_review
high_level_user_review
high_level_revision
detailed_planning
detailed_agent_review
detailed_user_review
execution_ordering
executing
qa
user_validation
done
```

Important transitions:

- `START` → `research`
- `RESEARCH_COMPLETE` → `high_level_planning`
- `HIGH_LEVEL_PLAN_SUBMITTED` → `high_level_user_review`
- `USER_APPROVED` from high-level review → `detailed_planning`
- `USER_REJECTED` from high-level review → `high_level_revision`
- `DETAILED_PLAN_SUBMITTED` → `detailed_user_review`
- `USER_APPROVED` from detailed review → `execution_ordering`
- `ORDER_DEFINED` → `executing`
- `EXECUTION_COMPLETE` → `qa`
- `QA_COMPLETE` → `user_validation`
- `USER_APPROVED` from validation → `done`
- `USER_REJECTED` from validation → `qa`

## Workflow definitions and XState execution

Workflow definitions wrap an XState v5 machine config with Changeflow-specific metadata: an ID/name, optional `initialEvent`, and optional artifact templates. The bundled `changeflow.mvp` definition lives in its own workflow file, `bundled-workflows/changeflow-mvp.ts`, and is loaded through the same registry path as other definitions; its only special treatment is that it is bundled with Changeflow and selected by default. Additional JSON definitions can be loaded from `.pi/changeflow/workflows/*.json`; definitions are validated for duplicate IDs, valid initial state, transition targets, and initial event.

`index.ts` resolves the selected definition for each workflow instance and executes lifecycle transitions with XState v5. For each transition, Changeflow creates an actor from the selected definition and persisted `machineSnapshot`, starts it, checks whether the normalized event is valid from the current state, sends the event, then persists `actor.getPersistedSnapshot()` back to the workflow file.

New default workflows are initialized by sending `START` through the `changeflow.mvp` actor and storing the resulting persisted snapshot for `research`. If no workflow is specified on `/changeflow start`, `changeflow.mvp` is used. Persisted workflows record `workflowDefinitionId`; older workflows without this field default to `changeflow.mvp` when restored.

## State metadata

Contextual workflow behavior is declared on state nodes under `meta.changeflow` inside each loaded workflow definition and consumed through helper functions. This keeps behavior close to the selected workflow definition instead of scattering state-name checks across the extension.

Supported metadata fields include:

- `autoContinue`: queue the next agent turn after entering the state.
- `editPolicy`: either `artifactsOnly` or `sourceAllowed`.
- `prompt.instructions`: phase-specific prompt text appended to the common Changeflow context.
- `reviewGate`: declares human or agent approval gates and their review kind.
- `submission`: maps plan-producing states to the review kind/event they submit.
- `executionOrder`: maps the execution-ordering state to its artifact filename and submitted event.
- `plannotator`: declares the Plannotator action, artifact, and optional mode arguments.
- `subagents.allowedRoles`: declares which subagent roles may run in a state.
- `subagents.roleOverrides`: optional per-role overrides for child-agent `tools`, `model`, `thinking`, and additional `systemPrompt` instructions. Tool overrides can only narrow the role's default tool allowlist; empty or invalid narrowed toolsets fall back to the role defaults. Prompt overrides are appended after the default safety prompt.

Example:

```ts
high_level_planning: {
  meta: {
    changeflow: {
      autoContinue: true,
      editPolicy: "artifactsOnly",
      prompt: { instructions: phaseInstructions.highLevelPlanning },
      subagents: { allowedRoles: ["planner", "reviewer"] },
      submission: { reviewKind: "high_level_plan", submittedEvent: "HIGH_LEVEL_PLAN_SUBMITTED" },
      plannotator: { action: "plan-review", artifact: "highLevelPlanPath" },
    },
  },
  on: { HIGH_LEVEL_PLAN_SUBMITTED: "high_level_user_review" },
}
```

Human approval with Plannotator is represented by combining `reviewGate` and `plannotator` on the review state. Plannotator arguments such as `artifact` and `mode` are carried in metadata so future review modes can be added by changing the workflow declaration and request adapter. Subagent defaults live in `subagents.ts`, while state metadata can allow roles and override model/effort, tool scope, or prompt text for that phase.

Artifact templates are declared on workflow definitions and rendered when a workflow starts. The default definition creates `research.md` and `high-level-plan.md` with the same initial content as before.

The `package.json` declares `xstate`; local Pi extension dependencies should be installed next to the extension before development or runtime use:

```bash
cd ~/dotfiles/pi/extensions/changeflow
npm install
```

## Subagent orchestration MVP

Changeflow now exposes a small built-in subagent runner for orchestrator-driven delegation. The main Pi session remains the orchestrator: it owns workflow state, Plannotator/human gates, and lifecycle transitions. Subagents are child Pi subprocesses with isolated context and role-scoped built-in tools. Default role definitions are declared in `subagents.ts`; each workflow state decides which roles are available through `meta.changeflow.subagents.allowedRoles` and can override a role's model, thinking level, additional prompt instructions, or a narrowed tool set with `meta.changeflow.subagents.roleOverrides`.

### Roles

| Role | Allowed phases | Tool scope | Purpose |
| --- | --- | --- | --- |
| `scout` | `research` | read/grep/find/ls/bash | Read-only codebase reconnaissance |
| `planner` | planning and `execution_ordering` | read/grep/find/ls | Plan generation, step expansion, ordering advice |
| `reviewer` | planning critique, `executing`, `qa` | read/grep/find/ls/bash | Plan/code review and validation checks |
| `worker` | `executing` | read/grep/find/ls/bash/edit/write | Approved implementation steps |
| `qa` | `qa` | read/grep/find/ls/bash | Final validation/readiness review |

Review/wait states intentionally block subagent execution. Source-editing workers are only allowed once the workflow has entered `executing`.

### Artifact layout

Each subagent run writes durable artifacts under the active workflow directory:

```text
.pi/changeflow/<workflow-id>/subagents/<run-id>/
├── input.md       # delegated task and metadata
├── output.md      # final output or failure summary
├── metadata.json  # role, phase, usage, model, exit/error data
└── events.jsonl   # child Pi JSON-mode event stream
```

### Safety model

- Child agents run as separate `pi --mode json -p --no-session` subprocesses.
- Child processes are launched with `--no-extensions`, `--no-skills`, and `--no-prompt-templates` to avoid recursive subagent/Changeflow tools in the child.
- Role-specific `--tools` allowlists constrain read-only/planning vs implementation agents; metadata tool overrides are intersected with the role defaults so they can narrow but not broaden those safety boundaries, with empty/invalid intersections falling back to the defaults.
- The parent orchestrator must synthesize child output before recording decisions, submitting plans, or advancing the workflow.
- Parallel source-editing subagents are deferred until git worktree isolation exists.
- SDK child sessions, forked context, package-backed runners, background jobs, and dependency-aware parallelism remain future options.

## Development

Install local dependencies and run validation from the extension directory:

```bash
cd ~/dotfiles/pi/extensions/changeflow
npm install
npm run check
npm run build
```

`check` and `build` both run TypeScript with `noEmit`. Pi loads `index.ts` directly via jiti, so the build script is a validation/typecheck step rather than a JavaScript emit step.

## Plannotator integration

Changeflow integrates through Plannotator's shared event API instead of importing Plannotator internals:

- request channel: `plannotator:request`
- result channel: `plannotator:review-result`

For high-level and detailed plan review, Changeflow emits:

```ts
pi.events.emit("plannotator:request", {
  requestId,
  action: "plan-review",
  payload: { planContent, planFilePath, origin: "changeflow" },
  respond(response) { /* capture pending reviewId */ }
});
```

Then it listens for `plannotator:review-result` and transitions:

- approved → next phase, with automatic continuation when the next phase is agent-owned
- rejected → revision phase with feedback persisted in context and automatic continuation into revision

Queued continuations intentionally use a minimal message and rely on `before_agent_start` to inject fresh phase context from persisted workflow state. On session start and before agent turns, Changeflow also asks Plannotator for `review-status` for pending high-level and detailed plan reviews so completed reviews can be reconciled if the live result event was missed.

For QA/code validation, a later iteration should use Plannotator's `code-review` action.

## Design principles

- The extension owns state; the model only receives the currently valid phase instructions.
- Workflow transitions are events, and state behavior is declared as workflow metadata, not hidden in conversation text or scattered conditionals.
- Agent-owned phases advance through Changeflow tools; slash commands are a manual fallback.
- Artifacts live on disk and are stable across compaction/restart.
- Session entries store resumable pointers and snapshots, not the full source of truth.
- Human review uses Plannotator where possible.
- Agent review gates should eventually be SDK sub-agents, not prompts to the main agent.
- Parallel execution should eventually use dependency graphs and isolated worktrees.

## Current Plannotator review behavior

High-level and detailed plan review are integrated with Plannotator through the shared event API.

Expected behavior:

- `changeflow_submit_high_level_plan` saves `.pi/changeflow/<workflow-id>/high-level-plan.md` and requests a Plannotator review.
- `changeflow_submit_detailed_plan` saves `.pi/changeflow/<workflow-id>/detailed-plan.md` and requests a Plannotator review.
- If Plannotator accepts the request, Changeflow records the returned `reviewId` and transitions to the corresponding user review gate (`high_level_user_review` or `detailed_user_review`).
- If the reviewer rejects the high-level plan, Changeflow receives `plannotator:review-result`, records the feedback, transitions through `USER_REJECTED` to `high_level_revision`, and queues the revision phase.
- If the reviewer approves the high-level plan, Changeflow transitions through `USER_APPROVED` to `detailed_planning` and queues the detailed planning phase.
- If the reviewer rejects the detailed plan, Changeflow transitions through `USER_REJECTED` to `detailed_planning`, records feedback, and queues detailed planning again.
- If the reviewer approves the detailed plan, Changeflow transitions through `USER_APPROVED` to `execution_ordering` and queues execution ordering.
- If Pi reloads after a review was requested, Changeflow can still correlate the result when the `reviewId` exists in the persisted workflow `reviews` array.
- If a persisted pending review was completed while Changeflow missed the live result event, Changeflow reconciles it through Plannotator's `review-status` request on session/agent start.
- If Plannotator times out or is unavailable, the plan remains saved, workflow state is not advanced, and the review can be retried for high-level plans with `/changeflow review-plan`.
- If a high-level or detailed review is already pending at its review gate, Changeflow does not open a duplicate review window.

## Pre-execution write policy

Before `executing` or `qa`, model-initiated `write` and `edit` tool calls are restricted to the active workflow artifacts directory:

```text
.pi/changeflow/<workflow-id>/
```

This keeps research and planning from modifying source files or unrelated markdown files. Changeflow's own tools may still write workflow artifacts directly.

## Manual Plannotator integration verification

1. Apply the Pi settings containing `npm:@plannotator/pi-extension@0.19.4` and reload Pi.
2. Start a workflow: `/changeflow start <description>`.
3. Complete research with `changeflow_advance` using `RESEARCH_COMPLETE` and confirm high-level planning is queued automatically.
4. Submit a high-level plan with `changeflow_submit_high_level_plan`.
5. Confirm Plannotator opens a browser review and Changeflow waits at the review gate.
6. Reject with feedback and confirm Changeflow enters `high_level_revision`, includes the feedback in future phase prompts, and queues revision automatically.
7. Resubmit the revised plan.
8. Approve and confirm Changeflow enters `detailed_planning` and queues detailed planning automatically.
9. Submit a detailed plan with `changeflow_submit_detailed_plan` and confirm Plannotator opens a browser review.
10. Approve the detailed plan in Plannotator and confirm execution ordering is queued automatically.
11. Complete execution ordering, execution, and QA with `changeflow_advance` and confirm each next agent-owned phase is queued until `user_validation`.
12. During a pending review, reload Pi and confirm the result is still correlated through the persisted review id.
13. Temporarily make Plannotator unavailable and confirm Changeflow reports a retryable failure without advancing state.
14. During research/planning, verify model-initiated writes outside `.pi/changeflow/<workflow-id>/` are blocked.

## Suggested next iterations

1. Add Plannotator review for detailed plans and code review in QA.
2. Add SDK reviewer sub-agents for plan critique and QA audit.
3. Add an execution graph artifact and dependency-aware step scheduling.
4. Add optional git worktree isolation for parallel execution.
5. Consider replacing or augmenting the subprocess runner with SDK-backed child sessions once lifecycle/cancellation semantics are clearer.
