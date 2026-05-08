# Execution order

Run sequentially in the main Pi session.

1. **Extract default workflow definition module**
   - Create workflow definition wrapper/types using XState config typing.
   - Move current MVP `phaseInstructions`/machine config into the default `changeflow.mvp` definition.

2. **Add registry and definition validation**
   - Register the built-in default.
   - Add external definition loading if feasible in this pass.
   - Validate IDs, initial state, transition targets, and initial event.

3. **Persist selected definition ID and refactor helpers**
   - Add `workflowDefinitionId` with default fallback for old workflows.
   - Replace module-level machine/config assumptions with selected-definition helpers.

4. **Add selection UX and artifact templates**
   - Support `/changeflow start --workflow <id> <description>` while preserving default start syntax.
   - Add `/changeflow workflows` and show definition in status.
   - Initialize artifacts from definition templates.

5. **Documentation and validation**
   - Update README.
   - Run `cd pi/extensions/changeflow && npm run check`.
   - Inspect default and explicit workflow paths.

No parallel source-editing subagents for this change; the refactor touches shared state/persistence paths and should remain sequential.