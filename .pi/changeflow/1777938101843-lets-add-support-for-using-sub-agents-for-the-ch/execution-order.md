# Execution order: Changeflow subagent orchestration

## Overall ordering

This MVP should be implemented mostly sequentially because the early steps establish the subagent runner API and later steps depend on its shape.

## Sequential critical path

1. **Step 1 — Extract subagent runner types and module skeleton**
   - Must happen first to define the local abstraction and role registry.

2. **Step 2 — Implement subprocess JSON-mode single-agent runner**
   - Depends on Step 1 types and config.

3. **Step 3 — Persist subagent run artifacts**
   - Depends on Step 2 runner behavior and result shape.

4. **Step 4 — Register `changeflow_run_subagent` tool**
   - Depends on Steps 1–3.
   - This is the integration point between the runner and the current Changeflow extension.

5. **Step 5 — Update phase prompts for orchestrator behavior**
   - Depends on Step 4 tool schema/name and role guards.

6. **Step 6 — Add execution-order artifact support**
   - Can be done after Step 5; if time is short, document/manual artifact is acceptable.

7. **Step 7 — Decide/document agent review gate deferral**
   - Depends on Step 5 prompt behavior.

8. **Step 8 — Update README and safety documentation**
   - Depends on implemented behavior from Steps 4–7.

9. **Step 9 — Validation and manual smoke test**
   - Final verification after all code/docs changes.

## Parallel opportunities

The following can be done in parallel only after the runner skeleton exists:

- Draft README sections while Steps 2–4 are being implemented, but reconcile after implementation.
- Draft phase prompt text after the `changeflow_run_subagent` tool schema is stable.
- Explore execution-order tool implementation while runner work proceeds, because it only touches existing Changeflow workflow tooling.

## Explicit non-parallel areas

- Do not implement subprocess runner, artifact persistence, and Changeflow tool registration in parallel in the same files without coordination; these are tightly coupled.
- Do not run parallel source-editing subagents in this MVP.
- Do not wire the dormant `high_level_agent_review` / `detailed_agent_review` states until the basic subagent runner is stable.

## Execution mode for MVP

Implementation should be driven in the main Pi session. Subagents introduced by this change are a feature being implemented, not required to implement the feature itself. After the feature is available, QA can smoke-test read-only and worker roles through `changeflow_run_subagent`.
