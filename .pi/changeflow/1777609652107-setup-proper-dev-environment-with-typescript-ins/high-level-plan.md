# High-level plan: Changeflow TypeScript dev environment

## Goal

Set up a proper local development environment for the Changeflow Pi extension so changes can be validated with npm scripts instead of ad hoc `nix shell` or unavailable `tsc` commands.

## Approach

1. **Add TypeScript project configuration**
   - Add `pi/extensions/changeflow/tsconfig.json`.
   - Configure it for a Node ESM TypeScript extension loaded directly by Pi/jiti:
     - `module`/`moduleResolution`: `NodeNext`
     - `target`: modern Node target such as `ES2022`
     - `noEmit`: `true`, because Pi runs `index.ts` directly
     - strict type checking and Node/Pi-compatible settings
   - Include `index.ts`.

2. **Add npm scripts**
   - Update `pi/extensions/changeflow/package.json` with useful scripts:
     - `typecheck`: `tsc --noEmit`
     - `check`: `npm run typecheck`
     - `build`: `npm run typecheck`
   - Treat `build` as validation rather than emitted JS, since this extension is TypeScript-at-runtime.

3. **Add dev dependencies**
   - Add `typescript` for `tsc`.
   - Add `@types/node` for `node:fs`, `node:path`, etc.
   - Add `@mariozechner/pi-coding-agent@0.70.6` as a dev dependency for extension API types matching the currently installed Pi runtime.
   - Keep runtime dependencies unchanged unless validation proves an adjustment is needed.

4. **Refresh lockfile**
   - Update `pi/extensions/changeflow/package-lock.json` to include the new dev dependencies.
   - Avoid relying on globally installed TypeScript or Nix shell packages for normal extension validation.

5. **Verify and fix any surfaced type errors**
   - Run `npm run check` and `npm run build` in `pi/extensions/changeflow`.
   - If TypeScript reports legitimate issues in the existing extension code, fix them as part of this change.

## Files likely to change

- `pi/extensions/changeflow/package.json`
- `pi/extensions/changeflow/package-lock.json`
- `pi/extensions/changeflow/tsconfig.json`
- Possibly `pi/extensions/changeflow/index.ts` if typecheck exposes errors
- Possibly `pi/extensions/changeflow/README.md` to document the dev commands

## Reuse opportunities

- Use Pi’s documented package pattern: dependencies next to the extension are resolved normally.
- Follow Pi example convention of `build` and `check` scripts, but make them meaningful for this package.
- Use `noEmit` because Pi loads TypeScript extensions directly via jiti.

## Risks

- Pinning the Pi dev dependency to the current runtime version may need updating when Pi is upgraded.
- TypeScript may reveal existing type errors from recent code changes; those should be fixed rather than hidden if practical.
- Adding `@mariozechner/pi-coding-agent` as a dependency instead of dev dependency would be wrong for runtime/package hygiene; it should be dev-only for local typechecking.

## Verification

- `cd pi/extensions/changeflow && npm install` or package-lock refresh succeeds.
- `npm run check` succeeds.
- `npm run build` succeeds.
- `git diff` shows only dev-environment-related changes plus any type fixes required by validation.
