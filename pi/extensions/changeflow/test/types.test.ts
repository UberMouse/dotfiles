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

  it("accepts plain event objects when no schema is provided", () => {
    expect(parseWorkflowEvent(undefined, { type: "ADVANCE" })).toEqual({
      ok: true,
      event: { type: "ADVANCE" },
    });
    expect(parseWorkflowEvent(undefined, { notAType: 1 }).ok).toBe(false);
    expect(parseWorkflowEvent(undefined, null).ok).toBe(false);
  });
});
