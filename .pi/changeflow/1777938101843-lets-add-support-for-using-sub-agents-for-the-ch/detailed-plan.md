# Detailed plan: Changeflow subagent orchestration

## Implementation sequence

### Step 1 — Extract subagent runner types and module skeleton

**Files**

- Create `pi/extensions/changeflow/subagents.ts`.
- Update `pi/extensions/changeflow/tsconfig.json` to include the new file.

**Tasks**

1. Define core types:
   - `ChangeflowSubagentRole` (`scout`, `planner`, `worker`, `reviewer`, `qa`).
   - `ChangeflowSubagentConfig` with role/name, description, tools, optional model/thinking, and system prompt.
   - `ChangeflowSubagentRunInput` with workflow id, artifacts dir, cwd, role, task, phase, optional step id, and mode/concurrency metadata.
   - `ChangeflowSubagentRunResult` with run id, role, task, exit code, final output, stderr, usage, artifact paths, optional error.
2. Add a small built-in role registry in this module.
3. Keep this module independent of active workflow state; it should receive everything it needs as parameters.

**Dependencies**

- None.

**Verification**

- `cd pi/extensions/changeflow && npm run check` should pass after adding the skeleton.

---

### Step 2 — Implement subprocess JSON-mode single-agent runner

**Files**

- `pi/extensions/changeflow/subagents.ts`

**Tasks**

1. Borrow the safe subprocess pattern from Pi’s official subagent example:
   - determine the Pi invocation from the current process when possible,
   - spawn `pi --mode json -p --no-session`,
   - pass role-specific `--tools`, optional `--model`, and optional `--thinking`/model thinking suffix if used,
   - pass the role system prompt through a secure temp file using `--append-system-prompt`,
   - pass the task as `Task: ...` or via temp file if long.
2. Parse stdout as JSONL and collect:
   - `message_end` assistant/tool messages,
   - final assistant text,
   - usage totals,
   - model/stop reason/error message.
3. Capture stderr.
4. Propagate `AbortSignal` by sending `SIGTERM`, then `SIGKILL` after a grace period.
5. Do not expose Changeflow lifecycle tools or recursive subagent tools to child agents for the MVP; use CLI tool allowlists for built-ins.

**Dependencies**

- Step 1.

**Verification**

- Typecheck.
- Later integration can invoke a read-only role and confirm final output is returned.

---

### Step 3 — Persist subagent run artifacts

**Files**

- `pi/extensions/changeflow/subagents.ts`

**Tasks**

1. Add artifact path creation under:
   - `.pi/changeflow/<workflow-id>/subagents/<timestamp>-<role>-<slug>/`
2. Write:
   - `input.md` containing role, phase, task, cwd, and any step id.
   - `output.md` containing final output or failure summary.
   - `metadata.json` containing role, command args (redacted if needed), exit code, usage, model, timestamps, and errors.
   - optional `events.jsonl` transcript with child JSON events.
3. Ensure artifact writes use `mkdirSync(..., { recursive: true })` and avoid source-tree edits outside the workflow artifacts directory.

**Dependencies**

- Step 2.

**Verification**

- A manual/local invocation should create the expected artifact files.
- Typecheck.

---

### Step 4 — Register a Changeflow subagent tool for orchestrator use

**Files**

- `pi/extensions/changeflow/index.ts`
- `pi/extensions/changeflow/subagents.ts`

**Tasks**

1. Import the runner into `index.ts`.
2. Register a tool, e.g. `changeflow_run_subagent`, with parameters:
   - `role`: `scout | planner | worker | reviewer | qa`
   - `task`: string
   - optional `stepId`: string
   - optional `reason`: string
3. Enforce workflow-state/role guards:
   - `research`: allow `scout` only.
   - `high_level_planning`, `high_level_revision`, `detailed_planning`: allow `planner`, maybe `reviewer` for critique if read-only.
   - `execution_ordering`: allow `planner`.
   - `executing`: allow `worker` and `reviewer`.
   - `qa`: allow `reviewer` and `qa`.
   - review/waiting states: block.
4. Call `runChangeflowSubagent` with `ctx.cwd`, active workflow id/artifacts dir/state, `ctx.signal`, and return a concise result including artifact paths.
5. Ensure child failures return `isError: true` without advancing workflow state.
6. Optionally render a compact tool result showing role, status, output preview, usage, and artifact directory.

**Dependencies**

- Steps 1–3.

**Verification**

- Typecheck.
- From a test workflow, the main agent can call the tool during allowed states.
- The tool is blocked in disallowed states.

---

### Step 5 — Update phase prompts so the main thread is explicitly the orchestrator

**Files**

- `pi/extensions/changeflow/index.ts`

**Tasks**

1. Add common orchestrator instructions to `phasePrompt()`:
   - The main session owns Changeflow state and lifecycle transitions.
   - Subagents are delegated workers with isolated context.
   - The main session must synthesize subagent outputs before recording decisions or submitting plans.
   - Only the main session may call `changeflow_advance` and plan-submission tools.
2. Update specific phase instructions:
   - `research`: suggest `changeflow_run_subagent` with `scout` for codebase reconnaissance before recording findings.
   - `high_level_planning`: suggest planner/reviewer subagents for plan generation/critique before submission.
   - `detailed_planning`: suggest planner subagent for step expansion.
   - `execution_ordering`: instruct creation of an execution-order artifact and identify sequential vs parallel candidates, but keep MVP execution sequential.
   - `executing`: delegate approved steps to worker subagents one at a time where useful.
   - `qa`: delegate review/QA checks to reviewer/QA subagents.
3. Keep prompts concise to avoid bloating context.

**Dependencies**

- Step 4, or can be done in parallel after the intended tool schema is known.

**Verification**

- Inspect prompt text manually.
- Confirm stale queued continuation behavior remains safe because `queuePhaseContinuation()` still queues only the minimal continuation message.

---

### Step 6 — Add execution-order artifact support

**Files**

- `pi/extensions/changeflow/index.ts`

**Tasks**

1. Extend workflow context with optional `executionOrderPath` if desired.
2. Add a new Changeflow tool or extend existing flow to persist `execution-order.md` under the workflow artifacts directory.
   - A minimal tool could be `changeflow_submit_execution_order({ markdown })` that is valid only in `execution_ordering` and transitions with `ORDER_DEFINED`.
   - Alternatively, keep the current `changeflow_advance(ORDER_DEFINED)` and instruct the agent to write the artifact directly under artifacts before advancing.
3. For MVP, prefer a dedicated tool if time allows; otherwise document the expected artifact.

**Dependencies**

- Can be done after Step 5.

**Verification**

- Typecheck.
- Execution ordering produces a durable artifact before entering `executing`.

---

### Step 7 — Wire agent review states only if needed, otherwise document deferral

**Files**

- `pi/extensions/changeflow/index.ts`
- `pi/extensions/changeflow/README.md`

**Tasks**

1. Decide whether `high_level_agent_review` and `detailed_agent_review` should be activated in this iteration.
2. Recommended MVP: do not change the state machine topology yet; use reviewer/planner subagents inside existing planning states before human review.
3. Document that separate agent review gates are deferred until the first subagent runner is stable.

**Dependencies**

- Step 5.

**Verification**

- Existing Plannotator approval/rejection flow remains unchanged.

---

### Step 8 — Update README and safety documentation

**Files**

- `pi/extensions/changeflow/README.md`

**Tasks**

1. Document the orchestrator model.
2. Document the `changeflow_run_subagent` tool and allowed roles by phase.
3. Document artifact layout.
4. Document safety model:
   - child agents are subprocesses,
   - read-only roles use read-only tools,
   - implementation roles only allowed in execution/QA,
   - no parallel implementation/worktree support in MVP,
   - project-local prompt/agent trust considerations.
5. Document future options:
   - SDK child sessions,
   - package-backed runner,
   - background async jobs,
   - forked context,
   - git worktree isolation.

**Dependencies**

- Steps 4–7 so docs match implemented behavior.

**Verification**

- Manual README review.

---

### Step 9 — Validation and manual smoke test

**Commands**

1. `cd pi/extensions/changeflow && npm run check`
2. Restart/reload Pi if needed.
3. Start a throwaway Changeflow workflow.

**Manual smoke test**

1. In `research`, run a `scout` subagent against a small task.
2. Confirm artifacts appear under `.pi/changeflow/<id>/subagents/`.
3. Confirm source edits remain blocked during research/planning.
4. Submit a high-level plan and verify Plannotator still opens.
5. Approve through detailed planning to execution ordering.
6. Confirm `worker` is blocked before `executing` and allowed in `executing`.
7. Abort a running subagent and confirm the child process terminates and the parent workflow remains valid.

---

## Dependency graph / execution ordering

- Steps 1 → 2 → 3 → 4 are sequential.
- Step 5 depends on the tool schema from Step 4 but can be drafted in parallel after Step 1.
- Step 6 can be implemented independently after familiarizing with `index.ts` workflow tools.
- Step 7 should happen after Step 5.
- Step 8 depends on final behavior from Steps 4–7.
- Step 9 is final validation.

## Parallelization guidance

For this implementation, do not use parallel source-editing subagents. Parallelism is acceptable only for read-only roles after the single-agent runner is stable. Full dependency-aware parallel implementation should wait for git worktree isolation.

## Rollback strategy

- Keep the subagent runner isolated in `subagents.ts`.
- If subprocess integration is unstable, disable or remove only `changeflow_run_subagent` and leave the existing Changeflow lifecycle untouched.
- Do not change existing Plannotator review transitions unless required.

## Acceptance criteria

- Changeflow exposes a guarded subagent invocation path usable by the main orchestrator.
- Subagent runs are isolated child Pi processes with role-specific tool limits.
- Subagent outputs are persisted as workflow artifacts.
- The main session remains responsible for lifecycle transitions and plan submission.
- Existing Changeflow research/planning/review/execute/QA flow still works.
- Typechecking passes.
