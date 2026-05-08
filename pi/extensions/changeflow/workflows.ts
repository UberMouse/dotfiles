import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createMachine } from "xstate";
import defaultWorkflowDefinition from "./bundled-workflows/changeflow-mvp.js";
import type { ChangeflowSubagentConfigOverride, ChangeflowSubagentRole } from "./subagents.js";

export type WorkflowState = string;
export type ReviewKind = "high_level_plan" | "detailed_plan" | "code" | "qa";
export type EditPolicy = "artifactsOnly" | "sourceAllowed";

export type PlannotatorMeta = {
  action: "plan-review" | "code-review";
  artifact?: "highLevelPlanPath" | "detailedPlanPath";
  mode?: string;
};

export type ChangeflowStateMeta = {
  autoContinue?: boolean;
  editPolicy?: EditPolicy;
  prompt?: { instructions: string };
  reviewGate?: { actor: "human" | "agent"; kind: ReviewKind };
  plannotator?: PlannotatorMeta;
  submission?: { reviewKind: ReviewKind; submittedEvent: string };
  executionOrder?: { artifactName: string; submittedEvent: string };
  subagents?: {
    allowedRoles?: readonly ChangeflowSubagentRole[];
    roleOverrides?: Partial<Record<ChangeflowSubagentRole, ChangeflowSubagentConfigOverride>>;
  };
};

export type ChangeflowStateConfig = {
  on?: Record<string, unknown>;
  meta?: { changeflow?: ChangeflowStateMeta };
};

type XStateMachineConfig = Parameters<typeof createMachine>[0];

export type ArtifactTemplate = {
  path: string;
  content: string;
};

export type ChangeflowWorkflowDefinition = {
  id: string;
  name: string;
  description?: string;
  initialEvent?: string;
  machineDefinition: XStateMachineConfig & {
    id: string;
    initial: string;
    states: Record<string, ChangeflowStateConfig>;
  };
  artifactTemplates?: readonly ArtifactTemplate[];
};

export const DEFAULT_WORKFLOW_DEFINITION_ID = "changeflow.mvp";

export type WorkflowRegistry = {
  definitions: Map<string, ChangeflowWorkflowDefinition>;
  warnings: string[];
};

function transitionTargets(transition: unknown): string[] {
  if (typeof transition === "string") return [transition];
  if (Array.isArray(transition)) return transition.flatMap(transitionTargets);
  if (!transition || typeof transition !== "object") return [];
  const target = (transition as { target?: unknown }).target;
  if (typeof target === "string") return [target];
  if (Array.isArray(target)) return target.filter((value): value is string => typeof value === "string");
  return [];
}

function validateDefinition(definition: ChangeflowWorkflowDefinition): string[] {
  const errors: string[] = [];
  if (!definition.id.trim()) errors.push("definition id is empty");
  if (definition.id !== definition.machineDefinition.id) {
    errors.push(`definition id ${definition.id} must match machineDefinition.id ${definition.machineDefinition.id}`);
  }
  const states = definition.machineDefinition.states;
  const stateNames = new Set(Object.keys(states));
  if (!stateNames.has(definition.machineDefinition.initial)) {
    errors.push(`initial state ${definition.machineDefinition.initial} is not declared`);
  }
  for (const [state, config] of Object.entries(states)) {
    const transitions = config.on ?? {};
    for (const [event, transition] of Object.entries(transitions)) {
      for (const target of transitionTargets(transition)) {
        if (!stateNames.has(target)) errors.push(`${state}.${event} targets unknown state ${target}`);
      }
    }
  }
  const initialEvent = definition.initialEvent;
  if (initialEvent) {
    const initialTransitions = states[definition.machineDefinition.initial]?.on ?? {};
    if (!(initialEvent in initialTransitions)) errors.push(`initialEvent ${initialEvent} is not valid from ${definition.machineDefinition.initial}`);
  }
  return errors;
}

function registerDefinition(registry: WorkflowRegistry, definition: ChangeflowWorkflowDefinition): void {
  if (registry.definitions.has(definition.id)) {
    registry.warnings.push(`Skipping duplicate Changeflow workflow definition ${definition.id}.`);
    return;
  }
  const errors = validateDefinition(definition);
  if (errors.length > 0) {
    registry.warnings.push(`Skipping invalid Changeflow workflow definition ${definition.id || "<missing>"}: ${errors.join("; ")}`);
    return;
  }
  registry.definitions.set(definition.id, definition);
}

function loadExternalDefinitions(cwd: string, registry: WorkflowRegistry): void {
  const dir = join(cwd, ".pi", "changeflow", "workflows");
  if (!existsSync(dir)) return;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    const path = join(dir, entry.name);
    try {
      const parsed = JSON.parse(readFileSync(path, "utf-8")) as ChangeflowWorkflowDefinition;
      registerDefinition(registry, parsed);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      registry.warnings.push(`Skipping unreadable Changeflow workflow definition ${path}: ${message}`);
    }
  }
}

export function createWorkflowRegistry(cwd: string): WorkflowRegistry {
  const registry: WorkflowRegistry = { definitions: new Map(), warnings: [] };
  registerDefinition(registry, defaultWorkflowDefinition);
  loadExternalDefinitions(cwd, registry);
  return registry;
}

export function definitionStateList(definition: ChangeflowWorkflowDefinition): WorkflowState[] {
  return Object.keys(definition.machineDefinition.states);
}
