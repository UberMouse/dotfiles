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

type PlannerOutput = { markdown: string };
type ReviewerOutput = { approved: boolean; summary: string; feedback?: string };

export default defineWorkflow({
  id: "changeflow.runtime",
  name: "Changeflow Runtime Workflow",
  description: "Machine-owned Changeflow lifecycle with child-agent planning and critique.",
  initialEvent: { type: "START" },
  eventSchemas,
  artifactTemplates: [
    { path: "research.md", content: "# Research: {description}\n\n" },
    { path: "high-level-plan.md", content: "# High-level plan: {description}\n\n" },
  ],
  createActorLogic: ({ runtime, actors }) => setup({
    types: {
      context: {} as { highLevelPlan?: string; latestFeedback?: string },
      events: {} as ChangeflowEvent,
    },
    actors: {
      plannerAgent: fromPromise(() =>
        actors.childAgent({
          role: "planner",
          task: "Write the high-level plan and return { markdown }.",
          state: "high_level_planning",
        }) as Promise<PlannerOutput>
      ),
      reviewerAgent: fromPromise(({ input }: { input: { highLevelPlan: string } }) =>
        actors.childAgent({
          role: "reviewer",
          task: `Review this high-level plan and return { approved, summary, feedback }:
${input.highLevelPlan}`,
          state: "high_level_agent_review",
        }) as Promise<ReviewerOutput>
      ),
    },
  }).createMachine({
    id: "changeflow.runtime",
    context: { highLevelPlan: undefined, latestFeedback: undefined },
    initial: "idle",
    states: {
      idle: { on: { START: "research" } },
      research: {
        entry: () => runtime.queueMainAgentMessage("Research the requested change. Record findings in artifacts and send RESEARCH_COMPLETE when ready."),
        on: { RESEARCH_COMPLETE: "high_level_planning" },
      },
      high_level_planning: {
        invoke: {
          src: "plannerAgent",
          onDone: {
            target: "high_level_agent_review",
            actions: [
              assign({ highLevelPlan: ({ event }) => event.output.markdown }),
              ({ event }) => runtime.writeArtifact("high-level-plan.md", event.output.markdown),
            ],
          },
          onError: {
            target: "high_level_revision",
            actions: assign({ latestFeedback: ({ event }) => String(event.error) }),
          },
        },
      },
      high_level_agent_review: {
        invoke: {
          src: "reviewerAgent",
          input: ({ context }) => ({ highLevelPlan: context.highLevelPlan ?? "" }),
          onDone: [
            { guard: ({ event }) => Boolean(event.output.approved), target: "high_level_user_review" },
            {
              target: "high_level_revision",
              actions: assign({ latestFeedback: ({ event }) => event.output.feedback ?? event.output.summary }),
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
            actions: [
              assign({ highLevelPlan: ({ event }) => event.markdown }),
              ({ event }) => runtime.writeArtifact("high-level-plan.md", event.markdown),
            ],
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
