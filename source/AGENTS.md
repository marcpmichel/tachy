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
  - `app.d` — CLI surface only (command word: apply/check/hosts/
    generate/webui/webdoc/man/version/help; `help` prints the short
    form, `man` the full manual, man-page style — the text blocks live
    in `assets/*.txt` and are embedded with `import()`, one source for
    both outputs; the `version` command prints the build date from
    `assets/version`, maintained by dub's preBuildCommands — D
    reserves `version`, so the symbol is `tachyVersion` and the enum
    member `Cmd.showVersion`); delegates to `runner.d`, `generate.d`,
    `web.d` and `webdoc.d`
    - Asset prose is authored as single logical lines (one per
      paragraph or table entry) — no hard wrap at 80 columns; the
      terminal wraps. Code examples and their aligned comment columns
      stay hand-formatted. README's "CLI reference" block is kept
      byte-identical to `tachy help`.
  - `runner.d` — per-host orchestration and the read-only `hosts`
    command (`runHosts`: `hosts list [<selection>]` prints the former
    --list-hosts output — `all` when the selection is omitted,
    `hosts info <host>` one host's attributes
    plus effective vars, values via project.d's `pravicValue`);
    direct mode and bundled mode
    (default: the tasks file's parent directory is the project, copied
    with the tachy binary to each host and run there with `--direct
    --events`); the job loop produces `JobEvent`s consumed by one
    renderer; bundled mode also decrypts `age = true` file sources on
    the controller (`collectDecryptedFiles`) and ships the plaintext
    through the bundle — for applies deferred to an import landing it
    first shadow-composes the entry file in a staging mirror of the
    bundle layout (`makeStaging`, symlinks; removed after the tasks
    file)
  - `models.d` — tasks-file composition: Pravic statements in source
    order (`apply` composes its file at the statement's position;
    vars/import statements are file-wide, not jobs), duplicate-target
    and cycle detection, `import` collection with config search
    paths (bundled-mode external files; applies under an import
    landing missing locally defer to the host)
  - `events.d` — execution events (producer/consumer split): `JobEvent` + builders, `foldCounters`, `TextRenderer` (the one renderer for both modes), NDJSON `eventLine`/`parseEventLine` for the stream between inner runs and the controller
  - `vars.d` — variable scopes, `{ env, default, from }` resolution
    (environment or dotenv file), `{ run, stream }` command capture
    (stdout/stderr through /bin/sh in the declaring file's directory,
    where the loading process runs), `{ age }` secret markers
    (controller-side age decryption, inventory vars only), `{{ expr }}`
    templating, plus the age file helpers `file` sources use
    (`isAgeCiphertext`, `decryptAgeFile` — the same identity
    resolution and swappable decrypt hook)
  - `value.d` — `Val` trees, the Pravic parser (`loadPractic` →
    ordered statements, `file: line N:` errors, duplicate-key
    detection) and the validated accessors; the grammar is specified
    in the root `LANGUAGE.md` (a keyword registered in both forms —
    `identity` — takes its group form when a `{` follows)
  - `transport.d` — `local` and `ssh` transports (abstract class; `runStreaming` delivers output lines live — POSIX `read`, not buffered `rawRead`, so streams are not batched), `shQuote`, stat helpers
  - `http.d` — the minimal HTTP/1.1 client behind the `http` directive:
    plain TCP via std.socket (no libcurl, no external processes), plain
    `http://` only, one deadline bounding connect/send/receive
    (select(2)), bodies by Content-Length/chunked/close, capped size;
    methods and header entries are validated here at run time (the
    module pre-checks literal values at load time)
  - `project.d` — project bundles (project copy plus `import` sources
    under their base name, controller-decrypted `age = true` sources
    written over their ciphertext copies, generated one-host
    inventory), Val → Pravic serialization
  - `generate.d` — the `generate` command: age key pairs (`age-keygen`),
    sample tasks/config files (controller-side scaffolding; the sample
    texts are assets — `sampleTask.txt`/`sampleConfig.txt` — embedded
    with `import()` like app.d's help/man blocks)
  - `config.d` — the optional config.pravic (discovery: `--config`,
    `TACHY_CONFIG`, ./config.pravic, XDG; the `identity` age entry
    — both spellings, `effectiveIdentity` makes the `--identity` flag
    supersede it, wired once per entry point in runner.d/web.d —
    `imports` search paths and `webui` projects, strict validation)
  - `web.d` — the `webui` command AND the shared ad-hoc HTTP layer:
    a tiny server (thread per connection, `Connection: close`, a
    Router with `:param` segments — `Request`/`Response`/`Router`/
    `asset`/`bindListener`/`bindListenerAuto` (the random-port
    default, [10000, 65534])/`webListener`/`serveForever` are public
    for `webdoc.d`) plus the run registry; each run spawns this binary
    as `tachy <mode> --events ...` and relays its NDJSON stream as
    Server-Sent Events (`/api/events/<id>`, resumable via
    `Last-Event-ID`, terminated by an `event: end` frame); child stderr
    and non-event stdout become `log` records. Both web commands try
    to open the bound URL in the local browser (`tryOpenBrowser`,
    `gio open`, best-effort). The browser application in `webui/`
    (plain index.html/app.js/app.css) is embedded at compile time with
    `import("...")` — no framework, no asset pipeline, one binary
  - `webdoc.d` — the `webdoc` command: serves the compiled-in
    DOCUMENTATION.md (embedded via the `.` string-import path) as a
    multi-page HTML site — `##` groups become menu groups (their page
    holds the intro), `###` become pages; a two-pass split registers
    every anchor first so internal links rewrite across pages; a
    small markdown-subset renderer (fences, pipe tables, bullet
    lists, inline code/bold/italic/links), styled by the webui's own
    `app.css` (one stylesheet for both sites; the doc rules scope
    under `body.webdoc`, so the docs share the console's dark theme);
    read-only, same `--address`/`--port` as the webui (random-port
    default, browser-open attempt)

- Errors carry file context (`"<file>: <section> \"<key>\": ...`) and are raised at load time wherever possible, before any host is contacted
- The event stream (`eventLine`/`parseEventLine`) is the internal protocol between inner runs and the controller (and the webui, which spawns `--events` runs); changes must round-trip and keep `--direct` and bundled output identical — byte-compare both before/after any renderer or event change
- Deterministic everywhere: job lists sorted by key, directives processed sorted by path, hosts in selection order; per-host failure isolation (a failing host is dropped, others continue, exit 1)
- Anything user-visible ships with its three doc updates (`--help` in `app.d`, `README.md`, `DOCUMENTATION.md`) and unit tests

- Follow the existing file's style: module doc comment stating purpose and semantics, private helpers below; the module's unit tests live in `tests/<module>.d` (module `tachy.tests.<name>`, fixtures local to the test file) — production modules carry no unittests, and every unittest block is named with a silly attribute, `@("what it checks")`, on the line before `unittest` (the runner prints these names)

- `@trusted` only where the boundary demands it (file/process IO wrappers); keep pure/@safe elsewhere
- No new abstractions around `Val`/`Job` — extend the existing accessors (`optString`, `optTable`, `checkKeys`) and registries instead
- the Pravic parser follows the root `LANGUAGE.md` grammar exactly; one
  statement per line, `file: line N:` error context, and duplicate
  directive keys within a file are parse errors (composition-wide
  duplicate targets stay loader errors)
- Linux/amd64 only for bundled mode (the controller copies its own executable); hosts need GNU coreutils + tar

- `dub build` compiles; `dub test` runs the test suite in `tests/` through the silly runner (must pass). The runner is threaded by default: tests must be parallel-safe — unique scratch directories, no cross-test shared state (see `freshDir` in `tests/filemod.d`); tests that read or mutate shared environment variables (HOME, AGE_IDENTITY, ...) hold the lock from `tests/envsync.d` around the whole span


# Child DOX Index

- `source/tachy/modules/AGENTS.md` — job modules: registry, idempotence and check-mode contracts, per-module testing
