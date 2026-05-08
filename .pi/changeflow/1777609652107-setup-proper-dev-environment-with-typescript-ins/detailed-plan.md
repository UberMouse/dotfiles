# Detailed plan: TypeScript dev environment for Changeflow

## Scope

Set up local TypeScript validation for `pi/extensions/changeflow` and document the newly observed Changeflow/Plannotator automation issue once source edits are allowed.

## Step 1: Create `issues.md` with observed automation bug notes

**File:** `pi/extensions/changeflow/issues.md`

Add notes covering:

- Stale queued phase prompt snapshots can cause the agent to repeat old phase actions.
- Repeated `changeflow_submit_high_level_plan` calls can reopen Plannotator reviews.
- Submission tools need state guards.
- Pending Plannotator reviews may need status reconciliation via `review-status`.
- Potential fixes: minimal continuation messages, state guards, duplicate review protection, and review-status reconciliation.

**Verification:** File exists and contains the bug notes requested by the user.

## Step 2: Add TypeScript config

**File:** `pi/extensions/changeflow/tsconfig.json`

Create a TypeScript config for a Node ESM Pi extension:

- `target`: `ES2022`
- `module`: `NodeNext`
- `moduleResolution`: `NodeNext`
- `noEmit`: `true`
- `strict`: `true`
- `skipLibCheck`: `true`
- `types`: `['node']`
- include `index.ts`

**Verification:** `npx tsc --noEmit` uses the config.

## Step 3: Update npm scripts

**File:** `pi/extensions/changeflow/package.json`

Add scripts:

- `typecheck`: `tsc --noEmit`
- `check`: `npm run typecheck`
- `build`: `npm run typecheck`

This treats build as validation because Pi runs TypeScript directly via jiti.

**Verification:** `npm run check` and `npm run build` are available.

## Step 4: Add dev dependencies and refresh lockfile

**Files:**

- `pi/extensions/changeflow/package.json`
- `pi/extensions/changeflow/package-lock.json`

Add dev dependencies:

- `typescript`
- `@types/node`
- `@mariozechner/pi-coding-agent@0.70.6`

Refresh the lockfile with npm from `pi/extensions/changeflow`.

**Verification:** Lockfile includes the new dev deps and `node_modules` can provide `tsc` locally.

## Step 5: Run validation and fix type errors

Run from `pi/extensions/changeflow`:

```bash
npm install
npm run check
npm run build
```

If TypeScript reports legitimate errors in `index.ts`, fix them within this change.

**Verification:** Both scripts pass.

## Step 6: Document developer commands

**File:** `pi/extensions/changeflow/README.md`

Add a short development section documenting:

```bash
cd pi/extensions/changeflow
npm install
npm run check
npm run build
```

Clarify that `build` typechecks only because Pi loads `index.ts` directly.

**Verification:** README mentions the new scripts and no longer leaves validation ambiguous.

## Ordering

All steps are sequential:

1. Record `issues.md` first, per user request.
2. Add config/scripts/deps.
3. Refresh lockfile.
4. Validate and fix surfaced type errors.
5. Document commands.
