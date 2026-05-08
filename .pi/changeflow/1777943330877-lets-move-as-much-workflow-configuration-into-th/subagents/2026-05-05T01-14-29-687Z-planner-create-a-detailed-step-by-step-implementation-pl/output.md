## Detailed implementation plan: metadata-driven Changeflow configuration

### Dependencies / order

1. Update `subagents.ts` first to support config overrides at the runner boundary.
2. Update `index.ts` metadata types and `machineDefinition`.
3. Refactor `index.ts` helpers to consume metadata instead of switches.
4. Update `README.md`.
5. Run validation and do targeted manual checks.

---

## Step 1: Add subagent override support in `pi/extensions/changeflow/subagents.ts`

### Concrete edits

1. Add a new exported override type near `ChangeflowSubagentConfig`:

```ts
export type ChangeflowSubagentConfigOverride = {
  tools?: string[];
  model?: string;
  thinking?: ChangeflowSubagentConfig["thinking"];
  systemPrompt?: string;
};
```

2. Add an optional override field to `ChangeflowSubagentRunInput`:

```ts
configOverride?: ChangeflowSubagentConfigOverride;
```

3. Add a helper to merge defaults with overrides:

```ts
function resolveSubagentConfig(
  role: ChangeflowSubagentRole,
  override?: ChangeflowSubagentConfigOverride,
): ChangeflowSubagentConfig {
  const base = changeflowSubagentRoles[role];

  return {
    ...base,
    tools: override?.tools ?? base.tools,
    model: override?.model ?? base.model,
    thinking: override?.thinking ?? base.thinking,
    systemPrompt: override?.systemPrompt ?? base.systemPrompt,
  };
}
```

4. In `runChangeflowSubagent`, replace:

```ts
const config = changeflowSubagentRoles[input.role];
```

with:

```ts
const config = resolveSubagentConfig(input.role, input.configOverride);
```

5. Add safety validation helper so metadata cannot accidentally grant tools a role does not normally have:

```ts
function validateToolOverride(role: ChangeflowSubagentRole, tools: string[] | undefined): string | undefined {
  if (!tools) return undefined;
  const allowed = new Set(changeflowSubagentRoles[role].tools);
  const disallowed = tools.filter((tool) => !allowed.has(tool));
  return disallowed.length > 0
    ? `Subagent ${role} tool override includes disallowed tools: ${disallowed.join(", ")}`
    : undefined;
}
```

6. In `runChangeflowSubagent`, before resolving config, reject invalid tool overrides by returning a normal failed `ChangeflowSubagentRunResult` after artifacts are created, or simpler: validate after artifacts creation and write `output.md`/`metadata.json` with `exitCode: 1`.

Preferred minimal approach:
- Create artifacts as currently done.
- If invalid override exists, write failure output/metadata and return failed result.
- This keeps runner behavior observable in subagent artifacts.

### Verification

- Run:

```bash
cd pi/extensions/changeflow
npm run check
```

- Confirm no type errors.
- Confirm existing calls to `runChangeflowSubagent` still compile without `configOverride`.

### Risks

- Tool override safety behavior must be strict: metadata should be able to narrow tools, not broaden them.
- If future work needs broader tools, add an explicit trusted escape hatch later rather than now.

---

## Step 2: Extend metadata types in `pi/extensions/changeflow/index.ts`

### Concrete edits

1. Update import from `subagents.ts`:

```ts
import {
  runChangeflowSubagent,
  summarizeSubagentResult,
  type ChangeflowSubagentConfigOverride,
  type ChangeflowSubagentRole,
} from "./subagents.js";
```

2. Replace `PromptKind` usage with metadata that supports embedded instructions while preserving `kind` for compatibility/debugging:

```ts
type PhasePromptMeta = {
  kind?: PromptKind;
  instructions?: string;
};
```

3. Add subagent metadata types:

```ts
type SubagentPhaseMeta = {
  allowedRoles?: ChangeflowSubagentRole[];
  overrides?: Partial<Record<ChangeflowSubagentRole, ChangeflowSubagentConfigOverride>>;
};
```

4. Add metadata for execution-order artifact submission:

```ts
type ArtifactSubmissionMeta = {
  artifactName: string;
  contextPath: "executionOrderPath";
  submittedEvent: string;
};
```

5. Update `ChangeflowStateMeta`:

```ts
type ChangeflowStateMeta = {
  autoContinue?: boolean;
  editPolicy?: EditPolicy;
  prompt?: PhasePromptMeta;
  reviewGate?: { actor: "human" | "agent"; kind: ReviewKind };
  plannotator?: PlannotatorMeta;
  submission?: { reviewKind: ReviewKind; submittedEvent: string };
  artifactSubmission?: ArtifactSubmissionMeta;
  subagents?: SubagentPhaseMeta;
};
```

### Verification

- Run `npm run check` after type edits.
- Expect temporary errors until `machineDefinition` and helpers are updated; resolve in later steps.

### Risks

- `machineDefinition` is persisted into workflow files, so all new metadata must remain JSON-serializable.
- Do not place functions, classes, Sets, or imported objects inside metadata.

---

## Step 3: Move phase prompt bodies into `machineDefinition` metadata

### Concrete edits in `index.ts`

1. Add reusable prompt strings above `machineDefinition`:

```ts
const promptInstructions = {
  research: `Research phase instructions:
- Gather codebase context for this change.
...`,
  highLevelPlanning: `High-level planning instructions:
- Synthesize research into a concise plan/spec.
...`,
  highLevelUserReview: `Waiting for human high-level plan review in Plannotator. Do not proceed until review result is received.`,
  detailedPlanning: `Detailed planning instructions:
- Expand the approved high-level plan into step-by-step implementation tasks.
...`,
  detailedUserReview: `Waiting for human detailed plan review in Plannotator. Do not proceed until review result is received.`,
  executionOrdering: `Execution ordering instructions:
- Define which detailed steps must run sequentially and which could run in parallel.
...`,
  executing: `Execution instructions:
- Source edits are now allowed.
...`,
  qa: `QA instructions:
- Review the whole output.
...`,
  userValidation: `Waiting for final user validation. If rejected, return to QA. If approved, finish the workflow.`,
} as const;
```

2. For each relevant state in `machineDefinition`, change prompt metadata from:

```ts
prompt: { kind: "research" }
```

to:

```ts
prompt: { kind: "research", instructions: promptInstructions.research }
```

Do this for:
- `research`
- `high_level_planning`
- `high_level_user_review`
- `high_level_revision`
- `detailed_planning`
- `detailed_user_review`
- `execution_ordering`
- `executing`
- `qa`
- `user_validation`

3. Replace the large `phasePrompt()` switch with generic assembly:

```ts
function phasePrompt(workflow: Workflow): string {
  const feedback = workflow.context.latestFeedback ? `\n\nLatest review feedback:\n${workflow.context.latestFeedback}` : "";
  const orchestrator = `

Orchestrator instructions:
- This main Pi session owns Changeflow state, lifecycle transitions, and human review gates.
- Use changeflow_run_subagent when focused isolated research, planning, implementation, review, or QA would help.
- Subagents are delegated workers. Synthesize their outputs before recording decisions, submitting plans, or advancing state.
- Only this main session may call Changeflow lifecycle and submission tools.`;

  const common = `[CHANGEFLOW]
Workflow: ${workflow.title} (${workflow.id})
Current state: ${workflow.state}
Description:
${workflow.description}${feedback}

Artifacts directory: ${workflow.artifactsDir}${orchestrator}`;

  const instructions = stateMeta(workflow.state).prompt?.instructions;
  return instructions ? `${common}\n\n${instructions}` : common;
}
```

### Verification

- Run:

```bash
cd pi/extensions/changeflow
npm run check
```

- Manually inspect the prompt strings against the old switch to ensure no phase lost critical instructions:
  - research still says no source edits and record research
  - planning still says submit plans
  - review states still say wait
  - execution says source edits allowed
  - QA says validate and advance with `QA_COMPLETE`

### Risks

- Moving text into constants near `machineDefinition` increases file size but makes config explicit.
- Ensure `high_level_revision` reuses high-level planning instructions.

---

## Step 4: Move allowed subagent roles into state metadata

### Concrete edits in `index.ts`

1. Add `subagents.allowedRoles` to `machineDefinition` states:

```ts
research: {
  meta: {
    changeflow: {
      ...
      subagents: { allowedRoles: ["scout"] },
    },
  },
}
```

Use:

- `research`: `["scout"]`
- `high_level_planning`: `["planner", "reviewer"]`
- `high_level_revision`: `["planner", "reviewer"]`
- `detailed_planning`: `["planner", "reviewer"]`
- `execution_ordering`: `["planner"]`
- `executing`: `["worker", "reviewer"]`
- `qa`: `["reviewer", "qa"]`

Leave review/wait states without `subagents` metadata.

2. Replace `allowedSubagentRoles(state)` switch with:

```ts
function allowedSubagentRoles(state: WorkflowState): ChangeflowSubagentRole[] {
  return stateMeta(state).subagents?.allowedRoles ?? [];
}
```

### Verification

- Run `npm run check`.
- Manual behavior checks:
  - `worker` in `research` should still be rejected.
  - `scout` in `research` should still be accepted.
  - no subagents should be allowed in `high_level_user_review` or `detailed_user_review`.

### Risks

- Metadata typos in role arrays are caught by TypeScript because `machineDefinition` is typed through `as const` plus metadata helper casts only indirectly. If errors are not caught, consider annotating the metadata helper return type more strictly later.

---

## Step 5: Add metadata-driven subagent config overrides

### Concrete edits in `index.ts`

1. Add optional example/default overrides to one or more states if desired. For example:

```ts
executing: {
  meta: {
    changeflow: {
      ...
      subagents: {
        allowedRoles: ["worker", "reviewer"],
        overrides: {
          worker: {
            thinking: "medium",
          },
          reviewer: {
            thinking: "low",
          },
        },
      },
    },
  },
}
```

Keep overrides conservative. Do not add new tools beyond role defaults.

2. Add helper:

```ts
function subagentOverrideForState(
  state: WorkflowState,
  role: ChangeflowSubagentRole,
): ChangeflowSubagentConfigOverride | undefined {
  return stateMeta(state).subagents?.overrides?.[role];
}
```

3. In `changeflow_run_subagent`, pass the effective override:

```ts
const result = await runChangeflowSubagent({
  workflowId: activeWorkflow.id,
  artifactsDir: activeWorkflow.artifactsDir,
  cwd: ctx.cwd,
  role,
  task: params.task,
  phase: activeWorkflow.state,
  stepId: params.stepId,
  reason: params.reason,
  configOverride: subagentOverrideForState(activeWorkflow.state, role),
  signal,
});
```

### Verification

- Run `npm run check`.
- Manually run a planner/reviewer/worker subagent in a valid phase and inspect:
  - `.pi/changeflow/<workflow-id>/subagents/<run-id>/metadata.json`
  - confirm `requestedModel`, `model`, `tools`, and effective settings reflect overrides when present.
- Try a metadata `tools` override that includes an invalid tool during development and confirm the runner fails safely. Revert invalid test metadata before finalizing.

### Risks

- Model names and thinking suffixes are passed through to child Pi; invalid model names will fail at runtime.
- Tool overrides should remain subset-only to preserve safety.

---

## Step 6: Move execution-order submission behavior into metadata

### Concrete edits in `index.ts`

1. Add `artifactSubmission` to `execution_ordering` metadata:

```ts
artifactSubmission: {
  artifactName: "execution-order.md",
  contextPath: "executionOrderPath",
  submittedEvent: "ORDER_DEFINED",
},
```

2. Add helper:

```ts
function artifactSubmissionStatesForContextPath(
  contextPath: ArtifactSubmissionMeta["contextPath"],
): WorkflowState[] {
  return statesMatchingMeta((meta) => meta.artifactSubmission?.contextPath === contextPath);
}
```

3. Refactor `changeflow_submit_execution_order`:

Replace hardcoded state check:

```ts
if (activeWorkflow.state !== "execution_ordering") return invalidStateResult(...);
```

with:

```ts
const allowedStates = artifactSubmissionStatesForContextPath("executionOrderPath");
if (!allowedStates.includes(activeWorkflow.state)) {
  return invalidStateResult("changeflow_submit_execution_order", allowedStates);
}
const submission = stateMeta(activeWorkflow.state).artifactSubmission;
if (!submission) return invalidStateResult("changeflow_submit_execution_order", allowedStates);
```

4. Replace hardcoded artifact/event:

```ts
const path = artifactPath(ctx, "execution-order.md");
...
const result = transitionAndMaybeContinue(ctx, "ORDER_DEFINED");
```

with:

```ts
const path = artifactPath(ctx, submission.artifactName);
activeWorkflow.context[submission.contextPath] = path;
...
const result = transitionAndMaybeContinue(ctx, submission.submittedEvent);
```

### Verification

- Run `npm run check`.
- Manual check:
  - in `execution_ordering`, `changeflow_submit_execution_order` still writes `execution-order.md`
  - workflow advances to `executing`
  - outside `execution_ordering`, tool returns invalid-state error with allowed states listed

### Risks

- Indexed assignment to `activeWorkflow.context[submission.contextPath]` should typecheck because `contextPath` is limited to `"executionOrderPath"`.
- If TypeScript complains, use:

```ts
activeWorkflow.context.executionOrderPath = path;
```

after validating `submission.contextPath === "executionOrderPath"`.

---

## Step 7: Update `pi/extensions/changeflow/README.md`

### Concrete edits

1. In **Current MVP scope**, replace wording that implies subagent config is hardcoded.

Mention:
- phase instructions are stored in `meta.changeflow.prompt.instructions`
- subagent role allowlists and overrides are state metadata

2. In **State metadata**, add fields:

```md
- `prompt.instructions`: phase-specific prompt body injected after the common Changeflow header.
- `subagents.allowedRoles`: role allowlist for `changeflow_run_subagent` in the state.
- `subagents.overrides`: optional per-role config overrides for child agents, including `model`, `thinking`, `tools`, and `systemPrompt`.
- `artifactSubmission`: metadata for non-review artifact submissions such as execution ordering.
```

3. Update the TypeScript example to include:

```ts
prompt: {
  kind: "high_level_planning",
  instructions: promptInstructions.highLevelPlanning,
},
subagents: {
  allowedRoles: ["planner", "reviewer"],
},
```

4. In **Subagent orchestration MVP**, add a subsection:

```md
### Metadata-driven overrides

Default role definitions live in `subagents.ts`. State metadata may narrow or tune a role for a phase via `subagents.overrides`. Tool overrides are safety-checked against the role defaults and cannot grant additional tools.
```

5. Update **Suggested next iterations**:
- remove “Add SDK reviewer sub-agents” if no longer accurate, or reword to “Replace subprocess runner with SDK-backed child sessions”.
- keep dependency-aware parallelism and worktree isolation as future work.

### Verification

- Read README sections for consistency with actual code.
- Ensure no stale sentence says prompts/roles are hardcoded.

---

## Step 8: Final validation

### Commands

```bash
cd pi/extensions/changeflow
npm run check
npm run build
```

### Manual smoke checks

1. Start workflow:
   - `/changeflow start <test description>`
2. Confirm research prompt includes metadata-provided research instructions.
3. Submit/advance through:
   - `RESEARCH_COMPLETE`
   - high-level plan submission
   - detailed plan submission if Plannotator is available
4. Confirm invalid subagent roles are rejected based on metadata.
5. Confirm valid subagents still create artifacts under:

```text
.pi/changeflow/<workflow-id>/subagents/<run-id>/
```

6. Confirm execution-order submission still advances to `executing`.

### Overall risks

- Existing persisted workflows contain older `machineDefinition` snapshots, but runtime helpers use canonical in-code metadata, so compatibility should be acceptable.
- Prompt text moved into metadata must remain serializable.
- Subagent tool overrides must not broaden permissions, especially before `executing`.