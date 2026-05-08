# High-level plan: Changeflow subagent orchestration

## Goal

Evolve Changeflow so the main Pi conversation acts as a workflow orchestrator while focused subagents perform research, planning, implementation, review, and QA work. The main thread should own workflow state, human review gates, and final decisions; subagents should produce bounded outputs that are persisted as Changeflow artifacts.

## Recommended approach

Start with a Changeflow-owned subprocess runner modeled on Pi’s official `examples/extensions/subagent` JSON-mode implementation, not a full SDK rewrite or hard dependency on a third-party package.

Rationale:

- Pi officially supports subagent-like behavior via extensions and subprocesses.
- Separate `pi --mode json` child processes provide strong context isolation and clear model/tool boundaries.
- This is easier to integrate into the current Changeflow extension than nested SDK sessions.
- A local abstraction can later be swapped for SDK-based sessions or a package such as `@cmf/pi-subagent`/`pi-subagents`.

## Scope for the first iteration

1. Add a small internal subagent runner abstraction to `pi/extensions/changeflow`.
2. Define Changeflow-specific agent roles:
   - `scout` / `researcher`: read-only codebase investigation.
   - `planner`: read-only plan generation/refinement.
   - `worker`: implementation of approved steps.
   - `reviewer` / `qa`: review and validation.
3. Persist every subagent run under the active workflow artifacts directory, for example:
   - `.pi/changeflow/<id>/subagents/<run-id>/input.md`
   - `.pi/changeflow/<id>/subagents/<run-id>/output.md`
   - `.pi/changeflow/<id>/subagents/<run-id>/metadata.json`
   - optional JSONL transcript.
4. Update phase prompts so the main agent is explicitly instructed to orchestrate and synthesize subagent outputs rather than doing all work itself.
5. Ensure only the main orchestrator calls Changeflow lifecycle tools (`changeflow_advance`, plan submission tools, etc.). Child agents should return findings/plans/patch summaries/reviews only.
6. Keep parallel execution conservative for the first iteration: allow parallel read-only research/review, but keep implementation sequential unless worktree isolation is added.

## Integration points in the existing workflow

- `research`: invoke one or more read-only scout/researcher subagents, then record synthesized findings with `changeflow_record_research`.
- `high_level_planning`: optionally invoke planner/oracle-style critique subagents, then submit the plan for Plannotator review.
- `detailed_planning`: use planner subagents to expand approved scope into concrete steps.
- `execution_ordering`: produce an execution-order artifact that identifies sequential vs potentially parallel steps.
- `executing`: delegate approved steps to worker subagents, initially sequentially.
- `qa`: delegate review/test-focused checks to reviewer/QA subagents, then synthesize results.

## Files likely to change

- `pi/extensions/changeflow/index.ts`
  - Add runner helpers or import them from new local files.
  - Add subagent-related workflow metadata/state where needed.
  - Update phase prompts.
  - Add tools/commands for invoking or inspecting Changeflow subagent runs if appropriate.
- New local module(s), likely under `pi/extensions/changeflow/`:
  - `subagents.ts` or `subagents/runner.ts`
  - optional `subagents/agents.ts` for built-in agent definitions.
- `pi/extensions/changeflow/package.json` / `tsconfig.json`
  - Include new source files in typechecking.
- `pi/extensions/changeflow/README.md`
  - Document the orchestration model, security model, artifact layout, and limitations.

## Reuse opportunities

- Borrow the official Pi subagent example’s subprocess JSON-mode parsing, abort propagation, single/parallel/chain concepts, and usage aggregation.
- Borrow third-party package design ideas without taking an immediate dependency:
  - fresh vs forked context,
  - child recursion guards,
  - artifact persistence,
  - worktree isolation for future parallel implementation,
  - role-based agents with scoped tools/models.

## Security and safety considerations

- Default child agents should be embedded or user-level trusted definitions; project-controlled agent prompts should require explicit opt-in/confirmation.
- Child agents should not receive recursive `subagent` capability by default.
- Research/planning children should use read-only tools.
- Implementation children should only run during `executing`/`qa` and within approved scope.
- Parallel implementation should be deferred until git worktree isolation exists.

## Risks

- Subprocess startup overhead and model cost can increase quickly.
- Child output can be too verbose; artifacts plus summaries should prevent bloating the parent context.
- Same-worktree parallel writes can conflict; avoid initially.
- Passing stale workflow context to child prompts can cause drift; child prompts should include current persisted workflow artifacts and explicit phase/step instructions.

## Verification

- Run `npm run check` in `pi/extensions/changeflow`.
- Start a test Changeflow and confirm research/planning can invoke child agents without source edits.
- Confirm subagent artifacts are written under the active workflow directory.
- Confirm child failures/aborts are surfaced to the parent and do not corrupt workflow state.
- Confirm pre-execution edit blocking still works.
- Confirm Plannotator plan review flow still works after prompt changes.
