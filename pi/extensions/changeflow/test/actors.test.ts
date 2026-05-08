import { describe, expect, it, vi } from "vitest";
import { createActorAdapters } from "../src/actors.js";

describe("actor adapters", () => {
  it("runs a child agent through the injected runner", async () => {
    const runChildAgent = vi.fn(async () => ({ approved: true, summary: "looks good" }));
    const adapters = createActorAdapters({ runChildAgent });

    await expect(adapters.childAgent({ role: "reviewer", task: "review plan", state: "review" })).resolves.toEqual({
      approved: true,
      summary: "looks good",
    });
    expect(runChildAgent).toHaveBeenCalledWith({ role: "reviewer", task: "review plan", state: "review" });
  });

  it("records a pending main-agent task and resolves it later", async () => {
    const adapters = createActorAdapters({ runChildAgent: vi.fn() });
    const promise = adapters.mainAgent({ taskId: "task-1", task: "write plan", expectedEvents: ["PLAN_SUBMITTED"] });

    expect(adapters.pendingMainAgentTask()).toMatchObject({ taskId: "task-1", task: "write plan" });
    adapters.completeMainAgentTask("task-1", { type: "PLAN_SUBMITTED", markdown: "# Plan" });

    await expect(promise).resolves.toEqual({ type: "PLAN_SUBMITTED", markdown: "# Plan" });
    expect(adapters.pendingMainAgentTask()).toBeUndefined();
  });

  it("runs a script through the injected runner", async () => {
    const runScript = vi.fn(async () => ({ exitCode: 0, stdout: "success", stderr: "" }));
    const adapters = createActorAdapters({ runChildAgent: vi.fn(), runScript });

    await expect(adapters.runScript({ command: "echo", args: ["hello"], cwd: "/tmp" })).resolves.toEqual({
      exitCode: 0,
      stdout: "success",
      stderr: "",
    });
    expect(runScript).toHaveBeenCalledWith({ command: "echo", args: ["hello"], cwd: "/tmp" });
  });
});
