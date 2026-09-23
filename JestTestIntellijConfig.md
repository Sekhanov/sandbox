# Running Jest tests in IntelliJ across a multi-package monorepo

## The problem

Tests run fine via the npm script but fail in IntelliJ with:

```
SyntaxError: .../tradeProcess.test.ts: Unexpected token, expected "from" (4:12)
> 4 | import type { TradeData } from '@functions/tradeProcessV2/types';
```

### Why

The `rules-engine-3.0` package has **no Babel config and no default Jest config**. All the
TypeScript handling lives in `jest.unit.config.mjs`:

- `preset: 'ts-jest'` + `transform: { '^.+\\.ts$': 'ts-jest' }` — compiles `.ts` / `import type` / TS syntax via `ts-jest`.
- `moduleNameMapper` for `@functions`, `@libs`, etc.

- `npm run test:unit` passes `--config jest.unit.config.mjs`, so Jest uses `ts-jest` → everything parses.
- IntelliJ's Jest run configuration is **not pointing at that config file**. With no config, Jest falls
  back to its defaults, which use **`babel-jest`**. There's no `@babel/preset-typescript` anywhere, so
  Babel's parser chokes on the first TS-only syntax — `import type` at line 4. (If it got past that, the
  `@functions/...` aliases would fail next, because `moduleNameMapper` also only exists in that config.)

The test file itself is correct — this is purely a run-configuration mismatch.

## Single-package fix

Tell IntelliJ to use the config file. **Run → Edit Configurations → Jest** (edit the default/template so
future runs inherit it):

- **Configuration file**: `jest.unit.config.mjs`
- or **Jest options**: `--config jest.unit.config.mjs`
- **Working directory**: `.../rules-engine-3.0`
- Optionally add `TZ=UTC` as an env var to match the npm script.

Or set it once in **Settings → Languages & Frameworks → JavaScript → Jest**.

## The multi-package problem

`~/Projects/BA` is opened as one IntelliJ window over several independent packages, each with its own
working directory and config:

| Package | Config file |
|---------|-------------|
| `compliance-security-master` | `jest.config.mjs` |
| `compliance-app/ui` | `jest.config.ts` |
| `compliance-rules-engine/lambdas/rules-engine-3.0` | `jest.unit.config.mjs` (+ `jest.integration.config.mjs`) |

A single global Jest **template** can't cover these — the config path and working directory differ per
package.

### Option 1 — Let IntelliJ auto-detect per test

Leave the config field **blank** in the Jest template and rely on Jest's own resolution. Jest only
auto-discovers `jest.config.*` **at the package root**, so this works for `compliance-security-master`
and `compliance-app/ui`, but **not** rules-engine (its config is named `jest.unit.config.mjs`, not the
default `jest.config.*`).

### Option 2 — One saved run configuration per package (reliable)

Create a dedicated Jest run config for each package once; they coexist in the Run dropdown:

| Name | Working directory | Config file |
|------|-------------------|-------------|
| RE3 unit | `.../rules-engine-3.0` | `jest.unit.config.mjs` |
| RE3 integration | `.../rules-engine-3.0` | `jest.integration.config.mjs` |
| security-master | `.../compliance-security-master` | `jest.config.mjs` |
| app-ui | `.../compliance-app/ui` | `jest.config.ts` |

IntelliJ matches the closest configuration by path, so gutter-runs (▶) go to the correct package
automatically. One-time setup; per-package (not per-file) granularity.

### Option 3 — Add a discoverable config alias per package (cleanest long-term)

Make each package auto-detectable so gutter-runs "just work" without saved configs. In `rules-engine-3.0`
add a thin default-named config that re-exports the unit config:

```js
// jest.config.mjs — default config so IDEs/tools auto-discover unit tests
export { default } from './jest.unit.config.mjs';
```

Now IntelliJ (and a bare `jest`) finds a root config in every package → Option 1's auto-detect covers
everything. Integration tests still need explicit `--config jest.integration.config.mjs` (saved config or
npm script). This is a shared repo file, so it should go through a PR.

### Option 4 — Open each package as its own IntelliJ project/module

If you rarely cross package boundaries, open `rules-engine-3.0` on its own (or attach each as a separate
module with its own JS/Jest settings). The per-project Jest setting becomes unambiguous. Heavier
context-switching.

## Recommendation

- **Option 3** (`jest.config.mjs` re-export) for a durable, IDE-agnostic fix.
- Fall back to **Option 2** saved configs for the integration variants that can't share a default name.

Both avoid touching test code.
