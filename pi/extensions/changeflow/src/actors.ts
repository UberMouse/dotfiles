import type { ChildAgentInput, MainAgentInput, PlannotatorReviewInput, AskUserInput, RunScriptInput } from "./types.js";

export type PendingMainAgentTask = MainAgentInput & { startedAt: string };

export type ActorAdapterDependencies = {
  runChildAgent(input: ChildAgentInput): Promise<unknown>;
  runScript?(input: RunScriptInput): Promise<unknown>;
  requestPlannotatorReview?(input: PlannotatorReviewInput): Promise<unknown>;
  askUser?(input: AskUserInput): Promise<unknown>;
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

    runScript(input: RunScriptInput): Promise<unknown> {
      if (!deps.runScript) throw new Error("No script runner adapter configured.");
      return deps.runScript(input);
    },

    plannotatorReview(input: PlannotatorReviewInput): Promise<unknown> {
      if (!deps.requestPlannotatorReview) throw new Error("No Plannotator review adapter configured.");
      return deps.requestPlannotatorReview(input);
    },

    askUser(input: AskUserInput): Promise<unknown> {
      if (!deps.askUser) throw new Error("No user review adapter configured.");
      return deps.askUser(input);
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
