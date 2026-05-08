# QA: Changeflow subagent orchestration

## Validation performed

- Ran `cd /home/taylorl/dotfiles/pi/extensions/changeflow && npm run check`.
- Result: TypeScript check passed (`tsc --noEmit`).
- Reviewed `subagents.ts` for the expected subprocess runner behavior:
  - role registry exists for `scout`, `planner`, `worker`, `reviewer`, and `qa`;
  - child Pi process is launched with JSON mode, no session, no extensions, no skills, no prompt templates;
  - role-specific built-in tool allowlists are applied;
  - child stdout JSONL is parsed for assistant messages and usage;
  - stderr, exit code, stop reason, and errors are captured;
  - abort signal sends SIGTERM and later SIGKILL;
  - run artifacts are written under the active workflow artifact directory.
- Reviewed `index.ts` integration:
  - `changeflow_run_subagent` is registered with role/task/step/reason parameters;
  - role guards are state-specific;
  - child failures return `isError` and do not advance workflow state;
  - `changeflow_submit_execution_order` persists ordering and advances only from `execution_ordering`;
  - phase prompts now identify the main thread as orchestrator.
- Reviewed README updates for role table, artifact layout, and safety model.

## Notes

- I did not run a live child model smoke test from this session because the newly registered tool requires extension reload to appear in the current tool list. The implementation is typechecked and structurally follows Pi's official JSON-mode subprocess subagent example.
- Recommended user validation: reload Pi, start a throwaway Changeflow, and invoke `changeflow_run_subagent` with role `scout` during research to confirm artifacts are created.

## Result

QA passed for static/type validation and code review. Ready for user validation.
