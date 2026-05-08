import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { createActor, createMachine, type Snapshot } from "xstate";
import {
  runChangeflowSubagent,
  summarizeSubagentResult,
  type ChangeflowSubagentRole,
} from "./subagents.js";
import {
  createWorkflowRegistry,
  DEFAULT_WORKFLOW_DEFINITION_ID,
  definitionStateList,
  type ChangeflowStateConfig,
  type ChangeflowStateMeta,
  type ChangeflowWorkflowDefinition,
  type PlannotatorMeta,
  type ReviewKind,
  type WorkflowRegistry,
  type WorkflowState,
} from "./workflows.js";

type ReviewRecord = {
  id: string;
  kind: ReviewKind;
  approved?: boolean;
  feedback?: string;
  createdAt: string;
  completedAt?: string;
};

type Workflow = {
  id: string;
  title: string;
  description: string;
  cwd: string;
  workflowDefinitionId: string;
  state: WorkflowState;
  createdAt: string;
  updatedAt: string;
  artifactsDir: string;
  machineDefinition: unknown;
  machineSnapshot: Snapshot<unknown>;
  context: {
    researchNotes: string[];
    questions: string[];
    decisions: string[];
    highLevelPlanPath?: string;
    detailedPlanPath?: string;
    executionOrderPath?: string;
    latestFeedback?: string;
    reviews: ReviewRecord[];
  };
};

type PlannotatorResponse<T> =
  | { status: "handled"; result: T }
  | { status: "unavailable"; error?: string }
  | { status: "error"; error: string };

type PlannotatorPlanReviewStartResult = { status: "pending"; reviewId: string };
type PlannotatorReviewResultEvent = {
  reviewId: string;
  approved: boolean;
  feedback?: string;
  savedPath?: string;
};
type PlannotatorReviewStatusResult =
  | { status: "pending" }
  | ({ status: "completed" } & PlannotatorReviewResultEvent)
  | { status: "missing" };

const CUSTOM_ENTRY = "changeflow-state";
const REQUEST_CHANNEL = "plannotator:request";
const REVIEW_RESULT_CHANNEL = "plannotator:review-result";

const workflowMachines = new Map<string, ReturnType<typeof createMachine>>();

function machineForDefinition(definition: ChangeflowWorkflowDefinition): ReturnType<typeof createMachine> {
  const cached = workflowMachines.get(definition.id);
  if (cached) return cached;
  const machine = createMachine(definition.machineDefinition);
  workflowMachines.set(definition.id, machine);
  return machine;
}

function workflowDefinition(registry: WorkflowRegistry, workflow: Workflow): ChangeflowWorkflowDefinition {
  return registry.definitions.get(workflow.workflowDefinitionId) ?? registry.definitions.get(DEFAULT_WORKFLOW_DEFINITION_ID)!;
}

function canonicalStateConfig(definition: ChangeflowWorkflowDefinition, state: WorkflowState): ChangeflowStateConfig {
  return definition.machineDefinition.states[state] as ChangeflowStateConfig;
}

function stateMeta(definition: ChangeflowWorkflowDefinition, state: WorkflowState): ChangeflowStateMeta {
  return canonicalStateConfig(definition, state).meta?.changeflow ?? {};
}

function statesMatchingMeta(
  definition: ChangeflowWorkflowDefinition,
  predicate: (meta: ChangeflowStateMeta, state: WorkflowState) => boolean,
): WorkflowState[] {
  return definitionStateList(definition).filter((state) => predicate(stateMeta(definition, state), state));
}

function toWorkflowState(definition: ChangeflowWorkflowDefinition, value: unknown): WorkflowState {
  if (typeof value === "string" && definition.machineDefinition.states[value]) return value;
  throw new Error(`Unexpected Changeflow machine state for ${definition.id}: ${JSON.stringify(value)}`);
}

function initialWorkflowSnapshot(definition: ChangeflowWorkflowDefinition): Snapshot<unknown> {
  const actor = createActor(machineForDefinition(definition));
  actor.start();
  const initialEvent = definition.initialEvent;
  if (initialEvent) actor.send({ type: initialEvent });
  return actor.getPersistedSnapshot();
}

function renderTemplate(template: string, workflow: Pick<Workflow, "title" | "description">): string {
  return template.replaceAll("{description}", workflow.description).replaceAll("{title}", workflow.title);
}

export default function changeflow(pi: ExtensionAPI): void {
  let activeWorkflow: Workflow | undefined;
  let activeCtx: ExtensionContext | undefined;
  let workflowRegistry: WorkflowRegistry | undefined;
  let workflowRegistryWarningsShown = false;
  const pendingReviewToWorkflow = new Map<string, string>();

  function now(): string {
    return new Date().toISOString();
  }

  function slugify(text: string): string {
    return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "change";
  }

  function workflowRoot(ctx: ExtensionContext): string {
    return join(ctx.cwd, ".pi", "changeflow");
  }

  function workflowDir(ctx: ExtensionContext, id: string): string {
    return join(workflowRoot(ctx), id);
  }

  function workflowPath(ctx: ExtensionContext, id: string): string {
    return join(workflowDir(ctx, id), "workflow.json");
  }

  function ensureDir(path: string): void {
    mkdirSync(path, { recursive: true });
  }

  function registryFor(ctx: ExtensionContext): WorkflowRegistry {
    if (!workflowRegistry) workflowRegistry = createWorkflowRegistry(ctx.cwd);
    if (!workflowRegistryWarningsShown) {
      workflowRegistryWarningsShown = true;
      for (const warning of workflowRegistry.warnings) ctx.ui.notify(warning, "warning");
    }
    return workflowRegistry;
  }

  function definitionForWorkflow(ctx: ExtensionContext, workflow: Workflow): ChangeflowWorkflowDefinition {
    return workflowDefinition(registryFor(ctx), workflow);
  }

  function activeDefinition(): ChangeflowWorkflowDefinition | undefined {
    if (!activeWorkflow || !activeCtx) return undefined;
    return definitionForWorkflow(activeCtx, activeWorkflow);
  }

  function saveWorkflow(ctx: ExtensionContext, workflow = activeWorkflow): void {
    if (!workflow) return;
    workflow.updatedAt = now();
    const definition = definitionForWorkflow(ctx, workflow);
    workflow.workflowDefinitionId = definition.id;
    workflow.machineDefinition = definition.machineDefinition;
    ensureDir(workflow.artifactsDir);
    writeFileSync(workflowPath(ctx, workflow.id), JSON.stringify(workflow, null, 2));
    pi.appendEntry(CUSTOM_ENTRY, {
      workflowId: workflow.id,
      workflowDefinitionId: workflow.workflowDefinitionId,
      state: workflow.state,
      workflowPath: workflowPath(ctx, workflow.id),
      machineSnapshot: workflow.machineSnapshot,
    });
  }

  function loadWorkflowFromPath(path: string): Workflow | undefined {
    try {
      if (!existsSync(path)) return undefined;
      const workflow = JSON.parse(readFileSync(path, "utf-8")) as Workflow;
      workflow.workflowDefinitionId ??= DEFAULT_WORKFLOW_DEFINITION_ID;
      return workflow;
    } catch {
      return undefined;
    }
  }

  function restoreWorkflow(ctx: ExtensionContext): void {
    const entries = ctx.sessionManager.getEntries();
    const last = entries
      .filter((e: { type: string; customType?: string }) => e.type === "custom" && e.customType === CUSTOM_ENTRY)
      .pop() as { data?: { workflowPath?: string } } | undefined;
    const restored = last?.data?.workflowPath ? loadWorkflowFromPath(last.data.workflowPath) : undefined;
    if (restored) {
      restored.workflowDefinitionId ??= DEFAULT_WORKFLOW_DEFINITION_ID;
      activeWorkflow = restored;
    }
  }

  function applyTransition(event: string, metadata?: Record<string, unknown>): string {
    if (!activeWorkflow) return "No active Changeflow workflow.";
    const definition = activeDefinition();
    if (!definition) return "No active Changeflow workflow definition.";
    const normalized = event.trim().toUpperCase();
    const previous = activeWorkflow.state;
    const actor = createActor(machineForDefinition(definition), { snapshot: activeWorkflow.machineSnapshot });
    actor.start();

    if (!actor.getSnapshot().can({ type: normalized })) {
      return `Event ${normalized} is not valid from state ${activeWorkflow.state}.`;
    }

    actor.send({ type: normalized });
    const next = toWorkflowState(definition, actor.getSnapshot().value);
    activeWorkflow.state = next;
    if (typeof metadata?.feedback === "string" && metadata.feedback.trim()) {
      activeWorkflow.context.latestFeedback = metadata.feedback;
    }
    activeWorkflow.machineSnapshot = actor.getPersistedSnapshot();
    return `Changeflow transitioned ${previous} --${normalized}--> ${next}.`;
  }

  function transitionSucceeded(message: string): boolean {
    return !message.startsWith("Event ") && !message.startsWith("No active");
  }

  function transition(ctx: ExtensionContext, event: string, metadata?: Record<string, unknown>): string {
    const message = applyTransition(event, metadata);
    if (!activeWorkflow || !transitionSucceeded(message)) return message;
    saveWorkflow(ctx);
    ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${activeWorkflow.state}`));
    return message;
  }

  function isInactiveWorkflow(workflow: Workflow): boolean {
    return workflow.state === "idle" || workflow.state === "done";
  }

  function shouldAutoContinue(state: WorkflowState): boolean {
    const definition = activeDefinition();
    return definition ? stateMeta(definition, state).autoContinue === true : false;
  }

  function queuePhaseContinuation(ctx: ExtensionContext): void {
    if (!activeWorkflow || !shouldAutoContinue(activeWorkflow.state)) return;
    const message = "Continue the current Changeflow phase.";
    if (ctx.isIdle()) pi.sendUserMessage(message);
    else pi.sendUserMessage(message, { deliverAs: "followUp" });
  }

  function transitionAndMaybeContinue(ctx: ExtensionContext, event: string, metadata?: Record<string, unknown>): string {
    const message = transition(ctx, event, metadata);
    if (activeWorkflow && transitionSucceeded(message)) queuePhaseContinuation(ctx);
    return message;
  }

  function artifactPath(ctx: ExtensionContext, name: string): string {
    if (!activeWorkflow) throw new Error("No active workflow");
    const path = join(activeWorkflow.artifactsDir, name);
    ensureDir(dirname(path));
    return path;
  }

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

    const definition = activeCtx ? definitionForWorkflow(activeCtx, workflow) : undefined;
    const instructions = definition ? stateMeta(definition, workflow.state).prompt?.instructions : undefined;
    return instructions ? `${common}\n\n${instructions}` : common;
  }

  function reviewKindLabel(kind: ReviewRecord["kind"]): string {
    if (kind === "high_level_plan") return "high-level plan";
    if (kind === "detailed_plan") return "detailed plan";
    if (kind === "code") return "code";
    return "QA";
  }

  function reviewStateForKind(kind: ReviewRecord["kind"]): WorkflowState | undefined {
    const definition = activeDefinition();
    return definition ? statesMatchingMeta(definition, (meta) => meta.reviewGate?.actor === "human" && meta.reviewGate.kind === kind)[0] : undefined;
  }

  function reviewKindForState(state: WorkflowState): ReviewRecord["kind"] | undefined {
    const definition = activeDefinition();
    const gate = definition ? stateMeta(definition, state).reviewGate : undefined;
    return gate?.actor === "human" ? gate.kind : undefined;
  }

  function submittedEventForKind(kind: ReviewRecord["kind"]): string | undefined {
    const definition = activeDefinition();
    const submissionState = submissionStatesForKind(kind)[0];
    return definition && submissionState ? stateMeta(definition, submissionState).submission?.submittedEvent : undefined;
  }

  function submissionStatesForKind(kind: ReviewRecord["kind"]): WorkflowState[] {
    const definition = activeDefinition();
    return definition ? statesMatchingMeta(definition, (meta) => meta.submission?.reviewKind === kind) : [];
  }

  function pendingReview(kind: ReviewRecord["kind"]): ReviewRecord | undefined {
    if (!activeWorkflow) return undefined;
    return activeWorkflow.context.reviews.find((review) => review.kind === kind && !review.completedAt);
  }

  function invalidStateResult(toolName: string, allowedStates: WorkflowState[]) {
    const state = activeWorkflow?.state ?? "unknown";
    return {
      content: [
        {
          type: "text" as const,
          text: `${toolName} is not valid from Changeflow state ${state}. Allowed states: ${allowedStates.join(", ")}.`,
        },
      ],
      details: { state, allowedStates },
      isError: true,
    };
  }

  function allowedSubagentRoles(state: WorkflowState): readonly ChangeflowSubagentRole[] {
    const definition = activeDefinition();
    return definition ? stateMeta(definition, state).subagents?.allowedRoles ?? [] : [];
  }

  function invalidSubagentRoleResult(role: ChangeflowSubagentRole, allowedRoles: readonly ChangeflowSubagentRole[]) {
    const state = activeWorkflow?.state ?? "unknown";
    return {
      content: [
        {
          type: "text" as const,
          text: `changeflow_run_subagent role ${role} is not valid from Changeflow state ${state}. Allowed roles: ${allowedRoles.join(", ") || "none"}.`,
        },
      ],
      details: { state, role, allowedRoles },
      isError: true,
    };
  }

  async function requestReviewStatus(reviewId: string): Promise<PlannotatorReviewStatusResult | undefined> {
    const requestId = `changeflow-status-${Date.now()}`;
    const response = await new Promise<PlannotatorResponse<PlannotatorReviewStatusResult> | undefined>((resolveResponse) => {
      const timeout = setTimeout(() => resolveResponse(undefined), 5_000);
      pi.events.emit(REQUEST_CHANNEL, {
        requestId,
        action: "review-status",
        payload: { reviewId },
        respond(result: PlannotatorResponse<PlannotatorReviewStatusResult>) {
          clearTimeout(timeout);
          resolveResponse(result);
        },
      });
    });

    return response?.status === "handled" ? response.result : undefined;
  }

  function applyReviewResult(
    result: PlannotatorReviewResultEvent,
    ctx: ExtensionContext | undefined,
    options: { notify?: boolean; reconciled?: boolean } = {},
  ): boolean {
    if (!activeWorkflow) return false;

    const pendingWorkflowId = pendingReviewToWorkflow.get(result.reviewId);
    const review = activeWorkflow.context.reviews.find((r) => r.id === result.reviewId);
    if (pendingWorkflowId !== activeWorkflow.id && !review) return false;
    if (review?.completedAt) return false;

    const kind = review?.kind ?? reviewKindForState(activeWorkflow.state) ?? "high_level_plan";
    const label = reviewKindLabel(kind);
    const event = result.approved ? "USER_APPROVED" : "USER_REJECTED";
    const transitionMessage = ctx
      ? transitionAndMaybeContinue(ctx, event, { feedback: result.feedback })
      : applyTransition(event, { feedback: result.feedback });

    if (!transitionSucceeded(transitionMessage)) return false;

    pendingReviewToWorkflow.delete(result.reviewId);

    if (review) {
      review.approved = result.approved;
      review.feedback = result.feedback;
      review.completedAt = now();
    }

    if (ctx) {
      saveWorkflow(ctx);
      if (options.notify !== false) {
        const suffix = options.reconciled ? " via review-status" : "";
        ctx.ui.notify(
          `Changeflow: ${label} ${result.approved ? "approved" : "rejected"}${suffix}; entering ${activeWorkflow.state.replace(/_/g, " ")}.`,
          result.approved ? "info" : "warning",
        );
      }
    } else if (activeWorkflow) {
      writeFileSync(join(activeWorkflow.artifactsDir, "workflow.json"), JSON.stringify(activeWorkflow, null, 2));
    }

    return true;
  }

  async function reconcilePendingReviews(ctx: ExtensionContext): Promise<void> {
    if (!activeWorkflow) return;
    const initialState = activeWorkflow.state;
    const expectedKind = reviewKindForState(initialState);
    if (!expectedKind) return;
    const pendingReviews = activeWorkflow.context.reviews.filter(
      (review) => review.kind === expectedKind && !review.completedAt,
    );

    for (const review of pendingReviews) {
      const status = await requestReviewStatus(review.id);
      if (status?.status !== "completed") continue;
      applyReviewResult(status, ctx, { reconciled: true });
      if (activeWorkflow.state !== initialState) return;
    }
  }

  function parseStartArgs(text: string): { workflowDefinitionId: string; description: string; error?: string } {
    const parts = text.trim().split(/\s+/).filter(Boolean);
    let workflowDefinitionId = DEFAULT_WORKFLOW_DEFINITION_ID;
    const descriptionParts: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      if (part === "--workflow" || part === "-w") {
        const value = parts[++i];
        if (!value) return { workflowDefinitionId, description: "", error: `${part} requires a workflow definition id.` };
        workflowDefinitionId = value;
      } else {
        descriptionParts.push(part);
      }
    }
    return { workflowDefinitionId, description: descriptionParts.join(" ") };
  }

  async function requestPlanReview(
    ctx: ExtensionContext,
    kind: "high_level_plan" | "detailed_plan",
    planContent: string,
    planFilePath?: string,
    plannotator: PlannotatorMeta = { action: "plan-review" },
  ): Promise<string> {
    const stateForKind = reviewStateForKind(kind);
    const existingPendingReview = pendingReview(kind);
    const label = reviewKindLabel(kind);
    if (activeWorkflow?.state === stateForKind && existingPendingReview) {
      return `A ${label} Plannotator review is already pending (${existingPendingReview.id}); not opening another review.`;
    }

    const requestId = `changeflow-${Date.now()}`;
    const response = await new Promise<PlannotatorResponse<PlannotatorPlanReviewStartResult> | undefined>((resolveResponse) => {
      const timeout = setTimeout(() => resolveResponse(undefined), 5_000);
      pi.events.emit(REQUEST_CHANNEL, {
        requestId,
        action: plannotator.action,
        payload: { planContent, planFilePath, origin: "changeflow", ...(plannotator.mode ? { mode: plannotator.mode } : {}) },
        respond(result: PlannotatorResponse<PlannotatorPlanReviewStartResult>) {
          clearTimeout(timeout);
          resolveResponse(result);
        },
      });
    });

    const retryMessage = kind === "high_level_plan" ? "Retry with /changeflow review-plan." : "Retry by submitting the detailed plan again.";
    if (!response) {
      return `Plannotator did not respond within 5s. Plan saved; workflow state was not advanced. ${retryMessage}`;
    }
    if (response.status !== "handled") {
      return `Plannotator could not start review (${"error" in response ? response.error : "unavailable"}). Plan saved; workflow state was not advanced. ${retryMessage}`;
    }
    pendingReviewToWorkflow.set(response.result.reviewId, activeWorkflow?.id ?? "");
    if (activeWorkflow) {
      activeWorkflow.context.reviews.push({
        id: response.result.reviewId,
        kind,
        createdAt: now(),
      });
      const submittedEvent = submittedEventForKind(kind);
      if (submittedEvent) transition(ctx, submittedEvent);
    }
    return `Opened Plannotator ${label} review (${response.result.reviewId}).`;
  }

  pi.registerCommand("changeflow", {
    description: "Manage persistent state-machine-driven change workflows",
    handler: async (args, ctx) => {
      activeCtx = ctx;
      const [subcommandRaw, ...rest] = (args ?? "").trim().split(/\s+/);
      const subcommand = subcommandRaw || "status";
      const restText = rest.join(" ").trim();

      if (subcommand === "start") {
        const parsed = parseStartArgs(restText);
        if (parsed.error) {
          ctx.ui.notify(parsed.error, "warning");
          return;
        }
        if (!parsed.description) {
          ctx.ui.notify("Usage: /changeflow start [--workflow <id>] <change description>", "warning");
          return;
        }
        const definition = registryFor(ctx).definitions.get(parsed.workflowDefinitionId);
        if (!definition) {
          ctx.ui.notify(`Unknown Changeflow workflow definition ${parsed.workflowDefinitionId}. Use /changeflow workflows to list available workflows.`, "warning");
          return;
        }
        const id = `${Date.now()}-${slugify(parsed.description)}`;
        const dir = workflowDir(ctx, id);
        ensureDir(dir);
        const snapshot = initialWorkflowSnapshot(definition);
        const state = toWorkflowState(definition, (snapshot as { value?: unknown }).value);
        activeWorkflow = {
          id,
          title: slugify(parsed.description),
          description: parsed.description,
          cwd: ctx.cwd,
          workflowDefinitionId: definition.id,
          state,
          createdAt: now(),
          updatedAt: now(),
          artifactsDir: dir,
          machineDefinition: definition.machineDefinition,
          machineSnapshot: snapshot,
          context: { researchNotes: [], questions: [], decisions: [], reviews: [] },
        };
        for (const template of definition.artifactTemplates ?? []) {
          const path = join(dir, template.path);
          ensureDir(dirname(path));
          writeFileSync(path, renderTemplate(template.content, activeWorkflow));
        }
        saveWorkflow(ctx);
        pi.setSessionName(`Changeflow: ${activeWorkflow.title}`);
        ctx.ui.notify(`Started Changeflow workflow ${id} using ${definition.id}`, "info");
        pi.sendUserMessage(`Start the Changeflow research phase for this change:\n\n${parsed.description}`, { deliverAs: "followUp" });
        return;
      }

      if (subcommand === "workflows") {
        const registry = registryFor(ctx);
        const rows = [...registry.definitions.values()].map((definition) => {
          const marker = definition.id === DEFAULT_WORKFLOW_DEFINITION_ID ? " (default)" : "";
          return `- ${definition.id}${marker}: ${definition.name}`;
        });
        ctx.ui.notify(`Available Changeflow workflows:\n${rows.join("\n")}`, "info");
        return;
      }

      if (subcommand === "status") {
        if (!activeWorkflow) restoreWorkflow(ctx);
        if (!activeWorkflow) {
          ctx.ui.notify("No active Changeflow workflow. Use /changeflow start <description>.", "info");
          return;
        }
        const definition = definitionForWorkflow(ctx, activeWorkflow);
        ctx.ui.notify(
          `Changeflow ${activeWorkflow.id}\nWorkflow definition: ${definition.id}\nState: ${activeWorkflow.state}\nArtifacts: ${activeWorkflow.artifactsDir}`,
          "info",
        );
        return;
      }

      if (subcommand === "advance") {
        ctx.ui.notify(transitionAndMaybeContinue(ctx, restText), "info");
        return;
      }

      if (subcommand === "review-plan") {
        if (!activeWorkflow) restoreWorkflow(ctx);
        if (!activeWorkflow?.context.highLevelPlanPath) {
          ctx.ui.notify("No high-level plan has been submitted yet.", "warning");
          return;
        }
        const existingPendingReview = pendingReview("high_level_plan");
        if (activeWorkflow.state === reviewStateForKind("high_level_plan") && existingPendingReview) {
          ctx.ui.notify(`A high-level plan Plannotator review is already pending (${existingPendingReview.id}); not opening another review.`, "info");
          return;
        }
        const allowedStates = submissionStatesForKind("high_level_plan");
        if (!allowedStates.includes(activeWorkflow.state)) {
          ctx.ui.notify(`/changeflow review-plan is not valid from state ${activeWorkflow.state}.`, "warning");
          return;
        }
        const content = readFileSync(activeWorkflow.context.highLevelPlanPath, "utf-8");
        ctx.ui.notify(
          await requestPlanReview(
            ctx,
            "high_level_plan",
            content,
            activeWorkflow.context.highLevelPlanPath,
            activeDefinition() ? stateMeta(activeDefinition()!, activeWorkflow.state).plannotator : undefined,
          ),
          "info",
        );
        return;
      }

      if (subcommand === "clear") {
        activeWorkflow = undefined;
        pi.appendEntry(CUSTOM_ENTRY, { cleared: true, at: now() });
        ctx.ui.notify("Cleared active Changeflow workflow pointer for this session.", "info");
        return;
      }

      ctx.ui.notify("Usage: /changeflow start|workflows|status|advance|review-plan|clear", "warning");
    },
  });

  pi.registerTool({
    name: "changeflow_record_research",
    label: "Record Changeflow Research",
    description: "Record a research note, user question, or decision in the active Changeflow workflow.",
    parameters: Type.Object({
      kind: Type.Union([Type.Literal("note"), Type.Literal("question"), Type.Literal("decision")]),
      text: Type.String(),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      activeCtx = ctx;
      if (!activeWorkflow) restoreWorkflow(ctx);
      if (!activeWorkflow) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      const text = params.text.trim();
      if (params.kind === "question") activeWorkflow.context.questions.push(text);
      else if (params.kind === "decision") activeWorkflow.context.decisions.push(text);
      else activeWorkflow.context.researchNotes.push(text);
      const line = `- ${now()} [${params.kind}] ${text}\n`;
      const researchPath = artifactPath(ctx, "research.md");
      const existing = existsSync(researchPath) ? readFileSync(researchPath, "utf-8") : `# Research\n\n`;
      writeFileSync(researchPath, existing + line);
      saveWorkflow(ctx);
      return { content: [{ type: "text", text: `Recorded ${params.kind}.` }], details: { workflowId: activeWorkflow.id } };
    },
  });

  pi.registerTool({
    name: "changeflow_advance",
    label: "Advance Changeflow",
    description: "Send a lifecycle event for the active Changeflow workflow and automatically continue the next agent-owned phase.",
    parameters: Type.Object({
      event: Type.String({ description: "Lifecycle event to send, e.g. RESEARCH_COMPLETE, ORDER_DEFINED, EXECUTION_COMPLETE, QA_COMPLETE." }),
      note: Type.Optional(Type.String({ description: "Optional note explaining why this phase is complete." })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      activeCtx = ctx;
      if (!activeWorkflow) restoreWorkflow(ctx);
      if (!activeWorkflow) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      const note = params.note?.trim();
      if (note) {
        activeWorkflow.context.decisions.push(note);
        const researchPath = artifactPath(ctx, "research.md");
        const existing = existsSync(researchPath) ? readFileSync(researchPath, "utf-8") : `# Research\n\n`;
        writeFileSync(researchPath, existing + `- ${now()} [decision] ${note}\n`);
      }
      const result = transitionAndMaybeContinue(ctx, params.event);
      return {
        content: [{ type: "text", text: result }],
        details: { workflowId: activeWorkflow.id, state: activeWorkflow.state },
        isError: !transitionSucceeded(result),
      };
    },
  });

  pi.registerTool({
    name: "changeflow_submit_high_level_plan",
    label: "Submit Changeflow High-level Plan",
    description: "Save a high-level plan/spec for the active Changeflow workflow and request Plannotator human review.",
    parameters: Type.Object({
      markdown: Type.String({ description: "The high-level plan/spec as markdown." }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      activeCtx = ctx;
      if (!activeWorkflow) restoreWorkflow(ctx);
      if (!activeWorkflow) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      const allowedStates = submissionStatesForKind("high_level_plan");
      if (!allowedStates.includes(activeWorkflow.state)) return invalidStateResult("changeflow_submit_high_level_plan", allowedStates);
      const path = artifactPath(ctx, "high-level-plan.md");
      writeFileSync(path, params.markdown);
      activeWorkflow.context.highLevelPlanPath = path;
      saveWorkflow(ctx);
      const definition = definitionForWorkflow(ctx, activeWorkflow);
      const reviewMessage = await requestPlanReview(ctx, "high_level_plan", params.markdown, path, stateMeta(definition, activeWorkflow.state).plannotator);
      return { content: [{ type: "text", text: `High-level plan saved to ${path}. ${reviewMessage}` }], details: { path } };
    },
  });

  pi.registerTool({
    name: "changeflow_submit_detailed_plan",
    label: "Submit Changeflow Detailed Plan",
    description: "Save a detailed step-by-step plan for the active Changeflow workflow and request Plannotator human review.",
    parameters: Type.Object({
      markdown: Type.String({ description: "The detailed step-by-step plan as markdown." }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      activeCtx = ctx;
      if (!activeWorkflow) restoreWorkflow(ctx);
      if (!activeWorkflow) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      const allowedStates = submissionStatesForKind("detailed_plan");
      if (!allowedStates.includes(activeWorkflow.state)) return invalidStateResult("changeflow_submit_detailed_plan", allowedStates);
      const path = artifactPath(ctx, "detailed-plan.md");
      writeFileSync(path, params.markdown);
      activeWorkflow.context.detailedPlanPath = path;
      saveWorkflow(ctx);
      const definition = definitionForWorkflow(ctx, activeWorkflow);
      const reviewMessage = await requestPlanReview(ctx, "detailed_plan", params.markdown, path, stateMeta(definition, activeWorkflow.state).plannotator);
      return { content: [{ type: "text", text: `Detailed plan saved to ${path}. ${reviewMessage}` }], details: { path } };
    },
  });

  pi.registerTool({
    name: "changeflow_submit_execution_order",
    label: "Submit Changeflow Execution Order",
    description: "Save execution ordering for the active workflow and advance from execution_ordering to executing.",
    parameters: Type.Object({
      markdown: Type.String({ description: "The execution ordering as markdown." }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      activeCtx = ctx;
      if (!activeWorkflow) restoreWorkflow(ctx);
      if (!activeWorkflow) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      const definition = definitionForWorkflow(ctx, activeWorkflow);
      const allowedStates = statesMatchingMeta(definition, (meta) => meta.executionOrder !== undefined);
      if (!allowedStates.includes(activeWorkflow.state)) return invalidStateResult("changeflow_submit_execution_order", allowedStates);
      const executionOrder = stateMeta(definition, activeWorkflow.state).executionOrder;
      if (!executionOrder) return invalidStateResult("changeflow_submit_execution_order", allowedStates);
      const path = artifactPath(ctx, executionOrder.artifactName);
      writeFileSync(path, params.markdown);
      activeWorkflow.context.executionOrderPath = path;
      saveWorkflow(ctx);
      const result = transitionAndMaybeContinue(ctx, executionOrder.submittedEvent);
      return {
        content: [{ type: "text", text: `Execution order saved to ${path}. ${result}` }],
        details: { path, workflowId: activeWorkflow.id, state: activeWorkflow.state },
        isError: !transitionSucceeded(result),
      };
    },
  });

  const SubagentRoleSchema = Type.Union([
    Type.Literal("scout"),
    Type.Literal("planner"),
    Type.Literal("worker"),
    Type.Literal("reviewer"),
    Type.Literal("qa"),
  ]);

  pi.registerTool({
    name: "changeflow_run_subagent",
    label: "Run Changeflow Subagent",
    description: "Delegate a focused task to a guarded Changeflow subagent. The main session remains the orchestrator and owns lifecycle transitions.",
    parameters: Type.Object({
      role: SubagentRoleSchema,
      task: Type.String({ description: "Focused task to delegate to the subagent." }),
      stepId: Type.Optional(Type.String({ description: "Optional approved plan step identifier." })),
      reason: Type.Optional(Type.String({ description: "Why this subagent is being invoked." })),
    }),
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      activeCtx = ctx;
      if (!activeWorkflow) restoreWorkflow(ctx);
      if (!activeWorkflow) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      const role = params.role as ChangeflowSubagentRole;
      const definition = definitionForWorkflow(ctx, activeWorkflow);
      const meta = stateMeta(definition, activeWorkflow.state);
      const allowedRoles = allowedSubagentRoles(activeWorkflow.state);
      if (!allowedRoles.includes(role)) return invalidSubagentRoleResult(role, allowedRoles);

      onUpdate?.({ content: [{ type: "text", text: `Running ${role} subagent...` }], details: { role, state: activeWorkflow.state } });
      const result = await runChangeflowSubagent({
        workflowId: activeWorkflow.id,
        artifactsDir: activeWorkflow.artifactsDir,
        cwd: ctx.cwd,
        role,
        task: params.task,
        phase: activeWorkflow.state,
        stepId: params.stepId,
        reason: params.reason,
        configOverride: meta.subagents?.roleOverrides?.[role],
        signal,
      });
      const summary = summarizeSubagentResult(result);
      return {
        content: [{ type: "text", text: summary }],
        details: result,
        isError: result.exitCode !== 0 || Boolean(result.error),
      };
    },
  });

  pi.on("before_agent_start", async (_event, ctx) => {
    activeCtx = ctx;
    if (!activeWorkflow) restoreWorkflow(ctx);
    if (!activeWorkflow || isInactiveWorkflow(activeWorkflow)) return;
    await reconcilePendingReviews(ctx);
    if (!activeWorkflow || isInactiveWorkflow(activeWorkflow)) return;
    return {
      message: {
        customType: "changeflow-context",
        display: false,
        content: phasePrompt(activeWorkflow),
      },
    };
  });

  pi.on("tool_call", async (event, ctx) => {
    activeCtx = ctx;
    if (!activeWorkflow) restoreWorkflow(ctx);
    if (!activeWorkflow) return;
    const definition = definitionForWorkflow(ctx, activeWorkflow);
    const sourceEditAllowed = stateMeta(definition, activeWorkflow.state).editPolicy === "sourceAllowed";
    if (sourceEditAllowed) return;
    if (event.toolName !== "write" && event.toolName !== "edit") return;
    const inputPath = (event.input as { path?: string }).path;
    if (!inputPath) return;
    const fullPath = resolve(ctx.cwd, inputPath);
    const artifacts = resolve(activeWorkflow.artifactsDir);
    const isArtifact = fullPath === artifacts || fullPath.startsWith(artifacts + sep);
    if (!isArtifact) {
      return {
        block: true,
        reason: `Changeflow: source edits are blocked while workflow is in ${activeWorkflow.state}. Write/edit files under the active workflow artifacts directory only: ${activeWorkflow.artifactsDir}`,
      };
    }
  });

  pi.on("session_start", async (_event, ctx) => {
    activeCtx = ctx;
    restoreWorkflow(ctx);
    if (activeWorkflow) {
      ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${activeWorkflow.state}`));
      await reconcilePendingReviews(ctx);
    } else {
      ctx.ui.setStatus("changeflow", undefined);
    }
  });

  pi.events.on(REVIEW_RESULT_CHANNEL, (data) => {
    const result = data as Partial<PlannotatorReviewResultEvent>;
    if (!result.reviewId || typeof result.approved !== "boolean") return;
    applyReviewResult(
      {
        reviewId: result.reviewId,
        approved: result.approved,
        feedback: result.feedback,
        savedPath: result.savedPath,
      },
      activeCtx,
    );
  });
}
