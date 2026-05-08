import { mkdir, rm, writeFile } from "node:fs/promises";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setup } from "xstate";
import { ChangeflowRuntime } from "../src/runtime.js";
import { defineWorkflow } from "../src/types.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("actor recovery", () => {
  it("sends recovery events for orphaned actors on restore", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-recovery-"));
    const receivedEvents: unknown[] = [];

    const workflow = defineWorkflow({
      id: "recovery.workflow",
      name: "Recovery",
      createActorLogic: () => setup({
        types: { events: {} as { type: "START" } | { type: "ACTOR_RECOVERY_NEEDED"; actorId: string; error: string } },
      }).createMachine({
        id: "recovery.workflow",
        initial: "idle",
        states: {
          idle: {
            on: {
              START: "working",
              ACTOR_RECOVERY_NEEDED: {
                target: "idle",
                actions: ({ event }) => receivedEvents.push(event),
              },
            },
          },
          working: {},
        },
      }),
    });

    const runtime = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow] });
    const started = await runtime.start({ workflowDefinitionId: "recovery.workflow", description: "test" });

    // Simulate an orphaned actor by writing a running actor record
    const actorDir = join(tempDir, ".pi", "changeflow", started.metadata.id, "actors", "orphan-1");
    await mkdir(actorDir, { recursive: true });
    await writeFile(join(actorDir, "metadata.json"), JSON.stringify({
      id: "orphan-1",
      workflowId: started.metadata.id,
      kind: "childAgent",
      state: "working",
      status: "running",
      input: {},
      startedAt: new Date().toISOString(),
    }));

    // Restore should detect orphaned actor and send recovery event
    const restored = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow] });
    await restored.restore(started.metadata.id);

    await vi.waitFor(() => expect(receivedEvents.length).toBe(1));
    expect(receivedEvents[0]).toMatchObject({
      type: "ACTOR_RECOVERY_NEEDED",
      actorId: "orphan-1",
    });
  });
});
