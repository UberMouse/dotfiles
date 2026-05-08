import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { loadWorkflowRegistry } from "../src/loader.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const typesPath = pathToFileURL(join(__dirname, "..", "src", "types.ts")).href;

let tempDir: string | undefined;

afterEach(async () => {
  if (tempDir) await rm(tempDir, { recursive: true, force: true });
  tempDir = undefined;
});

describe("workflow loader", () => {
  it("loads bundled workflow by default", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-loader-"));
    const registry = await loadWorkflowRegistry(tempDir);
    expect(registry.definitions.has("changeflow.runtime")).toBe(true);
    expect(registry.warnings).toEqual([]);
  });

  it("loads project-local ts workflows", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-loader-"));
    const workflowsDir = join(tempDir, ".pi", "changeflow", "workflows");
    await mkdir(workflowsDir, { recursive: true });
    await writeFile(join(workflowsDir, "local.ts"), `
      import { setup } from "xstate";
      import { defineWorkflow } from "${typesPath}";
      export default defineWorkflow({ id: "local.workflow", name: "Local Workflow", createActorLogic: () => setup({}).createMachine({ id: "local.workflow", initial: "idle", states: { idle: {} } }) });
    `);

    const registry = await loadWorkflowRegistry(tempDir);
    expect(registry.definitions.has("changeflow.runtime")).toBe(true);
    expect(registry.definitions.has("local.workflow")).toBe(true);
    expect(registry.warnings).toEqual([]);
  });

  it("warns on duplicate workflow ids", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-loader-"));
    const workflowsDir = join(tempDir, ".pi", "changeflow", "workflows");
    await mkdir(workflowsDir, { recursive: true });
    // Try to register a workflow with the same id as the bundled one
    await writeFile(join(workflowsDir, "duplicate.ts"), `
      import { setup } from "xstate";
      import { defineWorkflow } from "${typesPath}";
      export default defineWorkflow({ id: "changeflow.runtime", name: "Duplicate", createActorLogic: () => setup({}).createMachine({ id: "changeflow.runtime", initial: "idle", states: { idle: {} } }) });
    `);

    const registry = await loadWorkflowRegistry(tempDir);
    expect(registry.definitions.has("changeflow.runtime")).toBe(true);
    expect(registry.warnings.length).toBe(1);
    expect(registry.warnings[0]).toContain("Skipping duplicate workflow changeflow.runtime");
  });

  it("warns on workflow with no default export", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-loader-"));
    const workflowsDir = join(tempDir, ".pi", "changeflow", "workflows");
    await mkdir(workflowsDir, { recursive: true });
    await writeFile(join(workflowsDir, "nodefault.ts"), `
      export const notDefault = { id: "no.default" };
    `);

    const registry = await loadWorkflowRegistry(tempDir);
    expect(registry.definitions.has("changeflow.runtime")).toBe(true);
    expect(registry.warnings.length).toBe(1);
    expect(registry.warnings[0]).toContain("no default export");
  });

  it("warns on workflow with empty id", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-loader-"));
    const workflowsDir = join(tempDir, ".pi", "changeflow", "workflows");
    await mkdir(workflowsDir, { recursive: true });
    await writeFile(join(workflowsDir, "emptyid.ts"), `
      import { setup } from "xstate";
      import { defineWorkflow } from "${typesPath}";
      export default defineWorkflow({ id: "  ", name: "Empty Id", createActorLogic: () => setup({}).createMachine({ id: "empty", initial: "idle", states: { idle: {} } }) });
    `);

    const registry = await loadWorkflowRegistry(tempDir);
    expect(registry.definitions.has("changeflow.runtime")).toBe(true);
    expect(registry.warnings.length).toBe(1);
    expect(registry.warnings[0]).toContain("empty id");
  });

  it("warns on workflows that fail to import", async () => {
    tempDir = await mkdtemp(join(tmpdir(), "changeflow-loader-"));
    const workflowsDir = join(tempDir, ".pi", "changeflow", "workflows");
    await mkdir(workflowsDir, { recursive: true });
    // Use syntax error that will definitely fail at parse time
    await writeFile(join(workflowsDir, "broken.ts"), `
      export default {{{ syntax error
    `);

    const registry = await loadWorkflowRegistry(tempDir);
    expect(registry.definitions.has("changeflow.runtime")).toBe(true);
    expect(registry.warnings.length).toBe(1);
    expect(registry.warnings[0]).toContain("Skipping workflow");
    expect(registry.warnings[0]).toContain("broken.ts");
  });
});
