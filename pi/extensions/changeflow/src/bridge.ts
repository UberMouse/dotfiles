import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
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

function ensureRuntime(state: BridgeState, cwd: string, registry: WorkflowRegistry, pi: ExtensionAPI): ChangeflowRuntime {
  if (!state.runtime) {
    state.runtime = new ChangeflowRuntime({
      cwd,
      workflows: [...registry.definitions.values()],
      actorAdapters: {
        runChildAgent: async (input) => {
          const current = state.runtime?.current();
          if (!current) throw new Error("No active workflow to run child agent.");
          const actorId = `child-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
          const controller = state.runtime!.trackActorStart(actorId, "childAgent", input.state, input);
          try {
            const result = await runChangeflowSubagent({
              workflowId: current.metadata.id,
              artifactsDir: current.metadata.artifactsDir,
              cwd,
              role: input.role as ChangeflowSubagentRole,
              task: input.task,
              phase: input.state,
              stepId: input.stepId,
              reason: input.reason,
              signal: controller.signal,
            });
            if (result.exitCode !== 0 || result.error) {
              const error = result.error ?? `Subagent exited with code ${result.exitCode}`;
              await state.runtime!.trackActorComplete(actorId, undefined, error);
              throw new Error(error);
            }
            let output: unknown;
            try {
              output = JSON.parse(result.finalOutput);
            } catch {
              output = { output: result.finalOutput };
            }
            await state.runtime!.trackActorComplete(actorId, output);
            return output;
          } catch (error) {
            await state.runtime!.trackActorComplete(actorId, undefined, error instanceof Error ? error.message : String(error));
            throw error;
          }
        },
        runScript: async (input) => {
          const actorId = `script-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
          const controller = state.runtime!.trackActorStart(actorId, "script", "script", input);
          try {
            const { spawn } = await import("node:child_process");
            const result = await new Promise<{ exitCode: number | null; stdout: string; stderr: string }>((resolve, reject) => {
              const proc = spawn(input.command, input.args ?? [], {
                cwd: input.cwd ?? cwd,
                timeout: input.timeout ?? 30_000,
                shell: true,
              });
              let stdout = "";
              let stderr = "";
              proc.stdout?.on("data", (data) => { stdout += data; });
              proc.stderr?.on("data", (data) => { stderr += data; });
              proc.on("close", (exitCode) => resolve({ exitCode, stdout, stderr }));
              proc.on("error", reject);
              controller.signal.addEventListener("abort", () => proc.kill());
            });
            await state.runtime!.trackActorComplete(actorId, result);
            return result;
          } catch (error) {
            await state.runtime!.trackActorComplete(actorId, undefined, error instanceof Error ? error.message : String(error));
            throw error;
          }
        },
        requestPlannotatorReview: async (input) => {
          const requestId = `changeflow-${Date.now()}`;
          return await new Promise((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error("Plannotator did not respond within 5s.")), 5_000);
            pi.events.emit("plannotator:request", {
              requestId,
              action: "plan-review",
              payload: { planFilePath: input.artifactPath, planContent: input.content, origin: "changeflow-runtime", kind: input.kind },
              respond(response: unknown) {
                clearTimeout(timeout);
                resolve(response);
              },
            });
          });
        },
        askUser: async (input) => {
          if (!state.ctx) throw new Error("No extension context available for askUser.");
          return state.ctx.ui.select(input.prompt, input.choices ?? ["approved", "rejected"]);
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
          const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
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
          const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
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
          const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
          const current = runtime.current();
          if (!current) {
            ctx.ui.notify("No active Changeflow workflow.", "info");
            return;
          }
          const actors = await runtime.listActorRuns();
          if (actors.length === 0) {
            ctx.ui.notify(`Active workflow: ${current.metadata.id}\nNo actor runs recorded.`, "info");
            return;
          }
          const rows = actors.map((a) => `- [${a.status}] ${a.id} (${a.kind}) in state ${a.state}`);
          ctx.ui.notify(`Active workflow: ${current.metadata.id}\n\nActor runs:\n${rows.join("\n")}`, "info");
          return;
        }

        case "cancel-actor": {
          const actorId = restText.trim();
          if (!actorId) {
            ctx.ui.notify("Usage: /changeflow cancel-actor <actor-id>", "warning");
            return;
          }
          const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
          try {
            await runtime.cancelActor(actorId);
            ctx.ui.notify(`Cancelled actor ${actorId}.`, "info");
          } catch (err) {
            ctx.ui.notify(err instanceof Error ? err.message : String(err), "warning");
          }
          return;
        }

        case "send": {
          const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
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
      const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
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
      const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
      const current = runtime.current();
      const pendingMainAgentTask = runtime.pendingMainAgentTask();
      const details = { metadata: current?.metadata, pendingMainAgentTask, editPolicy: runtime.currentEditPolicy() };
      return { content: [{ type: "text", text: current ? JSON.stringify(details, null, 2) : "No active Changeflow workflow." }], details };
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
      const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
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
      const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
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
      const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
      try {
        runtime.completeMainAgentTask(params.task_id, params.output);
        return { content: [{ type: "text", text: `Completed main-agent task ${params.task_id}.` }], details: { taskId: params.task_id } };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return { content: [{ type: "text", text: message }], details: { taskId: params.task_id }, isError: true };
      }
    },
  });

  // Hook: before_agent_start to inject workflow context
  pi.on("before_agent_start", async (_event, ctx) => {
    state.ctx = ctx;
    const registry = await ensureRegistry(state, ctx.cwd);
    const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
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
    const workflowId = lastWorkflowIdFromSession(ctx);
    if (!workflowId) {
      ctx.ui.setStatus("changeflow", undefined);
      return;
    }
    try {
      const registry = await ensureRegistry(state, ctx.cwd);
      const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
      const restored = await runtime.restore(workflowId);
      ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${restored.metadata.state}`));
    } catch (error) {
      ctx.ui.notify(`Could not restore Changeflow workflow ${workflowId}: ${error instanceof Error ? error.message : String(error)}`, "warning");
    }
  });

  // Hook: tool_call to enforce edit policy
  pi.on("tool_call", async (event, ctx) => {
    state.ctx = ctx;
    const registry = await ensureRegistry(state, ctx.cwd);
    const runtime = ensureRuntime(state, ctx.cwd, registry, pi);
    const current = runtime.current();
    if (!current) return;
    if (runtime.currentEditPolicy() === "sourceAllowed") return;
    if (event.toolName !== "write" && event.toolName !== "edit") return;
    const inputPath = (event.input as { path?: string }).path;
    if (!inputPath) return;
    const fullPath = resolve(ctx.cwd, inputPath);
    const artifacts = resolve(current.metadata.artifactsDir);
    const isArtifact = fullPath === artifacts || fullPath.startsWith(artifacts + sep);
    if (!isArtifact) {
      return {
        block: true,
        reason: `Changeflow: source edits are blocked in ${current.metadata.state}. Write/edit under ${current.metadata.artifactsDir} only.`,
      };
    }
  });
}

function lastWorkflowIdFromSession(ctx: ExtensionContext): string | undefined {
  const entries = ctx.sessionManager.getEntries();
  const last = entries
    .filter((entry: { type: string; customType?: string }) => entry.type === "custom" && entry.customType === CUSTOM_ENTRY)
    .pop() as { data?: { workflowId?: string; cleared?: boolean } } | undefined;
  if (last?.data?.cleared) return undefined;
  return last?.data?.workflowId;
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
