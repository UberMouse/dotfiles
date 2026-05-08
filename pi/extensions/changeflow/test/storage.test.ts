import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { appendEvent, createWorkflowPaths, readEvents, readWorkflowMetadata, writeActorRun, writeSnapshot, writeWorkflowMetadata } from "../src/storage.js";
import type { ActorRunRecord, WorkflowMetadata } from "../src/types.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("changeflow storage", () => {
  it("writes metadata, event log entries, snapshots, and actor records", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-storage-"));
    const paths = createWorkflowPaths(tempDir, "wf-1");
    const metadata: WorkflowMetadata = {
      id: "wf-1",
      title: "demo",
      description: "demo workflow",
      cwd: tempDir,
      workflowDefinitionId: "demo.workflow",
      state: "idle",
      createdAt: "2026-05-08T00:00:00.000Z",
      updatedAt: "2026-05-08T00:00:00.000Z",
      artifactsDir: paths.artifactsDir,
      latestSnapshotSeq: 0,
    };

    await writeWorkflowMetadata(paths, metadata);
    await appendEvent(paths, { seq: 1, at: metadata.createdAt, direction: "in", kind: "event.accepted", workflowId: "wf-1", event: { type: "START" } });
    await writeSnapshot(paths, 1, { value: "idle" });

    const actor: ActorRunRecord = {
      id: "actor-1",
      workflowId: "wf-1",
      kind: "childAgent",
      state: "review",
      status: "running",
      input: { task: "review plan" },
      startedAt: metadata.createdAt,
    };
    await writeActorRun(paths, actor);

    await expect(readWorkflowMetadata(paths)).resolves.toEqual(metadata);
    await expect(readEvents(paths)).resolves.toHaveLength(1);
    await expect(readFile(join(paths.actorDir("actor-1"), "input.json"), "utf-8")).resolves.toContain("review plan");
  });
});
