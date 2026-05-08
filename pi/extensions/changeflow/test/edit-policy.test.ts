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
