import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { setup } from "xstate";
import { ChangeflowRuntime } from "../src/runtime.js";
import { defineWorkflow } from "../src/types.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("runtime restoreCurrent", () => {
  it("restores an existing workflow id and reports missing ids clearly", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-restore-"));
    const workflow = defineWorkflow({
      id: "restore.workflow",
      name: "Restore",
      createActorLogic: () =>
        setup({}).createMachine({
          id: "restore.workflow",
          initial: "idle",
          states: { idle: {} },
        }),
    });
    const runtime = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow] });
    const started = await runtime.start({ workflowDefinitionId: "restore.workflow", description: "restore me" });

    const restored = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow] });
    await expect(restored.restore(started.metadata.id)).resolves.toMatchObject({
      metadata: { id: started.metadata.id },
    });
    await expect(restored.restore("missing-id")).rejects.toThrow();
  });
});
