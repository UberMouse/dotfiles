import { describe, expect, it, vi } from "vitest";
import { createActor } from "xstate";
import changeflowWorkflow from "../bundled-workflows/changeflow-runtime.js";
import type { WorkflowActorFactories, RuntimeCapabilities } from "../src/types.js";

const createMockRuntime = (): RuntimeCapabilities => ({
  log: () => undefined,
  writeArtifact: () => undefined,
  setStatus: () => undefined,
  emitToPi: () => undefined,
  queueMainAgentMessage: () => undefined,
});

const createMockActors = (
  childAgentImpl: WorkflowActorFactories["childAgent"]
): WorkflowActorFactories => ({
  childAgent: childAgentImpl,
  mainAgent: async () => ({ type: "MAIN_TASK_DONE" }),
  plannotatorReview: async () => ({ approved: true }),
  askUser: async () => ({ response: "yes" }),
  runScript: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
});

describe("ported Changeflow workflow", () => {
  it("moves through planning, machine agent review, human review, execution, and done", async () => {
    const runtime = createMockRuntime();
    const actors = createMockActors(async (input) => {
      if (input.role === "planner") return { markdown: "# Plan" };
      if (input.role === "reviewer") {
        expect(input.task).toContain("# Plan");
        return { approved: true, summary: "approved" };
      }
      throw new Error(`Unexpected role ${input.role}`);
    });
    const actor = createActor(changeflowWorkflow.createActorLogic({ runtime, actors, actions: {} }));
    actor.start();

    actor.send({ type: "START" });
    expect(actor.getSnapshot().value).toBe("research");
    actor.send({ type: "RESEARCH_COMPLETE" });
    expect(actor.getSnapshot().value).toBe("high_level_planning");
    await vi.waitFor(() => expect(actor.getSnapshot().value).toBe("high_level_user_review"));
    actor.send({ type: "USER_APPROVED" });
    expect(actor.getSnapshot().value).toBe("detailed_planning");
    actor.send({ type: "PLAN_SUBMITTED", kind: "detailed_plan", markdown: "# Details" });
    expect(actor.getSnapshot().value).toBe("detailed_user_review");
    actor.send({ type: "USER_APPROVED" });
    expect(actor.getSnapshot().value).toBe("execution_ordering");
    actor.send({ type: "ORDER_DEFINED", markdown: "# Order" });
    expect(actor.getSnapshot().value).toBe("executing");
    actor.send({ type: "EXECUTION_COMPLETE" });
    expect(actor.getSnapshot().value).toBe("qa");
    actor.send({ type: "QA_COMPLETE" });
    expect(actor.getSnapshot().value).toBe("user_validation");
    actor.send({ type: "USER_APPROVED" });
    expect(actor.getSnapshot().value).toBe("done");
  });

  it("loops through revision when reviewer rejects the plan", async () => {
    const runtime = createMockRuntime();

    let plannerCallCount = 0;
    let reviewerCallCount = 0;

    const actors = createMockActors(async (input) => {
      if (input.role === "planner") {
        plannerCallCount++;
        return { markdown: plannerCallCount === 1 ? "# Bad Plan" : "# Good Plan" };
      }
      if (input.role === "reviewer") {
        reviewerCallCount++;
        if (reviewerCallCount === 1) {
          expect(input.task).toContain("# Bad Plan");
          return { approved: false, summary: "needs work", feedback: "be more specific" };
        }
        expect(input.task).toContain("# Good Plan");
        return { approved: true, summary: "approved" };
      }
      throw new Error(`Unexpected role ${input.role}`);
    });

    const actor = createActor(changeflowWorkflow.createActorLogic({ runtime, actors, actions: {} }));
    actor.start();

    actor.send({ type: "START" });
    actor.send({ type: "RESEARCH_COMPLETE" });

    // First planning attempt - reviewer rejects
    await vi.waitFor(() => expect(actor.getSnapshot().value).toBe("high_level_revision"));

    // Submit revised plan (simulating main agent response to revision prompt)
    actor.send({ type: "PLAN_SUBMITTED", kind: "high_level_plan", markdown: "# Good Plan" });

    // Second review should approve
    await vi.waitFor(() => expect(actor.getSnapshot().value).toBe("high_level_user_review"));

    expect(plannerCallCount).toBe(1); // Planner only called once initially
    expect(reviewerCallCount).toBe(2); // Reviewer called twice
  });

  it("handles actor invocation errors gracefully", async () => {
    const runtime = createMockRuntime();

    const actors = createMockActors(async (input) => {
      if (input.role === "planner") {
        throw new Error("Planner agent crashed");
      }
      return { approved: true, summary: "ok" };
    });

    const actor = createActor(changeflowWorkflow.createActorLogic({ runtime, actors, actions: {} }));
    actor.start();

    actor.send({ type: "START" });
    actor.send({ type: "RESEARCH_COMPLETE" });

    // Error should transition to revision state
    await vi.waitFor(() => expect(actor.getSnapshot().value).toBe("high_level_revision"));

    // Context should contain error feedback
    expect(actor.getSnapshot().context.latestFeedback).toContain("Planner agent crashed");
  });
});
