
1. remove the "group" concept and replace by tags on each host
   - `inventory.d`: `[groups]` parsing, nested `children`, closures and cycle
     detection are gone; hosts take `tags = [...]`; selection by `#tag`
     (unknown tags list the known ones); var precedence is now global < host.
2. inventory.toml should be the default (with the optional '-i' still there
   to point to another inventory file) and the first parameter to the tachy
   command should be the hosts selection (comma separated list of hosts
   identifications declares with [hosts]) or tags (command separated list of
   identifiers preceded by '#').
   - CLI is now `tachy [options] <selection> <tasks.toml>...`; selection is
     host names, `#tags` or `all`, freely mixed and comma-separated;
     `inventory.toml` stays the default for `-i`. `--limit` was removed as
     the selection now covers it.
3. instead of "[[tasks]]" entries, use explicit "[files]", "[directories]",
   "[services]"
   Ensure the toml expressiveness of either using
   ```
   [files."/tmp/myfile"]
   owner = "root"
   mode = "0600"
   ```
   or
   ```
   [files]
   "/tmp/myfile"={ owner="root", mode="0600" }`
   ```
   - Tasks files are now keyed tables; the path/unit is the table key and
     both spellings are accepted (verified against the TOML library).
     Deterministic order: files, directories, services, each by key;
     duplicate targets anywhere in a composition are a load-time error.
4. remote the concept of [requirements] and keep only the concept of tasks
   (which are lists of idempotent atomic "ensure" jobs).
   ```
   [includes]
   "tasks/one.toml" = { var1:"value1", var2:"value2" }
   ```
   or
   ```
   [includes."tasks/one"]
   var1 = "value1"
   var2 = "value2"
   ```
   - Requirements are gone; any tasks file may `[includes]` other task files,
     each include binding its own variables. Scopes chain
     (outer < include vars < included file's [vars]) and flow forward, so
     the includer's own jobs can use variables from its includes.

5. In the <selection> argument of the command-line (list of hosts or tags):
   change the tag identification character from '#' to '@' (because, as
   noted, the shell interprets '#' as a comment).
   - Tags are now selected with `@web`; a `#web` selector is treated as a
     host name and reported unknown. CLI help, README and tests updated
     (the "remember to quote #tags" warning is gone).
6. [apply]: add the "apply" directive, doing the same thing as the
   "include" directive but respecting the order of execution of the
   directives in the task files.
   - `[apply]` composes exactly like `[includes]` (per-entry variable
     binding, scopes chaining and flowing forward) except for timing:
     includes run before the file's own jobs (prerequisites), applies run
     after them — execution order is now includes, then own jobs (files,
     directories, services; by key), then applies; each list sorted by
     path. Both directives share cycle and duplicate-target detection
     ("composition cycle").
7. [file]: add the "line" and "block" attributes to the file directive:
   ensure a given line/block is present in the target file. "line" and
   "block" are mutually exclusive and also exclusive with "content"
   and "src".
   - state=file only (rejected otherwise). Presence is checked line by
     line: `line` needs one whole-line match, `block` a contiguous run
     of its lines; a missing line/block is appended, newline-terminated
     (fixing a missing final newline if needed). Idempotent, check-mode
     safe; mode/owner/group still apply afterwards.
8. Introduce the concept of "project": in the command-line, take note of
   the parent directory of the task file passed as an argument and copy it
   to the host (in a temporary location) as a 'project' directory. The
   tachy binary should be also copied along and executed there (either
   remotely or locally). If no task file is passed, assume "main.toml".
   - The parent directory of each tasks file is its project. Per host,
     `project.d` deploys a temporary bundle via the host's transport
     (`mktemp -d` under `TMPDIR`): a tar-stream copy of the project, a
     copy of the running tachy binary (`cat > tachy` + `chmod`) and a
     generated one-host local inventory carrying the host's effective
     variables (Val → TOML serializer, round-trip tested).
   - The copied binary then executes on the host (`cd project &&
     tachy --direct ...`) and applies the copied tasks file over a local
     connection — includes and `file.src` resolve inside the copied
     project. Check mode, verbosity and colors are forwarded; the inner
     run's per-job lines are relayed and its "ok changed failed" counters
     aggregated from a report file, so the output shape is unchanged.
   - Bundles are cached per (host, project) and removed after the run
     (also in check mode — the bundle is scaffolding, nothing managed is
     touched). Failing hosts are isolated as before; `--list-hosts` no
     longer needs a tasks file.
   - With no tasks file argument, "main.toml" is assumed (its parent
     directory — the working directory — is the project).
   - A project must be self-contained: includes escaping it are a
     controller-side load-time error with real paths; `file.src` outside
     the project fails at run time on the host. Linux/amd64 only for now
     (the copied binary is the controller's own executable; hosts need
     GNU tar alongside coreutils).
9. fix default taskfile name: if the second parameter to the cli is a
   directory, look for a file named "tachy.toml" in this directory
   otherwise use the filename provided as an entrypoint/main task.
   - `resolveTasksFiles` (runner.d, unit-tested): each positional
     tasks-file argument that is an existing directory resolves to
     `<dir>/tachy.toml`; anything else (including missing paths) passes
     through untouched and fails later with the usual read error.
   - The no-argument default changed from "main.toml" to "tachy.toml"
     in the current directory, so `tachy '@web'` and `tachy '@web' .`
     are equivalent, and `tachy '@web' ~/site` runs ~/site/tachy.toml
     with ~/site as the project.
   - CLI help, README (example layout now uses tachy.toml as the entry
     point) and the runner unittests updated; app.d just delegates.
10. [files]: add a "template" boolean attribute: render files loaded from
    src (e.g. `[files."/tmp/pouet"]` / `template = true` /
    `src = "templates/pouet.tmpl"`), interpolating variables before
    rendering the file on the target.
   - `template` requires `src` and state=file, and is mutually exclusive
     with `content` (always rendered anyway) and `line`/`block`; type-
     checked as a boolean. `template = false` (or absent) keeps the
     verbatim copy semantics.
   - `TaskContext` now carries the job's rendered variable scope; the
     file module renders the src content with `renderTemplate` before
     comparing/writing, so idempotence, drift repair and check mode
     compare against the rendered form. Rendering happens on the host
     (bundled mode) against the same scope params use: host vars, global
     vars, include-chain vars and `{{ inventory_hostname }}` all resolve;
     unknown variables are hard errors naming the src path.
   - Unittests cover rendering (scalars, nested tables, floats),
     idempotence, scope drift, verbatim src, check mode and all
     combination errors; end-to-end verified through a bundled local
     run. CLI help and README updated.
11. revert to use main.toml instead of tachy.toml for the default
    taskfile name.
   - `resolveTasksFiles` maps a directory argument to `<dir>/main.toml`
     and the no-argument default back to "main.toml" in the current
     directory; runner unittests updated. CLI help and README use
     main.toml as the entry-point convention again (item 8's original
     default).
12. change the "template" attribute: it now takes a file path instead of
    a boolean. In the file directive, "src" *copies* the file verbatim;
    "template" *renders* the named file onto the destination.
   - `template` is a string path resolved like `src` (absolute or
     relative to the defining tasks file); its content is rendered with
     the job's variable scope (host vars, globals, include chain,
     `{{ inventory_hostname }}`) and used as the managed content, so
     idempotence/drift/check mode compare against the rendered form.
   - `content`, `src` and `template` are now three mutually exclusive
     content sources; `template` is also exclusive with `line`/`block`
     and rejected for state=link/directory/absent. A boolean value is a
     type error ("'template' must be a string, not a boolean").
   - Unittests cover rendering, scope drift, verbatim `src` alongside,
     undefined-variable and missing-file errors, check mode and all
     combination errors; verified end-to-end through a bundled local
     run. CLI help and README updated (example now uses
     `template = "files/index.tmpl"`).
13. allow the variables declared in [vars] to read environment variables:
    `[vars]` / `something = { env = "SOMETHING" }` stores the content of
    environment variables into tachy's own variables. Amended: an
    optional `default` covers an unset variable —
    `myvar = { env = "MYVAR", default = "my var default" }` — and it
    only errors when there is no value and no default.
   - `resolveEnvVars` (vars.d, unit-tested): a `[vars]` entry that is
     `{ env = "NAME" }` (optionally with `default = "..."`, and nothing
     else) is replaced by that environment variable's value when the
     table is consumed; an unset variable falls back to `default`.
     Applied to inventory globals, per-host vars (inventory.d) and
     tasks-file `[vars]` (models.d). Nested tables are walked; scalars
     and arrays pass through; set-but-empty variables resolve to the
     empty string (the default only covers an unset variable, so an
     empty value is still a value). A table holding `env` plus
     unrelated keys stays a plain nested table.
   - Resolution happens in the environment of the process that reads
     the table: inventory vars on the controller (resolved values are
     shipped to hosts in the generated bundle inventory), tasks-file
     vars on the host in bundled runs (so one project can pick up
     per-host values); identical machine for local hosts and --direct.
   - An unset variable without a default is a hard error naming the
     file, the entry and the variable ("vars.x: environment variable
     'X' is not set"), raised before any host is contacted for
     inventory vars and at composition load for tasks-file vars.
   - Unittests in vars.d/inventory.d/models.d (resolution, nesting,
     default semantics — value wins, default covers unset, empty value
     is not the default, non-string default type error, `env`-plus-other-
     keys stays a table — arrays untouched, error contexts); verified
     end-to-end through a bundled local run (global, host and
     tasks-file env markers all render into managed content). CLI help
     and README updated.
14. add the "execute" directive: execute a remote shell script and check
    the exit status and/or the output.
   - New `execute` module (modules/executemod.d), a fourth job kind:
     `[execute]` entries keyed by a unique task name, both TOML
     spellings, injected `name` param, run after files/directories/
     services in the deterministic order, subject to duplicate-name and
     cycle detection like every other resource.
   - `run` (required, templated like every string param) executes
     through the host's transport. `exit_status` accepts an integer
     (default 0), `{ not = N }` or `{ cond = "OP N" }` with OP one of
     == != < <= > >= (so ranges like `cond = "< 1"` and negations are
     expressible); `output` accepts a string (exact match on the
     whitespace-trimmed output), `{ contains = "..." }` or
     `{ matches = "regex" }` (std.regex, invalid patterns rejected at
     load time). Expectation shapes are validated at load time for
     early typo detection.
   - A passing job reports `ok` and never `changed`; a failed assertion
     fails the host with the actual status and an excerpt of the output
     (e.g. "exit status 9, expected < 5", "output 'manjaro' does not
     satisfy exactly \"debian\""). Execute jobs are checks by nature and
     run even in check mode (documented: keep mutating commands out);
     `-v` shows the command and trimmed output.
   - Unittests in executemod.d (all expectation forms, pass and fail
     messages, parse errors) and models.d (spellings, ordering, name
     injection, duplicate/missing-run/unknown-key/bad-shape errors);
     verified end-to-end through bundled local runs including the
     "check if debian" example shape, failure isolation (host dropped
     after a failed assertion) and check mode. Amended after user
     feedback: the multi-line inline-table spelling
     (`"name" = {` ... `}` across lines) is now accepted and is exactly
     equivalent to the sub-table spelling — `joinInlineTables`
     (value.d, unit-tested) rewrites newlines inside unclosed inline
     tables into element separators before parsing (string-, comment-
     and brace-aware, inserting commas only where a separator is
     needed), for every file tachy loads (inventory and tasks). A
     genuinely unterminated inline table now reports "unterminated
     inline table (missing '}') opened around line N" with the file
     context instead of the parser's cryptic "Key is empty or contains
     invalid characters". CLI help and README updated.
   - Follow-up: `run` now executes with the defining tasks file's
     directory as its working directory (`cd <dir> && <run>`, like
     `file.src`), so relative script paths resolve next to the
     declaring file instead of the project root; unittest and bundled
     E2E cover it. Help and README updated.
15. add the [groups] and [users] directives: account management through
    the standard shadow-utils commands (groupadd, groupmod, groupdel,
    useradd, usermod, userdel), as specified.
   - New `group` and `user` modules (modules/accounts.d), fifth and
     sixth job kinds. `[groups]` entries: `state` (default present,
     absent removes). `[users]` entries: `group` (primary, default a
     group named after the user), `groups` (supplementary, ADDITIVE —
     only missing memberships are added), `shell` (default /bin/sh at
     creation), `comment`, `create_home` (default true, creation only:
     useradd -m/-M), `home` (default /home/<name> at creation),
     `state` (default present), `remove_home` (default false, only
     with state=absent: userdel -r). Both TOML spellings, unique-name
     keys, duplicate/cycle detection, load-time key and literal-state
     validation like every other resource.
   - Idempotence: existence is probed with `getent` (a single passwd
     getent doubles as the existence probe and the attribute source).
     Missing accounts are created with one useradd/groupadd; existing
     users have their explicitly set attributes enforced with a single
     usermod (home drift uses `-m -d`, which moves the home); unset
     attributes only shape creation. An explicit primary or
     supplementary group that does not exist is a clear error pointing
     at [groups]. groupdel of a group that is still a primary group
     fails with shadow-utils' message plus a hint (remove the user in
     an earlier tasks file). Groups run before users in the
     deterministic order (files, directories, groups, users, services,
     execute).
   - Unittests with the scripted fake transport cover creation
     (defaults and full attributes), drift repair (shell, comment,
     primary group, home, additive groups), removal (with and without
     remove_home) and every error path. Verified end-to-end on a real
     Debian 12 VM over ssh (root@testing.internal): full project run
     creating group+user+templated file+execute check, idempotent
     second run, drift repair (shell+comment in one usermod), check
     mode, two-file teardown (userdel -r then groupdel), VM state
     inspected via getent, and the wrong-order purge hint. Note for
     execute checks: Debian's /bin/sh is dash — use `.` not `source`.
     CLI help and README updated.
16. change on [apply]: add the vars attribute to the [apply] directive —
    `[apply."files.toml"]` / `vars = { three = "three" }` passes the
    "three" variable to the applied file's context.
   - `processDirective` (models.d, shared by `[includes]` and `[apply]`,
     so both spellings work symmetrically): a directive entry may carry
     its bindings directly (existing behaviour, unchanged) and/or
     grouped under a `vars = { ... }` sub-table; the two are merged
     (nested tables deep-merge). Binding the same variable both
     directly and under `vars` is an ambiguity error; a non-table
     `vars` is a type error. The sub-table is unwrapped, so it never
     leaks into the applied scope as a "vars" variable.
   - Unittests cover the sub-table binding (scalars and nested tables),
     merging with direct bindings, the includes spelling, unwrapping
     and both error paths. Verified end-to-end on the Debian 12 VM over
     ssh with the TODO's exact shape: the applied file rendered
     `{{ three }}` into managed content and an [execute] check inside
     it echoed the variable; own jobs still run before applies;
     idempotent second run. CLI help and README updated.

17. add the [packages] directive. its purpose is to install or remove
    system packages.
   - New `package` module (modules/packagemod.d), keyed by
    `"<manager>:<name>"` (only "apt" implemented; other managers and
    colonless/empty-name keys are load-time errors via
    `validatePackageKey` for literal keys). Both TOML spellings;
    `version` (default "latest") and `present` (default true; false
    removes) validated at load time.
   - State is probed read-only with `dpkg-query -W -f='${Status}
    ${Version}'` (non-zero or "deinstall ok config-files" counts as
    missing). Mutations all run through `mustRun` (check-mode safe):
    missing -> `DEBIAN_FRONTEND=noninteractive apt-get install -y
    '<pkg>'` (or `'<pkg>=<version>'` when pinned); pinned but installed
    version differs -> same with `--allow-downgrades`; present=false ->
    `DEBIAN_FRONTEND=noninteractive apt-get remove -y '<pkg>'`.
    "latest" only ensures presence (no per-run candidate check);
    explicit versions compare exactly against dpkg's ${Version}
    (epoch-qualified).
   - Job order is now directories, files, packages, groups, users,
    services, execute — directories were also moved ahead of files so a
    file can live inside a directory the same tasks file manages
    (previously such a run could never converge: the file job failed
    before its parent directory was created). CLI help and README
    updated.
   - Unittests with the scripted fake transport cover install and
    idempotence, config-files-counts-as-missing, version pinning (both
    branches), removal, and key/param errors. Verified end-to-end on
    the Debian 12 VM over ssh (root@testing.internal): install of tree
    and bc (both spellings), dpkg-query state inspection, idempotent
    re-run, exact-version pin, bogus-pin failure relaying apt's
    message (exit 1), present=false removal and idempotence, and check
    mode leaving the VM untouched; VM and scratch cleaned up after.
   - Follow-up fixes from the docker-ce use case: `src` now copies bytes
    (a binary keyring used to fail readText's UTF-8 validation) and file
    content is compared by sha256 checksum instead of reading the whole
    target back — only the hash crosses the transport; `line`/`block`
    still need the real content. Unittest covers byte-exact copy,
    checksum idempotence and binary drift repair; verified on the VM
    with the real Docker GPG key.

18. [vars] directive change: add a "from" attribute that looks up the
    variable named by 'env' in the dotenv file named by 'from' —
    `[vars]` / `secret_var = { env = "SECRET_VAR", from = ".env" }`;
    the "default" attribute still applies in this context.
   - `resolveEnvVars` (vars.d): an env marker may now also carry
    `from = "<path>"`. With `from` the value is looked up in that
    dotenv file instead of the process environment (the environment is
    not consulted — verified with the variable set in the process to a
    different value); without `from`, behaviour is unchanged. The
    `from` path resolves like every other file reference: absolute, or
    relative to the directory of the declaring inventory/tasks file.
    A set-but-empty entry is a value; `default` covers a key the file
    does not define; neither value nor default is a hard error naming
    the file, the entry, the variable and the resolved dotenv path
    ("vars.secret_var: environment variable 'X' is not set in
    '<path>'"); a missing/unreadable file errors the same way. `env`,
    `default` and `from` must be strings; a table mixing `env`/`from`
    with unrelated keys is still a plain nested table. Each file is
    parsed once per [vars] table (per-call cache).
   - dotenv format (`parseDotenv`): KEY=VALUE lines, `#` comments,
    blank lines, optional `export ` prefix, whitespace around keys and
    unquoted values trimmed; single-line quoted values — double quotes
    process the \n \t \r \f \b \" \' \\ escapes, single quotes are
    literal; a `#` at the start or after whitespace ends an unquoted
    value but stays part of the value otherwise; an empty value is a
    value; later keys win; malformed lines (missing '=', whitespace in
    keys, unterminated quotes, unknown escapes, junk after a quoted
    value) are errors naming file and line.
   - Where it runs is unchanged: inventory vars resolve on the
    controller, tasks-file vars in the process that loads them (the
    host, in bundled runs) — with `from` the file is read in that same
    place, so a bundled tasks file's dotenv must live inside the
    project (the bundle copies it along).
   - Unittests in vars.d (resolution, quoting/escapes, export prefix,
    comments, trailing comments, '#' inside values, duplicates,
    nesting, subdirectory and absolute paths, default/empty
    semantics, environment-ignored-with-from, and every parse error
    with file:line context), models.d and inventory.d (load-time
    integration for tasks files and inventories). Verified end-to-end
    through bundled runs: local host with the TODO's exact example
    shape (quoted value, default for a missing key, idempotent re-run,
    drift repair after rotating the value, check mode, hard error and
    exit 1 for a key without default) and over ssh on the Debian 12 VM
    (root@testing.internal: same project, `{{ inventory_hostname }}`
    rendered per host, idempotent second run, failure isolation of a
    host missing the parent directory, no leftover bundles). CLI help,
    README and DOCUMENTATION updated.

   - Follow-up from a user test (`tachy testing testing/main.toml`
     with `[files./tmp/some_secret.txt]`): TOML bare keys cannot
     contain `/` or `.`, so the natural header spelling was rejected
     with "Key is empty or contains invalid characters". New
     `quotePathKeys` pass (value.d, unit-tested) rewrites table
     headers before parsing: the first segment that is neither a bare
     key nor already quoted starts the target, everything from there
     to the end of the header merges into one double-quoted key (the
     dots belong to the path) — `[files./tmp/some_secret.txt]` ==
     `[files."/tmp/some_secret.txt"]`, `[[...]]` headers likewise.
     Segments needing escapes (embedded quotes/backslashes/whitespace)
     are left for the parser to reject, and only header lines are
     touched: comments, strings (including multi-line) and values are
     copied verbatim. Wired into `loadToml` for every file tachy
     loads. The user's exact scenario then passed on the VM over ssh:
     inventory host var `{ env = "SECRET_VAR", from = ".env.testing" }`
     (double-quoted dotenv value), header-style path key and
     `template = "some_secret.tmpl"` rendering `{{ secret_var }}` —
     /tmp/some_secret.txt written with exactly "this is a secret",
     second run ok/changed=0, check mode agrees. CLI help, README and
     DOCUMENTATION updated.

19. hooks: add the [before.services], [after.services], [before.packages],
    [after.packages], [before.accounts] and [after.accounts] directives
    to trigger tasks at specific points — each considered as an
    "execute" directive (run, exit_status, output attributes).
   - `addHooks` (models.d): hooks are `[execute]`-style checks keyed by
    unique task name (both TOML spellings, `name` injected, full
    load-time validation of `run`/`exit_status`/`output`), wrapped
    around one job group. Groups: packages, accounts (both `[groups]`
    and `[users]`), services. Per-file execution order is now
    directories, files, [before.packages], packages, [after.packages],
    [before.accounts], groups, users, [after.accounts],
    [before.services], services, [after.services], execute — each list
    still sorted by key, includes still first and applies last.
    Hooks run at their group's position whether or not the group has
    entries, so a composition's entry file can health-check what its
    includes managed (an include's hooks stay inside the include).
   - Validation: `[before]`/`[after]` must be tables; only the three
    group keys are accepted (typo detection); hook names share the
    `[execute]` name space, so a duplicate anywhere in a composition is
    a load-time error; error contexts name the directive
    ("main.toml: after.services \"health\"").
   - Hooks are execute jobs in every other respect: checks by nature
    (run even in check mode, never report changed), the defining file's
    directory as working directory, `-v` shows command and output.
   - Unittests in models.d (exact interleaved ordering with all six
    hooks around real groups, hooks with empty groups, include scoping,
    both spellings, name injection, unknown group, duplicate with
    [execute], missing run, non-table [before]). Verified end-to-end on
    the Debian 12 VM over ssh: a project with all six hooks around a
    package, an (empty) accounts group and a service printed the exact
    interleaved order and passed; idempotent second run (ok=9
    changed=0); a failing [after.services] output assertion failed the
    host with the directive in the message and exit 1 while earlier
    jobs of the file stayed applied; check mode runs hooks. CLI help,
    README and DOCUMENTATION updated (execution order + a hooks
    section).

20. modify [services]: add both a "src" attribute and a "template"
    attribute to create/update the unit file of managed services (from a
    plain file or a template), plus a "vars" attribute for a local
    variable context (only meaningful with "template").
   - `servicemod.d`: `src` copies the unit file verbatim (binary-safe),
    `template` renders it with the host's variable scope merged with the
    entry's local `vars` table (local values win; `vars` values
    themselves may be templated, like every param). Paths resolve like
    `file.src` — relative to the defining tasks file. The unit file
    lives at /etc/systemd/system/<name> (".service" appended when the
    name has no suffix), is checksum-compared (sha256, only the hash
    crosses the transport) and, on drift, written and followed by
    `systemctl daemon-reload` — always before any state action, so a
    subsequent start uses the new definition. A running service is
    never restarted by a file change alone (use state = "restarted" to
    apply it); check mode reports the would-be write without touching
    the host. An entry may now manage only the unit file (no state/
    enabled required).
   - `state = "enabled"` (the TODO example's spelling) is a new state:
    ensure boot enablement without touching the running state (never
    queries is-active); contradicts enabled = false with a clear error.
   - Validation (package.d, load time): src/template mutually exclusive
    and strings; vars must be a table and requires template; allowed
    keys extended. State values re-validated at run time with "enabled"
    added.
   - Unittests: servicemod (template create with local-vars precedence
    and daemon-reload ordering, checksum idempotence, drift without
    restart, verbatim src, unit-file-only entries, enabled state both
    branches + contradiction, check mode records without executing,
    missing template file error) and models.d (the TODO's exact
    spellings, exclusivity, vars-without-template, non-table vars).
    Verified end-to-end on the Debian 12 VM over ssh (root@
    testing.internal): template service created+enabled+started with the
    local ttl winning over the host var (ExecStart=/bin/sleep 3600,
    User=root), src service enabled-but-never-started (inactive +
    enabled), [after.services] hook confirming active, fully idempotent
    second run, drift run updating the unit file while the service
    kept running, state="restarted" applying the new definition (new
    MainPID), check mode, and full VM teardown. CLI help, README and
    DOCUMENTATION updated; modules AGENTS.md contract refreshed (DOX).

21. rework output: separate task-execution data (and metadata like
    timing) from result rendering, producer-consumer style, so the host
    report displays each task as it finishes instead of the whole report
    at the end of the process.
   - New `events.d`: `JobEvent` (fileStart / job / fileDone) with
    builders, `foldCounters` (ok/changed/failed fold), `TextRenderer`
    (the classic text output — headers, padded colored job lines,
    `-v` details, check-mode footers — now the single renderer for
    both modes) and NDJSON serialization (`eventLine` /
    `parseEventLine`, flat JSON objects, strict parser, escaping incl.
    control chars and \uXXXX; non-event lines are refused so remote
    noise passes through, malformed event lines are errors).
   - `runner.d`: the job loops (direct and the controller's own
    failure lines) are producers — timing measured around `runModule`
    (`ms` per event), counters via `foldCounters`; direct mode renders
    in process (or serializes with `--events`); `printTask` and the
    per-mode header/footer duplication are gone. Bundled mode: the
    inner run executes with `--direct --events --direct-report`, its
    stdout is one JSON event per line, and the controller parses and
    renders each job line live as it arrives — header/footer/counters
    stay controller-owned (the report file is still written and read).
   - `transport.d`: `Transport` became an abstract class so
    `runStreaming(command, sink)` can carry a default implementation
    (batch `run` + split; FakeTransport inherits it) while local/ssh
    override with true incremental delivery — stdout lines on the
    calling thread, stderr on the drain thread, per-stream carry
    buffers, partial final lines flushed at EOF, full text still
    returned. Key fix found by testing: `File.rawRead` has fill-the-
    buffer (fread) semantics that batch a stream until EOF — the
    drains now use POSIX `read()` so lines are delivered as written.
   - `--events` is a documented machine mode (requires --direct);
    getopts, help, README and DOCUMENTATION updated ("What a run does"
    now describes the live rendering).
   - Unittests: events.d (golden renderer output incl. colors/padding/
    check suffix/details, counter fold, NDJSON round trip with
    escaping, malformed-line errors), transport.d (streamed lines
    arrive while the command runs — µs-stamped assertions, race-
    tolerant ordering, CommandResult unchanged). Output shape proven
    byte-identical before/after for six reference runs (direct,
    bundled, both -v, check×2, stdout+stderr) captured from the
    pre-change binary. E2E on the Debian 12 VM over ssh: each job line
    timestamped on the controller as its job finished (file lines at
    t≈6.86s, the 2-second execute's line exactly 2s later — not
    batched at the end), idempotent rerun, failing execute streaming
    its line with failure isolation intact (exit 1). DOX: source/
    AGENTS.md records events.d in the layering, the streaming
    transport contract and the event-protocol byte-compare rule.

   - Follow-up: `--events` no longer requires `--direct`. With
    `--direct` it keeps its meaning (the local run's own NDJSON
    events); without it, bundled mode displays the RAW event stream:
    each host's inner-run lines pass straight to stdout, live as they
    arrive (headers/footers suppressed, controller-side failures
    emitted as events, `--keep-bundle` notes moved to stderr so stdout
    stays machine-clean). Verified: both modes produce identical,
    all-valid-JSON streams locally; over ssh on the VM the raw events
    arrived live (2-second execute's event exactly 2 s after the
    file's); classic text output unchanged. Help, README and
    DOCUMENTATION updated.

22. secrets: age-encrypted variables — inventory `[vars]` entries of the
    form `db_password = { age = "secrets/db_password.age" }` are replaced
    by the decrypted content of the named file; ssh-key-as-identity
    default; no naming convention for `.age` files.
   - `resolveEnvVars`/`resolveEnvVal` (vars.d): an age marker is a table
    of exactly `{ age = "path" }` — combining it with `env`, `default`
    or `from` is an error (a failed decryption is an error, not an
    absent value). The path resolves relative to the declaring file;
    decryption happens where the marker is allowed, and one trailing
    newline (or CRLF) is stripped, so `echo secret | age -r … > f.age`
    files work as-is. Plaintext must be valid UTF-8 — binary secrets
    are rejected with a pointer at the future `secret =` file source.
   - Controller-side only: `AgeConfig` enables age markers, and only
    `Inventory.load(path, identity)` enables them (global and per-host
    vars). Tasks-file `[vars]` (which resolve on the host in bundled
    runs, where no identity may travel inside a bundle) reject the
    marker with an error explaining the split. The decrypted value
    reaches hosts through the generated per-host inventory, exactly
    like every other resolved inventory var.
   - Identity resolution (`resolveAgeIdentity`): `--identity PATH`
    (new long-only option), then the `AGE_IDENTITY` environment
    variable (an existing file path, or raw key material), then
    `~/.ssh/id_ed25519` — age accepts ed25519 ssh keys natively, so the
    controller's deployment key doubles as the decryption key
    (encrypt with `age -R ~/.ssh/id_ed25519.pub`). No identity → an
    error naming the three options.
   - `defaultAgeDecrypt` runs `age --decrypt` with key material fed to
    `/dev/stdin` (never written to disk; verified against age 1.3.1)
    and relays age's stderr on failure; the decrypt step is a swappable
    module-level hook (`ageDecrypt`) so the unittest suite needs no age
    binary. age is a controller-only dependency.
   - Unittests: vars.d (resolution, newline/CRLF stripping, nesting,
    every identity variant including material-vs-path and the ssh
    default via HOME, missing identity, wrong-identity failure relay,
    binary rejection, combination and type errors, tasks-file
    rejection), inventory.d (global+host resolution with context,
    failing decryption), models.d (rejection). E2E on the Debian 12 VM
    with real age 1.3.1: all four identity variants delivered the
    decrypted secret into a managed file over ssh (--identity,
    AGE_IDENTITY as path, AGE_IDENTITY as key material via stdin,
    default ssh key), mode enforced, idempotent rerun, and a
    wrong-identity run failing at load time with age's message before
    any host was contacted. CLI help, README (new "Secrets (age)"
    section) and DOCUMENTATION updated; source/AGENTS.md DOX pass.

   - Follow-up from `export AGE_IDENTITY=key.txt`: a relative AGE_IDENTITY
    resolves against the controller's cwd (works when running from the
    directory holding the key); a value that is neither an existing file
    nor recognizable key material (AGE-SECRET-KEY-1... or an ssh private
    key block — `isKeyMaterial`) is now a clear load-time error instead
    of being fed to age as material and failing with age's cryptic
    "unknown identity type". Unittest added; both cwd cases verified
    live.

23. add a command as the first argument to the binary: apply (perform
    the task, e.g. `tachy apply @web req/web`), check (check mode,
    replacing the `-c` option, e.g. `tachy check @web req/web`),
    generate (`tachy generate key key.txt`, `tachy generate task
    main.toml`) and help (the general help).
   - `app.d`: after option parsing the first positional is the command
    word (`parseCommand`, unit-tested — an unknown word is an error
    listing the four commands; `--check`/`-c` is gone from getopt and a
    unittest now asserts it is rejected). `apply`/`check` share the run
    path and differ only in check mode; options may appear before or
    after the command (getopt permutes). `generate` and `help` need no
    selection. The inner binary in bundles now runs `tachy apply|check
    --direct --events ...` (`innerTachyCommand`, unittest updated).
   - New `generate.d`: `generate key <path>` runs `age-keygen -o` (mode
    0600, refuses to overwrite, public key relayed, clear error when
    age-keygen is missing); `generate task <path>` writes a commented
    sample tasks file (loadable as-is — asserted through
    `loadTasksFile` in the unittest) and never overwrites. The sample
    uses `{{ admin }}`/`{{ inventory_hostname }}` templating in content
    so it runs unprivileged (no chown).
   - Follow-up found by the E2E: `runBundled` never called
    `removeBundle`, so every bundled run leaked its
    /tmp/tachy.XXXXXXXXXX bundle (16 stale dirs on the VM); the
    finally block now removes bundles unless `--keep-bundle`, as the
    docs always promised. Verified: 0 leftovers after VM runs, and
    `--keep-bundle` still keeps.
   - Verification: `dub build`, `dub test` (14 modules); locally —
    no-args/help/`help` identical, unknown command message, `-c`
    rejected, missing-selection error, generate arg/overwrite errors,
    bundled apply → changed, idempotent rerun → ok, check, drift
    repair, and a full age round-trip from `generate key` (secret
    encrypted to the printed public key, decrypted into managed content
    via `--identity` and `AGE_IDENTITY`); on the Debian VM over ssh
    (root@testing.internal) — apply/idempotent/check/drift through the
    ssh transport with the inner binary running the apply/check command
    words, no leftover bundles, VM and scratch cleaned. Help, README,
    DOCUMENTATION and the DOX chain (root CLI shape, source layering +
    module count, modules check-mode wording) updated.

24. add an [import] directive, valid only in bundled mode, that copies
    designated files or folders into the bundle before deployment
    (ex: `[import.tasks/install_gogs]` → `project/install_gogs`), so
    tasks external to the local project directory can be used on the
    remote target.
   - `models.d` (`addImports`): `[import]` entries are paths (both
    spellings; header path keys like `[import.tasks/install_gogs]` come
    free from quotePathKeys), resolved absolute like every path —
    `buildNormalizedPath(absolutePath(...))` relative to the defining
    tasks file — collected into `LoadedTasks.imports`, deduplicated.
    Entries take no parameters (strict: an unknown key is an error);
    imports are not jobs, not scope, not composition (an `[includes]`
    pointing at an imported path still errors as escaping the project).
   - `project.d` (`ImportSpec`, `checkImports`, `tarBundle`): sources
    are validated on the controller at deploy time — must exist, and the
    destination (the path's base name, per the TODO's example) may not
    collide with project content or another import (imports never
    overwrite anything). One tar archive carries the project plus each
    import from its absolute parent dir (successive tar -C options
    chain, so the -C arguments must be absolute — found live).
   - `runner.d`: bundled mode maps `loaded.imports` to ImportSpecs and
    deploys them with the bundle; the per-(host, project) bundle cache
    key now includes the import set signature. Direct runs (including
    the on-host inner run, where the copies already sit inside the
    project) parse and ignore the directive.
   - Unittests: models.d (header + inline spellings, dedupe, parameter/
    non-table errors, absolute resolution, no jobs created), project.d
    (import dir + file copied under base names, missing source,
    project-content collision, duplicate destinations — over the local
    transport). E2E locally: imported dir with a template and a script,
    template rendered from the imported copy, execute running it,
    idempotent rerun, check mode, both error messages, and `--direct`
    accepting-and-ignoring the directive (fails later on the missing
    template, as documented). E2E on the Debian VM over ssh
    (root@testing.internal): `src` copy from the imported directory,
    execute with `{{ gogs_port }}` templating asserting hostname+port,
    idempotent second run, check mode, no leftover bundles, VM and
    scratch cleaned. Help, README (directives table + self-containment
    wording), DOCUMENTATION (new "[import] — external files in the
    bundle" section) and source/AGENTS.md layering updated.

25. fix [import] + composition: an [includes]/[apply] entry whose path
    falls under a declared [import] destination failed controller-side
    validation ("cannot read ..."), because the imported tree only
    exists inside the bundle.
   - `models.d`: import landings (project root / base name of each
    import source) are accumulated through the load; `processDirective`
    now resolves entries absolute (the second relative-path trap: landings
    are absolute, so a cwd-relative match could never hit) and defers an
    entry that is under a landing and missing locally — recorded in
    `LoadedTasks.deferred`, not read, not in `sourceFiles`. When the
    file is readable locally it composes normally (exactly what the
    on-host inner run sees, where the import has landed).
   - Bundled mode therefore composes the deferred file on the host,
    with its directive binding, in its directive position (apply after
    own jobs); controller-side validation cannot see inside a deferred
    subtree — the on-host load catches errors there, failing only that
    host. A manual `--direct` run without a bundle skips deferred
    entries with one stderr warning each (`runner.d`, stderr so
    `--events` stdout stays machine-clean); the inner run never warns
    because its copies exist.
   - Unittest in models.d: deferral (entry job only, deferred recorded,
    file not read), local-presence composition (jobs + binding
    `flavor = "chocolate"` flowing), and missing-not-under-a-landing
    still a load error. E2E locally and on the Debian VM over ssh
    (root@testing.internal) with the reported shape —
    `[import."../tasks/install_gogs"]` + `[apply."install_gogs/gogs.toml"]`:
    entry jobs then the applied file's jobs, `{{ gogs_user }}` binding
    and `{{ inventory_hostname }}` rendered per host, execute check
    passing, idempotent rerun, check mode, drift repair inside the
    applied file, `--direct` skip warning, no leftover bundles, VM and
    scratch cleaned. Help, README ([import] row), DOCUMENTATION
    ("Composing imported tasks files" paragraph) and source/AGENTS.md
    updated.

26. add an optional settings.toml, read once at the start of every
    apply/check, holding the paths to look for [import] entries in
    (and, later, other settings).
   - New `settings.d` (`Settings`, `loadSettings`): discovery, first
    found wins — `--settings PATH` (new long-only option; must exist),
    the `TACHY_SETTINGS` variable (must exist), `./settings.toml`, then
    `$XDG_CONFIG_HOME/tachy/settings.toml` (default
    `~/.config/tachy/settings.toml`); with none found, settings are
    empty. The file is strict like every other: unknown keys, non-table
    `[imports]`, non-array/string `paths` are load-time errors with
    file context. Entries are `~`-expanded and resolve against the
    settings file's own directory when relative (never the cwd), so a
    settings file works from anywhere.
   - `models.d` (`resolveImportPath`, threaded through `loadTasksFile`
    as an optional parameter): an `[import]` key resolves as-is when
    absolute, as before relative to the defining file when it exists
    there, then through the search paths in order (first existing
    match); unresolved keys keep the defining-relative path, so the
    deploy-time existence check names it. Landings (and therefore
    composition deferral) key off the base name, so search-path
    resolution stays symmetric between controller and host — settings
    are a controller-side concern only.
   - `runner.d` loads settings once per run (both modes) and passes
    them to `loadTasksFile`; `generate.d` grew `tachy generate settings
    <path>` (commented sample, never overwrites, loadable as-is).
   - Unittests: settings.d (all four discovery routes plus absence,
    explicit/env-missing errors, tilde expansion, relative-to-file
    resolution, every parse error, empty [imports]), models.d
    (search-path resolution order: defining-relative wins, first
    existing search match next, unresolved keeps the guess, no-settings
    unchanged), generate.d (sample loads through loadSettings, no
    overwrite). E2E locally: cwd settings, TACHY_SETTINGS, --settings
    and XDG (absolute path — relative entries correctly anchor to the
    settings file's directory, verified failing then passing), search-
    path import driving a deferred [apply] with rendered bindings,
    idempotence, bad --settings error; on the Debian VM over ssh
    (root@testing.internal): settings on the controller, search-path
    import + deferred apply + execute check over ssh, idempotent,
    check mode, no leftover bundles, VM and scratch cleaned. Help,
    README (settings section, [import] row, invocations, layout),
    DOCUMENTATION (options row, Settings section, [import] cross-refs)
    and source/AGENTS.md layering (settings.d, 15 modules) updated.

27. fix: an imported task could still not be applied —
    `[apply."neovim"]` (naming the import destination itself) failed
    with "cannot read '.../neovim'".
   - Two gaps found. (1) `underImportLanding` matched only paths
    strictly under the landing, never the landing itself, so an entry
    naming the imported directory never deferred and the controller
    tried to read it. (2) Even deferred, the host would loadToml a
    directory: composition entries had no directory convention.
   - `models.d` (`processDirective`): the landing test now includes
    equality, and a composition entry that resolves to an existing
    directory names its `main.toml` — the same entry-point convention
    as a directory argument on the command line, for plain includes
    too, not just imports. (Also: `std.file.isDir` throws on missing
    paths in Phobos — guarded with `exists`.)
   - Follow-up found while verifying the reporter's `check` invocation:
    check mode on a not-yet-existing `[directories]` target with
    mode/owner failed the host instead of reporting a would-be change
    (`applyAttrs` probed the suppressed creation). It now folds the
    attrs into the reported creation in check mode (filemod.d,
    regression unittest for directory and file).
   - Unittests in models.d (landing-itself deferral, host-side compose
    through the directory's main.toml, plain non-import directory
    include). E2E with the reporter's exact shape — mytasks/main.toml
    with `[import."neovim"]` (resolved through settings search paths)
    + `[apply."neovim"]` where neovim/ is a directory holding
    main.toml: locally and over ssh on the Debian VM, `tachy check`
    (before creation: directory+file reported as changed (check)),
    `tachy apply` (jobs of the imported main.toml run with bindings and
    `{{ inventory_hostname }}`), check after, idempotent rerun, no
    leftover bundles, VM and scratch cleaned. Help, README
    (composition bullet, [import] row) and DOCUMENTATION (composition
    section, "Composing imported tasks files") updated.

28. include a webserver (the webui command-line option) that starts a
    local webserver that acts as a graphical version of the cli: the
    interface displays a list of projects/tasks folders and actions
    ("apply" and "check") can be performed on them with a nice display
    of the progress (events from the remote executor instance).
    [Notes: no existing webserver framework (no vibe.d), no existing
    web-application framework (no react), no asset compilation (no
    scss/typescript) — tiny ad-hoc frameworks instead; the web
    application files are embedded in the binary using D's
    `import("file.ext)` — everything in one binary.]
   - New `web.d` (the 16th module) — a few hundred lines of
     `std.socket`: a tiny ad-hoc HTTP framework (thread per
     connection, `Connection: close`, request/head/body parsing with
     caps, a Router with `:param` segments, streamed responses) plus
     the `WebApp`: routes `/`+`/app.js`+`/app.css` (embedded assets),
     `GET /api/state` (projects from settings, inventory hosts/tags —
     reloaded per call, load errors reported as a field —, run
     history), `POST /api/run` (flat-string JSON, strict validation:
     unknown/missing fields, unknown project, mode, selection sanity)
     and `GET /api/events/<id>` (SSE). Each run is this binary spawned
     through `LocalTransport.runStreaming` as
     `exec tachy <mode> --events -i <inv> [<opts>] <selection>
     <project>`; its NDJSON lines are parsed (`parseEventLine`) and
     relayed as SSE records (`{"ts",...,"ev":{...}}`), with stderr and
     non-event stdout as `log` records and a final `{"done","exit"}`;
     per-run registry (mutex + condition), server-side counter
     folding, replay via `Last-Event-ID`, 15 s keepalives, `event:
     end` frame so browsers do not reconnect to finished runs forever.
   - The web application (`source/tachy/webui/`: index.html, app.js,
     app.css — plain ES2020/CSS, a ~40-line `h()` dom helper is the
     whole "framework") embedded at compile time via
     `import("tachy/webui/...")` (`stringImportPaths` in dub.json).
     Projects sidebar (missing paths struck through), selection input
     with host/@tag chips, Check/Apply buttons, live events table
     (coloured statuses, per-job ms, file dividers/footers with
     counters, log lines), a verbose toggle (detail rows always in the
     DOM, CSS-unhidden), runs history with replay.
   - `--events` (bundled, no `--direct`) is now self-describing: the
     controller emits its fileStart/fileDone events into the stream
     (display() routes them through the raw serializer), and machine
     mode (`--direct-report`) filters non-job events in the events
     branch too — the inner run no longer duplicates the header/footer
     events it used to leak into the raw stream.
   - settings.toml gains `[webui] projects = [...]` (a directory is a
     project entered through its main.toml, a file is the entry point
     itself; resolved like imports paths; existence reported per
     project, not a load error); `tachy generate settings` sample
     updated. CLI: `tachy webui [--address ADDR] [--port PORT]` (new
     options; 127.0.0.1:8080 defaults, port 0 picks a free one); no
     positional arguments.
   - Unittests: web.d (parseHead incl. malformed inputs, router
     literals/params/404/405, parseStringObject happy/escape/error
     paths with jsonEscStr round-trip, Run folding + wire records +
     done-last, sseFrame, and a loopback server over an ephemeral
     port driving GET/POST/SSE/404/400 end-to-end), settings.d
     ([webui] resolution: relative-to-file, ~, absolute, alongside
     [imports], every wrong shape), app.d (webui command word, option
     registration incl. --address/--port, updated unknown-command
     message), generate.d (sample loads with empty webuiProjects).
   - E2E local: server on 18080; assets served; state (projects,
     hosts, tags); check run streamed (statuses ok/changed (check),
     counters, check-suffix footer); apply run creating the managed
     file; idempotent rerun (ok=3 changed=0); drift repaired through
     the browser; load-error project surfacing as a log line + exit 1;
     replay of a finished run; every error path (unknown run 404,
     unknown project/bad JSON/non-string/missing/unknown field/bad
     mode/dash selection 400, unknown resource 404, wrong method 405);
     `--events` CLI stream verified single-header/single-footer.
     Browser-verified with a real headless Chromium: page renders,
     chips toggle, runs stream in live, counters fold, verbose toggle
     unhides detail rows, failed runs replayable.
   - E2E on the Debian VM over ssh (root@testing.internal): webui
     server on the controller, project applied to the ssh host —
     events from the remote executor arrived over SSE (host "testing",
     `{{ inventory_hostname }}` rendered on the VM, directory+file
     created, execute check ok), idempotent rerun, check mode, VM file
     verified, VM and local scratch cleaned up.
   - Docs: --help (webui command, Web UI section, --address/--port,
     --events wording), README (feature bullet, example, CLI block,
     settings [webui] projects, Web UI section), DOCUMENTATION
     (command/options tables, Settings [webui] row, new "Web UI"
     section). DOX: root AGENTS.md command list, source/AGENTS.md
     layering (web.d + embedded webui/ assets), module count 16.

29. add a [compose] directive to be able to manage docker containers
   via a compose file
   - `[compose]` is keyed by the stack's project directory (the table key
     injects `dir`, like `path` for files): `file` (required; relative
     resolves inside `dir`), `state` = running (default) | stopped |
     absent, `project` (default: compose's own derivation, lowercased dir
     basename sanitized to [a-z0-9_-], always passed as `-p`), `services`
     subset (default: every service the file enables), `pull` = missing |
     always | never, `build` / `recreate` = auto | always | never, `wait`
     (default true) + `wait_timeout`, `timeout`, `remove_orphans`
     (stopped), `remove_volumes` / `remove_images` (absent). Unknown keys,
     bad enums, relative dirs, invalid project names and contradictory
     combinations are load-time errors with file context; templated values
     are re-checked at run time.
   - `source/tachy/modules/composemod.d` (new): idempotence is probe-then-
     act, all read-only — `docker compose config --services` / `--hash`
     for the model and canonical hashes, `docker ps --filter label=...`
     with a service/names/state/config-hash template for the project's
     containers, `docker inspect` for runtime/health ("none" when no
     healthcheck). `running` acts (`up --detach` with the policy flags,
     `--wait` + re-probe to confirm) only on drift: missing/stopped
     container, config-hash mismatch, unhealthy container. `stopped` runs
     `compose stop`; `remove_orphans` drops containers whose service left
     the model via `docker rm -f`. `absent` probes labels (containers,
     networks, volumes with remove_volumes) and runs
     `down --remove-orphans [-v] [--rmi all]` only when something exists —
     the compose file is not needed for an already-absent project. Check
     mode reports would-be actions; probes always run.
   - Wiring: `modules/package.d` (registry, static validation), `models.d`
     (section allowed, jobs run after `[after.services]` and before
     `execute`, `dir` injection, kind "compose", duplicate-directory
     detection, module doc + order list), `runner.d` (`defaultLabel` maps
     compose to the `dir` param).
   - Tests: `dub test` — 17 modules pass; new composemod unittests with
     the scripted fake transport (idempotence, hash drift, unhealthy
     container, policy-flag command construction, services subset,
     stopped + orphans, absent with/without leftovers, check mode, every
     error path) and a models.d wiring/validation unittest.
   - E2E on the Debian VM over ssh (root@testing.internal) with real
     docker-ce + compose plugin v5.5.1 (installed, then purged): check
     before deploy (truthful compose-file-missing failure), apply → both
     services running + healthcheck healthy + named volume, idempotent
     rerun ("2 service(s) up to date"), compose.yml edit → config-hash
     drift → `up --detach --wait --wait-timeout` recreated both containers
     (new command confirmed running), stopped (containers/volume
     preserved, idempotent), injected orphan container removed via
     `docker rm -f` while managed ones kept (this caught and fixed a real
     parse bug: containers without the config-hash label print 3 fields),
     absent with remove_volumes + remove_images (containers, networks,
     volumes and the alpine image all gone, idempotent "already absent").
     VM (docker purged, /tmp scratch removed) and local scratch cleaned.
   - Docs: --help ([compose] block, execution order), README (intro,
     features, tasks-file table, directive bullet, execution order,
     module tree, limitations), DOCUMENTATION (order list, new
     "[compose] — Docker Compose stacks" section). DOX:
     modules/AGENTS.md (module list, path/dir/name injection, 17
     modules), source/AGENTS.md (17 modules); root AGENTS.md unchanged
     (no directive enumeration there).

30. implement the "webdoc" cli-command: generate the html documentation
    (one file per section) with a left menu to select each section,
    served by the internal web server, re-using the webui's ad-hoc
    framework.
   - New `webdoc.d` (the 18th module): `tachy webdoc [--address ADDR]
     [--port PORT]` serves the DOCUMENTATION.md embedded at compile
     time (`import("DOCUMENTATION.md")` via the new `.` entry in
     dub.json stringImportPaths — the site always documents the binary
     being run). Read-only, no positional arguments, localhost by
     default, same shared options as the webui.
   - Splitting: `##` headings become menu groups (each group's own
     page holds its intro), `###` become pages; sections come out in
     reading order numbered as emitted ("1-purpose",
     "9-directives", ...), a group's page always preceding its
     subsections. The split is two-pass — all page titles and in-page
     headings are registered as anchors first, then bodies render —
     so internal `#anchor` links rewrite to `/doc/<page>#<anchor>`
     even when they point forward (a group's table linking to its own
     later subsections); both the hyphenated and the compact GitHub
     spellings resolve (`#settings-settingstoml`,
     `#settingssettingstoml`). Unknown section addresses get a styled
     404 page.
   - Markdown subset renderer (what the file uses, nothing more):
     fenced code blocks, pipe tables (`\|` escapes), bullet lists
     with wrapped items, paragraphs, inline code/bold/italic/links
     with code spans shielded from the other rules. Styling is
     `webdoc/doc.css`, embedded like the webui assets (the CSS
     started life in a `q{}` token string, which cannot lex `#hex`/
     `NNpx`). The HTTP layer is web.d's, now shared: Request/
     Response/Router/asset/bindListener/serveForever are public.
   - Fixed along the way: the interrupted draft's compile errors
     (never-built code), the per-### duplicate-section bug (pending
     headings were never cleared), and one real webui bug — `--port
     0` is documented as "picks a free port" but both commands
     rejected it; the validation now allows 0 and the banner reports
     the bound port (webui and webdoc).
   - Unittests in webdoc.d: slug/anchor rules against the file's real
     spellings, inline and block rendering (escape shielding,
     tables/lists/fences), section splitting (reading order, group
     pages, anchors), site dispatch/menu/404, and the real embedded
     file — every section reachable from the menu and every internal
     link resolving. app.d gained the command-word tests (six words,
     error listing).
   - E2E local: server on a fixed port; `/` renders the first group
     page with all 22 sections in the menu; group, subsection and
     table/code pages verified over HTTP; every internal link on every
     page rewritten (zero plain `href="#..."` remain); 404 page,
     favicon, POST→405; browser-verified with headless Chromium — menu
     clicks navigate (active state follows), tables/code render, and
     computed styles prove the layout (280px #fafafa menu, #1a73e8
     active/h1 border, #f7f7f9 code blocks, 23 inline CSS rules
     parsed). `--port 0` picks a free port on both webdoc and webui.
   - Docs: --help (webdoc command, Web docs section, examples,
     --address/--port wording), README (feature bullet, example, CLI
     block, Web docs section), DOCUMENTATION (command table row,
     option rows, "Web docs (tachy webdoc)" section — the new section
     itself served and cross-linked as proof). DOX: root AGENTS.md
     command list, source/AGENTS.md layering (web.d shared-layer
     wording, webdoc.d, 18 modules).

31. add a "man" command  (i.e. `tachy man`):
    * copy everything that is actually outputed by the help command there and give it the format of a unix man page.

  change the output of the help command  (i.e. `tachy help`):
    * Keep only the first sections: project-line, command-line, commands and options
   - app.d: new `man` command word (Cmd.man, parseCommand case, main
     dispatch; the unknown-command error lists it). printHelp's
     monolithic string split into shared text blocks (helpHead,
     commandEntries, optionEntries, plus man-only reference bodies);
     helpText() composes the short form (project line, usage lines,
     Commands, Options, one pointer line to "tachy man"), manText()
     the full manual: TACHY(1) banners padded to exactly 80 columns,
     NAME/SYNOPSIS/DESCRIPTION/COMMANDS/OPTIONS/EXAMPLES/PROJECTS/
     WEB UI/WEB DOCS/INVENTORY FILE/TASKS FILE/COMPOSITION/VARIABLES/
     EXECUTION ORDER sections, bodies indented four spaces. One
     source of truth: commands and options blocks are shared between
     help and man, so they cannot drift. `--help`, no-args and getopt
     errors print the short form; `tachy man` prints all 259 lines.
   - Unittests: command-word tests extended to the seven words and the
     error listing; new help/man contract test — help carries exactly
     the four short sections (deep-reference markers asserted absent,
     pointer present), man carries all fourteen section headers, the
     TACHY(1) banner and the shared commands/options blocks verbatim.
   - Verified: dub test (19 modules pass); `tachy help`, `--help` and
     no-args byte-identical; `tachy man` first/last lines exactly 80
     columns, 259 lines; `tachy frobnicate` names all seven commands,
     exit 1.
   - Docs trio: --help text (the split itself), README (invocation
     list, CLI reference block = the new short help plus a pointer
     paragraph), DOCUMENTATION.md (man row in the command table, help
     row reworded, new "### man" section). DOX: root AGENTS.md CLI
     shape, source/AGENTS.md app.d layering bullet.

32. move away from TOML to a custom format — first step: language grammar + name
   (requested directly in chat; no TODO.md entry)

   - New root `LANGUAGE.md`: spec draft for **Pravic** (from Ursula K. Le
     Guin's The Dispossessed — the constructed language of Anarres, same
     Hainish cycle as ansible; runners-up ekumen/hain/kesh noted),
     `.pravic` extension proposed. Directives become independent
     statements: plural directives get a group form (`vars { ... }`) and
     a single form (`var X = "v"`, `file /path { ... }`); singular-named
     directives (execute, compose, apply, import, before, after) keep
     their name, always keyed; webui/settings imports are group-only.
     Value layer stays TOML 1.0 lexical rules (datetimes still
     rejected); multi-line blocks and unquoted path keys become native
     (joinInlineTables/quotePathKeys die with the migration).
   - Grammar written as a PEG (ordered choice, `!KeyChar` keyword
     guards) covering every directive of tasks/inventory/settings files,
     with directive inventory table and README/DOCUMENTATION examples
     rewritten. Open points recorded: statement order vs fixed job
     order (recommend keeping fixed order first), duplicate-statement
     merging, file discovery/coexistence, parser implementation
     (recursive descent or pegged feeding existing Val trees).
   - Verification: throwaway Python recursive-descent transcription of
     the grammar (/tmp/pravic_check.py, deleted after) — 30 positive
     cases, 22 negative cases (keyword boundary `varsite`, TOML header
     leftovers, datetimes, missing same-line commas, unterminated
     blocks...) and all 7 ```pravic blocks from LANGUAGE.md itself:
     ALL PASS.
   - No behavior change (no code touched); docs trio untouched by
     design. DOX: root AGENTS.md Project bullet added.

33. Pravic spec iteration 2: source order, drop TOML, directive cuts
   (requested directly in chat)

   - LANGUAGE.md: jobs run in statement order — the fixed per-file
     order and key sorting are gone, so the guarantees they hid are now
     the author's (directory before file, group before user, checks sit
     between statements); `before`/`after` hooks and `apply` dropped
     (meaningless without fixed groups); `includes` group form dropped
     — only `include "path" { bindings }`, composing at its position;
     `execute` renamed `check`; TOML support dropped entirely — one
     hard cutover, no dual-format reader (project pre-production).
   - Grammar keyword sets now: GroupKeyword = vars files directories
     packages groups users services hosts imports webui;
     SingleKeyword = var file directory package group user service
     host include check compose import. Directive inventory table
     rewritten natively (no TOML column); examples updated (check
     between jobs, deferred include under an import); open points
     trimmed to duplicate-statement merging, file names, and the
     one-cutover implementation plan.
   - Verification: throwaway checker rewritten (/tmp/pravic_check.py,
     deleted after) — 33 positives, 27 negatives (new rejections:
     `includes { }`, `apply "x" { }`, `before packages { }`,
     `after services { }`, `execute "x" { }`, `check { }` without
     key) and all 7 ```pravic blocks from LANGUAGE.md: ALL PASS.
   - No behavior change (no code touched); docs trio untouched by
     design. DOX: root AGENTS.md LANGUAGE.md bullet updated.

34. implement Pravic, drop TOML completely (requested directly in chat)

   - Parser: `source/tachy/value.d` rewritten around a hand-written
     recursive-descent parser of LANGUAGE.md's grammar (chosen over
     `pegged` for `file: line N:` errors and zero dependencies —
     the toml dependency is deleted from dub.json). `loadPractic`
     returns ordered `PracticStmt[]` (canonical kinds, group form
     expanded per entry in source order, `var`→`vars` etc.); `Val`
     trees and the validated accessors unchanged; duplicate directive
     keys within a file are parse errors naming both lines;
     `joinInlineTables`/`quotePathKeys` deleted (multi-line blocks and
     unquoted path keys are native). Fixed along the way: D floats
     default-init to NaN (`double v = 0;` in parseNumber), const(Val)
     casts, the ML-string quote-run rule.
   - Engine: `models.d` walks statements in source order — jobs run in
     statement order (no fixed order, no sorting), `include` composes
     at its position with bindings (vars/import statements are
     file-wide pre-passes; deferral under import landings preserved);
     hooks (`[before]`/`[after]`), `[apply]` and the `[includes]`
     table are gone; `execute` renamed `check` (module
     executemod.d → checkmod.d, registry, dispatch, kind strings,
     error contexts). inventory.d/settings.d consume statements
     (hosts/vars; imports/webui with per-file-kind strictness).
     project.d serializes the generated one-host inventory as Pravic
     (`hostInventoryPravic`, round-trip tested) into
     inventory.pravic; runner/app defaults renamed (main.pravic,
     inventory.pravic, settings.pravic discovery); generate.d
     scaffolds Pravic samples; webdoc slugs (settings-settingspravic).
   - Docs trio + LANGUAGE.md: app.d help/man rewritten for Pravic
     (statement-form reference, source-order EXECUTION ORDER section);
     DOCUMENTATION.md fully converted (directive sections retitled
     var/file/directory/package/group/user/service/compose/check,
     hooks section deleted, include/import rewritten); README.md
     converted (subagent, every fenced block validated by loading it
     through the real binary); LANGUAGE.md status → implemented.
     Restored two regressions found during smoke: getopt lost
     `--events`/`--keep-bundle`/`--settings` registrations and
     parseCommand lost `generate`/`webui` (caught by the README
     agent's validation; the app.d unittests don't run in the
     library test config).
   - Verified: dub test --force 19/19 modules; local bundled-mode
     smoke (source order directory→include→file→checks, include
     bindings, idempotence, check mode, TOML file rejected with
     `unknown directive`); webdoc serves the converted docs (Settings
     page 200, pravic blocks render); webui serves 200 with
     settings.pravic banner; E2E on testing.internal as a local host:
     directory/include-with-binding/template/{{ inventory_hostname }}/
     external import landed under its base name/src from it/two
     checks/second run ok=7 changed=0 — VM and scratch cleaned up.
   - DOX: root AGENTS.md (Pravic-driven, zero deps, CLI defaults,
     LANGUAGE.md implemented, TOML-spellings rule → Pravic
     equivalence rule), source/AGENTS.md (value.d parser, models.d
     source order, project.d Pravic serialization, settings.pravic,
     19 modules), modules/AGENTS.md (checkmod, check wording).

35. Pravic: an instruction with no attributes may omit the empty braces

   - Requested directly in chat: `directory /tmp/two {}` parseable as
     `directory /tmp/two`, `import "../task2" {}` as `import "../task2"`.
   - Parser (`source/tachy/value.d`): after a single-form key — and,
     symmetrically, after a group-form entry key — the block is
     optional; an end of line/EOF at statement level (`,`, `}` or a
     newline inside a block) yields the empty table, exactly as `{ }`
     always did. Only an EMPTY block is omittable: anything after the
     key that is neither `{` nor `=` stays a load-time error
     ("expected '{', '=' or end of line" / "... or a separator"), and
     group keywords (`vars`, `hosts`, ...) still require their block.
     Equivalence contract kept: `directories { /tmp/two }` and
     `directory /tmp/two` are the same statement.
   - Tests: value.d — new unittest (braceless statements and group
     entries, trailing comment, EOF without newline) and strictness rows
     (`directory /tmp/two mode = "0755"`, `vars { a b }`); models.d —
     braceless `import tasks/imp_gogs` collects like the braced form.
   - Docs: LANGUAGE.md (design bullet, new `EndOfEntry`/`Eq` grammar
     productions, prose note, import inventory row, example), the doc
     trio (app.d man: `group epices` shown braceless, forms sentence,
     `import` example; README import row + language paragraph;
     DOCUMENTATION.md language note + both import examples), and the
     generate settings hint now spells `import "name"` without braces.
   - DOX: root AGENTS.md Pravic equivalence bullet records the
     omittable empty block.
   - Verified: `dub test` 19/19 modules passed; local `--direct` smoke
     (braceless directory/group/check parse and run); E2E on
     testing.internal as root in bundled mode — braceless
     `import ../gogsdata` copied under its base name, `src` from it
     landed (mode 0755, content intact), braceless `directory` created,
     reapply ok=3 changed=0 — VM and local scratch cleaned up.

36. embed app.d help/man text blocks as compile-time imports (TODO 1)

   - The 14 text enums in `source/app.d` (helpHead, commandEntries,
     optionEntries, helpTail, manDescription, manExamples, projectsBody,
     webuiBody, webdocBody, inventoryBody, tasksBody, compositionBody,
     variablesBody, orderBody) are now raw files under
     `source/assets/<name>.txt`, embedded at compile time as
     `private immutable string X = import("assets/X.txt");` (immutable
     module storage — one copy — instead of per-use enum literals; the
     string quotes live unescaped in the files). `commandsBlock`/
     `optionsBlock` stay as derived one-line concatenations;
     `helpText`/`manText` and every consumer unchanged. No dub.json
     change: `source` was already a stringImportPath (webui assets).
   - No behavior change: `tachy help` (3153 bytes) and `tachy man`
     (14100 bytes) byte-identical to before (diff-verified in steps —
     two transcription slips in orderBody.txt caught by the diff and
     fixed). `dub test` 19/19 modules passed.
   - DOX: source/AGENTS.md app.d bullet (assets/*.txt embedded via
     import()); root AGENTS.md dub.json bullet lists the new text
     assets. TODO.md entry 1 removed.

37. webdoc dark mode: one stylesheet for webdoc and webui (TODO 2)

   - `source/tachy/webdoc/doc.css` deleted; `webdoc.d` now embeds the
     console's own `webui/app.css` (`pageCss = import("tachy/webui/app.css")`)
     and tags its pages `<body class="webdoc">`.  app.css gained a
     webdoc section (menu, doc main, headings, code, pre, tables,
     blockquote) written against the existing `:root` tokens and scoped
     under `body.webdoc`/`#menu`, so the docs get the console's dark
     theme and the console is untouched (its rules never match
     `.webdoc` pages and vice versa: no `#menu` in the webui DOM).
   - Verified: dub test 19/19; served both sites and asserted computed
     styles in a browser — webdoc: body #0d1117/#e6edf3, menu
     #161b22 + 280px, main display block/max-width 860px (grid
     override), h1 accent underline, td 1px --border, th --bg-raised,
     pre --bg-panel, active link accent; webui regression: main still
     grid 280px/1fr, aside border, uppercase h2, buttons, no #menu.
     Screenshots captured for both.
   - Docs: webdocBody (help/man) + README web docs bullet +
     DOCUMENTATION.md Web docs section note the shared stylesheet and
     dark theme.  DOX: source/AGENTS.md webdoc bullet, root AGENTS.md
     dub.json bullet (webdoc stylesheet → shared app.css).  TODO 2
     removed.

38. tests in a dedicated tests/ directory, run by silly (TODO 3)

   - dub.json now has two configurations: `application`
    (targetType executable) and `unittest` (library, sourcePaths
    [source, tests], silly ~>1.2.0-dev.2 as its ONLY dependency — the
    runtime binary stays dependency-free; dub.selections.json pins
    silly).  main in app.d is guarded `version (unittest) {} else`
    so the silly runner owns main under `dub test` (app.d itself
    still compiles into the test build; `Cmd`, `helpText`,
    `manText`, `parseOptions`, `commandEntries`, `optionEntries`
    lost their `private` for tests/app.d).
   - Every module's in-file `version (unittest)` blocks moved to
    `tests/<module>.d` (`module tachy.tests.<name>`); fixtures moved
    with them (writeTemp-style helpers, FakeTransport — the old
    `tachy/modules/fake.d` is now `tests/fake.d`,
    `tachy.tests.fake`).  Test-only internals widened to
    `package(tachy)` (which covers tachy.tests.*): web.d
    (Run, runJson, parseHead, splitPath, jsonEscStr, jstr,
    parseStringObject, jsonBody, errorJson, sseFrame, ChunkSink,
    sendAll), webdoc.d (splitSections, inlineMd, slugify, compactOf,
    layout, DocSite, docSource, menuHtml, MdRenderer), generate.d
    (generateTask).
   - The extraction was scripted (drop version wrappers, de-indent
    outside raw strings); braces in four files were mangled by a
    string-blind repair pass and events/vars/web regenerated
    faithfully from the git index; value.d's TOML-era index version
    was useless, so its suite was rebuilt from session reads — two
    parser suites (value kinds, multi-line strings) rewritten
    against the same contract, noted in tests/value.d's header.
   - Tests now RUN, where the old library-config runner silently
    skipped app.d's unittests (DONE 34) — three stale assertions
    fixed (TOML-era needles, man's indented bodies checked per line,
    value-taking options given values in the registration loop), and
    one real bug surfaced and fixed: `--keep-bundle` was documented
    but never registered in parseOptions (`tachy --keep-bundle`
    died with "Unrecognized option" — the exact regression its doc
    comment warns about).  filemod's shared scratch dir became
    thread-unique (silly runs threaded by default).
   - Verified: `dub test` 123 passed / 0 failed, three threaded runs
    + one `-- --threads 1`; `dub build` produces the executable
    again (the configuration initially and silently built a library
    — targetType executable added); help 3153 bytes and man md5
    unchanged; E2E on testing.internal: `--keep-bundle apply` kept
    the bundle ("bundle kept on vm at /tmp/tachy.XXXX", removed
    afterwards with the target dir).
   - DOX: source/AGENTS.md Work Guidance + Verification bullets
    (tests/ layout, parallel-safe convention); root AGENTS.md dub.json
    bullet (zero runtime deps; silly test-only).  TODO 3 removed.

39. generate a syntax coloring for the pravic language: only
    vim/neovim format for now (the TODO.md entry)

   - New `syntax/` directory with `pravic.vim`, a Vim/Neovim syntax
     file for Pravic built on LANGUAGE.md's grammar: all 22 directive
     keywords with the parser's own `!KeyChar` boundary guard (a
     `\ze` guard set — `vars-foo`, `varsite`, `var:foo` never light
     up as keywords), bare keys/targets (a bare token followed by
     `=`, `{`, `,`, `}` or `#` — or end of line, which is what makes
     braceless statements like `directory /tmp/two` keys; the grammar
     has no bare values), the TOML 1.0 value layer (four string kinds
     with escapes and `{{ ... }}` templates contained in strings,
     signed dec/hex/octal/binary integers with underscores, floats
     with frac/exp plus inf/nan, booleans), `=`/`{}[]` punctuation
     and `#` comments with TODO/FIXME. Install instructions are in
     the file header (copy to ~/.vim/syntax/, Neovim
     ~/.config/nvim/syntax/, plus one autocmd).
   - Definition order is part of the contract: same-position ties go
     to the later item and `syn keyword` beats matches, so pravicKey
     is defined first and keywords last — `8080`, `true` and `inf`
     win their ties against the key match, and `vars { var = 1 }`
     colors `var` as a keyword (documented, grammar-legal edge).
   - Verified headless in both vim 9.2 and nvim 0.12.4: 102 synID
     assertions (`vim -Nu NONE -es` / `nvim --headless`) over a
     sample exercising every construct — keywords in both forms,
     guard negatives, every number form, all four string kinds,
     escapes `\t`/`\"`/`\u0041`, templates at start/middle/end,
     trailing and full-line comments, braceless statements, path and
     colon keys, multi-line strings — 102/102 in each editor. The
     link chain was dumped separately: every pravic* group resolves
     through `hi def link` to its standard group with colors under
     `syntax enable` + colorscheme default. TOhtml and pty screen
     capture stay partial under -u NONE (vim headless cterm→CSS
     quirk) — not counted as proof.
   - Docs: README "Editor syntax" section; DOCUMENTATION.md new
     "## Editor syntax" section (webdoc serves it as its own page).
     The doc trio's app.d --help/man half was deliberately not
     touched: no CLI behavior changed, the syntax file is a repo
     artifact, not part of the binary's interface. LANGUAGE.md
     untouched (it specifies the language, not tooling).
   - DOX: new `syntax/AGENTS.md` (lockstep-with-LANGUAGE.md contract,
     the ordering rule, no-other-formats rule, empty-by-policy
     Verification section); root AGENTS.md Project bullet + Child
     DOX Index entry. TODO.md entry removed.

40. implement age decryption for files (similar to what has been done
    for vars)
   - Language: `file`/`files` entries take `age = true` marking their
     `src` as age-encrypted — `file /etc/x { src = "x.age", age = true }`
     (spelling chosen in chat over `src_age`/`secret =`). Load-time
     validation (package.d): boolean only, requires `src`; run-time
     (filemod.d): exclusive with content/template/line/block and every
     non-file state, including link (where `src` is the target).
   - Semantics: the plaintext deploys byte-exact — binary secrets that
     `{ age = ... }` vars reject; not templated, nothing stripped. The
     source resolves like `src` (defining file's dir) and must live
     inside the project. `vars.d` gained `isAgeCiphertext` (the
     `age-encryption.org/v1` header decides ciphertext vs plaintext)
     and `decryptAgeFile` (identity resolution + the swappable
     `ageDecrypt` hook, errors wrapped with file context); the vars
     binary-secret message now points at the file spelling.
   - Bundled mode: the identity never travels inside a bundle, so the
     controller decrypts — `collectDecryptedFiles` (runner.d) renders
     each host's scope (secret paths may be templated per host),
     dedupes by resolved path across hosts, and `deployProject`
     (project.d, `DecryptedFile`) writes the plaintext over the
     ciphertext copy after the tar extract; the bundle cache key gained
     the decrypted-set signature (two entry files sharing a project but
     with different secrets no longer reuse one bundle). On the host,
     a source without the age header is used as-is — that is the
     pre-decrypted bundle copy; `--direct` runs decrypt in-process
     (`TaskContext.ageIdentity` from `--identity`). Secrets inside
     includes that only exist under an import destination stay
     unsupported (documented): the controller cannot see them.
   - Unittests: filemod (decrypt round-trip incl. binary bytes,
     idempotence, drift, check mode, pre-decrypted-as-is, every
     combination error, decrypt-failure context), models (load-time
     validation), runner (`collectDecryptedFiles`: dedupe, host-templated
     path, cache reuse, outside-project error), vars (isAgeCiphertext).
   - E2E with real age 1.3.2: local bundled run (binary secret
     byte-exact via cmp, mode 0600, idempotent rerun, drift repair,
     check mode untouched), `--direct`, `AGE_IDENTITY`, wrong identity
     failing with age's message before any write, `--keep-bundle`
     showing the plaintext inside the bundle, two entry files with
     different secret sets in one invocation (cache-key split), and the
     same project applied over ssh to the Debian 12 VM (sha256 match).
     Docs trio updated (help/man optionEntries + tasksBody/
     variablesBody, README Secrets section + help copy verified
     byte-identical to `tachy --help`, DOCUMENTATION file table row +
     new "## Secrets (age)" group served by webdoc at /doc/23-secrets-age).
     LANGUAGE.md/pravic.vim untouched: `age` is an attribute key, not
     grammar.

41. the webserver (webdoc and webui) should default to a random port
    between 10000 and 65534 instead of 8080
   - `RunOptions.webPort` defaults to 0; `webListener` (web.d, shared by
     both commands) binds `--port N` when given and otherwise calls the
     new `bindListenerAuto`: 16 attempts at a uniform random port in
     [10000, 65534] (unpredictableSeed), then a kernel-picked free port
     (bind 0). The listening banner always prints the bound URL.
   - Unittests: port range + connect + explicit-port override through
     `webListener`. E2E: webdoc and webui banners showed in-range ports
     (13015, 59967), pages/API served, explicit `--port` still binds
     exactly. Docs trio updated (optionEntries --port, both man web
     bodies, README help copy + web sections, DOCUMENTATION options row
     + webui/webdoc sections).

42. webdoc and webui should try to automatically open a web browser on
    the host (`gio open`)
   - `tryOpenBrowser`/`browserUrl` (web.d): after the banner, before
     serveForever, both commands spawn `gio open http://<addr>:<port>/`
     in a daemon thread (waited, so no zombie; stdio to /dev/null) —
     Linux is the only supported platform and gio the freedesktop
     opener; failures are silent and the URL is printed regardless.
     Every-interface binds (0.0.0.0) open on 127.0.0.1.
   - Unittest: browserUrl mapping. E2E: a stub `gio` on PATH recorded
     `gio open http://127.0.0.1:<port>/` for both commands; with gio
     absent from PATH the servers start and print the URL unchanged.
     Docs trio updated alongside 41.


43. avoid the limitation on secrets inside included projects/tasks
    (requested directly in chat — "option 1" from the follow-up
    discussion; no TODO.md entry)
   - Mechanism: instead of translating paths, the controller builds a
     *staging mirror* of the bundle's project layout — `makeStaging`
     (runner.d): a temp dir with one symlink per top-level project
     entry plus one per import under its base name (names already
     mirrored are skipped — such landings exist for real and deferred
     nothing). Composing the entry file inside the mirror with the
     unmodified `loadTasksFile` sees exactly what the on-host inner
     run sees (same directory shape: relative paths, `..` escapes
     back into the project, nested includes under the landing), so
     the shadow composition's `age = true` sources flow through the
     existing `collectDecryptedFiles` unchanged — no new composition
     rules to keep in sync.
   - Wiring (runner.d, runBundled): when `loaded.deferred.length`, the
     mirror is composed once per tasks file (with the controller's
     settings) and replaces the real composition for secret
     collection only — execution, validation and the runDirect skip
     messages still use the real `loaded`. The mirror is removed with
     the tasks file (`scope (exit)` at the loop-body level — the first
     cut bound it to the `if` block and the E2E caught the mirror
     being deleted before decryption, ENOENT from age). Side effect,
     documented: errors in a deferred subtree now surface on the
     controller during deploy (per-host isolation as before) instead
     of only on the host mid-run.
   - Unittest (tests/runner.d): import source with a deferred include
     + nested include + two age sources — real composition sees no
     secrets (the old limit reproduced), the mirror composes both
     jobs, collects both `land/*.age` plaintexts with staging-space
     paths, and `removeStaging` unlinks without touching the real
     files.
   - E2E with real age: local bundled run through a deferred include
     (byte-exact via cmp, mode 0600, idempotent rerun, drift repair,
     check mode untouched, no staging leftovers) and the same project
     over ssh on the Debian 12 VM (sha256 match); `--keep-bundle`
     shows the plaintext written over the ciphertext copy at the
     bundle's import landing. VM and scratch cleaned.
   - Docs: DOCUMENTATION.md Secrets section (limitation sentence
     replaced by the staging-mirror behavior), README Secrets
     paragraph; source/AGENTS.md runner.d bullet. `--help`/man
     untouched — no CLI change.


44. name unit tests with silly attributes instead of comments
    (requested directly in chat; no TODO.md entry)
   - Every unittest block in `tests/` now carries `@("what it checks")`
     on the line before `unittest` (silly reads string attributes as
     test names); the runner output shows descriptions instead of
     `__unittest_L<line>_C<col>`. Mechanical rewrite of all 131
     `unittest // name` blocks (quotes escaped in the five names that
     carry them) plus the one nameless block (tests/value.d), which
     got "validated accessors: checkKeys and optString".
   - Follow-up, exposed while hammering the suite: a pre-existing race
     between threaded tests mutating process-global env — vars' age
     test and settings' discovery/webui tests all touch HOME, so
     `~`-expansion assertions intermittently compared against another
     test's transient HOME (~50% failure rate across repeated runs).
     New `tests/envsync.d` (`envM`, a shared mutex); settings'
     `withEnv` holds it across the whole set/run/restore span, the
     webui-projects test locks its hermetic-HOME span, vars' age test
     wraps its body. Tests using unique per-test names
     (TACHY_UT_*) stay lock-free. Verified: 20 consecutive full-suite
     runs, 0 failures (previously ~1 in 2); convention recorded in
     source/AGENTS.md.


45. add a "hosts" command (list/info sub-commands) and drop
    --list-hosts; re-work the "generate" help entry
   - CLI: new `hosts` command word (app.d: Cmd enum, parseCommand,
     dispatch, command list in the unknown-command error). `tachy
     hosts list <selection>` prints exactly the former --list-hosts
     output (`hostsListText`); `tachy hosts info <host>` prints the
     host line (name + connection target) then its attributes —
     connection/port always, address/user/key/tags when set — and
     effective variables (global < host, sorted, values as Pravic via
     project.d's `pravicValue`, now package(tachy)); the injected
     `inventory_hostname` builtin is dropped (the header restates
     it). inventory.d gained a `host(name)` lookup (unknown names
     list the known hosts); `runHosts` validates its arguments before
     the inventory is read. `--list-hosts` is gone entirely: getopt
     registration, `RunOptions.listHosts`, the runTachy branch and
     its --direct conflict check removed.
   - generate help entry reformatted as requested: one line per thing
     ("key <path> : writes a new age key pair", …) plus a
     "(note: all refuse to overwrite)" line, in commandEntries.txt —
     one asset feeding --help, README and man.
   - Unittests: tests/app.d (eight command words, hosts in the
     unknown-command list, --list-hosts now rejected the way --check
     was); tests/runner.d (hostsListText/hostInfoText exact output —
     ssh host with every attribute, bare local host, host without
     vars; runHosts argument shapes, unknown host listing the known
     ones, empty selection). `dub test`: 134 passed, 0 failed.
   - E2E (local — the command never contacts hosts, so no VM run):
     `hosts list all`/`@front` and `hosts info` of an ssh and a local
     host against a scratch inventory; every error path exits 1 with
     its message; `--list-hosts` rejected with the help; `tachy man`
     COMMANDS carries the new entries (same embedded asset); webdoc
     serves the new hosts page (25 sections). Docs trio updated
     (README commands+options blocks, DOCUMENTATION command table /
     options table / new "### hosts" section); AGENTS.md CLI shape
     and source/AGENTS.md layering bullets refreshed.


46. settings.pravic: an `identity` entry for the age key, superseded
    by --identity (requested directly in chat; no TODO.md entry)
   - Both spellings are legal and equivalent: `identity "key.txt"`
    and `identity { path = "key.txt" }`. Pravic-wise this is the
     first keyword with both forms on one spelling: value.d's
     parseStatement now dispatches a keyword registered in both sets
     to its group form when a `{` follows the keyword, its single
     form otherwise — existing keywords keep identical behavior and
     error messages (group-only keywords still demand their block;
     LANGUAGE.md grammar, prose and example updated to match).
   - settings.d: `Settings.identity` (absolute, resolved like search
     paths — ~-expanded, relative to the settings file), strict
     validation (duplicate entries, non-string paths and attribute
     blocks are load-time errors with file:line context) and
     `effectiveIdentity(flag, settings)` — the flag wins, an empty
     result keeps the old AGE_IDENTITY → ~/.ssh/id_ed25519 chain at
     use time. Wired once per entry point: runTachy (settings now
     loaded there once and threaded into runDirect/runBundled),
     runHosts, and runWebUi (the webui's inventory load and the
     spawned runs' `--identity` forwarding both use the effective
     identity).
   - Sample settings, generate key output and the no-identity error
     mention the new entry; TaskContext/vars.d comments refreshed.
   - Unittests (tests/settings.d): both spellings, unquoted and
     absolute paths, coexistence with imports/webui, seven
     bad-shape/duplicate errors with context, and effectiveIdentity
     precedence. Follow-up caught by hammering the suite: the new
     runHosts test in tests/runner.d raced the settings-discovery
     test's transient TACHY_SETTINGS (runHosts reads discovery when
     no --settings is given) — it now passes an explicit empty
     settings file, making it hermetic; 20 consecutive full-suite
     runs, 0 failures. `dub test`: 136 passed, 0 failed.
   - E2E with real age (local --direct): settings identity decrypts
     an `{ age }` var end-to-end; `--identity <wrong key>` fails the
     decryption (the flag superseded the working settings entry);
     the group form and cwd settings discovery (via `tachy hosts
     info`) behave the same. --help/man/webdoc render the updated
     text (webdoc settings page carries the identity example). Docs
     trio updated throughout (option rows/blocks, settings and
     Secrets sections, LANGUAGE.md); source/AGENTS.md settings.d and
     value.d bullets refreshed.

47. version: the program version is the build date, 'YY.mm.dd'
   - source/assets/version holds it; dub's preBuildCommands refresh
     it before every build — `date +%y.%m.%d | cmp -s - <file> ||
     date +%y.%m.%d > <file>` — so the file is rewritten only when
     the day changes: a second same-day build stays an up-to-date
     no-op (mtime untouched, verified), while a stale date is
     rewritten and the binary relinked with the new string (verified
     by planting yesterday's date). Dub 1.39 rejected a shell `$(...)`
     guard in preBuildCommands ("Invalid variable"), hence the cmp
     pipeline with no shell dollar signs.
   - app.d: `immutable string tachyVersion = strip(import(
     "assets/version"))` — D reserves `version`, so the Cmd enum
     member is Cmd.showVersion while the command word stays
     "version"; `versionText()` returns "tachy <date>", the dispatch
     prints it; parseCommand's unknown-command message and
     commandEntries.txt gained the entry between man and help.
   - Unittests (tests/app.d): ninth command word parses, the
     unknown-command list carries version, and a new block pins the
     `^\d{2}\.\d{2}\.\d{2}$` shape of tachyVersion, versionText()
     and the help/man command entry. `dub test`: 137 passed, 0
     failed.
   - E2E (local — the command never contacts hosts, so no VM run):
     `tachy version` prints "tachy 26.09.11", an unknown command
     lists version, help and man carry the entry, and README's CLI
     reference block now diffs clean against `tachy help` (also
     fixed pre-existing drift found by that diff: a missing blank
     line and the --settings option wrap). Docs trio updated
     (commandEntries asset, README examples + CLI block,
     DOCUMENTATION command table + new "### version" section);
     AGENTS.md CLI shape and source/AGENTS.md app.d bullet refreshed.

48. extract the two immutable strings for the samples (sampleSettings
   and sampleTasks) into assets and import them using D's import
   - generate.d's `private immutable string sampleTasks`/`sampleSettings`
     q-token literals are gone; the texts now live in
     `source/assets/sampleTask.txt` and
     `source/assets/sampleSettings.txt` and are embedded at compile
     time with `import("assets/...")`, exactly like app.d's help/man
     blocks (dub.json's stringImportPaths already covers them).
   - Verified byte-identical: generated task/settings samples with the
     pre-change binary and the rebuilt one, `cmp` clean on both.
     `dub test`: 137 passed, 0 failed. No behavior change (internal
     refactor), so the doc trio is untouched; source/AGENTS.md
     generate.d bullet refreshed to name the assets.

49. change in pravic language: replace the 'check' statement by the
   'ensure' statement, and the 'include' statement by the 'apply'
   statement
   - Parser (value.d singleKeywords), models.d (kinds, module wiring,
     `processApply` — was `processInclude`) and the module layer all
     renamed in one clean cutover: the check module is now `ensuremod.d`
     (`runEnsureModule`, module name "ensure", error contexts
     "ensure 'name'"), the job kind/dispatch name is "ensure", and the
     composition statement/kind is `apply` (`the composition applies
     'x', which is outside the project directory ...` escaping error
     reworded). Old keywords are parse errors again
     ("unknown directive 'check ...'/'include ...'").
   - The CLI is untouched: `tachy check` (check mode), the webui
     check runs and the event-stream "check" flag (check-mode marker)
     are a different layer and keep their names.
   - Doc trio + spec + syntax all switched together: LANGUAGE.md
     (grammar alternation, no-plural list, directive inventory,
     examples, semantics notes), README (features, example walk,
     directive table, idempotence list, internals), DOCUMENTATION.md
     (intro example and output, `### apply` — composition, deferred
     applies, `### ensure` — command checks), the man/help assets
     (compositionBody, orderBody, tasksBody, variablesBody,
     projectsBody, sampleTask — `ensure "demo file exists"`, commented
     `apply "base.pravic"`) and syntax/pravic.vim's keyword match.
   - Tests: tests/ensuremod.d (renamed from checkmod.d), models/value/
     runner fixtures and asserts updated; value.d's `apply "x.pravic"`
     unknown-directive negative became `hook "x.pravic"` (apply is a
     keyword now). Fixed a pre-existing fixture race the rename
     exposed: two tests in tests/models.d both wrote "compose.pravic"
     into the shared scratch dir (threaded runner) — the compose-
     wiring fixture is "stack.pravic" now; suite run 5x, 137/137 each.
   - E2E local --direct and bundled (event relay shows `ensure ...`
     labels), failure isolation (`ensure 'must fail': exit status 9,
     expected 0`, later jobs skipped, exit 1), check mode, generate
     task sample loads and applies ok=... idempotently, `tachy man`
     free of old keywords; on the Debian 12 VM over ssh (root@
     testing.internal): bundled run with `apply` + vars sub-block
     binding + dash-safe `. /etc/os-release` ensure, idempotent second
     run, check mode, "flavor chocolate on vm1" verified, VM cleaned.
   - DOX: root AGENTS.md language bullet, source/AGENTS.md models.d/
     runner.d bullets and modules/AGENTS.md module list + check-mode
     contract refreshed; syntax/AGENTS.md unchanged (no keyword text,
     pravic.vim contract is "track LANGUAGE.md").

50. hosts list: default the selection to all when omitted —
   `tachy hosts list` used to error with "expected exactly one
   selection" and now lists every host (user-reported).
   - runHosts (runner.d): `hosts list [<selection>]` — the selection
     is optional and defaults to "all" (the header line shows 'all');
     more than one selection is still an argument error ("expected at
     most one selection ... not N"), `hosts info <host>` still
     requires exactly one name, and the no-sub-command usage text now
     shows 'list [<selection>]' with a bare `tachy hosts list`
     example.
   - Tests (tests/runner.d): `["list"]` left the rejected-shapes list
     and gained a positive `runHosts(["list"], opts) == 0` regression
     check (failed pre-change, passes post) plus the "at most one
     selection" guard. dub test: 137 passed, 0 failed.
   - E2E: `tachy hosts list` prints "== all | hosts: buildbox, web1"
     (exit 0), `hosts list @web` still filters, `hosts list a b`
     errors exit 1, and README's CLI reference block byte-matches
     `tachy help` again. Doc trio (commandEntries asset, README,
     DOCUMENTATION hosts section + example) and the root/source AGENTS
     CLI bullets updated.
