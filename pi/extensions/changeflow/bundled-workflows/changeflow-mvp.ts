import type { ChangeflowWorkflowDefinition } from "../workflows.js";

const DEFAULT_WORKFLOW_DEFINITION_ID = "changeflow.mvp";

const phaseInstructions = {
  research: `Research phase instructions:
- Gather codebase context for this change.
- Consider using changeflow_run_subagent with role "scout" for focused read-only reconnaissance.
- Read relevant files and identify reusable patterns.
- Ask the user questions only when the answer cannot be found from the repo.
- Record synthesized findings with changeflow_record_research.
- Do not modify source code.
- When sufficient context exists, call changeflow_advance with event RESEARCH_COMPLETE.`,
  highLevelPlanning: `High-level planning instructions:
- Synthesize research into a concise plan/spec.
- Consider using changeflow_run_subagent with role "planner" or "reviewer" for read-only plan generation/critique.
- Cover approach, files likely to change, reuse opportunities, risks, and verification.
- Save/submit the synthesized plan with changeflow_submit_high_level_plan.
- Do not modify source code.`,
  highLevelUserReview: `Waiting for human high-level plan review in Plannotator. Do not proceed until review result is received.`,
  detailedPlanning: `Detailed planning instructions:
- Expand the approved high-level plan into step-by-step implementation tasks.
- Consider using changeflow_run_subagent with role "planner" for step expansion or role "reviewer" for critique.
- Include dependencies between steps and verification for each step.
- Submit the synthesized detailed plan with changeflow_submit_detailed_plan.
- Do not modify source code.`,
  detailedUserReview: `Waiting for human detailed plan review in Plannotator. Do not proceed until review result is received.`,
  executionOrdering: `Execution ordering instructions:
- Define which detailed steps must run sequentially and which could run in parallel.
- Consider using changeflow_run_subagent with role "planner" for ordering advice.
- For the MVP, execution is still driven in this main Pi session and source-editing subagents should run sequentially.
- Save the ordering with changeflow_submit_execution_order, or if already saved call changeflow_advance with event ORDER_DEFINED.`,
  executing: `Execution instructions:
- Source edits are now allowed.
- Implement the approved plan in the defined order.
- Consider delegating focused approved steps to changeflow_run_subagent with role "worker"; use role "reviewer" for implementation checks.
- Keep source-editing subagents sequential for this MVP.
- Keep changes focused on the approved scope.
- After execution, call changeflow_advance with event EXECUTION_COMPLETE.`,
  qa: `QA instructions:
- Review the whole output.
- Consider using changeflow_run_subagent with role "reviewer" or "qa" for focused validation.
- Add/fix tests and documentation as needed.
- Run relevant validation commands.
- Synthesize subagent QA findings before deciding readiness.
- When ready for user validation, call changeflow_advance with event QA_COMPLETE.`,
  userValidation: `Waiting for final user validation. If rejected, return to QA. If approved, finish the workflow.`,
} as const;

const defaultMachineDefinition = {
  id: DEFAULT_WORKFLOW_DEFINITION_ID,
  initial: "idle",
  states: {
    idle: { on: { START: "research" } },
    research: {
      meta: {
        changeflow: {
          autoContinue: true,
          editPolicy: "artifactsOnly",
          prompt: { instructions: phaseInstructions.research },
          subagents: { allowedRoles: ["scout"] },
        },
      },
      on: { RESEARCH_COMPLETE: "high_level_planning" },
    },
    high_level_planning: {
      meta: {
        changeflow: {
          autoContinue: true,
          editPolicy: "artifactsOnly",
          prompt: { instructions: phaseInstructions.highLevelPlanning },
          subagents: { allowedRoles: ["planner", "reviewer"] },
          submission: { reviewKind: "high_level_plan", submittedEvent: "HIGH_LEVEL_PLAN_SUBMITTED" },
          plannotator: { action: "plan-review", artifact: "highLevelPlanPath" },
        },
      },
      on: { HIGH_LEVEL_PLAN_SUBMITTED: "high_level_user_review" },
    },
    high_level_agent_review: { on: { AGENT_APPROVED: "high_level_user_review", AGENT_REJECTED: "high_level_revision" } },
    high_level_user_review: {
      meta: {
        changeflow: {
          prompt: { instructions: phaseInstructions.highLevelUserReview },
          reviewGate: { actor: "human", kind: "high_level_plan" },
          plannotator: { action: "plan-review", artifact: "highLevelPlanPath" },
        },
      },
      on: { USER_APPROVED: "detailed_planning", USER_REJECTED: "high_level_revision" },
    },
    high_level_revision: {
      meta: {
        changeflow: {
          autoContinue: true,
          editPolicy: "artifactsOnly",
          prompt: { instructions: phaseInstructions.highLevelPlanning },
          subagents: { allowedRoles: ["planner", "reviewer"] },
          submission: { reviewKind: "high_level_plan", submittedEvent: "HIGH_LEVEL_PLAN_SUBMITTED" },
          plannotator: { action: "plan-review", artifact: "highLevelPlanPath" },
        },
      },
      on: { HIGH_LEVEL_PLAN_SUBMITTED: "high_level_user_review" },
    },
    detailed_planning: {
      meta: {
        changeflow: {
          autoContinue: true,
          editPolicy: "artifactsOnly",
          prompt: { instructions: phaseInstructions.detailedPlanning },
          subagents: { allowedRoles: ["planner", "reviewer"] },
          submission: { reviewKind: "detailed_plan", submittedEvent: "DETAILED_PLAN_SUBMITTED" },
          plannotator: { action: "plan-review", artifact: "detailedPlanPath" },
        },
      },
      on: { DETAILED_PLAN_SUBMITTED: "detailed_user_review" },
    },
    detailed_agent_review: { on: { AGENT_APPROVED: "detailed_user_review", AGENT_REJECTED: "detailed_planning" } },
    detailed_user_review: {
      meta: {
        changeflow: {
          prompt: { instructions: phaseInstructions.detailedUserReview },
          reviewGate: { actor: "human", kind: "detailed_plan" },
          plannotator: { action: "plan-review", artifact: "detailedPlanPath" },
        },
      },
      on: { USER_APPROVED: "execution_ordering", USER_REJECTED: "detailed_planning" },
    },
    execution_ordering: {
      meta: {
        changeflow: {
          autoContinue: true,
          editPolicy: "artifactsOnly",
          prompt: { instructions: phaseInstructions.executionOrdering },
          subagents: { allowedRoles: ["planner"] },
          executionOrder: { artifactName: "execution-order.md", submittedEvent: "ORDER_DEFINED" },
        },
      },
      on: { ORDER_DEFINED: "executing" },
    },
    executing: {
      meta: {
        changeflow: {
          autoContinue: true,
          editPolicy: "sourceAllowed",
          prompt: { instructions: phaseInstructions.executing },
          subagents: { allowedRoles: ["worker", "reviewer"] },
        },
      },
      on: { EXECUTION_COMPLETE: "qa" },
    },
    qa: {
      meta: {
        changeflow: {
          autoContinue: true,
          editPolicy: "sourceAllowed",
          prompt: { instructions: phaseInstructions.qa },
          subagents: { allowedRoles: ["reviewer", "qa"] },
        },
      },
      on: { QA_COMPLETE: "user_validation" },
    },
    user_validation: {
      meta: {
        changeflow: {
          prompt: { instructions: phaseInstructions.userValidation },
          reviewGate: { actor: "human", kind: "qa" },
        },
      },
      on: { USER_APPROVED: "done", USER_REJECTED: "qa" },
    },
    done: {},
  },
} as const satisfies ChangeflowWorkflowDefinition["machineDefinition"];

const defaultWorkflowDefinition: ChangeflowWorkflowDefinition = {
  id: DEFAULT_WORKFLOW_DEFINITION_ID,
  name: "Default Changeflow workflow",
  description: "The original linear Changeflow research, planning, execution, QA, and validation workflow.",
  initialEvent: "START",
  machineDefinition: defaultMachineDefinition,
  artifactTemplates: [
    { path: "research.md", content: "# Research: {description}\n\n" },
    { path: "high-level-plan.md", content: "# High-level plan: {description}\n\n" },
  ],
};

export default defaultWorkflowDefinition;
