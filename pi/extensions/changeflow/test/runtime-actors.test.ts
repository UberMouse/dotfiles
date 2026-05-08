import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import { afterEach, describe, expect, it, vi } from "vitest";
import { assign, fromPromise, setup } from "xstate";
import { ChangeflowRuntime } from "../src/runtime.js";
import { defineWorkflow, type EventUnionFromSchemas } from "../src/types.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("runtime capabilities and actors", () => {
  it("lets invoked child agents hand data from planning to reviewing", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-runtime-actors-"));
    const eventSchemas = { START: Type.Object({ type: Type.Literal("START") }) } as const;
    type ActorWorkflowEvent = EventUnionFromSchemas<typeof eventSchemas>;
    type PlanningOutput = { markdown: string };
    type ReviewOutput = { approved: boolean; summary: string };

    const workflow = defineWorkflow({
      id: "actor.workflow",
      name: "Actor Workflow",
      eventSchemas,
      createActorLogic: ({ runtime, actors }) => setup({
        types: {
          context: {} as { planMarkdown?: string; reviewSummary?: string },
          events: {} as ActorWorkflowEvent,
        },
        actors: {
          planningAgent: fromPromise(() => actors.childAgent({ role: "planner", task: "write a plan", state: "planning" }) as Promise<PlanningOutput>),
          reviewingAgent: fromPromise(({ input }: { input: { planMarkdown: string } }) => actors.childAgent({
            role: "reviewer",
            task: `Review this plan:
${input.planMarkdown}`,
            state: "reviewing",
          }) as Promise<ReviewOutput>),
        },
      }).createMachine({
        id: "actor.workflow",
        context: {},
        initial: "idle",
        states: {
          idle: { on: { START: "planning" } },
          planning: {
            invoke: {
              src: "planningAgent",
              onDone: {
                target: "reviewing",
                actions: [
                  assign({ planMarkdown: ({ event }) => event.output.markdown }),
                  ({ event }) => runtime.writeArtifact("plan.md", event.output.markdown),
                ],
              },
              onError: { target: "revision" },
            },
          },
          reviewing: {
            invoke: {
              src: "reviewingAgent",
              input: ({ context }) => ({ planMarkdown: context.planMarkdown ?? "" }),
              onDone: [
                {
                  guard: ({ event }) => event.output.approved,
                  target: "approved",
                  actions: assign({ reviewSummary: ({ event }) => event.output.summary }),
                },
                { target: "revision" },
              ],
              onError: { target: "revision" },
            },
          },
          revision: {},
          approved: {},
        },
      }),
    });

    const runChildAgent = vi.fn(async (input: { role: string; task: string }) => {
      if (input.role === "planner") return { markdown: "# Plan" } satisfies PlanningOutput;
      if (input.role === "reviewer") {
        expect(input.task).toContain("# Plan");
        return { approved: true, summary: "looks good" } satisfies ReviewOutput;
      }
      throw new Error(`Unexpected role ${input.role}`);
    });

    const runtime = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow], actorAdapters: { runChildAgent } });
    await runtime.start({ workflowDefinitionId: "actor.workflow", description: "actor workflow" });
    await expect(runtime.send({ type: "START" })).resolves.toMatchObject({ ok: true });
    await vi.waitFor(() => expect(runtime.current()?.metadata.state).toBe("approved"));

    expect(runChildAgent).toHaveBeenNthCalledWith(1, expect.objectContaining({ role: "planner" }));
    expect(runChildAgent).toHaveBeenNthCalledWith(2, expect.objectContaining({ role: "reviewer", task: expect.stringContaining("# Plan") }));

    const artifactsDir = runtime.current()?.metadata.artifactsDir;
    await expect(readFile(join(artifactsDir!, "plan.md"), "utf-8")).resolves.toBe("# Plan");
  });
});
