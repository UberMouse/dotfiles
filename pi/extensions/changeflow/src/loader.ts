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
