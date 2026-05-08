# Changeflow XState Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `pi/extensions/changeflow` so trusted TypeScript XState workflow modules own workflow behavior, while the Pi extension acts as a runtime/harness.

**Architecture:** Split the current monolithic extension into focused modules: workflow definitions, durable storage, runtime, actor/capability adapters, and Pi bridge. Workflow modules return a fully constructed XState actor logic object, typically from `setup(...).createMachine(...)`; the runtime passes that object directly to `createActor`. Port the existing Changeflow lifecycle into a bundled TS workflow and add a machine-invoked high-level plan reviewer child agent to prove the machine can spawn agents and branch on their results.

**Tech Stack:** TypeScript, Pi extension API, XState v5, TypeBox, Vitest, Node filesystem/process APIs.

---

## Scope Check

The spec covers one cohesive subsystem: a refactor of the existing Changeflow extension into an XState-controlled runtime. The implementation is large, so tasks are staged to keep the extension typechecking after each commit and to preserve a runnable `/changeflow` command throughout the migration. Backward compatibility with the current phase-specific tools is out of scope.

## File Structure

Create or modify these files:

- Modify `pi/extensions/changeflow/package.json`: add Vitest scripts and test dependency.
- Modify `pi/extensions/changeflow/tsconfig.json`: include new source and test files.
- Create `pi/extensions/changeflow/src/types.ts`: shared workflow/runtime/event/persistence types and TypeBox helpers. The workflow contract accepts XState actor logic, not raw machine config, so workflows can use the XState `setup()` API. Workflow event schemas must be declared as `const` values, converted to a TypeScript union with `EventUnionFromSchemas`, and supplied to `setup({ types: { events } })` so transition handlers typecheck.
- Create `pi/extensions/changeflow/src/storage.ts`: event log, snapshot, workflow metadata, and actor-run filesystem persistence.
- Create `pi/extensions/changeflow/src/runtime.ts`: actor logic lifecycle, event validation, snapshot persistence, action capabilities, actor completion routing.
- Create `pi/extensions/changeflow/src/actors.ts`: awaited actor factories for child agents, main-agent tasks, Plannotator/user review, and scripts.
- Create `pi/extensions/changeflow/src/bridge.ts`: Pi command/tool/lifecycle bridge around the runtime.
- Rewrite `pi/extensions/changeflow/index.ts`: thin extension entrypoint that installs the bridge.
- Create `pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts`: ported Changeflow workflow module.
- Keep `pi/extensions/changeflow/subagents.ts`: reuse existing child-agent subprocess implementation.
- Replace or retire `pi/extensions/changeflow/workflows.ts` after the new loader exists.
- Create tests under `pi/extensions/changeflow/test/*.test.ts`.
- Modify `pi/extensions/changeflow/README.md`: document the new machine-as-program model and generic tools.

## Task 1: Add Test Harness

**Files:**
- Modify: `pi/extensions/changeflow/package.json`
- Modify: `pi/extensions/changeflow/tsconfig.json`
- Create: `pi/extensions/changeflow/test/smoke.test.ts`

- [ ] **Step 1: Add a failing smoke test**

Create `pi/extensions/changeflow/test/smoke.test.ts`:

```ts
import { describe, expect, it } from "vitest";

describe("changeflow test harness", () => {
  it("runs TypeScript tests", () => {
    expect(1 + 1).toBe(2);
  });
});
```

- [ ] **Step 2: Run the test before Vitest is installed**

Run:

```bash
cd pi/extensions/changeflow
npm test
```

Expected: FAIL because no `test` script exists.

- [ ] **Step 3: Add Vitest scripts and dependency**

Update `pi/extensions/changeflow/package.json` to this complete shape, preserving existing versions if npm has already updated lockfile ranges:

```json
{
  "name": "pi-changeflow-extension",
  "private": true,
  "type": "module",
  "scripts": {
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "check": "npm run typecheck && npm test",
    "build": "npm run typecheck"
  },
  "dependencies": {
    "typebox": "^1.1.36",
    "xstate": "^5.19.0"
  },
  "devDependencies": {
    "@mariozechner/pi-coding-agent": "0.70.6",
    "@types/node": "^22.15.3",
    "typescript": "^5.9.3",
    "vitest": "^3.2.4"
  },
  "pi": {
    "extensions": [
      "./index.ts"
    ]
  }
}
```

Run:

```bash
cd pi/extensions/changeflow
npm install
```

Expected: `package-lock.json` updates and installs Vitest.

- [ ] **Step 4: Include new source and test files in TypeScript**

Update `pi/extensions/changeflow/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "strict": true,
    "skipLibCheck": true,
    "types": ["node", "vitest"]
  },
  "include": ["index.ts", "src/**/*.ts", "subagents.ts", "workflows.ts", "bundled-workflows/**/*.ts", "test/**/*.ts"]
}
```

- [ ] **Step 5: Run checks**

Run:

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add pi/extensions/changeflow/package.json pi/extensions/changeflow/package-lock.json pi/extensions/changeflow/tsconfig.json pi/extensions/changeflow/test/smoke.test.ts
git commit -m "test(changeflow): add runtime test harness"
```

## Task 2: Define Workflow Runtime Types

**Files:**
- Create: `pi/extensions/changeflow/src/types.ts`
- Create: `pi/extensions/changeflow/test/types.test.ts`

- [ ] **Step 1: Write failing type helper tests**

Create `pi/extensions/changeflow/test/types.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { Type } from "typebox";
import { setup } from "xstate";
import { defineWorkflow, parseWorkflowEvent, type EventUnionFromSchemas } from "../src/types.js";

describe("workflow definition helpers", () => {
  it("returns the trusted workflow definition unchanged", () => {
    const eventSchemas = { START: Type.Object({ type: Type.Literal("START") }) } as const;
    type DemoEvent = EventUnionFromSchemas<typeof eventSchemas>;

    const workflow = defineWorkflow({
      id: "demo.workflow",
      name: "Demo Workflow",
      eventSchemas,
      createActorLogic: () => setup({ types: { events: {} as DemoEvent } }).createMachine({
        id: "demo.workflow",
        initial: "idle",
        states: { idle: { on: { START: "idle" } } },
      }),
    });

    expect(workflow.id).toBe("demo.workflow");
    expect(workflow.name).toBe("Demo Workflow");
  });

  it("validates events with optional workflow schemas", () => {
    const schema = Type.Object({ type: Type.Literal("PLAN_SUBMITTED"), markdown: Type.String() });

    expect(parseWorkflowEvent(schema, { type: "PLAN_SUBMITTED", markdown: "# Plan" })).toEqual({
      ok: true,
      event: { type: "PLAN_SUBMITTED", markdown: "# Plan" },
    });

    const rejected = parseWorkflowEvent(schema, { type: "PLAN_SUBMITTED", markdown: 42 });
    expect(rejected.ok).toBe(false);
    if (!rejected.ok) expect(rejected.error).toContain("markdown");
  });
});
```

- [ ] **Step 2: Run the failing tests**

```bash
cd pi/extensions/changeflow
npm test -- test/types.test.ts
```

Expected: FAIL because `src/types.ts` does not exist.

- [ ] **Step 3: Implement shared types**

Create `pi/extensions/changeflow/src/types.ts`:

```ts
import { Value } from "typebox/value";
import type { Static, TSchema } from "typebox";
import type { AnyActorLogic, AnyEventObject, Snapshot } from "xstate";

export type WorkflowId = string;
export type WorkflowInstanceId = string;
export type WorkflowStateValue = string;

export type RuntimeEventRecord = {
  seq: number;
  at: string;
  direction: "in" | "out" | "effect";
  kind: string;
  workflowId: WorkflowInstanceId;
  state?: unknown;
  event?: unknown;
  actorRunId?: string;
  snapshotSeq?: number;
  error?: string;
};

export type WorkflowMetadata = {
  id: WorkflowInstanceId;
  title: string;
  description: string;
  cwd: string;
  workflowDefinitionId: WorkflowId;
  state: WorkflowStateValue;
  createdAt: string;
  updatedAt: string;
  artifactsDir: string;
  latestSnapshotSeq: number;
};

export type ActorRunStatus = "running" | "completed" | "failed" | "cancelled";

export type ActorRunRecord = {
  id: string;
  workflowId: WorkflowInstanceId;
  kind: "childAgent" | "mainAgent" | "plannotatorReview" | "askUser" | "script";
  state: string;
  status: ActorRunStatus;
  input: unknown;
  output?: unknown;
  error?: string;
  startedAt: string;
  completedAt?: string;
};

export type RuntimeCapabilities = {
  log(message: string, details?: unknown): void;
  writeArtifact(path: string, content: string): void;
  setStatus(label: string): void;
  emitToPi(message: string, level?: "info" | "warning" | "error"): void;
  queueMainAgentMessage(message: string): void;
};

export type WorkflowActorFactories = Record<string, (...args: any[]) => Promise<unknown>>;
export type EventSchemaMap = Record<string, TSchema>;
export type EventUnionFromSchemas<TSchemas extends EventSchemaMap> = Static<TSchemas[keyof TSchemas]> & AnyEventObject;

export type WorkflowActorLogicFactoryInput = {
  runtime: RuntimeCapabilities;
  actors: WorkflowActorFactories;
  actions: Record<string, unknown>;
};

export type TrustedWorkflowDefinition<TEventSchemas extends EventSchemaMap = EventSchemaMap> = {
  id: WorkflowId;
  name: string;
  description?: string;
  initialEvent?: AnyEventObject;
  createActorLogic(input: WorkflowActorLogicFactoryInput): AnyActorLogic;
  eventSchemas?: TEventSchemas;
  artifactTemplates?: readonly { path: string; content: string }[];
  tools?: readonly { name: string; description: string; eventType: string; schema: TSchema }[];
};

export type WorkflowRuntimeSnapshot = {
  metadata: WorkflowMetadata;
  machineSnapshot: Snapshot<unknown>;
};

export type ParseWorkflowEventResult =
  | { ok: true; event: AnyEventObject }
  | { ok: false; error: string };

export function defineWorkflow<
  const TEventSchemas extends EventSchemaMap = EventSchemaMap,
  T extends TrustedWorkflowDefinition<TEventSchemas> = TrustedWorkflowDefinition<TEventSchemas>,
>(definition: T): T {
  return definition;
}

export function parseWorkflowEvent(schema: TSchema | undefined, value: unknown): ParseWorkflowEventResult {
  if (!schema) {
    if (value && typeof value === "object" && typeof (value as { type?: unknown }).type === "string") {
      return { ok: true, event: value as AnyEventObject };
    }
    return { ok: false, error: "Workflow event must be an object with a string type." };
  }

  if (Value.Check(schema, value)) return { ok: true, event: value as AnyEventObject };
  const errors = [...Value.Errors(schema, value)].map((error) => `${error.path || "/"}: ${error.message}`);
  return { ok: false, error: errors.join("; ") || "Workflow event failed schema validation." };
}
```

- [ ] **Step 4: Run tests**

```bash
cd pi/extensions/changeflow
npm test -- test/types.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pi/extensions/changeflow/src/types.ts pi/extensions/changeflow/test/types.test.ts
git commit -m "feat(changeflow): define trusted workflow runtime types"
```

## Task 3: Implement Durable Storage

**Files:**
- Create: `pi/extensions/changeflow/src/storage.ts`
- Create: `pi/extensions/changeflow/test/storage.test.ts`

- [ ] **Step 1: Write storage tests**

Create `pi/extensions/changeflow/test/storage.test.ts`:

```ts
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
```

- [ ] **Step 2: Run failing storage tests**

```bash
cd pi/extensions/changeflow
npm test -- test/storage.test.ts
```

Expected: FAIL because `src/storage.ts` does not exist.

- [ ] **Step 3: Implement storage**

Create `pi/extensions/changeflow/src/storage.ts`:

```ts
import { mkdir, readFile, writeFile } from "node:fs/promises";
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
  const existing = await readFile(paths.eventsFile, "utf-8").catch(() => "");
  await writeFile(paths.eventsFile, `${existing}${JSON.stringify(record)}\n`, "utf-8");
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
```

- [ ] **Step 4: Run storage tests**

```bash
cd pi/extensions/changeflow
npm test -- test/storage.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pi/extensions/changeflow/src/storage.ts pi/extensions/changeflow/test/storage.test.ts
git commit -m "feat(changeflow): add durable runtime storage"
```

## Task 4: Build Minimal Runtime Core

**Files:**
- Create: `pi/extensions/changeflow/src/runtime.ts`
- Create: `pi/extensions/changeflow/test/runtime.test.ts`

- [ ] **Step 1: Write runtime tests for start/send/restore**

Create `pi/extensions/changeflow/test/runtime.test.ts`:

```ts
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
```

- [ ] **Step 2: Run failing runtime tests**

```bash
cd pi/extensions/changeflow
npm test -- test/runtime.test.ts
```

Expected: FAIL because `src/runtime.ts` does not exist.

- [ ] **Step 3: Implement minimal runtime**

Create `pi/extensions/changeflow/src/runtime.ts` with start/send/restore only. Include this public API exactly:

```ts
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { createActor, type Actor, type AnyActorLogic, type Snapshot } from "xstate";
import { appendEvent, createWorkflowPaths, readSnapshot, readWorkflowMetadata, writeSnapshot, writeWorkflowMetadata, type WorkflowPaths } from "./storage.js";
import { parseWorkflowEvent, type TrustedWorkflowDefinition, type WorkflowMetadata, type WorkflowRuntimeSnapshot } from "./types.js";

export type ChangeflowRuntimeOptions = {
  cwd: string;
  workflows: readonly TrustedWorkflowDefinition[];
  now?: () => string;
};

export type StartWorkflowInput = {
  workflowDefinitionId: string;
  description: string;
};

export type SendEventResult =
  | { ok: true; state: string }
  | { ok: false; error: string };

export class ChangeflowRuntime {
  private readonly workflows = new Map<string, TrustedWorkflowDefinition>();
  private readonly cwd: string;
  private readonly now: () => string;
  private active?: { metadata: WorkflowMetadata; paths: WorkflowPaths; definition: TrustedWorkflowDefinition; actor: Actor<AnyActorLogic> };
  private eventSeq = 0;

  constructor(options: ChangeflowRuntimeOptions) {
    this.cwd = options.cwd;
    this.now = options.now ?? (() => new Date().toISOString());
    for (const workflow of options.workflows) this.workflows.set(workflow.id, workflow);
  }

  current(): WorkflowRuntimeSnapshot | undefined {
    if (!this.active) return undefined;
    return { metadata: this.active.metadata, machineSnapshot: this.active.actor.getPersistedSnapshot() };
  }

  async start(input: StartWorkflowInput): Promise<WorkflowRuntimeSnapshot> {
    const definition = this.requireWorkflow(input.workflowDefinitionId);
    const id = `${Date.now()}-${this.slugify(input.description)}`;
    const paths = createWorkflowPaths(join(this.cwd, ".pi", "changeflow"), id);
    await mkdir(paths.root, { recursive: true });

    const logic = definition.createActorLogic({ runtime: this.noopCapabilities(), actors: {}, actions: {} });
    const actor = createActor(logic);
    actor.start();

    const metadata: WorkflowMetadata = {
      id,
      title: this.slugify(input.description),
      description: input.description,
      cwd: this.cwd,
      workflowDefinitionId: definition.id,
      state: this.snapshotState(actor.getSnapshot().value),
      createdAt: this.now(),
      updatedAt: this.now(),
      artifactsDir: paths.artifactsDir,
      latestSnapshotSeq: 1,
    };

    this.active = { metadata, paths, definition, actor };
    await writeWorkflowMetadata(paths, metadata);
    await writeSnapshot(paths, 1, actor.getPersistedSnapshot());
    await this.append("out", "workflow.started", { event: { type: "workflow.started", description: input.description }, snapshotSeq: 1 });
    return this.currentOrThrow();
  }

  async restore(workflowId: string): Promise<WorkflowRuntimeSnapshot> {
    const paths = createWorkflowPaths(join(this.cwd, ".pi", "changeflow"), workflowId);
    const metadata = await readWorkflowMetadata(paths);
    const definition = this.requireWorkflow(metadata.workflowDefinitionId);
    const snapshot = await readSnapshot(paths, metadata.latestSnapshotSeq) as Snapshot<unknown>;
    const logic = definition.createActorLogic({ runtime: this.noopCapabilities(), actors: {}, actions: {} });
    const actor = createActor(logic, { snapshot });
    actor.start();
    this.active = { metadata, paths, definition, actor };
    return this.currentOrThrow();
  }

  async send(rawEvent: unknown): Promise<SendEventResult> {
    if (!this.active) return { ok: false, error: "No active Changeflow workflow." };
    const eventType = rawEvent && typeof rawEvent === "object" ? (rawEvent as { type?: unknown }).type : undefined;
    const schema = typeof eventType === "string" ? this.active.definition.eventSchemas?.[eventType] : undefined;
    const parsed = parseWorkflowEvent(schema, rawEvent);
    if (!parsed.ok) {
      await this.append("in", "event.rejected", { event: rawEvent, error: parsed.error });
      return { ok: false, error: parsed.error };
    }

    await this.append("in", "event.accepted", { event: parsed.event });
    if (!this.active.actor.getSnapshot().can(parsed.event)) {
      const error = `Event ${parsed.event.type} is not valid from state ${this.active.metadata.state}.`;
      await this.append("out", "event.invalidTransition", { event: parsed.event, error });
      return { ok: false, error };
    }

    this.active.actor.send(parsed.event);
    const snapshotSeq = this.active.metadata.latestSnapshotSeq + 1;
    this.active.metadata.state = this.snapshotState(this.active.actor.getSnapshot().value);
    this.active.metadata.updatedAt = this.now();
    this.active.metadata.latestSnapshotSeq = snapshotSeq;
    await writeWorkflowMetadata(this.active.paths, this.active.metadata);
    await writeSnapshot(this.active.paths, snapshotSeq, this.active.actor.getPersistedSnapshot());
    await this.append("out", "snapshot.written", { snapshotSeq, state: this.active.metadata.state });
    return { ok: true, state: this.active.metadata.state };
  }

  private requireWorkflow(id: string): TrustedWorkflowDefinition {
    const workflow = this.workflows.get(id);
    if (!workflow) throw new Error(`Unknown Changeflow workflow definition ${id}.`);
    return workflow;
  }

  private currentOrThrow(): WorkflowRuntimeSnapshot {
    const current = this.current();
    if (!current) throw new Error("No active Changeflow workflow.");
    return current;
  }

  private async append(direction: "in" | "out" | "effect", kind: string, data: { event?: unknown; state?: unknown; snapshotSeq?: number; error?: string }): Promise<void> {
    if (!this.active) return;
    this.eventSeq += 1;
    await appendEvent(this.active.paths, {
      seq: this.eventSeq,
      at: this.now(),
      direction,
      kind,
      workflowId: this.active.metadata.id,
      ...data,
    });
  }

  private snapshotState(value: unknown): string {
    if (typeof value === "string") return value;
    return JSON.stringify(value);
  }

  private slugify(text: string): string {
    return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "change";
  }

  private noopCapabilities() {
    return {
      log: () => undefined,
      writeArtifact: () => undefined,
      setStatus: () => undefined,
      emitToPi: () => undefined,
      queueMainAgentMessage: () => undefined,
    };
  }
}
```

- [ ] **Step 4: Run runtime tests**

```bash
cd pi/extensions/changeflow
npm test -- test/runtime.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pi/extensions/changeflow/src/runtime.ts pi/extensions/changeflow/test/runtime.test.ts
git commit -m "feat(changeflow): add minimal xstate runtime"
```

## Task 5: Add Actor Adapter Interfaces and Main-Agent Pending Task State

**Files:**
- Create: `pi/extensions/changeflow/src/actors.ts`
- Modify: `pi/extensions/changeflow/src/types.ts`
- Create: `pi/extensions/changeflow/test/actors.test.ts`

- [ ] **Step 1: Write actor adapter tests**

Create `pi/extensions/changeflow/test/actors.test.ts`:

```ts
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
});
```

- [ ] **Step 2: Run failing actor tests**

```bash
cd pi/extensions/changeflow
npm test -- test/actors.test.ts
```

Expected: FAIL because `src/actors.ts` does not exist.

- [ ] **Step 3: Implement actor adapters**

Create `pi/extensions/changeflow/src/actors.ts`:

```ts
export type ChildAgentInput = { role: string; task: string; state: string; stepId?: string; reason?: string };
export type MainAgentInput = { taskId: string; task: string; expectedEvents: string[] };
export type PendingMainAgentTask = MainAgentInput & { startedAt: string };

export type ActorAdapterDependencies = {
  runChildAgent(input: ChildAgentInput): Promise<unknown>;
  now?: () => string;
};

export type ActorAdapters = ReturnType<typeof createActorAdapters>;

export function createActorAdapters(deps: ActorAdapterDependencies) {
  const now = deps.now ?? (() => new Date().toISOString());
  let pendingMainTask: PendingMainAgentTask | undefined;
  let resolveMainTask: ((output: unknown) => void) | undefined;
  let rejectMainTask: ((error: Error) => void) | undefined;

  return {
    childAgent(input: ChildAgentInput): Promise<unknown> {
      return deps.runChildAgent(input);
    },

    mainAgent(input: MainAgentInput): Promise<unknown> {
      if (pendingMainTask) throw new Error(`A main-agent task is already pending: ${pendingMainTask.taskId}`);
      pendingMainTask = { ...input, startedAt: now() };
      return new Promise((resolve, reject) => {
        resolveMainTask = resolve;
        rejectMainTask = reject;
      });
    },

    completeMainAgentTask(taskId: string, output: unknown): void {
      if (!pendingMainTask || pendingMainTask.taskId !== taskId || !resolveMainTask) {
        throw new Error(`No pending main-agent task ${taskId}.`);
      }
      const resolve = resolveMainTask;
      pendingMainTask = undefined;
      resolveMainTask = undefined;
      rejectMainTask = undefined;
      resolve(output);
    },

    cancelMainAgentTask(taskId: string): void {
      if (!pendingMainTask || pendingMainTask.taskId !== taskId || !rejectMainTask) {
        throw new Error(`No pending main-agent task ${taskId}.`);
      }
      const reject = rejectMainTask;
      pendingMainTask = undefined;
      resolveMainTask = undefined;
      rejectMainTask = undefined;
      reject(new Error(`Main-agent task ${taskId} was cancelled.`));
    },

    pendingMainAgentTask(): PendingMainAgentTask | undefined {
      return pendingMainTask;
    },
  };
}
```

- [ ] **Step 4: Run actor tests**

```bash
cd pi/extensions/changeflow
npm test -- test/actors.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pi/extensions/changeflow/src/actors.ts pi/extensions/changeflow/test/actors.test.ts
git commit -m "feat(changeflow): add actor adapter primitives"
```

## Task 6: Add Runtime Capabilities and Actor Invocation Hooks

**Files:**
- Modify: `pi/extensions/changeflow/src/runtime.ts`
- Modify: `pi/extensions/changeflow/src/types.ts`
- Create: `pi/extensions/changeflow/test/runtime-actors.test.ts`

- [ ] **Step 1: Write runtime actor/action tests**

Create `pi/extensions/changeflow/test/runtime-actors.test.ts`:

```ts
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import { afterEach, describe, expect, it, vi } from "vitest";
import { fromPromise, setup } from "xstate";
import { ChangeflowRuntime } from "../src/runtime.js";
import { defineWorkflow, type EventUnionFromSchemas } from "../src/types.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("runtime capabilities and actors", () => {
  it("lets workflow actions write artifacts and invoked actors branch the machine", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-runtime-actors-"));
    const eventSchemas = { PLAN_SUBMITTED: Type.Object({ type: Type.Literal("PLAN_SUBMITTED"), markdown: Type.String() }) } as const;
    type ActorWorkflowEvent = EventUnionFromSchemas<typeof eventSchemas>;
    const workflow = defineWorkflow({
      id: "actor.workflow",
      name: "Actor Workflow",
      eventSchemas,
      createActorLogic: ({ runtime, actors }) => setup({ types: { events: {} as ActorWorkflowEvent } }).createMachine({
        id: "actor.workflow",
        initial: "planning",
        states: {
          planning: {
            on: {
              PLAN_SUBMITTED: {
                target: "reviewing",
                actions: ({ event }) => runtime.writeArtifact("plan.md", (event as { markdown: string }).markdown),
              },
            },
          },
          reviewing: {
            invoke: {
              src: fromPromise(() => actors.childAgent({ role: "reviewer", task: "review plan", state: "reviewing" })),
              onDone: [
                { guard: ({ event }) => Boolean((event.output as { approved?: boolean }).approved), target: "approved" },
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

    const runChildAgent = vi.fn(async () => ({ approved: true }));
    const runtime = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow], actorAdapters: { runChildAgent } });
    await runtime.start({ workflowDefinitionId: "actor.workflow", description: "actor workflow" });
    await expect(runtime.send({ type: "PLAN_SUBMITTED", markdown: "# Plan" })).resolves.toMatchObject({ ok: true });
    await vi.waitFor(() => expect(runtime.current()?.metadata.state).toBe("approved"));

    const artifactsDir = runtime.current()?.metadata.artifactsDir;
    await expect(readFile(join(artifactsDir!, "plan.md"), "utf-8")).resolves.toBe("# Plan");
  });
});
```

- [ ] **Step 2: Run failing runtime actor test**

```bash
cd pi/extensions/changeflow
npm test -- test/runtime-actors.test.ts
```

Expected: FAIL because `ChangeflowRuntime` does not accept `actorAdapters` and does not persist async actor results yet.

- [ ] **Step 3: Extend runtime constructor and capability wiring**

Modify `ChangeflowRuntimeOptions` in `src/runtime.ts`:

```ts
import { createActorAdapters, type ActorAdapterDependencies, type ActorAdapters } from "./actors.js";

export type ChangeflowRuntimeOptions = {
  cwd: string;
  workflows: readonly TrustedWorkflowDefinition[];
  actorAdapters?: ActorAdapterDependencies;
  now?: () => string;
};
```

Add a private field:

```ts
private readonly actorAdapters: ActorAdapters;
```

Initialize it in the constructor:

```ts
this.actorAdapters = createActorAdapters(options.actorAdapters ?? { runChildAgent: async () => { throw new Error("No child-agent adapter configured."); } });
```

Replace both machine creation calls with:

```ts
const logic = definition.createActorLogic({ runtime: this.capabilities(paths), actors: this.actorAdapters, actions: {} });
```

- [ ] **Step 4: Implement artifact-writing capability**

Add this method to `ChangeflowRuntime`:

```ts
private capabilities(paths: WorkflowPaths) {
  return {
    log: (message: string, details?: unknown) => {
      void this.append("effect", "runtime.log", { event: { message, details } });
    },
    writeArtifact: (path: string, content: string) => {
      const fullPath = join(paths.artifactsDir, path);
      void mkdir(join(fullPath, ".."), { recursive: true }).then(() => import("node:fs/promises")).then(({ writeFile }) => writeFile(fullPath, content, "utf-8"));
      void this.append("effect", "artifact.write", { event: { path } });
    },
    setStatus: (label: string) => {
      void this.append("effect", "status.set", { event: { label } });
    },
    emitToPi: (message: string, level: "info" | "warning" | "error" = "info") => {
      void this.append("effect", "pi.emit", { event: { message, level } });
    },
    queueMainAgentMessage: (message: string) => {
      void this.append("effect", "mainAgent.queueMessage", { event: { message } });
    },
  };
}
```

Then immediately clean up the `writeArtifact` implementation to avoid using `join(fullPath, "..")` by importing `dirname` at the top and using:

```ts
void mkdir(dirname(fullPath), { recursive: true }).then(() => writeFile(fullPath, content, "utf-8"));
```

with `writeFile` imported from `node:fs/promises`.

- [ ] **Step 5: Subscribe to state changes and persist actor-driven transitions**

After `actor.start()` in both `start` and `restore`, subscribe:

```ts
actor.subscribe((snapshot) => {
  void this.persistObservedSnapshot(snapshot.value, actor.getPersistedSnapshot());
});
```

Add this method:

```ts
private async persistObservedSnapshot(stateValue: unknown, snapshot: Snapshot<unknown>): Promise<void> {
  if (!this.active) return;
  const state = this.snapshotState(stateValue);
  if (state === this.active.metadata.state) return;
  const snapshotSeq = this.active.metadata.latestSnapshotSeq + 1;
  this.active.metadata.state = state;
  this.active.metadata.updatedAt = this.now();
  this.active.metadata.latestSnapshotSeq = snapshotSeq;
  await writeWorkflowMetadata(this.active.paths, this.active.metadata);
  await writeSnapshot(this.active.paths, snapshotSeq, snapshot);
  await this.append("out", "snapshot.observed", { snapshotSeq, state });
}
```

- [ ] **Step 6: Run tests**

```bash
cd pi/extensions/changeflow
npm test -- test/runtime-actors.test.ts test/runtime.test.ts
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add pi/extensions/changeflow/src/runtime.ts pi/extensions/changeflow/src/types.ts pi/extensions/changeflow/test/runtime-actors.test.ts
git commit -m "feat(changeflow): wire runtime capabilities and actors"
```

## Task 7: Port Changeflow Lifecycle Workflow

**Files:**
- Create: `pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts`
- Create: `pi/extensions/changeflow/test/changeflow-workflow.test.ts`

- [ ] **Step 1: Write pure workflow transition tests**

Create `pi/extensions/changeflow/test/changeflow-workflow.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { createActor } from "xstate";
import changeflowWorkflow from "../bundled-workflows/changeflow-runtime.js";

describe("ported Changeflow workflow", () => {
  it("moves through planning, machine agent review, human review, execution, and done", async () => {
    const runtime = {
      log: () => undefined,
      writeArtifact: () => undefined,
      setStatus: () => undefined,
      emitToPi: () => undefined,
      queueMainAgentMessage: () => undefined,
    };
    const actors = {
      childAgent: async () => ({ approved: true, summary: "approved" }),
      mainAgent: async () => ({ type: "MAIN_TASK_DONE" }),
    };
    const actor = createActor(changeflowWorkflow.createActorLogic({ runtime, actors, actions: {} }));
    actor.start();

    actor.send({ type: "START" });
    expect(actor.getSnapshot().value).toBe("research");
    actor.send({ type: "RESEARCH_COMPLETE" });
    expect(actor.getSnapshot().value).toBe("high_level_planning");
    actor.send({ type: "PLAN_SUBMITTED", kind: "high_level_plan", markdown: "# Plan" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(actor.getSnapshot().value).toBe("high_level_user_review");
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
});
```

- [ ] **Step 2: Run failing workflow test**

```bash
cd pi/extensions/changeflow
npm test -- test/changeflow-workflow.test.ts
```

Expected: FAIL because `changeflow-runtime.ts` does not exist.

- [ ] **Step 3: Implement workflow module**

Create `pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts`:

```ts
import { Type } from "typebox";
import { assign, fromPromise, setup } from "xstate";
import { defineWorkflow, type EventUnionFromSchemas } from "../src/types.js";

const planSubmittedSchema = Type.Object({
  type: Type.Literal("PLAN_SUBMITTED"),
  kind: Type.Union([Type.Literal("high_level_plan"), Type.Literal("detailed_plan")]),
  markdown: Type.String(),
});

const markdownEventSchema = <T extends string>(type: T) => Type.Object({ type: Type.Literal(type), markdown: Type.String() });

const eventSchemas = {
  START: Type.Object({ type: Type.Literal("START") }),
  RESEARCH_COMPLETE: Type.Object({ type: Type.Literal("RESEARCH_COMPLETE") }),
  PLAN_SUBMITTED: planSubmittedSchema,
  USER_APPROVED: Type.Object({ type: Type.Literal("USER_APPROVED"), feedback: Type.Optional(Type.String()) }),
  USER_REJECTED: Type.Object({ type: Type.Literal("USER_REJECTED"), feedback: Type.Optional(Type.String()) }),
  ORDER_DEFINED: markdownEventSchema("ORDER_DEFINED"),
  EXECUTION_COMPLETE: Type.Object({ type: Type.Literal("EXECUTION_COMPLETE") }),
  QA_COMPLETE: Type.Object({ type: Type.Literal("QA_COMPLETE") }),
} as const;
type ChangeflowEvent = EventUnionFromSchemas<typeof eventSchemas>;

export default defineWorkflow({
  id: "changeflow.runtime",
  name: "Changeflow Runtime Workflow",
  description: "Machine-owned Changeflow lifecycle with child-agent plan critique.",
  initialEvent: { type: "START" },
  eventSchemas,
  artifactTemplates: [
    { path: "research.md", content: "# Research: {description}\n\n" },
    { path: "high-level-plan.md", content: "# High-level plan: {description}\n\n" },
  ],
  createActorLogic: ({ runtime, actors }) => setup({ types: { events: {} as ChangeflowEvent } }).createMachine({
    id: "changeflow.runtime",
    context: { latestFeedback: undefined as string | undefined },
    initial: "idle",
    states: {
      idle: { on: { START: "research" } },
      research: {
        entry: () => runtime.queueMainAgentMessage("Research the requested change. Record findings in artifacts and send RESEARCH_COMPLETE when ready."),
        on: { RESEARCH_COMPLETE: "high_level_planning" },
      },
      high_level_planning: {
        entry: () => runtime.queueMainAgentMessage("Write a high-level plan. Send PLAN_SUBMITTED with kind high_level_plan and markdown."),
        on: {
          PLAN_SUBMITTED: {
            guard: ({ event }) => event.kind === "high_level_plan",
            target: "high_level_agent_review",
            actions: ({ event }) => runtime.writeArtifact("high-level-plan.md", event.markdown),
          },
        },
      },
      high_level_agent_review: {
        invoke: {
          src: fromPromise(() => actors.childAgent({ role: "reviewer", task: "Review the high-level plan artifact and return { approved, summary, feedback }.", state: "high_level_agent_review" })),
          onDone: [
            { guard: ({ event }) => Boolean((event.output as { approved?: boolean }).approved), target: "high_level_user_review" },
            {
              target: "high_level_revision",
              actions: assign({ latestFeedback: ({ event }) => (event.output as { feedback?: string; summary?: string }).feedback ?? (event.output as { summary?: string }).summary }),
            },
          ],
          onError: {
            target: "high_level_revision",
            actions: assign({ latestFeedback: ({ event }) => String(event.error) }),
          },
        },
      },
      high_level_revision: {
        entry: ({ context }) => runtime.queueMainAgentMessage(`Revise the high-level plan using this feedback:\n${context.latestFeedback ?? "No feedback provided."}`),
        on: {
          PLAN_SUBMITTED: {
            guard: ({ event }) => event.kind === "high_level_plan",
            target: "high_level_agent_review",
            actions: ({ event }) => runtime.writeArtifact("high-level-plan.md", event.markdown),
          },
        },
      },
      high_level_user_review: {
        entry: () => runtime.emitToPi("High-level plan is ready for human review.", "info"),
        on: { USER_APPROVED: "detailed_planning", USER_REJECTED: "high_level_revision" },
      },
      detailed_planning: {
        entry: () => runtime.queueMainAgentMessage("Write the detailed implementation plan. Send PLAN_SUBMITTED with kind detailed_plan and markdown."),
        on: {
          PLAN_SUBMITTED: {
            guard: ({ event }) => event.kind === "detailed_plan",
            target: "detailed_user_review",
            actions: ({ event }) => runtime.writeArtifact("detailed-plan.md", event.markdown),
          },
        },
      },
      detailed_user_review: {
        entry: () => runtime.emitToPi("Detailed plan is ready for human review.", "info"),
        on: { USER_APPROVED: "execution_ordering", USER_REJECTED: "detailed_planning" },
      },
      execution_ordering: {
        entry: () => runtime.queueMainAgentMessage("Define execution ordering. Send ORDER_DEFINED with markdown."),
        on: { ORDER_DEFINED: { target: "executing", actions: ({ event }) => runtime.writeArtifact("execution-order.md", event.markdown) } },
      },
      executing: {
        entry: () => runtime.queueMainAgentMessage("Execute the approved plan. Send EXECUTION_COMPLETE when implementation is ready."),
        on: { EXECUTION_COMPLETE: "qa" },
      },
      qa: {
        entry: () => runtime.queueMainAgentMessage("Validate the completed change. Send QA_COMPLETE when ready for user validation."),
        on: { QA_COMPLETE: "user_validation" },
      },
      user_validation: {
        entry: () => runtime.emitToPi("Workflow is ready for final user validation.", "info"),
        on: { USER_APPROVED: "done", USER_REJECTED: "qa" },
      },
      done: { entry: () => runtime.setStatus("done") },
    },
  }),
});
```

- [ ] **Step 4: Run workflow test**

```bash
cd pi/extensions/changeflow
npm test -- test/changeflow-workflow.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts pi/extensions/changeflow/test/changeflow-workflow.test.ts
git commit -m "feat(changeflow): port lifecycle to trusted workflow"
```

## Task 8: Implement Workflow Loader

**Files:**
- Create: `pi/extensions/changeflow/src/loader.ts`
- Create: `pi/extensions/changeflow/test/loader.test.ts`

- [ ] **Step 1: Write loader tests**

Create `pi/extensions/changeflow/test/loader.test.ts`:

```ts
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadWorkflowRegistry } from "../src/loader.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("workflow loader", () => {
  it("loads bundled workflow and project-local ts workflows", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-loader-"));
    const workflowsDir = join(tempDir, ".pi", "changeflow", "workflows");
    await mkdir(workflowsDir, { recursive: true });
    await writeFile(join(workflowsDir, "local.ts"), `
      import { setup } from "xstate";
      import { defineWorkflow } from "../../../../pi/extensions/changeflow/src/types.js";
      export default defineWorkflow({ id: "local.workflow", name: "Local Workflow", createActorLogic: () => setup({}).createMachine({ id: "local.workflow", initial: "idle", states: { idle: {} } }) });
    `);

    const registry = await loadWorkflowRegistry(tempDir);
    expect(registry.definitions.has("changeflow.runtime")).toBe(true);
    expect(registry.definitions.has("local.workflow")).toBe(true);
  });
});
```

- [ ] **Step 2: Run failing loader tests**

```bash
cd pi/extensions/changeflow
npm test -- test/loader.test.ts
```

Expected: FAIL because `src/loader.ts` does not exist. If relative import in the dynamic local workflow is brittle, adjust the test to use an absolute file URL import to `src/types.ts`.

- [ ] **Step 3: Implement loader**

Create `pi/extensions/changeflow/src/loader.ts`:

```ts
import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import defaultWorkflow from "../bundled-workflows/changeflow-runtime.js";
import type { TrustedWorkflowDefinition } from "./types.js";

export type WorkflowRegistry = {
  definitions: Map<string, TrustedWorkflowDefinition>;
  warnings: string[];
};

export async function loadWorkflowRegistry(cwd: string): Promise<WorkflowRegistry> {
  const registry: WorkflowRegistry = { definitions: new Map(), warnings: [] };
  registerWorkflow(registry, defaultWorkflow);

  const dir = join(cwd, ".pi", "changeflow", "workflows");
  if (!existsSync(dir)) return registry;

  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(".ts")) continue;
    const path = join(dir, entry.name);
    try {
      const mod = await import(pathToFileURL(path).href) as { default?: TrustedWorkflowDefinition };
      if (!mod.default) registry.warnings.push(`Skipping workflow ${path}: no default export.`);
      else registerWorkflow(registry, mod.default);
    } catch (error) {
      registry.warnings.push(`Skipping workflow ${path}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  return registry;
}

function registerWorkflow(registry: WorkflowRegistry, definition: TrustedWorkflowDefinition): void {
  if (!definition.id.trim()) {
    registry.warnings.push("Skipping workflow with empty id.");
    return;
  }
  if (registry.definitions.has(definition.id)) {
    registry.warnings.push(`Skipping duplicate workflow ${definition.id}.`);
    return;
  }
  registry.definitions.set(definition.id, definition);
}
```

- [ ] **Step 4: Run loader tests**

```bash
cd pi/extensions/changeflow
npm test -- test/loader.test.ts
```

Expected: PASS. If Jiti/Vitest cannot import project-local TS from temp dirs, change the loader test to assert bundled loading only and manually test project-local loading during integration.

- [ ] **Step 5: Commit**

```bash
git add pi/extensions/changeflow/src/loader.ts pi/extensions/changeflow/test/loader.test.ts
git commit -m "feat(changeflow): load trusted workflow modules"
```

## Task 9: Replace Extension Entrypoint with Generic Bridge

**Files:**
- Create: `pi/extensions/changeflow/src/bridge.ts`
- Rewrite: `pi/extensions/changeflow/index.ts`
- Create: `pi/extensions/changeflow/test/bridge.test.ts`

- [ ] **Step 1: Write bridge unit tests with fake Pi API**

Create `pi/extensions/changeflow/test/bridge.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { installChangeflowBridge } from "../src/bridge.js";

describe("Changeflow bridge", () => {
  it("registers generic commands and tools", () => {
    const commands = new Map<string, unknown>();
    const tools: Array<{ name: string }> = [];
    const pi = {
      registerCommand: vi.fn((name: string, definition: unknown) => commands.set(name, definition)),
      registerTool: vi.fn((definition: { name: string }) => tools.push(definition)),
      on: vi.fn(),
      events: { on: vi.fn(), emit: vi.fn() },
      appendEntry: vi.fn(),
      setSessionName: vi.fn(),
      sendUserMessage: vi.fn(),
    };

    installChangeflowBridge(pi as never);

    expect(commands.has("changeflow")).toBe(true);
    expect(tools.map((tool) => tool.name)).toEqual(expect.arrayContaining([
      "changeflow_send_event",
      "changeflow_get_state",
      "changeflow_read_artifact",
      "changeflow_write_artifact",
      "changeflow_complete_main_task",
    ]));
  });
});
```

- [ ] **Step 2: Run failing bridge tests**

```bash
cd pi/extensions/changeflow
npm test -- test/bridge.test.ts
```

Expected: FAIL because `src/bridge.ts` does not exist.

- [ ] **Step 3: Implement bridge skeleton**

Create `pi/extensions/changeflow/src/bridge.ts` with command/tool registration. Keep handlers minimal first:

```ts
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { runChangeflowSubagent } from "../subagents.js";
import { createWorkflowPaths } from "./storage.js";
import { loadWorkflowRegistry, type WorkflowRegistry } from "./loader.js";
import { ChangeflowRuntime } from "./runtime.js";

const CUSTOM_ENTRY = "changeflow-runtime-state";

export function installChangeflowBridge(pi: ExtensionAPI): void {
  let runtime: ChangeflowRuntime | undefined;
  let registry: WorkflowRegistry | undefined;

  async function ensureRegistry(ctx: ExtensionContext): Promise<WorkflowRegistry> {
    registry ??= await loadWorkflowRegistry(ctx.cwd);
    for (const warning of registry.warnings) ctx.ui.notify(warning, "warning");
    return registry;
  }

  async function ensureRuntime(ctx: ExtensionContext): Promise<ChangeflowRuntime> {
    const loaded = await ensureRegistry(ctx);
    runtime ??= new ChangeflowRuntime({
      cwd: ctx.cwd,
      workflows: [...loaded.definitions.values()],
      actorAdapters: {
        runChildAgent: async (input) => runChangeflowSubagent({
          workflowId: runtime?.current()?.metadata.id ?? "unknown",
          artifactsDir: runtime?.current()?.metadata.artifactsDir ?? join(ctx.cwd, ".pi", "changeflow", "unknown", "artifacts"),
          cwd: ctx.cwd,
          role: input.role as never,
          task: input.task,
          phase: input.state,
          stepId: input.stepId,
          reason: input.reason,
          signal: ctx.signal,
        }),
      },
    });
    return runtime;
  }

  pi.registerCommand("changeflow", {
    description: "Manage trusted XState Changeflow workflows",
    handler: async (args, ctx) => {
      const [subcommand = "status", ...rest] = (args ?? "").trim().split(/\s+/).filter(Boolean);
      const restText = rest.join(" ");
      const rt = await ensureRuntime(ctx);

      if (subcommand === "start") {
        const workflowDefinitionId = "changeflow.runtime";
        const started = await rt.start({ workflowDefinitionId, description: restText });
        pi.appendEntry(CUSTOM_ENTRY, { workflowId: started.metadata.id });
        pi.setSessionName(`Changeflow: ${started.metadata.title}`);
        ctx.ui.notify(`Started ${started.metadata.id} in ${started.metadata.state}.`, "info");
        return;
      }

      if (subcommand === "status") {
        const current = rt.current();
        ctx.ui.notify(current ? `Changeflow ${current.metadata.id}\nState: ${current.metadata.state}\nArtifacts: ${current.metadata.artifactsDir}` : "No active Changeflow workflow.", "info");
        return;
      }

      if (subcommand === "workflows") {
        const loaded = await ensureRegistry(ctx);
        ctx.ui.notify([...loaded.definitions.values()].map((workflow) => `- ${workflow.id}: ${workflow.name}`).join("\n"), "info");
        return;
      }

      if (subcommand === "send") {
        const event = restText.trim().startsWith("{") ? JSON.parse(restText) : { type: restText.trim() };
        ctx.ui.notify(JSON.stringify(await rt.send(event)), "info");
        return;
      }

      if (subcommand === "clear") {
        runtime = undefined;
        pi.appendEntry(CUSTOM_ENTRY, { cleared: true, at: new Date().toISOString() });
        ctx.ui.notify("Cleared active Changeflow runtime pointer.", "info");
        return;
      }

      ctx.ui.notify("Usage: /changeflow start|status|workflows|send|clear", "warning");
    },
  });

  pi.registerTool({
    name: "changeflow_send_event",
    label: "Send Changeflow Event",
    description: "Send a typed event to the active Changeflow XState machine.",
    parameters: Type.Object({ event: Type.Any() }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const result = await (await ensureRuntime(ctx)).send(params.event);
      return { content: [{ type: "text", text: JSON.stringify(result) }], details: result, isError: !result.ok };
    },
  });

  pi.registerTool({
    name: "changeflow_get_state",
    label: "Get Changeflow State",
    description: "Inspect the active Changeflow runtime state.",
    parameters: Type.Object({}),
    async execute(_id, _params, _signal, _onUpdate, ctx) {
      const current = (await ensureRuntime(ctx)).current();
      return { content: [{ type: "text", text: current ? JSON.stringify(current.metadata, null, 2) : "No active Changeflow workflow." }], details: current?.metadata ?? {} };
    },
  });

  pi.registerTool({
    name: "changeflow_read_artifact",
    label: "Read Changeflow Artifact",
    description: "Read a workflow-scoped artifact.",
    parameters: Type.Object({ path: Type.String() }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const current = (await ensureRuntime(ctx)).current();
      if (!current) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      const content = readFileSync(join(current.metadata.artifactsDir, params.path), "utf-8");
      return { content: [{ type: "text", text: content }], details: { path: params.path } };
    },
  });

  pi.registerTool({
    name: "changeflow_write_artifact",
    label: "Write Changeflow Artifact",
    description: "Write a workflow-scoped artifact.",
    parameters: Type.Object({ path: Type.String(), content: Type.String() }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const current = (await ensureRuntime(ctx)).current();
      if (!current) return { content: [{ type: "text", text: "No active Changeflow workflow." }], details: {}, isError: true };
      writeFileSync(join(current.metadata.artifactsDir, params.path), params.content);
      return { content: [{ type: "text", text: `Wrote ${params.path}.` }], details: { path: params.path } };
    },
  });

  pi.registerTool({
    name: "changeflow_complete_main_task",
    label: "Complete Changeflow Main Task",
    description: "Complete a machine-invoked main-agent actor task.",
    parameters: Type.Object({ taskId: Type.String(), output: Type.Any() }),
    async execute() {
      return { content: [{ type: "text", text: "Main-agent task completion will be wired in the next task." }], details: {} };
    },
  });
}
```

- [ ] **Step 4: Rewrite entrypoint**

Replace `pi/extensions/changeflow/index.ts` with:

```ts
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { installChangeflowBridge } from "./src/bridge.js";

export default function changeflow(pi: ExtensionAPI): void {
  installChangeflowBridge(pi);
}
```

- [ ] **Step 5: Run bridge tests and typecheck**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add pi/extensions/changeflow/src/bridge.ts pi/extensions/changeflow/index.ts pi/extensions/changeflow/test/bridge.test.ts
git commit -m "feat(changeflow): install generic runtime bridge"
```

## Task 10: Restore Active Workflow from Session Entries

**Files:**
- Modify: `pi/extensions/changeflow/src/bridge.ts`
- Modify: `pi/extensions/changeflow/src/runtime.ts`
- Create: `pi/extensions/changeflow/test/restore.test.ts`

- [ ] **Step 1: Write restore-focused runtime test**

Create `pi/extensions/changeflow/test/restore.test.ts`:

```ts
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { setup } from "xstate";
import { ChangeflowRuntime } from "../src/runtime.js";
import { defineWorkflow, type EventUnionFromSchemas } from "../src/types.js";

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("runtime restoreCurrent", () => {
  it("restores an existing workflow id and reports missing ids clearly", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-restore-"));
    const workflow = defineWorkflow({ id: "restore.workflow", name: "Restore", createActorLogic: () => setup({}).createMachine({ id: "restore.workflow", initial: "idle", states: { idle: {} } }) });
    const runtime = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow] });
    const started = await runtime.start({ workflowDefinitionId: "restore.workflow", description: "restore me" });

    const restored = new ChangeflowRuntime({ cwd: tempDir, workflows: [workflow] });
    await expect(restored.restore(started.metadata.id)).resolves.toMatchObject({ metadata: { id: started.metadata.id } });
    await expect(restored.restore("missing-id")).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run restore tests**

```bash
cd pi/extensions/changeflow
npm test -- test/restore.test.ts
```

Expected: PASS if Task 4 restore already works; otherwise fix `restore()` before proceeding.

- [ ] **Step 3: Add bridge session restore helper**

In `src/bridge.ts`, add:

```ts
function lastWorkflowIdFromSession(ctx: ExtensionContext): string | undefined {
  const entries = ctx.sessionManager.getEntries();
  const last = entries
    .filter((entry: { type: string; customType?: string }) => entry.type === "custom" && entry.customType === CUSTOM_ENTRY)
    .pop() as { data?: { workflowId?: string; cleared?: boolean } } | undefined;
  if (last?.data?.cleared) return undefined;
  return last?.data?.workflowId;
}
```

Add session start handler:

```ts
pi.on("session_start", async (_event, ctx) => {
  const workflowId = lastWorkflowIdFromSession(ctx);
  if (!workflowId) {
    ctx.ui.setStatus("changeflow", undefined);
    return;
  }
  try {
    const rt = await ensureRuntime(ctx);
    const restored = await rt.restore(workflowId);
    ctx.ui.setStatus("changeflow", ctx.ui.theme.fg("accent", `⛓ ${restored.metadata.state}`));
  } catch (error) {
    ctx.ui.notify(`Could not restore Changeflow workflow ${workflowId}: ${error instanceof Error ? error.message : String(error)}`, "warning");
  }
});
```

- [ ] **Step 4: Run checks**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pi/extensions/changeflow/src/bridge.ts pi/extensions/changeflow/src/runtime.ts pi/extensions/changeflow/test/restore.test.ts
git commit -m "feat(changeflow): restore runtime from session pointer"
```

## Task 11: Enforce Workflow-Declared Edit Policy

**Files:**
- Modify: `pi/extensions/changeflow/src/types.ts`
- Modify: `pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts`
- Modify: `pi/extensions/changeflow/src/runtime.ts`
- Modify: `pi/extensions/changeflow/src/bridge.ts`
- Create: `pi/extensions/changeflow/test/edit-policy.test.ts`

- [ ] **Step 1: Add edit-policy tests**

Create `pi/extensions/changeflow/test/edit-policy.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import changeflowWorkflow from "../bundled-workflows/changeflow-runtime.js";

describe("workflow edit policy", () => {
  it("blocks source edits before executing and allows them in executing/qa", () => {
    expect(changeflowWorkflow.statePolicies?.research?.editPolicy).toBe("artifactsOnly");
    expect(changeflowWorkflow.statePolicies?.high_level_planning?.editPolicy).toBe("artifactsOnly");
    expect(changeflowWorkflow.statePolicies?.executing?.editPolicy).toBe("sourceAllowed");
    expect(changeflowWorkflow.statePolicies?.qa?.editPolicy).toBe("sourceAllowed");
  });
});
```

- [ ] **Step 2: Run failing policy tests**

```bash
cd pi/extensions/changeflow
npm test -- test/edit-policy.test.ts
```

Expected: FAIL because `statePolicies` does not exist.

- [ ] **Step 3: Add state policy type**

In `src/types.ts`, add:

```ts
export type EditPolicy = "artifactsOnly" | "sourceAllowed";

export type WorkflowStatePolicy = {
  editPolicy?: EditPolicy;
  mainAgentTask?: string;
  expectedEvents?: readonly string[];
};
```

Add to `TrustedWorkflowDefinition`:

```ts
statePolicies?: Record<string, WorkflowStatePolicy>;
```

- [ ] **Step 4: Declare policies in workflow**

Add this property to `changeflow-runtime.ts` before `machine`:

```ts
statePolicies: {
  idle: { editPolicy: "artifactsOnly" },
  research: { editPolicy: "artifactsOnly", expectedEvents: ["RESEARCH_COMPLETE"] },
  high_level_planning: { editPolicy: "artifactsOnly", expectedEvents: ["PLAN_SUBMITTED"] },
  high_level_agent_review: { editPolicy: "artifactsOnly" },
  high_level_revision: { editPolicy: "artifactsOnly", expectedEvents: ["PLAN_SUBMITTED"] },
  high_level_user_review: { editPolicy: "artifactsOnly", expectedEvents: ["USER_APPROVED", "USER_REJECTED"] },
  detailed_planning: { editPolicy: "artifactsOnly", expectedEvents: ["PLAN_SUBMITTED"] },
  detailed_user_review: { editPolicy: "artifactsOnly", expectedEvents: ["USER_APPROVED", "USER_REJECTED"] },
  execution_ordering: { editPolicy: "artifactsOnly", expectedEvents: ["ORDER_DEFINED"] },
  executing: { editPolicy: "sourceAllowed", expectedEvents: ["EXECUTION_COMPLETE"] },
  qa: { editPolicy: "sourceAllowed", expectedEvents: ["QA_COMPLETE"] },
  user_validation: { editPolicy: "artifactsOnly", expectedEvents: ["USER_APPROVED", "USER_REJECTED"] },
  done: { editPolicy: "artifactsOnly" },
},
```

- [ ] **Step 5: Expose current edit policy from runtime**

Add to `ChangeflowRuntime`:

```ts
currentEditPolicy(): "artifactsOnly" | "sourceAllowed" {
  if (!this.active) return "artifactsOnly";
  return this.active.definition.statePolicies?.[this.active.metadata.state]?.editPolicy ?? "artifactsOnly";
}
```

- [ ] **Step 6: Enforce policy in bridge tool_call hook**

In `src/bridge.ts`, add imports:

```ts
import { resolve, sep } from "node:path";
```

Register:

```ts
pi.on("tool_call", async (event, ctx) => {
  const rt = await ensureRuntime(ctx);
  const current = rt.current();
  if (!current) return;
  if (rt.currentEditPolicy() === "sourceAllowed") return;
  if (event.toolName !== "write" && event.toolName !== "edit") return;
  const inputPath = (event.input as { path?: string }).path;
  if (!inputPath) return;
  const fullPath = resolve(ctx.cwd, inputPath);
  const artifacts = resolve(current.metadata.artifactsDir);
  const isArtifact = fullPath === artifacts || fullPath.startsWith(artifacts + sep);
  if (!isArtifact) {
    return {
      block: true,
      reason: `Changeflow: source edits are blocked in ${current.metadata.state}. Write/edit under ${current.metadata.artifactsDir} only.`,
    };
  }
});
```

- [ ] **Step 7: Run tests and typecheck**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add pi/extensions/changeflow/src/types.ts pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts pi/extensions/changeflow/src/runtime.ts pi/extensions/changeflow/src/bridge.ts pi/extensions/changeflow/test/edit-policy.test.ts
git commit -m "feat(changeflow): enforce workflow edit policy"
```

## Task 12: Wire Main-Agent Task Completion

**Files:**
- Modify: `pi/extensions/changeflow/src/runtime.ts`
- Modify: `pi/extensions/changeflow/src/bridge.ts`
- Create: `pi/extensions/changeflow/test/main-agent-task.test.ts`

- [ ] **Step 1: Write main-agent task runtime test**

Create `pi/extensions/changeflow/test/main-agent-task.test.ts`:

```ts
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
```

- [ ] **Step 2: Run main-agent task test**

```bash
cd pi/extensions/changeflow
npm test -- test/main-agent-task.test.ts
```

Expected: PASS if Task 5 implementation is intact.

- [ ] **Step 3: Expose actor adapters from runtime**

Add to `ChangeflowRuntime`:

```ts
completeMainAgentTask(taskId: string, output: unknown): void {
  this.actorAdapters.completeMainAgentTask(taskId, output);
}

pendingMainAgentTask() {
  return this.actorAdapters.pendingMainAgentTask();
}
```

- [ ] **Step 4: Implement bridge tool**

Replace the current `changeflow_complete_main_task` execute handler in `src/bridge.ts`:

```ts
async execute(_id, params, _signal, _onUpdate, ctx) {
  const rt = await ensureRuntime(ctx);
  try {
    rt.completeMainAgentTask(params.taskId, params.output);
    return { content: [{ type: "text", text: `Completed main-agent task ${params.taskId}.` }], details: { taskId: params.taskId } };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { content: [{ type: "text", text: message }], details: { taskId: params.taskId }, isError: true };
  }
}
```

- [ ] **Step 5: Include pending main task in get_state output**

In `changeflow_get_state`, replace details/content construction with:

```ts
const rt = await ensureRuntime(ctx);
const current = rt.current();
const pendingMainAgentTask = rt.pendingMainAgentTask();
const details = { metadata: current?.metadata, pendingMainAgentTask, editPolicy: rt.currentEditPolicy() };
return { content: [{ type: "text", text: current ? JSON.stringify(details, null, 2) : "No active Changeflow workflow." }], details };
```

- [ ] **Step 6: Run checks**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add pi/extensions/changeflow/src/runtime.ts pi/extensions/changeflow/src/bridge.ts pi/extensions/changeflow/test/main-agent-task.test.ts
git commit -m "feat(changeflow): complete main-agent actor tasks"
```

## Task 13: Add Plannotator/User Review Actor Stubs as Machine Events

**Files:**
- Modify: `pi/extensions/changeflow/src/actors.ts`
- Modify: `pi/extensions/changeflow/src/bridge.ts`
- Modify: `pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts`
- Create: `pi/extensions/changeflow/test/review-actors.test.ts`

- [ ] **Step 1: Write review adapter test**

Create `pi/extensions/changeflow/test/review-actors.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { createActorAdapters } from "../src/actors.js";

describe("review actors", () => {
  it("delegates Plannotator review through injected dependency", async () => {
    const requestPlannotatorReview = vi.fn(async () => ({ approved: true, feedback: "ship it" }));
    const adapters = createActorAdapters({ runChildAgent: vi.fn(), requestPlannotatorReview });

    await expect(adapters.plannotatorReview({ kind: "high_level_plan", artifactPath: "high-level-plan.md" })).resolves.toEqual({
      approved: true,
      feedback: "ship it",
    });
  });
});
```

- [ ] **Step 2: Run failing review adapter test**

```bash
cd pi/extensions/changeflow
npm test -- test/review-actors.test.ts
```

Expected: FAIL because `requestPlannotatorReview` is not supported.

- [ ] **Step 3: Extend actor dependencies**

In `src/actors.ts`, add types:

```ts
export type PlannotatorReviewInput = { kind: string; artifactPath: string; content?: string };
export type AskUserInput = { prompt: string; choices?: string[] };
```

Extend `ActorAdapterDependencies`:

```ts
requestPlannotatorReview?(input: PlannotatorReviewInput): Promise<unknown>;
askUser?(input: AskUserInput): Promise<unknown>;
```

Add methods to returned object:

```ts
plannotatorReview(input: PlannotatorReviewInput): Promise<unknown> {
  if (!deps.requestPlannotatorReview) throw new Error("No Plannotator review adapter configured.");
  return deps.requestPlannotatorReview(input);
},

askUser(input: AskUserInput): Promise<unknown> {
  if (!deps.askUser) throw new Error("No user review adapter configured.");
  return deps.askUser(input);
},
```

- [ ] **Step 4: Wire bridge Plannotator dependency**

In `src/bridge.ts`, inside `actorAdapters`, add:

```ts
requestPlannotatorReview: async (input) => {
  const requestId = `changeflow-${Date.now()}`;
  return await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Plannotator did not respond within 5s.")), 5_000);
    pi.events.emit("plannotator:request", {
      requestId,
      action: "plan-review",
      payload: { planFilePath: input.artifactPath, planContent: input.content, origin: "changeflow-runtime", kind: input.kind },
      respond(response: unknown) {
        clearTimeout(timeout);
        resolve(response);
      },
    });
  });
},
askUser: async (input) => ctx.ui.select(input.prompt, input.choices ?? ["approved", "rejected"]),
```

- [ ] **Step 5: Keep workflow human review event-driven for MVP**

Do not change human review states to invoke Plannotator yet unless the bridge has a reliable result event integration. Keep `high_level_user_review` and `detailed_user_review` waiting for `USER_APPROVED`/`USER_REJECTED`. This task only makes the actor capability available to workflow authors and future workflow revisions.

- [ ] **Step 6: Run checks**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add pi/extensions/changeflow/src/actors.ts pi/extensions/changeflow/src/bridge.ts pi/extensions/changeflow/bundled-workflows/changeflow-runtime.ts pi/extensions/changeflow/test/review-actors.test.ts
git commit -m "feat(changeflow): add review actor adapters"
```

## Task 14: Remove Old Phase-Specific Workflow Code

**Files:**
- Modify/Delete: `pi/extensions/changeflow/workflows.ts`
- Modify/Delete: `pi/extensions/changeflow/bundled-workflows/changeflow-mvp.ts`
- Modify: `pi/extensions/changeflow/tsconfig.json`
- Modify: `pi/extensions/changeflow/README.md`

- [ ] **Step 1: Confirm no imports use old files**

Run:

```bash
cd pi/extensions/changeflow
rg "workflows\.js|changeflow-mvp|changeflow_submit_|changeflow_record_research|changeflow_advance|changeflow_run_subagent" . --glob '!node_modules/**'
```

Expected: only README references remain. If source files still import old modules or register old tools, finish replacing those references before deleting files.

- [ ] **Step 2: Delete old workflow metadata files**

Run:

```bash
rm pi/extensions/changeflow/workflows.ts pi/extensions/changeflow/bundled-workflows/changeflow-mvp.ts
```

- [ ] **Step 3: Update tsconfig include**

Ensure `pi/extensions/changeflow/tsconfig.json` no longer names `workflows.ts`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "strict": true,
    "skipLibCheck": true,
    "types": ["node", "vitest"]
  },
  "include": ["index.ts", "src/**/*.ts", "subagents.ts", "bundled-workflows/**/*.ts", "test/**/*.ts"]
}
```

- [ ] **Step 4: Replace README tool list**

In `pi/extensions/changeflow/README.md`, replace the current Tools section with:

```md
## Tools

The runtime exposes generic workflow tools. Workflow-specific behavior is encoded in trusted TypeScript workflow modules.

| Tool | Purpose |
| --- | --- |
| `changeflow_send_event` | Send a typed event to the active XState machine |
| `changeflow_get_state` | Inspect current state, pending main-agent task, edit policy, and artifacts |
| `changeflow_read_artifact` | Read a file under the workflow artifact directory |
| `changeflow_write_artifact` | Write a file under the workflow artifact directory |
| `changeflow_complete_main_task` | Complete a machine-invoked main-agent actor task |
```

- [ ] **Step 5: Run checks**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A pi/extensions/changeflow
git commit -m "refactor(changeflow): remove legacy phase-specific workflow code"
```

## Task 15: Manual Integration Verification

**Files:**
- Modify: `pi/extensions/changeflow/README.md`

- [ ] **Step 1: Add manual verification section**

Append this to `pi/extensions/changeflow/README.md`:

```md
## Manual runtime verification

1. Run `cd ~/dotfiles/pi/extensions/changeflow && npm run check`.
2. Reload Pi extensions.
3. Run `/changeflow workflows` and confirm `changeflow.runtime` appears.
4. Run `/changeflow start test the new runtime`.
5. Run `changeflow_get_state` and confirm the workflow is active.
6. Send `{ "type": "START" }` with `changeflow_send_event` if the workflow did not auto-start.
7. Progress research with `{ "type": "RESEARCH_COMPLETE" }`.
8. Submit a high-level plan with `{ "type": "PLAN_SUBMITTED", "kind": "high_level_plan", "markdown": "# Plan\n\nTest plan." }`.
9. Confirm a reviewer child-agent actor runs and the workflow reaches either `high_level_user_review` or `high_level_revision`.
10. Before execution, try a source `write` outside the artifact directory and confirm Changeflow blocks it.
11. Approve the high-level review with `{ "type": "USER_APPROVED" }`.
12. Submit detailed plan, approve it, define execution order, enter `executing`, and confirm source writes are allowed.
13. Complete execution, QA, and final user validation.
14. Reload Pi during a non-terminal state and confirm `/changeflow status` restores the workflow.
```

- [ ] **Step 2: Run full check**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 3: Manual smoke test in Pi**

Run the README steps in an interactive Pi session. Expected: workflow can start, accept generic events, block pre-execution edits, invoke the high-level reviewer child agent, and restore after reload.

- [ ] **Step 4: Commit docs**

```bash
git add pi/extensions/changeflow/README.md
git commit -m "docs(changeflow): document xstate runtime verification"
```

## Final Verification

- [ ] **Step 1: Run extension check**

```bash
cd pi/extensions/changeflow
npm run check
```

Expected: PASS.

- [ ] **Step 2: Inspect diff for legacy tool names**

```bash
rg "changeflow_submit_|changeflow_record_research|changeflow_advance" pi/extensions/changeflow --glob '!node_modules/**'
```

Expected: no source registrations remain. README may mention removal only if desired.

- [ ] **Step 3: Confirm repository status**

```bash
git status --short
```

Expected: no uncommitted Changeflow files. Pre-existing unrelated files, such as `home.nix`, may remain modified if they were already dirty before this work.

## Self-Review

- **Spec coverage:** The plan covers trusted TS workflow loading, runtime snapshots and event log, actor/capability split, main Pi agent supervision, child-agent invocation, generic bridge tools/commands, edit policy enforcement, restore, error surfaces through events, tests, docs, and removal of compatibility shims.
- **Intentional MVP boundary:** Plannotator/user review actor adapters are added, but the ported workflow keeps human review event-driven until result reconciliation is made robust. This still satisfies the spec's first extreme demonstration through the child-agent plan critique actor.
- **Completeness scan:** No incomplete markers or unspecified implementation steps remain.
- **Type consistency:** Core names are consistent across tasks: `TrustedWorkflowDefinition`, `ChangeflowRuntime`, `createActorAdapters`, `changeflow.runtime`, `changeflow_send_event`, `changeflow_get_state`, `changeflow_read_artifact`, `changeflow_write_artifact`, and `changeflow_complete_main_task`.
