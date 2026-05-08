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

  it("delegates askUser through injected dependency", async () => {
    const askUser = vi.fn(async () => "approved");
    const adapters = createActorAdapters({ runChildAgent: vi.fn(), askUser });

    await expect(adapters.askUser({ prompt: "Approve changes?", choices: ["approved", "rejected"] })).resolves.toEqual("approved");
    expect(askUser).toHaveBeenCalledWith({ prompt: "Approve changes?", choices: ["approved", "rejected"] });
  });

  it("throws if plannotatorReview adapter is not configured", () => {
    const adapters = createActorAdapters({ runChildAgent: vi.fn() });

    expect(() => adapters.plannotatorReview({ kind: "high_level_plan", artifactPath: "plan.md" })).toThrow(
      "No Plannotator review adapter configured."
    );
  });

  it("throws if askUser adapter is not configured", () => {
    const adapters = createActorAdapters({ runChildAgent: vi.fn() });

    expect(() => adapters.askUser({ prompt: "Continue?" })).toThrow("No user review adapter configured.");
  });
});
