# Purpose

The D implementation of tachy: everything between the command line and the
hosts. `source/app.d` is the CLI (command word dispatch, argument parsing,
`--help`); the `source/tachy/` package is the engine.

# Ownership

Owned by the root rail (build, task loop, doc trio, VM verification).
This doc owns the source tree's structure and conventions;
`source/tachy/modules/AGENTS.md` owns job modules.

# Local Contracts

- Layering, top-down:
  - `app.d` — CLI surface only (command word: apply/check/generate/
    webui/webdoc/man/help; `help` prints the short form, `man` the
    full manual, man-page style — shared text blocks, one source);
    delegates to `runner.d`, `generate.d`,
    `web.d` and `webdoc.d`
  - `runner.d` — per-host orchestration; direct mode and bundled mode (default: the tasks file's parent directory is the project, copied with the tachy binary to each host and run there with `--direct --events`); the job loop produces `JobEvent`s consumed by one renderer
  - `models.d` — tasks-file composition (`[includes]` before own jobs, `[apply]` after), the fixed per-file job order, duplicate-target and cycle detection, `[before.G]`/`[after.G]` hooks, `[import]` collection with settings search paths (bundled-mode external files; composition entries under an import landing missing locally defer to the host)
  - `events.d` — execution events (producer/consumer split): `JobEvent` + builders, `foldCounters`, `TextRenderer` (the one renderer for both modes), NDJSON `eventLine`/`parseEventLine` for the stream between inner runs and the controller
  - `vars.d` — variable scopes, `{ env, default, from }` resolution (environment or dotenv file), `{ age }` secret markers (controller-side age decryption, inventory vars only), `{{ expr }}` templating
  - `value.d` — `Val` trees, `loadToml` plus its preprocessing passes (`joinInlineTables`, `quotePathKeys`), validated accessors
  - `transport.d` — `local` and `ssh` transports (abstract class; `runStreaming` delivers output lines live — POSIX `read`, not buffered `rawRead`, so streams are not batched), `shQuote`, stat helpers
  - `project.d` — project bundles (project copy plus `[import]` sources under their base name), generated one-host inventory, Val → TOML serialization
  - `generate.d` — the `generate` command: age key pairs (`age-keygen`),
    sample tasks/settings files (controller-side scaffolding)
  - `settings.d` — the optional settings.toml (discovery: `--settings`,
    `TACHY_SETTINGS`, ./settings.toml, XDG; `[imports]` search paths
    and `[webui]` projects, strict validation)
  - `web.d` — the `webui` command AND the shared ad-hoc HTTP layer:
    a tiny server (thread per connection, `Connection: close`, a
    Router with `:param` segments — `Request`/`Response`/`Router`/
    `asset`/`bindListener`/`serveForever` are public for `webdoc.d`)
    plus the run registry; each run spawns this binary as
    `tachy <mode> --events ...` and relays its NDJSON stream as
    Server-Sent Events (`/api/events/<id>`, resumable via
    `Last-Event-ID`, terminated by an `event: end` frame); child stderr
    and non-event stdout become `log` records. The browser application
    in `webui/` (plain index.html/app.js/app.css) is embedded at
    compile time with `import("...")` — no framework, no asset
    pipeline, one binary
  - `webdoc.d` — the `webdoc` command: serves the compiled-in
    DOCUMENTATION.md (embedded via the `.` string-import path) as a
    multi-page HTML site — `##` groups become menu groups (their page
    holds the intro), `###` become pages; a two-pass split registers
    every anchor first so internal links rewrite across pages; a
    small markdown-subset renderer (fences, pipe tables, bullet
    lists, inline code/bold/italic/links) with `webdoc/doc.css`
    embedded like the webui assets; read-only, same
    `--address`/`--port` as the webui
- Errors carry file context (`"<file>: <section> \"<key>\": ...`) and are raised at load time wherever possible, before any host is contacted
- The event stream (`eventLine`/`parseEventLine`) is the internal protocol between inner runs and the controller (and the webui, which spawns `--events` runs); changes must round-trip and keep `--direct` and bundled output identical — byte-compare both before/after any renderer or event change
- Deterministic everywhere: job lists sorted by key, directives processed sorted by path, hosts in selection order; per-host failure isolation (a failing host is dropped, others continue, exit 1)
- Anything user-visible ships with its three doc updates (`--help` in `app.d`, `README.md`, `DOCUMENTATION.md`) and unit tests

# Work Guidance

- Follow the existing file's style: module doc comment stating purpose and semantics, private helpers below, `version (unittest)` blocks with local `writeTemp`-style fixtures at the end
- `@trusted` only where the boundary demands it (file/process IO wrappers); keep pure/@safe elsewhere
- No new abstractions around `Val`/`Job` — extend the existing accessors (`optString`, `optTable`, `checkKeys`) and registries instead
- `loadToml` may only gain preprocessing that is exactly equivalent to valid TOML (see `joinInlineTables`, `quotePathKeys`); anything ambiguous is left for the parser to reject
- Linux/amd64 only for bundled mode (the controller copies its own executable); hosts need GNU coreutils + tar

# Verification

- `dub build` compiles; `dub test` runs all module unittests (must pass, 18 modules)

# Child DOX Index

- `source/tachy/modules/AGENTS.md` — job modules: registry, idempotence and check-mode contracts, per-module testing
