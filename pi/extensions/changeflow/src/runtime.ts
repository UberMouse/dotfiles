import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createActor, type Actor, type AnyActorLogic, type Snapshot } from "xstate";
import { createActorAdapters, type ActorAdapterDependencies, type ActorAdapters } from "./actors.js";
import { appendEvent, createWorkflowPaths, readEvents, readSnapshot, readWorkflowMetadata, writeActorRun, writeSnapshot, writeWorkflowMetadata, type WorkflowPaths } from "./storage.js";
import { parseWorkflowEvent, type ActorRunRecord, type TrustedWorkflowDefinition, type WorkflowMetadata, type WorkflowRuntimeSnapshot } from "./types.js";

export type ChangeflowRuntimeOptions = {
  cwd: string;
  workflows: readonly TrustedWorkflowDefinition[];
  actorAdapters?: ActorAdapterDependencies;
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
  private readonly actorAdapters: ActorAdapters;
  private active?: { metadata: WorkflowMetadata; paths: WorkflowPaths; definition: TrustedWorkflowDefinition; actor: Actor<AnyActorLogic> };
  private eventSeq = 0;
  private actorRuns: Map<string, ActorRunRecord> = new Map();
  private actorCancellers: Map<string, AbortController> = new Map();

  constructor(options: ChangeflowRuntimeOptions) {
    this.cwd = options.cwd;
    this.now = options.now ?? (() => new Date().toISOString());
    this.actorAdapters = createActorAdapters(options.actorAdapters ?? { runChildAgent: async () => { throw new Error("No child-agent adapter configured."); } });
    for (const workflow of options.workflows) this.workflows.set(workflow.id, workflow);
  }

  current(): WorkflowRuntimeSnapshot | undefined {
    if (!this.active) return undefined;
    return { metadata: this.active.metadata, machineSnapshot: this.active.actor.getPersistedSnapshot() };
  }

  currentEditPolicy(): "artifactsOnly" | "sourceAllowed" {
    if (!this.active) return "artifactsOnly";
    return this.active.definition.statePolicies?.[this.active.metadata.state]?.editPolicy ?? "artifactsOnly";
  }

  async start(input: StartWorkflowInput): Promise<WorkflowRuntimeSnapshot> {
    const definition = this.requireWorkflow(input.workflowDefinitionId);
    const id = `${Date.now()}-${this.slugify(input.description)}`;
    const paths = createWorkflowPaths(join(this.cwd, ".pi", "changeflow"), id);
    await mkdir(paths.root, { recursive: true });

    const logic = definition.createActorLogic({ runtime: this.capabilities(paths), actors: this.actorAdapters, actions: {} });
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
    actor.subscribe((snapshot) => {
      void this.persistObservedSnapshot(snapshot.value, actor.getPersistedSnapshot());
    });
    await writeWorkflowMetadata(paths, metadata);
    await writeSnapshot(paths, 1, actor.getPersistedSnapshot());
    await this.append("out", "workflow.started", { event: { type: "workflow.started", description: input.description }, snapshotSeq: 1 });
    return this.currentOrThrow();
  }

  async restore(workflowId: string): Promise<WorkflowRuntimeSnapshot> {
    const paths = createWorkflowPaths(join(this.cwd, ".pi", "changeflow"), workflowId);
    const metadata = await readWorkflowMetadata(paths);
    const definition = this.requireWorkflow(metadata.workflowDefinitionId);
    const events = await readEvents(paths);
    this.eventSeq = events.reduce((max, e) => Math.max(max, e.seq), 0);
    const snapshot = await readSnapshot(paths, metadata.latestSnapshotSeq) as Snapshot<unknown>;
    const logic = definition.createActorLogic({ runtime: this.capabilities(paths), actors: this.actorAdapters, actions: {} });
    const actor = createActor(logic, { snapshot });
    actor.start();
    this.active = { metadata, paths, definition, actor };
    actor.subscribe((snapshot) => {
      void this.persistObservedSnapshot(snapshot.value, actor.getPersistedSnapshot());
    });

    // Check for orphaned running actors and send recovery events
    await this.reconcileOrphanedActors();

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

  async listActorRuns(): Promise<ActorRunRecord[]> {
    return [...this.actorRuns.values()].sort((a, b) =>
      new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime()
    );
  }

  async cancelActor(actorId: string): Promise<void> {
    const canceller = this.actorCancellers.get(actorId);
    if (!canceller) throw new Error(`No cancellable actor ${actorId}.`);
    canceller.abort();
    const run = this.actorRuns.get(actorId);
    if (run) {
      run.status = "cancelled";
      run.completedAt = this.now();
      await writeActorRun(this.active!.paths, run);
    }
  }

  trackActorStart(id: string, kind: ActorRunRecord["kind"], state: string, input: unknown): AbortController {
    const controller = new AbortController();
    const record: ActorRunRecord = {
      id,
      workflowId: this.active!.metadata.id,
      kind,
      state,
      status: "running",
      input,
      startedAt: this.now(),
    };
    this.actorRuns.set(id, record);
    this.actorCancellers.set(id, controller);
    void writeActorRun(this.active!.paths, record);
    return controller;
  }

  async trackActorComplete(id: string, output?: unknown, error?: string): Promise<void> {
    const run = this.actorRuns.get(id);
    if (!run) return;
    run.status = error ? "failed" : "completed";
    run.output = output;
    run.error = error;
    run.completedAt = this.now();
    this.actorCancellers.delete(id);
    await writeActorRun(this.active!.paths, run);
  }

  private async reconcileOrphanedActors(): Promise<void> {
    if (!this.active) return;

    const actorsDir = this.active.paths.actorsDir;
    try {
      const entries = await readdir(actorsDir, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        try {
          const metadataPath = join(actorsDir, entry.name, "metadata.json");
          const record = JSON.parse(await readFile(metadataPath, "utf-8")) as ActorRunRecord;
          if (record.status === "running") {
            record.status = "failed";
            record.error = "Session ended while actor was running";
            record.completedAt = this.now();
            await writeActorRun(this.active.paths, record);

            this.active.actor.send({
              type: "ACTOR_RECOVERY_NEEDED",
              actorId: record.id,
              actorKind: record.kind,
              originalState: record.state,
              error: record.error,
            });
          }
          this.actorRuns.set(record.id, record);
        } catch {
          // Skip invalid actor records
        }
      }
    } catch {
      // No actors directory yet
    }
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

  private capabilities(paths: WorkflowPaths) {
    return {
      log: (message: string, details?: unknown) => {
        void this.append("effect", "runtime.log", { event: { message, details } });
      },
      writeArtifact: (path: string, content: string) => {
        const fullPath = join(paths.artifactsDir, path);
        mkdir(dirname(fullPath), { recursive: true })
          .then(() => writeFile(fullPath, content, "utf-8"))
          .then(() => this.append("effect", "artifact.write", { event: { path } }))
          .catch((error) => {
            void this.append("effect", "artifact.write.failed", {
              event: { path },
              error: error instanceof Error ? error.message : String(error),
            });
          });
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
}
