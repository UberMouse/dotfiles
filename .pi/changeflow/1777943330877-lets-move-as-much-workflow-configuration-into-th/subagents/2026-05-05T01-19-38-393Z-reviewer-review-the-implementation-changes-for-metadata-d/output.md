Review findings:

- **High: subagent overrides can bypass phase/edit safety.**  
  `subagents.ts:30-34`, `subagents.ts:160-170`, `index.ts:903-918`  
  `roleOverrides.tools` replaces the default tool allowlist wholesale, and child Pi runs with `--no-extensions`, so the parent `tool_call` edit guard will not protect the child. A metadata override could give `edit/write` to `scout`, `planner`, or `reviewer` in `artifactsOnly` phases. `systemPrompt` replacement can also drop the safety instructions.  
  **Action:** constrain overrides to a safe subset of the base role tools, or validate against current state `editPolicy`; disallow `edit/write` unless explicitly in an execution/source-allowed state. Consider prompt “append/extraInstructions” instead of replacement, or always prepend immutable guardrails.

- **Medium: metadata type safety is weaker than it looks.**  
  `index.ts:48-64`, `index.ts:301-306`  
  `machineDefinition` is only `as const`, then state configs are cast to `ChangeflowStateConfig`. This means malformed `meta.changeflow` fields, typoed role names, wrong plannotator artifacts, or invalid submission events can slip through until runtime.  
  **Action:** use `satisfies` on the machine definition/state map, and preferably introduce a `WorkflowEvent` union for `on`, `submission.submittedEvent`, and `executionOrder.submittedEvent`.

- **Low/Medium: `plannotator.artifact` is documented as metadata-driven but not consumed.**  
  `index.ts:42-46`, `index.ts:610-630`, `index.ts:820-847`  
  Plan paths are still selected by hard-coded submit functions/context fields; `plannotator.artifact` does not drive the request path. This is okay for current behavior, but future metadata changes could silently not work.  
  **Action:** either remove the unused field for now or use it to resolve the artifact path consistently.

Validation:

- `npm run check` passes in `pi/extensions/changeflow`.
- Passing typecheck is **not sufficient** here because the main risks are behavioral/safety issues and are partly hidden by casts and runtime metadata interpretation. Add focused tests or static assertions for state metadata, allowed roles per phase, submission event validity, and override safety.

Prompt kind:

- I found no remaining `prompt.kind` references; prompt behavior now appears to use `prompt.instructions` only.