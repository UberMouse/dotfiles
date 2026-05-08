Read-only reconnaissance complete.

## Primary implementation files

### `pi/extensions/changeflow/index.ts`
Main Changeflow extension: workflow state machine, persistence, phase behavior, prompts, tools, review integration.

Key symbols / areas:

- `WorkflowState` union near top  
  Defines all legal phase/state names. Must stay in sync with machine states and `workflowStateList`.

- `PromptKind`, `EditPolicy`, `PlannotatorMeta`, `ChangeflowStateMeta`, `ChangeflowStateConfig`  
  Metadata schema for state-node behavior:
  - `autoContinue`
  - `editPolicy`
  - `prompt.kind`
  - `reviewGate`
  - `plannotator`
  - `submission`

- `const machineDefinition = { ... }` at `index.ts:112`  
  Central state machine definition. This is the main place where phase transitions and current metadata live.

  Examples:
  - `research.meta.changeflow.autoContinue/editPolicy/prompt`
  - `high_level_planning.submission/plannotator`
  - review states have `reviewGate`
  - `executing` and `qa` set `editPolicy: "sourceAllowed"`

- `const changeflowMachine = createMachine(machineDefinition)` at `index.ts:218`  
  XState v5 execution wrapper.

- Metadata access helpers:
  - `canonicalStateConfig()` / `stateMeta()` around `index.ts:220`
  - `statesMatchingMeta()` derives submission/review states from metadata.

- Transition behavior:
  - `initialWorkflowSnapshot()` initializes new workflows by sending `START`.
  - `applyTransition()` at `index.ts:305` restores actor from persisted snapshot, checks `can()`, sends event, persists `actor.getPersistedSnapshot()`.

- Auto-continuation:
  - `shouldAutoContinue()` uses `stateMeta(state).autoContinue`.
  - `queuePhaseContinuation()` at `index.ts:346` sends minimal `"Continue the current Changeflow phase."`

- Phase prompts:
  - `phasePrompt()` at `index.ts:366` is still a large hardcoded switch on `stateMeta(workflow.state).prompt?.kind`.
  - The state machine metadata only selects a prompt kind; full prompt text remains hardcoded here.
  - This is a likely change point if moving prompts fully into metadata/config.

- Hardcoded subagent role policy:
  - `allowedSubagentRoles()` at `index.ts:502` is a switch by workflow state.
  - Not currently in `machineDefinition.meta`.
  - Likely change point if model/agent settings should become per-phase metadata.

- Plannotator/review behavior:
  - `applyReviewResult()` at `index.ts:553`
  - `requestPlanReview()` at `index.ts:615`
  - These use metadata helpers like `reviewStateForKind()`, `submittedEventForKind()`, `stateMeta(...).plannotator`.

- Tool guards and phase-specific behavior:
  - submit tools derive allowed states from `submission` metadata.
  - `before_agent_start` at `index.ts:929` injects `phasePrompt(activeWorkflow)`.
  - `tool_call` hook at `index.ts:944` enforces `editPolicy`.

## Subagent configuration

### `pi/extensions/changeflow/subagents.ts`
Defines role-level subagent config and subprocess invocation.

Key symbols:

- `ChangeflowSubagentConfig` at `subagents.ts:20`
  ```ts
  {
    role;
    name;
    description;
    tools;
    model?;
    thinking?;
    systemPrompt;
  }
  ```

- `changeflowSubagentRoles` at `subagents.ts:69`  
  Current role definitions:
  - `scout`
  - `planner`
  - `worker`
  - `reviewer`
  - `qa`

  Each role has:
  - allowed tool list
  - hardcoded `systemPrompt`
  - optional `model`
  - optional `thinking`

  **Observation:** no role currently sets `model` or `thinking`; defaults are inherited from Pi unless configured later.

- `applyThinkingSuffix()` at `subagents.ts:145`  
  Converts `{ model, thinking }` into Pi model syntax like `model:high`.

- Subprocess args at `subagents.ts:241`
  ```ts
  ["--mode", "json", "-p", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates"]
  ```
  Then optionally:
  - `--model <model[:thinking]>`
  - `--tools <comma-separated allowlist>`
  - `--append-system-prompt <temp prompt file>`

## Package / extension loading

### `pi/extensions/changeflow/package.json`
Declares extension entry:

```json
"pi": {
  "extensions": [
    "./index.ts"
  ]
}
```

Dependencies include:
- `xstate`
- `typebox`
- Pi types/dev deps

Validation:
- `npm run check`
- `npm run build`
Both run `tsc --noEmit`.

## Documentation / design notes

### `pi/extensions/changeflow/README.md`
Good overview of current architecture.

Relevant sections:
- Lifecycle
- XState execution
- State metadata
- Subagent orchestration MVP
- Safety model
- Plannotator integration

Important doc evidence:
- State behavior is intended to live under `meta.changeflow`.
- Current metadata fields are explicitly documented.
- Subagent runner is still MVP and role-scoped.

### `pi/extensions/changeflow/issues.md`
Contains known issues around stale queued phase prompts and state guards. Useful if changing prompt/continuation behavior.

## Current patterns

- Source of truth for lifecycle transitions: `machineDefinition.states[phase].on`.
- Source of truth for many phase behaviors: `machineDefinition.states[phase].meta.changeflow`.
- Still hardcoded outside metadata:
  - full phase prompt text in `phasePrompt()`
  - allowed subagent roles in `allowedSubagentRoles()`
  - subagent role prompts/tools/model/thinking in `changeflowSubagentRoles`
  - `WorkflowState` union and `workflowStateList`
  - artifact filenames in start/submission tools
  - some command/tool state guards, though many now derive from metadata.

## Likely change points

1. `ChangeflowStateMeta` in `index.ts`  
   Add fields for per-phase agent/subagent config, e.g. allowed roles, model, thinking/effort, prompt body/template.

2. `machineDefinition` in `index.ts`  
   Move more phase-specific config into `meta.changeflow`.

3. `phasePrompt()` in `index.ts`  
   Replace hardcoded switch with metadata-driven prompt/template rendering.

4. `allowedSubagentRoles()` in `index.ts`  
   Replace switch with `stateMeta(state).subagents` or similar.

5. `changeflowSubagentRoles` in `subagents.ts`  
   Current role defaults live here. Could become base defaults merged with phase-specific overrides from metadata.

6. `runChangeflowSubagent()` call site in `index.ts`  
   Currently passes role/task/phase only. Would need to pass resolved model/thinking/system prompt/tools if per-phase overrides are introduced.

## Risks

- State names are duplicated across `WorkflowState`, `machineDefinition`, and `workflowStateList`.
- Moving prompts/config into metadata can bloat `machineDefinition`, which is persisted into workflow JSON.
- XState metadata must remain serializable if stored in workflow artifacts.
- Per-phase model/thinking config needs clear precedence vs role defaults vs Pi CLI defaults.
- Child subagents run with `--no-extensions`, so they cannot access Changeflow tools; this is intentional safety behavior.