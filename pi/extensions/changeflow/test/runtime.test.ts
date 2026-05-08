import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import { afterEach, describe, expect, it } from "vitest";
import { setup } from "xstate";
import { ChangeflowRuntime } from "../src/runtime.js";
import { defineWorkflow, type EventUnionFromSchemas } from "../src/types.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

const eventSchemas = {
  START: Type.Object({ type: Type.Literal("START") }),
  FINISH: Type.Object({ type: Type.Literal("FINISH"), note: Type.String() }),
} as const;
type DemoEvent = EventUnionFromSchemas<typeof eventSchemas>;

const demoWorkflow = defineWorkflow({
  id: "demo.workflow",
  name: "Demo Workflow",
  eventSchemas,
  createActorLogic: () => setup({ types: { events: {} as DemoEvent } }).createMachine({
    id: "demo.workflow",
    initial: "idle",
    states: {
      idle: { on: { START: "working" } },
      working: { on: { FINISH: "done" } },
      done: {},
    },
  }),
});

describe("ChangeflowRuntime", () => {
  it("starts a workflow, accepts valid events, rejects invalid events, and restores latest state", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-runtime-"));
    const runtime = new ChangeflowRuntime({ cwd: tempDir, workflows: [demoWorkflow] });

    const instance = await runtime.start({ workflowDefinitionId: "demo.workflow", description: "demo change" });
    expect(instance.metadata.state).toBe("idle");

    await expect(runtime.send({ type: "START" })).resolves.toMatchObject({ ok: true, state: "working" });
    await expect(runtime.send({ type: "FINISH", note: 42 })).resolves.toMatchObject({ ok: false });
    await expect(runtime.send({ type: "FINISH", note: "complete" })).resolves.toMatchObject({ ok: true, state: "done" });

    const restored = new ChangeflowRuntime({ cwd: tempDir, workflows: [demoWorkflow] });
    await restored.restore(instance.metadata.id);
    expect(restored.current()?.metadata.state).toBe("done");
  });
});
