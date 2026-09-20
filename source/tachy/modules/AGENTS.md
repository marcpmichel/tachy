# Purpose

Job modules: the idempotent "ensure" executors behind every tasks-file
directive. Each module owns one resource kind and is dispatched with
rendered params against one host.

# Ownership

Owned by `source/AGENTS.md` (tree structure, doc trio, verification).
This doc owns module-level contracts.

# Local Contracts

- Registration in `package.d`: `moduleNames`, `validateModuleParams`
  (static key/type checks at load time) and `runModule` (dispatch);
  `fake.d` is the scripted transport for unittests — a new module is
  not done until it is in all three plus `models.d`
- Modules: `filemod` (files/directories: state, content, src,
  template, line/block, the entry's local `vars` merged over the host
  scope for `template` rendering (like `service`), `age = true` marking
  src as age-encrypted — controller-decrypted and shipped as plaintext
  inside bundles, decrypted in-process on `--direct`, byte-exact either
  way — mode/owner/group), `servicemod` (systemctl state/enablement
  plus unit file management: `src` verbatim copy, `template` rendering
  with the entry's local `vars`, written to /etc/systemd/system with
  daemon-reload on drift), `packagemod` (apt), `repomod` (git checkouts behind `repo`: cloned when
  the path is not a repository, `url` enforced on the `origin` remote,
  `fetch --prune` refresh — remote-tracking refs only, so it runs in
  check mode like a probe — `branch` checkout + ff-only fast-forward,
  `tag` detached checkout; diverged branches error, never rewritten), `ensuremod` (run +
  exit_status/output assertions behind the `ensure` directive, with
  `args` — quoted literal arguments appended space-separated to
  `run`, one element one argument),
  `assertmod` (the `assert` directive: the rendered `value` tested
  against ensure's `output` shapes as expectation keys —
  `equals`/`contains`/`matches`, composed with `not`/`any`/`all`/`none`;
  controller-side over variables, no transport, a check by nature),
  `accounts.d` (groups + users via
  shadow-utils), `composemod` (Docker Compose stacks keyed by project
  dir: read-only probes — container runtime/health via `docker ps`/
  `docker inspect` labels, config drift via `docker compose config
  --hash` vs the container's config-hash label — then `up --detach`/
  `stop`/`down` with the pull/build/recreate/wait policy flags),
  `httpmod` (the `http` directive: one request through the in-process
  client in `tachy.http` — no transport, no curl — asserting on the
  status and body; a check by nature, so it runs even in check mode
  and never reports `changed`), `debugmod` (the `debug` directive: the
  statement key is the message, printed as the job line; no attributes,
  no transport, never fails and never reports `changed`, runs in check
  mode like the other checks by nature)
- Directives → module names are wired in `models.d` (`addJob` over the
  ordered Pravic statements): keys are targets, `path`/`dir`/`url`/`name`
  is injected, duplicate/cycle detection comes free — modules never
  re-implement those
- Idempotence is probe-then-act: inspect current state read-only
  (stat/getent/dpkg-query/systemctl), act only on drift, report
  `changed` truthfully; `ok` when already conformant
- Check mode: probes run, mutations go through `mustRun` (suppressed in
  check mode, i.e. the `check` command); `ensure`-, `assert`-, `http`-
  and `debug`-directive jobs are checks by nature and run even in check
  mode, never reporting `changed`
- Command output: `mustRun`/`mustRunWithInput` and `ensuremod` capture
  a command's stdout and stderr into the job's `details` (the event
  payload `-v` displays) as `stdout: `/`stderr: ` excerpts — empty
  streams add nothing, check mode captures nothing (commands don't
  run), and the excerpts share the error-message cap
- All shell input through `shQuote`; multi-step remote changes prefer
  one command over dribble; errors must name what failed and why
  (actual status/output, not just exit codes)

# Work Guidance

- Relative paths (`src`, `template`, execute `run`) resolve against the
  defining tasks file's directory (`TaskContext.tasksFileDir`)
- `httpmod` never touches the transport: it queries through
  `tachy.http` from the process running the job (the managed host in
  bundled runs, the controller for `--direct`), so its unittests run
  against the in-process listener in `tests/http.d` (`OneShotServer`)
  instead of the scripted fake transport
- File content compares by sha256 when possible (only the hash crosses
  the transport); `src` copies bytes, not text
- New expectation/param shapes are validated at load time for early
  typo detection, then re-checked at run time

# Verification

- Every module carries unittests covering creation, drift repair,
  removal, idempotence and every error path — against the scripted
  fake transport, or against the in-process listener for `httpmod`
- End-to-end on the `testing.internal` VM over ssh for anything
  touching real system state; leave the VM as found
- `dub build` compiles; `dub test` runs all module unittests (must pass)

# Child DOX Index
(none — individual `.d` files are not durable boundaries)
