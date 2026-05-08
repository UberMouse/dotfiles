import { describe, expect, it } from "vitest";
import { createActorAdapters } from "../src/actors.js";

describe("main-agent task completion", () => {
  it("rejects wrong task ids and resolves the matching task", async () => {
    const adapters = createActorAdapters({ runChildAgent: async () => ({}) });
    const promise = adapters.mainAgent({ taskId: "abc", task: "do work", expectedEvents: ["DONE"] });

    expect(() => adapters.completeMainAgentTask("wrong", { type: "DONE" })).toThrow("No pending main-agent task wrong");
    adapters.completeMainAgentTask("abc", { type: "DONE" });
    await expect(promise).resolves.toEqual({ type: "DONE" });
  });
});
