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
  template, line/block, `age = true` marking src as age-encrypted —
  controller-decrypted and shipped as plaintext inside bundles,
  decrypted in-process on `--direct`, byte-exact either way —
  mode/owner/group), `servicemod` (systemctl state/enablement
  plus unit file management: `src` verbatim copy, `template` rendering
  with the entry's local `vars`, written to /etc/systemd/system with
  daemon-reload on drift), `packagemod` (apt), `checkmod` (run +
  exit_status/output assertions behind the `check` directive),
  `accounts.d` (groups + users via
  shadow-utils), `composemod` (Docker Compose stacks keyed by project
  dir: read-only probes — container runtime/health via `docker ps`/
  `docker inspect` labels, config drift via `docker compose config
  --hash` vs the container's config-hash label — then `up --detach`/
  `stop`/`down` with the pull/build/recreate/wait policy flags)
- Directives → module names are wired in `models.d` (`addJob` over the
  ordered Pravic statements): keys are targets, `path`/`dir`/`name` is
  injected, duplicate/cycle detection comes free — modules never
  re-implement those
- Idempotence is probe-then-act: inspect current state read-only
  (stat/getent/dpkg-query/systemctl), act only on drift, report
  `changed` truthfully; `ok` when already conformant
- Check mode: probes run, mutations go through `mustRun` (suppressed in
  check mode, i.e. the `check` command); `check`-directive jobs are
  checks by nature and run even in check mode, never reporting
  `changed`
- All shell input through `shQuote`; multi-step remote changes prefer
  one command over dribble; errors must name what failed and why
  (actual status/output, not just exit codes)

# Work Guidance

- Relative paths (`src`, `template`, execute `run`) resolve against the
  defining tasks file's directory (`TaskContext.tasksFileDir`)
- File content compares by sha256 when possible (only the hash crosses
  the transport); `src` copies bytes, not text
- New expectation/param shapes are validated at load time for early
  typo detection, then re-checked at run time

# Verification

- Every module carries unittests against the scripted fake transport
  (creation, drift repair, removal, idempotence, every error path)
- End-to-end on the `testing.internal` VM over ssh for anything
  touching real system state; leave the VM as found
- `dub build` compiles; `dub test` runs all module unittests (must pass, 19 modules)

# Child DOX Index
(none — individual `.d` files are not durable boundaries)
