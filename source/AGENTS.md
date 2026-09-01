# Purpose

The D implementation of tachy: everything between the command line and the
hosts. `source/app.d` is the CLI (argument parsing, `--help`); the
`source/tachy/` package is the engine.

# Ownership

Owned by the root rail (build, task loop, doc trio, VM verification).
This doc owns the source tree's structure and conventions;
`source/tachy/modules/AGENTS.md` owns job modules.

# Local Contracts

- Layering, top-down:
  - `app.d` — CLI surface only; delegates to `runner.d`
  - `runner.d` — per-host orchestration; direct mode and bundled mode (default: the tasks file's parent directory is the project, copied with the tachy binary to each host and run there with `--direct --events`); the job loop produces `JobEvent`s consumed by one renderer
  - `inventory.d` — hosts, tags, `[vars]` (global < host precedence)
  - `models.d` — tasks-file composition (`[includes]` before own jobs, `[apply]` after), the fixed per-file job order, duplicate-target and cycle detection, `[before.G]`/`[after.G]` hooks
  - `events.d` — execution events (producer/consumer split): `JobEvent` + builders, `foldCounters`, `TextRenderer` (the one renderer for both modes), NDJSON `eventLine`/`parseEventLine` for the stream between inner runs and the controller
  - `vars.d` — variable scopes, `{ env, default, from }` resolution (environment or dotenv file), `{{ expr }}` templating
  - `value.d` — `Val` trees, `loadToml` plus its preprocessing passes (`joinInlineTables`, `quotePathKeys`), validated accessors
  - `transport.d` — `local` and `ssh` transports (abstract class; `runStreaming` delivers output lines live — POSIX `read`, not buffered `rawRead`, so streams are not batched), `shQuote`, stat helpers
  - `project.d` — project bundles, generated one-host inventory, Val → TOML serialization
  - `errors.d` — `TachyError`, the single error type surfaced to users
  - `modules/` — job modules (own child doc)
- All configuration becomes `Val` trees at load; nothing downstream depends on the toml library
- Errors carry file context (`"<file>: <section> \"<key>\": ...`) and are raised at load time wherever possible, before any host is contacted
- The event stream (`eventLine`/`parseEventLine`) is the internal protocol between inner runs and the controller; changes must round-trip and keep `--direct` and bundled output identical — byte-compare both before/after any renderer or event change
- Deterministic everywhere: job lists sorted by key, directives processed sorted by path, hosts in selection order; per-host failure isolation (a failing host is dropped, others continue, exit 1)
- Anything user-visible ships with its three doc updates (`--help` in `app.d`, `README.md`, `DOCUMENTATION.md`) and unit tests

# Work Guidance

- Follow the existing file's style: module doc comment stating purpose and semantics, private helpers below, `version (unittest)` blocks with local `writeTemp`-style fixtures at the end
- `@trusted` only where the boundary demands it (file/process IO wrappers); keep pure/@safe elsewhere
- No new abstractions around `Val`/`Job` — extend the existing accessors (`optString`, `optTable`, `checkKeys`) and registries instead
- `loadToml` may only gain preprocessing that is exactly equivalent to valid TOML (see `joinInlineTables`, `quotePathKeys`); anything ambiguous is left for the parser to reject
- Linux/amd64 only for bundled mode (the controller copies its own executable); hosts need GNU coreutils + tar

# Verification

- `dub build` compiles; `dub test` runs all module unittests (must pass, 13 modules)
- End-to-end: bundled local runs for quick checks; the `testing.internal` VM over ssh for real-host verification (read-only or `/tmp`-scoped, clean up after)

# Child DOX Index

- `source/tachy/modules/AGENTS.md` — job modules: registry, idempotence and check-mode contracts, per-module testing
