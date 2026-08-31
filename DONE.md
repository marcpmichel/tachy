
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
