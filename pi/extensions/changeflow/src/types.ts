import { Value } from "typebox/value";
import type { Static, TSchema } from "typebox";
import type { AnyActorLogic, AnyEventObject, Snapshot } from "xstate";

export type WorkflowId = string;
export type WorkflowInstanceId = string;
export type WorkflowStateValue = string;

export type RuntimeEventRecord = {
  seq: number;
  at: string;
  direction: "in" | "out" | "effect";
  kind: string;
  workflowId: WorkflowInstanceId;
  state?: unknown;
  event?: unknown;
  actorRunId?: string;
  snapshotSeq?: number;
  error?: string;
};

export type WorkflowMetadata = {
  id: WorkflowInstanceId;
  title: string;
  description: string;
  cwd: string;
  workflowDefinitionId: WorkflowId;
  state: WorkflowStateValue;
  createdAt: string;
  updatedAt: string;
  artifactsDir: string;
  latestSnapshotSeq: number;
};

export type ActorRunStatus = "running" | "completed" | "failed" | "cancelled";

export type ActorRunRecord = {
  id: string;
  workflowId: WorkflowInstanceId;
  kind: "childAgent" | "mainAgent" | "plannotatorReview" | "askUser" | "script";
  state: string;
  status: ActorRunStatus;
  input: unknown;
  output?: unknown;
  error?: string;
  startedAt: string;
  completedAt?: string;
};

export type RuntimeCapabilities = {
  log(message: string, details?: unknown): void;
  writeArtifact(path: string, content: string): void;
  setStatus(label: string): void;
  emitToPi(message: string, level?: "info" | "warning" | "error"): void;
  queueMainAgentMessage(message: string): void;
};

export type ChildAgentInput = { role: string; task: string; state: string; stepId?: string; reason?: string };
export type MainAgentInput = { taskId: string; task: string; expectedEvents: string[] };
export type PlannotatorReviewInput = { kind: string; artifactPath: string; content?: string };
export type AskUserInput = { prompt: string; choices?: string[] };
export type RunScriptInput = { command: string; args?: string[]; cwd?: string; timeout?: number };

export type WorkflowActorFactories = {
  childAgent(input: ChildAgentInput): Promise<unknown>;
  mainAgent(input: MainAgentInput): Promise<unknown>;
  plannotatorReview(input: PlannotatorReviewInput): Promise<unknown>;
  askUser(input: AskUserInput): Promise<unknown>;
  runScript(input: RunScriptInput): Promise<unknown>;
};

export type EventSchemaMap = Record<string, TSchema>;
export type EventUnionFromSchemas<TSchemas extends EventSchemaMap> = Static<TSchemas[keyof TSchemas]> & AnyEventObject;

export type WorkflowActorLogicFactoryInput = {
  runtime: RuntimeCapabilities;
  actors: WorkflowActorFactories;
  actions: Record<string, unknown>;
};

export type TrustedWorkflowDefinition<TEventSchemas extends EventSchemaMap = EventSchemaMap> = {
  id: WorkflowId;
  name: string;
  description?: string;
  initialEvent?: AnyEventObject;
  createActorLogic(input: WorkflowActorLogicFactoryInput): AnyActorLogic;
  eventSchemas?: TEventSchemas;
  artifactTemplates?: readonly { path: string; content: string }[];
  tools?: readonly { name: string; description: string; eventType: string; schema: TSchema }[];
};

export type WorkflowRuntimeSnapshot = {
  metadata: WorkflowMetadata;
  machineSnapshot: Snapshot<unknown>;
};

export type ParseWorkflowEventResult =
  | { ok: true; event: AnyEventObject }
  | { ok: false; error: string };

export function defineWorkflow<
  const TEventSchemas extends EventSchemaMap = EventSchemaMap,
  T extends TrustedWorkflowDefinition<TEventSchemas> = TrustedWorkflowDefinition<TEventSchemas>,
>(definition: T): T {
  return definition;
}

export function parseWorkflowEvent(schema: TSchema | undefined, value: unknown): ParseWorkflowEventResult {
  if (!schema) {
    if (value && typeof value === "object" && typeof (value as { type?: unknown }).type === "string") {
      return { ok: true, event: value as AnyEventObject };
    }
    return { ok: false, error: "Workflow event must be an object with a string type." };
  }

  if (Value.Check(schema, value)) return { ok: true, event: value as AnyEventObject };
  const errors = [...Value.Errors(schema, value)].map((error) => `${error.instancePath || "/"}: ${error.message}`);
  return { ok: false, error: errors.join("; ") || "Workflow event failed schema validation." };
}
