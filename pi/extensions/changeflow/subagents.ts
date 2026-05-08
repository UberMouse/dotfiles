import { spawn } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { Message } from "@mariozechner/pi-ai";

export type ChangeflowSubagentRole = "scout" | "planner" | "worker" | "reviewer" | "qa";

export type ChangeflowSubagentUsage = {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  turns: number;
  contextTokens: number;
};

export type ChangeflowSubagentConfig = {
  role: ChangeflowSubagentRole;
  name: string;
  description: string;
  tools: string[];
  model?: string;
  thinking?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  systemPrompt: string;
};

export type ChangeflowSubagentConfigOverride = {
  tools?: string[];
  model?: string;
  thinking?: ChangeflowSubagentConfig["thinking"];
  systemPrompt?: string;
};

export type ChangeflowSubagentRunInput = {
  workflowId: string;
  artifactsDir: string;
  cwd: string;
  role: ChangeflowSubagentRole;
  task: string;
  phase: string;
  stepId?: string;
  reason?: string;
  configOverride?: ChangeflowSubagentConfigOverride;
  signal?: AbortSignal;
};

export type ChangeflowSubagentArtifactPaths = {
  dir: string;
  input: string;
  output: string;
  metadata: string;
  events: string;
};

export type ChangeflowSubagentRunResult = {
  runId: string;
  role: ChangeflowSubagentRole;
  task: string;
  phase: string;
  stepId?: string;
  exitCode: number;
  finalOutput: string;
  stderr: string;
  usage: ChangeflowSubagentUsage;
  model?: string;
  stopReason?: string;
  error?: string;
  artifacts: ChangeflowSubagentArtifactPaths;
};

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh"]);
const TASK_ARG_LIMIT = 8000;

export const changeflowSubagentRoles: Record<ChangeflowSubagentRole, ChangeflowSubagentConfig> = {
  scout: {
    role: "scout",
    name: "Changeflow Scout",
    description: "Read-only codebase reconnaissance for Changeflow research and planning handoff.",
    tools: ["read", "grep", "find", "ls", "bash"],
    systemPrompt: `You are a Changeflow scout subagent. Investigate the codebase quickly and return compressed, evidence-backed context for the parent orchestrator.

Rules:
- You are not the orchestrator. Do not call Changeflow lifecycle tools or claim the workflow is complete.
- Prefer read-only tools. Bash commands must be inspection-only.
- Do not edit files.
- Return relevant files, symbols, patterns, risks, and recommended next reads.`,
  },
  planner: {
    role: "planner",
    name: "Changeflow Planner",
    description: "Read-only implementation planning and ordering specialist.",
    tools: ["read", "grep", "find", "ls"],
    systemPrompt: `You are a Changeflow planning subagent. Produce concrete plans from provided workflow context and code evidence.

Rules:
- You are not the orchestrator. Do not call Changeflow lifecycle tools or submit plans.
- Do not edit files.
- Make dependencies, risks, and verification steps explicit.
- Return concise markdown that the parent orchestrator can synthesize.`,
  },
  worker: {
    role: "worker",
    name: "Changeflow Worker",
    description: "Implementation specialist for approved Changeflow execution steps.",
    tools: ["read", "grep", "find", "ls", "bash", "edit", "write"],
    systemPrompt: `You are a Changeflow worker subagent. Implement only the specific approved task delegated by the parent orchestrator.

Rules:
- You are not the orchestrator. Do not call Changeflow lifecycle tools or advance the workflow.
- Stay within the delegated task and approved scope.
- Prefer minimal, focused edits.
- Validate when practical and report files changed, commands run, and remaining risks.`,
  },
  reviewer: {
    role: "reviewer",
    name: "Changeflow Reviewer",
    description: "Review specialist for plans, implementation diffs, and risk checks.",
    tools: ["read", "grep", "find", "ls", "bash"],
    systemPrompt: `You are a Changeflow reviewer subagent. Review the delegated plan or implementation and report actionable findings.

Rules:
- You are not the orchestrator. Do not call Changeflow lifecycle tools.
- Bash commands must be inspection or validation commands.
- Do not edit files.
- Prioritize correctness, scope drift, tests, safety, and simplicity.`,
  },
  qa: {
    role: "qa",
    name: "Changeflow QA",
    description: "Validation specialist for tests, typechecks, docs, and release readiness.",
    tools: ["read", "grep", "find", "ls", "bash"],
    systemPrompt: `You are a Changeflow QA subagent. Validate the completed change and produce a concise readiness report.

Rules:
- You are not the orchestrator. Do not call Changeflow lifecycle tools.
- Run or recommend relevant validation commands.
- Do not edit files.
- Report pass/fail status, evidence, and follow-up recommendations.`,
  },
};

function emptyUsage(): ChangeflowSubagentUsage {
  return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, turns: 0, contextTokens: 0 };
}

function slugify(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "subagent";
}

function applyThinkingSuffix(model: string | undefined, thinking: string | undefined): string | undefined {
  if (!model || !thinking || thinking === "off") return model;
  const colonIdx = model.lastIndexOf(":");
  if (colonIdx !== -1 && THINKING_LEVELS.has(model.slice(colonIdx + 1))) return model;
  return `${model}:${thinking}`;
}

function resolveSubagentConfig(
  role: ChangeflowSubagentRole,
  override?: ChangeflowSubagentConfigOverride,
): ChangeflowSubagentConfig {
  const base = changeflowSubagentRoles[role];
  const baseTools = new Set(base.tools);
  const narrowedTools = override?.tools?.filter((tool) => baseTools.has(tool));
  const tools = narrowedTools && narrowedTools.length > 0 ? narrowedTools : base.tools;
  const systemPrompt = override?.systemPrompt
    ? `${base.systemPrompt}\n\nAdditional phase-specific instructions:\n${override.systemPrompt}`
    : base.systemPrompt;

  return {
    ...base,
    tools,
    model: override?.model ?? base.model,
    thinking: override?.thinking ?? base.thinking,
    systemPrompt,
  };
}

function getPiInvocation(args: string[]): { command: string; args: string[] } {
  const currentScript = process.argv[1];
  const isBunVirtualScript = currentScript?.startsWith("/$bunfs/root/");
  if (currentScript && !isBunVirtualScript && existsSync(currentScript)) {
    return { command: process.execPath, args: [currentScript, ...args] };
  }

  const execName = basename(process.execPath).toLowerCase();
  const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName);
  if (!isGenericRuntime) return { command: process.execPath, args };
  return { command: "pi", args };
}

function textFromMessage(message: Message): string {
  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => {
      if (part.type === "text") return part.text;
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

function getFinalOutput(messages: Message[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message?.role === "assistant") return textFromMessage(message);
  }
  return "";
}

function createArtifacts(input: ChangeflowSubagentRunInput, runId: string): ChangeflowSubagentArtifactPaths {
  const dir = join(input.artifactsDir, "subagents", runId);
  mkdirSync(dir, { recursive: true });
  return {
    dir,
    input: join(dir, "input.md"),
    output: join(dir, "output.md"),
    metadata: join(dir, "metadata.json"),
    events: join(dir, "events.jsonl"),
  };
}

async function writeTempFile(prefix: string, fileName: string, content: string): Promise<{ dir: string; path: string }> {
  const dir = await mkdtemp(join(tmpdir(), prefix));
  const path = join(dir, fileName);
  await writeFile(path, content, { encoding: "utf-8", mode: 0o600 });
  return { dir, path };
}

function cleanupTempDir(dir: string | undefined): void {
  if (!dir) return;
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    // Best effort cleanup.
  }
}

export async function runChangeflowSubagent(input: ChangeflowSubagentRunInput): Promise<ChangeflowSubagentRunResult> {
  const config = resolveSubagentConfig(input.role, input.configOverride);
  const runId = `${new Date().toISOString().replace(/[:.]/g, "-")}-${input.role}-${slugify(input.task)}`;
  const artifacts = createArtifacts(input, runId);
  const startedAt = new Date().toISOString();

  writeFileSync(
    artifacts.input,
    [
      `# Changeflow subagent input`,
      ``,
      `- Workflow: ${input.workflowId}`,
      `- Phase: ${input.phase}`,
      `- Role: ${input.role}`,
      input.stepId ? `- Step: ${input.stepId}` : undefined,
      input.reason ? `- Reason: ${input.reason}` : undefined,
      `- CWD: ${input.cwd}`,
      ``,
      `## Task`,
      ``,
      input.task,
      ``,
    ]
      .filter((line): line is string => line !== undefined)
      .join("\n"),
  );

  const args = ["--mode", "json", "-p", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates"];
  const model = applyThinkingSuffix(config.model, config.thinking);
  if (model) args.push("--model", model);
  if (config.tools.length > 0) args.push("--tools", config.tools.join(","));

  let promptTempDir: string | undefined;
  let taskTempDir: string | undefined;
  const messages: Message[] = [];
  const usage = emptyUsage();
  const eventLines: string[] = [];
  let stderr = "";
  let stopReason: string | undefined;
  let observedModel: string | undefined = model;
  let error: string | undefined;
  let wasAborted = false;

  try {
    const prompt = await writeTempFile("pi-changeflow-subagent-", `${input.role}-system.md`, config.systemPrompt);
    promptTempDir = prompt.dir;
    args.push("--append-system-prompt", prompt.path);

    if (input.task.length > TASK_ARG_LIMIT) {
      const task = await writeTempFile("pi-changeflow-subagent-task-", "task.md", `Task: ${input.task}`);
      taskTempDir = task.dir;
      args.push(`@${task.path}`);
    } else {
      args.push(`Task: ${input.task}`);
    }

    const exitCode = await new Promise<number>((resolveExit) => {
      const invocation = getPiInvocation(args);
      const proc = spawn(invocation.command, invocation.args, {
        cwd: input.cwd,
        env: { ...process.env, PI_SUBAGENT_CHILD: "1", PI_CHANGEFLOW_SUBAGENT_CHILD: "1" },
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      });

      let buffer = "";
      let settled = false;
      let removeAbortListener: (() => void) | undefined;

      const finish = (code: number) => {
        if (settled) return;
        settled = true;
        removeAbortListener?.();
        resolveExit(code);
      };

      const processLine = (line: string) => {
        if (!line.trim()) return;
        eventLines.push(line);
        let event: { type?: string; message?: Message };
        try {
          event = JSON.parse(line) as { type?: string; message?: Message };
        } catch {
          return;
        }

        if (event.type === "message_end" && event.message) {
          messages.push(event.message);
          if (event.message.role === "assistant") {
            usage.turns += 1;
            const assistant = event.message as Message & {
              usage?: {
                input?: number;
                output?: number;
                cacheRead?: number;
                cacheWrite?: number;
                totalTokens?: number;
                cost?: { total?: number };
              };
              model?: string;
              stopReason?: string;
              errorMessage?: string;
            };
            if (assistant.usage) {
              usage.input += assistant.usage.input ?? 0;
              usage.output += assistant.usage.output ?? 0;
              usage.cacheRead += assistant.usage.cacheRead ?? 0;
              usage.cacheWrite += assistant.usage.cacheWrite ?? 0;
              usage.cost += assistant.usage.cost?.total ?? 0;
              usage.contextTokens = assistant.usage.totalTokens ?? usage.contextTokens;
            }
            observedModel = assistant.model ?? observedModel;
            stopReason = assistant.stopReason ?? stopReason;
            error = assistant.errorMessage ?? error;
          }
        }
      };

      proc.stdout.on("data", (data) => {
        buffer += data.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) processLine(line);
      });

      proc.stderr.on("data", (data) => {
        stderr += data.toString();
      });

      proc.on("close", (code) => {
        if (buffer.trim()) processLine(buffer);
        finish(code ?? 0);
      });

      proc.on("error", (spawnError) => {
        error = spawnError instanceof Error ? spawnError.message : String(spawnError);
        finish(1);
      });

      const abort = () => {
        wasAborted = true;
        proc.kill("SIGTERM");
        setTimeout(() => {
          if (!proc.killed) proc.kill("SIGKILL");
        }, 5000).unref?.();
      };

      if (input.signal) {
        if (input.signal.aborted) abort();
        else {
          input.signal.addEventListener("abort", abort, { once: true });
          removeAbortListener = () => input.signal?.removeEventListener("abort", abort);
        }
      }
    });

    const finalOutput = getFinalOutput(messages);
    const completedAt = new Date().toISOString();
    if (wasAborted) error = error ?? "Subagent was aborted.";
    if (exitCode !== 0 && !error) error = stderr.trim() || `Subagent exited with code ${exitCode}.`;
    if (stopReason === "error" && !error) error = finalOutput || "Subagent reported an error.";

    const result: ChangeflowSubagentRunResult = {
      runId,
      role: input.role,
      task: input.task,
      phase: input.phase,
      stepId: input.stepId,
      exitCode: wasAborted && exitCode === 0 ? 1 : exitCode,
      finalOutput,
      stderr,
      usage,
      model: observedModel,
      stopReason,
      error,
      artifacts,
    };

    writeFileSync(artifacts.events, eventLines.join("\n") + (eventLines.length > 0 ? "\n" : ""));
    writeFileSync(artifacts.output, finalOutput || error || stderr || "(no output)");
    writeFileSync(
      artifacts.metadata,
      JSON.stringify(
        {
          runId,
          workflowId: input.workflowId,
          role: input.role,
          phase: input.phase,
          stepId: input.stepId,
          reason: input.reason,
          cwd: input.cwd,
          tools: config.tools,
          model: observedModel,
          requestedModel: model,
          exitCode: result.exitCode,
          stopReason,
          error,
          stderr,
          usage,
          artifacts,
          startedAt,
          completedAt,
        },
        null,
        2,
      ),
    );

    return result;
  } finally {
    cleanupTempDir(promptTempDir);
    cleanupTempDir(taskTempDir);
  }
}

export function summarizeSubagentResult(result: ChangeflowSubagentRunResult): string {
  const status = result.exitCode === 0 && !result.error ? "succeeded" : "failed";
  const previewSource = result.finalOutput || result.error || result.stderr || "(no output)";
  const preview = previewSource.length > 1200 ? `${previewSource.slice(0, 1200)}\n…` : previewSource;
  return [
    `Changeflow subagent ${result.role} ${status}.`,
    `Run: ${result.runId}`,
    `Artifacts: ${result.artifacts.dir}`,
    result.model ? `Model: ${result.model}` : undefined,
    `Usage: ${result.usage.turns} turn(s), input ${result.usage.input}, output ${result.usage.output}, cost $${result.usage.cost.toFixed(4)}`,
    ``,
    preview,
  ]
    .filter((line): line is string => line !== undefined)
    .join("\n");
}
