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
