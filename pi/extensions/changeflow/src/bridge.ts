import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { runChangeflowSubagent, summarizeSubagentResult, type ChangeflowSubagentRole } from "../subagents.js";
import { createWorkflowPaths } from "./storage.js";
import { loadWorkflowRegistry, type WorkflowRegistry } from "./loader.js";
import { ChangeflowRuntime } from "./runtime.js";

const CUSTOM_ENTRY = "changeflow-state";

type BridgeState = {
  registry?: WorkflowRegistry;
  runtime?: ChangeflowRuntime;
  ctx?: ExtensionContext;
};

async function ensureRegistry(state: BridgeState, cwd: string): Promise<WorkflowRegistry> {
  if (!state.registry) {
    state.registry = await loadWorkflowRegistry(cwd);
  }
  return state.registry;
}

function ensureRuntime(state: BridgeState, cwd: string, registry: WorkflowRegistry): ChangeflowRuntime {
  if (!state.runtime) {
    state.runtime = new ChangeflowRuntime({
      cwd,
      workflows: [...registry.definitions.values()],
      actorAdapters: {
        runChildAgent: async (input) => {
          const current = state.runtime?.current();
          if (!current) throw new Error("No active workflow to run child agent.");
          const result = await runChangeflowSubagent({
            workflowId: current.metadata.id,
            artifactsDir: current.metadata.artifactsDir,
            cwd,
            role: input.role as ChangeflowSubagentRole,
            task: input.task,
            phase: input.state,
            stepId: input.stepId,
            reason: input.reason,
          });
          if (result.exitCode !== 0 || result.error) {
            throw new Error(result.error ?? `Subagent exited with code ${result.exitCode}`);
          }
          try {
            return JSON.parse(result.finalOutput);
          } catch {
            return { output: result.finalOutput };
          }
        },
      },
    });
  }
  return state.runtime;
}

export function installChangeflowBridge(pi: ExtensionAPI): void {
  const state: BridgeState = {};

  // /changeflow command with subcommands
  pi.registerCommand("changeflow", {
    description: "Manage persistent state-machine-driven change workflows",
    handler: async (args, ctx) => {
      state.ctx = ctx;
      const [subcommandRaw, ...rest] = (args ?? "").trim().split(/\s+/);
      const subcommand = subcommandRaw || "status";
      const restText = rest.join(" ").trim();
      const registry = await ensureRegistry(state, ctx.cwd);

      // Show registry warnings once
      for (const warning of registry.warnings) {
        ctx.ui.notify(warning, "warning");
      }
      registry.warnings.length = 0;

      switch (subcommand) {
        case "start": {
          const parsed = parseStartArgs(restText);
          if (parsed.error) {
            ctx.ui.notify(parsed.error, "warning");
            return;
          }
          if (!parsed.description) {
            ctx.ui.notify("Usage: /changeflow start [--workflow <id>] <change description>", "warning");
            return;
          }
          const definition = registry.definitions.get(parsed.workflowDefinitionId);
          if (!definition) {
            ctx.ui.notify(`Unknown workflow definition ${parsed.workflowDefinitionId}. Use /changeflow workflows to list.`, "warning");
            return;
          }
          const runtime = ensureRuntime(state, ctx.cwd, registry);
          const snapshot = await runtime.start({
            workflowDefinitionId: parsed.workflowDefinitionId,
            description: parsed.description,
          });
          pi.appendEntry(CUSTOM_ENTRY, {
            workflowId: snapshot.metadata.id,
            workflowDefinitionId: snapshot.metadata.workflowDefinitionId,
            state: snapshot.metadata.state,
          });
          pi.setSessionName(`Changeflow: ${snapshot.metadata.title}`);
          ctx.ui.notify(`Started Changeflow workflow ${snapshot.metadata.id} using ${definition.id}`, "info");
          ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${snapshot.metadata.state}`));
          pi.sendUserMessage(`Start the Changeflow research phase for this change:\n\n${parsed.description}`, { deliverAs: "followUp" });
          return;
        }

        case "status": {
          const runtime = ensureRuntime(state, ctx.cwd, registry);
          const current = runtime.current();
          if (!current) {
            ctx.ui.notify("No active Changeflow workflow. Use /changeflow start <description>.", "info");
            return;
          }
          ctx.ui.notify(
            `Changeflow ${current.metadata.id}\nWorkflow definition: ${current.metadata.workflowDefinitionId}\nState: ${current.metadata.state}\nArtifacts: ${current.metadata.artifactsDir}`,
            "info",
          );
          return;
        }

        case "workflows": {
          const rows = [...registry.definitions.values()].map((def) => `- ${def.id}: ${def.name}`);
          ctx.ui.notify(`Available Changeflow workflows:\n${rows.join("\n")}`, "info");
          return;
        }

        case "actors": {
          const runtime = ensureRuntime(state, ctx.cwd, registry);
          const current = runtime.current();
          if (!current) {
            ctx.ui.notify("No active Changeflow workflow.", "info");
            return;
          }
          // Actor info would come from runtime - simplified for now
          ctx.ui.notify(`Active workflow: ${current.metadata.id}\nNo actor info available in this bridge version.`, "info");
          return;
        }

        case "cancel-actor": {
          ctx.ui.notify("Actor cancellation not implemented in this bridge version.", "warning");
          return;
        }

        case "send": {
          const runtime = ensureRuntime(state, ctx.cwd, registry);
          const current = runtime.current();
          if (!current) {
            ctx.ui.notify("No active Changeflow workflow.", "warning");
            return;
          }
          try {
            const event = JSON.parse(restText);
            const result = await runtime.send(event);
            if (result.ok) {
              pi.appendEntry(CUSTOM_ENTRY, {
                workflowId: current.metadata.id,
                state: result.state,
              });
              ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${result.state}`));
              ctx.ui.notify(`Sent event. New state: ${result.state}`, "info");
            } else {
              ctx.ui.notify(`Failed to send event: ${result.error}`, "warning");
            }
          } catch (error) {
            ctx.ui.notify(`Invalid event JSON: ${error instanceof Error ? error.message : String(error)}`, "warning");
          }
          return;
        }

        case "clear": {
          state.runtime = undefined;
          pi.appendEntry(CUSTOM_ENTRY, { cleared: true, at: new Date().toISOString() });
          ctx.ui.setStatus("changeflow", undefined);
          ctx.ui.notify("Cleared active Changeflow workflow pointer for this session.", "info");
          return;
        }

        default:
          ctx.ui.notify("Usage: /changeflow start|status|workflows|actors|cancel-actor|send|clear", "warning");
      }
    },
  });

  // Tool: changeflow_send_event
  pi.registerTool({
    name: "changeflow_send_event",
    label: "Send Changeflow Event",
    description: "Send a lifecycle event to the active Changeflow workflow state machine.",
    parameters: Type.Object({
      event_type: Type.String({ description: "The event type to send, e.g. RESEARCH_COMPLETE, PLAN_SUBMITTED." }),
      payload: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "Additional event payload fields." })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      state.ctx = ctx;
      const registry = await ensureRegistry(state, ctx.cwd);
      const runtime = ensureRuntime(state, ctx.cwd, registry);
      const current = runtime.current();
      if (!current) {
        return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      }

      const event = { type: params.event_type, ...(params.payload ?? {}) };
      const result = await runtime.send(event);

      if (result.ok) {
        pi.appendEntry(CUSTOM_ENTRY, { workflowId: current.metadata.id, state: result.state });
        ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${result.state}`));
        return {
          content: [{ type: "text", text: `Event sent. Transitioned to state: ${result.state}` }],
          details: { workflowId: current.metadata.id, state: result.state },
        };
      }
      return { content: [{ type: "text", text: result.error }], details: {}, isError: true };
    },
  });

  // Tool: changeflow_get_state
  pi.registerTool({
    name: "changeflow_get_state",
    label: "Get Changeflow State",
    description: "Get the current state of the active Changeflow workflow.",
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      state.ctx = ctx;
      const registry = await ensureRegistry(state, ctx.cwd);
      const runtime = ensureRuntime(state, ctx.cwd, registry);
      const current = runtime.current();
      if (!current) {
        return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      }
      return {
        content: [{ type: "text", text: `Workflow: ${current.metadata.id}\nState: ${current.metadata.state}\nArtifacts: ${current.metadata.artifactsDir}` }],
        details: { metadata: current.metadata },
      };
    },
  });

  // Tool: changeflow_read_artifact
  pi.registerTool({
    name: "changeflow_read_artifact",
    label: "Read Changeflow Artifact",
    description: "Read an artifact file from the active Changeflow workflow's artifacts directory.",
    parameters: Type.Object({
      path: Type.String({ description: "Relative path within the artifacts directory." }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      state.ctx = ctx;
      const registry = await ensureRegistry(state, ctx.cwd);
      const runtime = ensureRuntime(state, ctx.cwd, registry);
      const current = runtime.current();
      if (!current) {
        return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      }

      const fullPath = join(current.metadata.artifactsDir, params.path);
      if (!existsSync(fullPath)) {
        return { content: [{ type: "text", text: `Artifact not found: ${params.path}` }], details: { path: fullPath }, isError: true };
      }
      const content = readFileSync(fullPath, "utf-8");
      return { content: [{ type: "text", text: content }], details: { path: fullPath } };
    },
  });

  // Tool: changeflow_write_artifact
  pi.registerTool({
    name: "changeflow_write_artifact",
    label: "Write Changeflow Artifact",
    description: "Write an artifact file to the active Changeflow workflow's artifacts directory.",
    parameters: Type.Object({
      path: Type.String({ description: "Relative path within the artifacts directory." }),
      content: Type.String({ description: "Content to write to the artifact file." }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      state.ctx = ctx;
      const registry = await ensureRegistry(state, ctx.cwd);
      const runtime = ensureRuntime(state, ctx.cwd, registry);
      const current = runtime.current();
      if (!current) {
        return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      }

      const fullPath = join(current.metadata.artifactsDir, params.path);
      mkdirSync(dirname(fullPath), { recursive: true });
      writeFileSync(fullPath, params.content, "utf-8");
      return { content: [{ type: "text", text: `Artifact written: ${params.path}` }], details: { path: fullPath } };
    },
  });

  // Tool: changeflow_complete_main_task
  pi.registerTool({
    name: "changeflow_complete_main_task",
    label: "Complete Changeflow Main Task",
    description: "Signal completion of a main-agent task invoked by the workflow, resuming the state machine.",
    parameters: Type.Object({
      task_id: Type.String({ description: "The task ID provided when the main-agent task was invoked." }),
      output: Type.Unknown({ description: "Output data to pass back to the workflow." }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      state.ctx = ctx;
      const registry = await ensureRegistry(state, ctx.cwd);
      const runtime = ensureRuntime(state, ctx.cwd, registry);
      const current = runtime.current();
      if (!current) {
        return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      }

      // The actual main task completion would be handled by the actor adapters
      // For now, we provide a placeholder implementation
      return {
        content: [{ type: "text", text: `Main task completion not yet implemented. Task ID: ${params.task_id}` }],
        details: { taskId: params.task_id, output: params.output },
        isError: true,
      };
    },
  });

  // Hook: before_agent_start to inject workflow context
  pi.on("before_agent_start", async (_event, ctx) => {
    state.ctx = ctx;
    const registry = await ensureRegistry(state, ctx.cwd);
    const runtime = ensureRuntime(state, ctx.cwd, registry);
    const current = runtime.current();
    if (!current) return;

    const prompt = `[CHANGEFLOW]
Workflow: ${current.metadata.title} (${current.metadata.id})
Current state: ${current.metadata.state}
Description: ${current.metadata.description}
Artifacts directory: ${current.metadata.artifactsDir}

Use changeflow_send_event to advance the workflow state.
Use changeflow_read_artifact and changeflow_write_artifact to manage artifacts.`;

    return {
      message: {
        customType: "changeflow-context",
        display: false,
        content: prompt,
      },
    };
  });

  // Hook: session_start to restore status
  pi.on("session_start", async (_event, ctx) => {
    state.ctx = ctx;
    const registry = await ensureRegistry(state, ctx.cwd);
    const runtime = ensureRuntime(state, ctx.cwd, registry);
    const current = runtime.current();
    if (current) {
      ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${current.metadata.state}`));
    } else {
      ctx.ui.setStatus("changeflow", undefined);
    }
  });
}

function parseStartArgs(text: string): { workflowDefinitionId: string; description: string; error?: string } {
  const parts = text.trim().split(/\s+/).filter(Boolean);
  let workflowDefinitionId = "changeflow.runtime";
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
