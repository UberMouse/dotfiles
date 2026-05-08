import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { ActorRunRecord, RuntimeEventRecord, WorkflowMetadata } from "./types.js";

export type WorkflowPaths = {
  root: string;
  workflowFile: string;
  eventsFile: string;
  snapshotsDir: string;
  artifactsDir: string;
  actorsDir: string;
  snapshotFile(seq: number): string;
  actorDir(actorRunId: string): string;
};

export function createWorkflowPaths(changeflowRoot: string, workflowId: string): WorkflowPaths {
  const root = join(changeflowRoot, workflowId);
  const snapshotsDir = join(root, "snapshots");
  const artifactsDir = join(root, "artifacts");
  const actorsDir = join(root, "actors");
  return {
    root,
    workflowFile: join(root, "workflow.json"),
    eventsFile: join(root, "events.jsonl"),
    snapshotsDir,
    artifactsDir,
    actorsDir,
    snapshotFile: (seq) => join(snapshotsDir, `${seq}.json`),
    actorDir: (actorRunId) => join(actorsDir, actorRunId),
  };
}

async function ensureParent(path: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
}

export async function writeWorkflowMetadata(paths: WorkflowPaths, metadata: WorkflowMetadata): Promise<void> {
  await ensureParent(paths.workflowFile);
  await mkdir(paths.artifactsDir, { recursive: true });
  await mkdir(paths.snapshotsDir, { recursive: true });
  await mkdir(paths.actorsDir, { recursive: true });
  await writeFile(paths.workflowFile, `${JSON.stringify(metadata, null, 2)}\n`, "utf-8");
}

export async function readWorkflowMetadata(paths: WorkflowPaths): Promise<WorkflowMetadata> {
  return JSON.parse(await readFile(paths.workflowFile, "utf-8")) as WorkflowMetadata;
}

export async function appendEvent(paths: WorkflowPaths, record: RuntimeEventRecord): Promise<void> {
  await ensureParent(paths.eventsFile);
  await appendFile(paths.eventsFile, `${JSON.stringify(record)}\n`, "utf-8");
}

export async function readEvents(paths: WorkflowPaths): Promise<RuntimeEventRecord[]> {
  const content = await readFile(paths.eventsFile, "utf-8").catch(() => "");
  return content.split("\n").filter(Boolean).map((line) => JSON.parse(line) as RuntimeEventRecord);
}

export async function writeSnapshot(paths: WorkflowPaths, seq: number, snapshot: unknown): Promise<void> {
  const path = paths.snapshotFile(seq);
  await ensureParent(path);
  await writeFile(path, `${JSON.stringify(snapshot, null, 2)}\n`, "utf-8");
}

export async function readSnapshot(paths: WorkflowPaths, seq: number): Promise<unknown> {
  return JSON.parse(await readFile(paths.snapshotFile(seq), "utf-8"));
}

export async function writeActorRun(paths: WorkflowPaths, record: ActorRunRecord): Promise<void> {
  const dir = paths.actorDir(record.id);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, "metadata.json"), `${JSON.stringify(record, null, 2)}\n`, "utf-8");
  await writeFile(join(dir, "input.json"), `${JSON.stringify(record.input, null, 2)}\n`, "utf-8");
  if (record.output !== undefined) await writeFile(join(dir, "output.json"), `${JSON.stringify(record.output, null, 2)}\n`, "utf-8");
  if (record.error) await writeFile(join(dir, "logs.txt"), `${record.error}\n`, "utf-8");
}
