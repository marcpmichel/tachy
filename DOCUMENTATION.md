# tachy — documentation

## Purpose

tachy is a small, agentless configuration-management tool: you describe the
state machines should be in — packages installed, files written, users
created, services running — in **TOML tasks files**, and tachy makes it so,
idempotently. Run it twice and the second run changes nothing.

Core ideas:

- **Idempotent "ensure" jobs.** Every managed resource is a table entry
  keyed by its target (a path, a package name, a user…). tachy inspects the
  current state first and only acts — and reports `changed` — when it
  differs. Check mode (`tachy check`) reports would-be changes without
  touching anything.
- **One binary, no agent.** For every selected host, tachy copies the
  project directory — and itself — to a temporary directory on the host and
  runs the copy there, over SSH (or locally). The remote host needs nothing
  but a POSIX shell with GNU coreutils, `tar`, and systemd for services.
  Controller and hosts must be linux/amd64 (the copied binary is the
  controller's own).
- **Deterministic order.** Jobs run in a fixed, documented order
  (directories, files, packages, groups, users, services, execute — by key
  within each kind), so dependencies between kinds are respected without
  you sequencing anything.
- **Everything is shell.** All inspection and mutation is expressed as
  POSIX shell commands with strict quoting, built and executed through one
  transport; nothing is decoded or interpreted in between (file copies are
  byte-exact and compared by checksum).

### A simple example

`inventory.toml` — the hosts:

```toml
[vars]
site_owner = "www-data"          # global variable, lowest precedence

[hosts.web1]
address = "192.168.1.10"
user = "root"
tags = ["web"]

[hosts.web2]
address = "192.168.1.11"
user = "root"
tags = ["web"]
```

`main.toml` — the state (a tasks file's parent directory is its
*project*), with `index.html.tmpl` next to it containing
`hello {{ site_owner }} on port {{ http_port }}`:

```toml
[vars]
http_port = 8080                 # tasks-file variables

[directories."/srv/www"]
mode = "0755"
owner = "{{ site_owner }}"

[files."/srv/www/index.html"]
template = "index.html.tmpl"     # rendered with the variables above
mode = "0644"

[execute."content rendered"]
run = "cat /srv/www/index.html"
output = { contains = "hello" }
```

Run it against a tag:

```sh
$ tachy apply '@web'
== main.toml | hosts: web1, web2
web1 | changed         | directory /srv/www: created directory; owner root -> www-data
web1 | changed         | file /srv/www/index.html: created file
web1 | ok              | execute content rendered: exit 0
web2 | changed         | directory /srv/www: created directory; owner root -> www-data
web2 | changed         | file /srv/www/index.html: created file
web2 | ok              | execute content rendered: exit 0
-- main.toml: ok=2 changed=4 failed=0
```

A second run prints `ok=6 changed=0 failed=0` — nothing left to do.

---

## Command line

```
tachy <command> [options] <selection> [<tasks.toml>...]
```

- The first argument is a **command** word:

  | Command | Description |
  |---|---|
  | `apply` | Apply the tasks files to the selected hosts. |
  | `check` | Check mode: report the changes that would be made, apply nothing. Execute jobs still run — they are checks by nature. |
  | `generate` | Create something new — see [generate](#generate). |
  | `webui` | Start a local web server, a graphical version of the CLI — see [Web UI](#web-ui-tachy-webui). |
  | `webdoc` | Serve this documentation as a browsable web site — see [Web docs](#web-docs-tachy-webdoc). |
  | `man` | Print the full built-in manual, unix man-page style — see [man](#man). |
  | `help` | Show the short help: project and usage lines, commands, options (same as `--help`). |

- `<selection>` is a comma-separated list of host names and `@tag`
  selectors; the special selector `all` matches every host.
  Examples: `web1`, `web1,web2`, `@web,@db`, `@web,buildbox`, `all`.
- A tasks-file argument may be a **directory**: its `main.toml` is the
  entry point. With no tasks-file argument at all, `main.toml` in the
  current directory is used. Either way, the entry file's parent directory
  is the project that gets copied to each host.
- Exit code is `0` when everything succeeded, `1` when anything failed
  (unknown option or command, load error, unreachable host, failed
  job…). A failing host is dropped for the rest of its tasks file; other
  hosts continue.

Example: `tachy apply @web req/web`, `tachy check all`,
`tachy generate key key.txt`.

### Options

| Option | Description |
|---|---|
| `-i, --inventory PATH` | Inventory file (default: `inventory.toml`). |
| `-v, --verbose` | Show executed commands and change details under each job line. |
| `--list-hosts` | List the hosts matching the selection, then exit. |
| `--keep-bundle` | Keep each host's temporary bundle directory after the run (project copy, generated inventory, report) and print its location — for debugging. |
| `--direct` | Apply tasks files directly in this process, without bundling a project. (This is how the copied binary runs on each host; use it manually for local execution.) |
| `--direct-report PATH` | With `--direct`: suppress headers/footers and write `ok changed failed` counters to PATH (machine mode). |
| `--events` | Print one JSON event per line on stdout instead of text — the machine-readable stream (fileStart / job / fileDone objects carrying host, label, status, msg, details and per-job `ms`). With `--direct`: the local run's own events. Without: the raw events streamed live from each host's run, wrapped in the controller's fileStart/fileDone events (so the stream is self-describing: one header and one footer with counters per tasks file; the `webui` consumes exactly this); controller-side failures are emitted as events too, and `--keep-bundle` notes go to stderr so stdout stays machine-clean. |
| `--identity PATH` | Age identity for `{ age = ... }` inventory vars. Resolution order: `--identity`, then `AGE_IDENTITY` (existing file path, or raw key material fed to age on stdin), then `~/.ssh/id_ed25519`. Requires the `age` binary on the controller. |
| `--address ADDR` | `webui`/`webdoc` only: address to bind (default `127.0.0.1`; an IP — `0.0.0.0` listens on every interface). The webui executes real runs: anyone who can reach the port can run tachy. |
| `--port PORT` | `webui`/`webdoc` only: port to listen on (default `8080`; `0` picks a free port). |


### generate

`tachy generate <what> <path>` creates scaffolding on the controller; it
never contacts a host and never overwrites an existing file.

- `tachy generate key <path>` — a new age key pair: the `age-keygen`
  binary writes the identity to `<path>` (mode 0600; it refuses to
  overwrite) and tachy relays the public key. The identity decrypts
  `{ age = ... }` inventory vars (pass it with `--identity <path>` or
  `AGE_IDENTITY`); encrypt secrets with the printed public key:
  `age -r <pubkey> -o secret.age`. Requires `age-keygen` (it ships with
  the age package) on the controller.
- `tachy generate task <path>` — a commented sample tasks file exercising
  the common directives (`[vars]`, `[directories]`, `[files]`,
  `[execute]`, composition hints), loadable as-is.
- `tachy generate settings <path>` — a commented sample settings file
  (see [settings](#settingssettingstoml)).

### man

`tachy man` prints the complete built-in manual on stdout, formatted
like a unix man page — `NAME`, `SYNOPSIS`, `DESCRIPTION`, `COMMANDS`,
`OPTIONS`, then the reference sections (selection syntax, projects,
the web UI and web docs, the inventory and tasks file reference,
composition, variables, execution order), with the `TACHY(1)` banner
top and bottom. Pipe it through `less` to page through it.

`tachy help` (and `--help`, and no arguments at all) prints only the
short form: the project line, the usage lines, the commands and the
options, plus a pointer to `man`. Everything the help used to carry
beyond that now lives here and in `tachy man`.

### Settings (settings.toml)

Optional; read once at the start of every `apply`/`check` (and once
when the webui server starts). Discovery, first found wins:
`--settings PATH`, the `TACHY_SETTINGS` variable, `./settings.toml`,
then `$XDG_CONFIG_HOME/tachy/settings.toml` (default
`~/.config/tachy/settings.toml`). An explicit `--settings` path or
`TACHY_SETTINGS` that does not exist is an error; with no file found
anywhere, settings are empty. Unknown keys in the file are load-time
errors (strict). Today it holds two things:

| Section | Keys | Meaning |
|---|---|---|
| `[imports]` | `paths` | Array of directories searched, in order, for `[import]` keys that do not resolve relative to their defining tasks file (first existing match wins; unresolved keys keep the defining-relative path, which the deploy-time existence check reports). Entries are `~`-expanded; relative entries resolve against the settings file's directory, never the cwd. |
| `[webui]` | `projects` | Array of project paths offered by [`tachy webui`](#web-ui-tachy-webui) in the browser. A directory is a project whose entry point is its `main.toml`; a plain file is used as the entry point directly. Entries resolve like `imports.paths` (`~`-expanded, relative to the settings file); existence is not required at load time — the interface reports missing paths per project. |

```toml
[imports]
paths = ["libs", "~/.config/tachy/imports"]

[webui]
projects = ["~/Code/site"]
```

### What a run does

For every selected host (bundled mode, the default) tachy creates
`/tmp/tachy.XXXXXXXXXX` on the host (respecting `TMPDIR`) containing a
copy of the project, a copy of the tachy binary, and a generated one-host
inventory carrying the host's variables; it then executes the copied
binary there. The inner run emits one JSON event per line; the
controller renders each job line **live, as the job finishes** on the
host (execution metadata — per-job duration — travels in the events;
`--events` exposes the same stream for machine consumption). The bundle
is removed when the run finishes — check mode deploys and removes a
bundle too but manages nothing. A project must be
self-contained: includes and `file.src`/`template` paths resolve inside
the copied project — `[import]` is the sanctioned way to pull external
files into the bundle.

### Web UI (tachy webui)

`tachy webui [--address ADDR] [--port PORT]` starts a local web server
(default `http://127.0.0.1:8080`) that is a graphical version of the
CLI:

- **Projects**: the `[webui]` `projects` list of settings.toml becomes
  a clickable sidebar (a directory is a project entered through its
  `main.toml`; missing paths show struck through). Settings are read
  once when the server starts — restart it after editing them.
- **Runs**: pick a host selection (the inventory's hosts and `@tag`s
  are offered as toggleable chips; free text works too) and press
  **Check** or **Apply**. Each run is this very binary spawned as
  `tachy <mode> --events -i <inventory> [options] <selection>
  <project>` — bundled mode, exactly the equivalent CLI invocation,
  bundles cleaned up after each run.
- **Live progress**: the page subscribes to the run over Server-Sent
  Events (`GET /api/events/<id>`) and shows each job line as the
  remote executor on the host finishes the job — the same NDJSON event
  stream `--events` prints, wrapped with a server timestamp. Headers,
  footers and ok/changed/failed counters come from the events
  themselves; child stderr and non-event stdout show as log lines (so
  load errors stay visible); past runs stay listed and replayable; a
  verbose toggle unhides the per-job detail lines.
- **API**: `GET /api/state` (projects, hosts, tags, runs), `POST
  /api/run` (flat string fields `project`, `selection`, `mode`),
  `GET /api/events/<id>` (SSE, resumable through `Last-Event-ID`).
  Everything is strict like the rest of tachy: unknown projects,
  fields or modes are 400s with a message.

The browser application — plain HTML, CSS and JavaScript, no framework
and no asset pipeline — is embedded in the binary at compile time with
D's `import("...")` (`source/tachy/webui/`): one binary, no external
files. The webserver itself is a few hundred lines of `std.socket`
(one thread per connection, no framework either). The server executes
real runs and binds to localhost only by default: anyone who can reach
the port can run tachy.

### Web docs (tachy webdoc)

`tachy webdoc [--address ADDR] [--port PORT]` serves this documentation
as a small web site (default `http://127.0.0.1:8080`) — the same
ad-hoc web server as the webui, read-only:

- **One page per section**: `##` groups become menu groups (their page
  holds the group's intro), each `###` becomes a page inside its group;
  the left menu lists them in reading order.
- **Internal links work across pages**: `#anchor` links are resolved
  against every heading and rewritten to the page holding their
  target (both the hyphenated and the compact spelling, e.g.
  `#settings-settingstoml` and `#settingssettingstoml`).
- **Always current**: the pages are generated from the
  `DOCUMENTATION.md` embedded in the binary at compile time — the site
  documents exactly the binary being run, with no file to discover.
  The markdown renderer covers what the file uses: headings, fenced
  code blocks, pipe tables, bullet lists, paragraphs and inline
  code/bold/italic/links.

The command takes no arguments; unknown section addresses return a
404 page.

---

## Directives

A tasks file is a set of top-level tables, each mapping **targets to
parameter tables**. Both TOML spellings are equivalent everywhere:

```toml
[files."/etc/app.conf"]          # sub-table style
mode = "0644"

[files]                          # inline style
"/etc/other" = { mode = "0600" }
```

In table headers the quotes around a path key are optional: the first
segment that is not a bare TOML key starts the target, and any further
dots belong to the path — `[files./etc/nginx.conf]` means exactly
`[files."/etc/nginx.conf"]` (array-of-table headers `[[...]]` behave the
same).

Every string — parameter values **and table keys** — is templated with
`{{ name }}` / `{{ table.key }}` before use; `{{ inventory_hostname }}`
always holds the current host's name. Unknown variables and reference
cycles are hard errors.

Managing the same target twice for the same kind anywhere in a composition
(includes, applies, the same file) is a load-time error.

Job execution order within one file is fixed:

**directories, files, `[before.packages]`, packages, `[after.packages]`,
[before.accounts], groups, users, `[after.accounts]`, [before.services],
services, `[after.services]`, compose, execute** — by key within each
kind — with `[includes]` running before all of them and `[apply]` after.
Directories precede files so a file can live in a directory the same file
manages (including the compose file a `[compose]` entry uses); packages
follow files so an apt repository config can be laid down first; groups
precede users so a user's primary group can be ensured in the same file;
compose follows services and precedes the execute checks.

### `[before.G]` / `[after.G]` — hooks

Hooks trigger execute-style checks at specific points of the order
above, immediately before or after the file's jobs of one group. The
group `G` is `packages`, `accounts` (both `[groups]` and `[users]`) or
`services`; entries have exactly the `[execute]` shape — keyed by a
unique task name, `run` (required), `exit_status`, `output`:

```toml
[after.services."answers on port 80"]
run = "curl -fsS http://localhost/"
exit_status = 0
```

Hooks run at their group's position whether or not the group has
entries, so the composition's entry file can health-check what its
includes managed. They are execute jobs in every other respect: checks
by nature (they run even in check mode and never report `changed`),
working directory is the defining file's directory, and their names
share the `[execute]` name space (a duplicate anywhere in a composition
is a load-time error). Unknown groups under `[before]`/`[after]` are
load-time errors.

---

### `[vars]` — variables

Variables for this file's jobs and everything it composes. Precedence:
global `[vars]` (inventory) < host vars < include chain < this file's
`[vars]`. Entries may read the environment of the process loading the
file — the controller for inventory vars, the host for tasks-file vars in
bundled runs:

```toml
[vars]
domain = "example.org"
port = 8080
db_host = { env = "DB_HOST" }                       # from the environment
db_fallback = { env = "DB_HOST", default = "localhost" }
secret_var = { env = "SECRET_VAR", from = ".env" }  # from a dotenv file
```

| Entry | Description |
|---|---|
| `{ age = "path" }` | Inventory vars only: replaced by the age-decrypted content of `path` (relative to the inventory; one trailing newline stripped). Decrypted on the controller with the identity from `--identity PATH`, `AGE_IDENTITY` (path or key material — stdin, never on disk) or `~/.ssh/id_ed25519`; cannot combine with `env`/`default`/`from`; plaintext must be valid UTF-8. |
| `{ env = "NAME" }` | Replaced by the environment variable `NAME`. Unset without a `default` is an error; set-but-empty resolves to the empty string. |
| `{ env = "NAME", from = "path" }` | Same, but the value is looked up in the dotenv file at `path` (relative to the declaring file) instead of the process environment; the environment is not consulted. `KEY=VALUE` lines, `#` comments, blank lines, optional `export ` prefix, single-line quoted values (double quotes process `\n \t \r \f \b \" \' \\`, single quotes are literal); empty values count, later keys win, malformed lines are errors naming file and line. `default` covers a key the file does not define; in bundled runs the file is read on the host, so it must live inside the project. |

---

### `[includes]` and `[apply]` — composition

Both compose another tasks file, binding variables for it. Entries are
keyed by path (relative paths resolve against the defining file). The only
difference is timing:

- `[includes]` runs **before** this file's own jobs (prerequisites — the
  includer can use variables from the files it includes).
- `[apply]` runs **after** this file's own jobs (respecting the directive
  execution order).

Both are processed sorted by path; scopes chain and flow forward through
the composition. Composition cycles are detected and reported. An
entry naming an existing directory uses its `main.toml` — the same
entry-point convention as a directory argument on the command line
(`[apply."neovim"]` composing an imported `neovim/` directory is the
common case).

```toml
[includes."tasks/base.toml"]       # bindings as the entry's keys
env = "prod"

[includes."tasks/net.toml"]        # ...or grouped under vars (same thing)
vars = { iface = "eth0" }

[apply."tasks/logging.toml"]       # runs after this file's own jobs
vars = { keep = 14 }
```

| Spelling | Meaning |
|---|---|
| `var = "value"` (entry keys) | The binding for the composed file. |
| `vars = { ... }` sub-table | Same binding, grouped. Mixing both for one variable is an ambiguity error. |

### `[import]` — external files in the bundle

Bundled mode only. An `[import]` entry names a file or directory
outside the project (absolute, or relative to the defining tasks file,
like every path) that is copied into the bundle next to the project
copy under its **base name** — so `src`, `template` and `run`
references resolve on the host:

```toml
[import."../shared/install_gogs"]   # lands at project/install_gogs

[files."/opt/gogs/setup.sh"]
src = "install_gogs/setup.sh"       # reads the imported copy
mode = "0755"
```

Entries take no parameters (an empty table). A key that does not
resolve relative to its defining file is searched in the
[settings](#settingssettingstoml) `[imports]` paths. Sources are validated on
the controller at deploy time (existence, and a destination that does
not collide with project content or another import — imports never
overwrite anything). Direct runs (`--direct`, including the on-host
inner run, where the copies already sit inside the project) parse and
ignore the directive.

**Composing imported tasks files.** An `[includes]`/`[apply]` entry
whose path falls under — or names — a declared import's destination
does not exist on the controller — so it *defers*: the controller
skips it at load time, and the on-host inner run composes it there,
with its variable binding, in its directive position (a directory
entry resolves to its `main.toml`, as everywhere). If the file is readable locally
after all, it composes normally:

```toml
[import."../tasks/install_gogs"]    # lands at project/install_gogs

[apply."install_gogs/gogs.toml"]    # deferred: composed on the host
gogs_user = "deployer"              # bindings flow into it
```

Consequences: controller-side validation cannot see inside a deferred
subtree (the on-host load catches errors there, failing only that
host), and a manual `--direct` run without a bundle skips deferred
entries with a warning on stderr.

---

### `[directories]` — directories

Keyed by absolute path. Created with parent directories when missing;
mode/owner/group enforced on every run.

```toml
[directories."/srv/app"]
mode = "0755"
owner = "app"
group = "app"

[directories."/srv/old"]           # removal
state = "absent"
```

| Attribute | Default | Description |
|---|---|---|
| `state` | `"directory"` | `"directory"` ensures it exists; `"absent"` removes whatever is there (`rm -rf`). |
| `mode` | — | Octal string (`"0755"`) or TOML integer (`0o755`). |
| `owner`, `group` | — | User/group names, enforced with chown. |

---

### `[files]` — files, links, removal

Keyed by path. Four mutually exclusive content sources — `content`,
`src`, `template`, and the `line`/`block` pair — plus `state`:

```toml
[files."/etc/app/app.conf"]        # literal content, templated inline
content = "port = {{ http_port }}\n"
mode = "0644"
owner = "root"

[files."/usr/local/bin/tool"]      # verbatim copy from the project
src = "files/tool"                 # (binary-safe; compared by checksum)
mode = "0755"

[files."/etc/nginx/site.conf"]     # rendered from a template file
template = "site.conf.tmpl"        # {{ vars }} resolved with the host scope

[files."/etc/sysctl.d/99-forward.conf"]   # ensure one line is present
line = "net.ipv4.ip_forward = 1"

[files."/etc/hosts.deny"]          # ensure a contiguous block of lines
block = """
sshd: ALL
ALL: LOCAL
"""

[files."/etc/default/legacy"]      # symlink: src is the target
state = "link"
src = "/etc/default/legacy.new"

[files."/tmp/stale.conf"]          # removal of whatever is there
state = "absent"
```

| Attribute | Default | Description |
|---|---|---|
| `state` | `"file"` | `"file"`, `"link"` (`src` is the link target), `"absent"` (removes the path). |
| `content` | — | The exact file content; `{{ }}` rendered inline. |
| `src` | — | Copy this project file verbatim — byte-exact, binary files (keyrings, archives) included. Presence/drift is detected by comparing sha256 checksums, so file content never travels back over the transport. |
| `template` | — | Path to a template file (like `src`, resolved relative to the defining tasks file); its content is rendered with the variable scope and becomes the managed content. |
| `line` | — | Ensure this line is present anywhere in the file (whole-line match); appended, newline-terminated, only when missing. |
| `block` | — | Same for a contiguous block of lines, in order. |
| `mode` | — | Octal string or integer. |
| `owner`, `group` | — | Enforced after content. |

With no content source at all, the entry only ensures the file exists.
`src` and `template` resolve inside the project (also in bundled runs).

---

### `[packages]` — system packages

Keyed by `"<manager>:<name>"`; only `apt` is implemented for now. State is
probed read-only with `dpkg-query`; mutations run `apt-get install -y` /
`remove -y` with `DEBIAN_FRONTEND=noninteractive`, so installs never block
on configuration prompts.

```toml
[packages]
"apt:curl" = {}                          # install if missing

[packages."apt:nginx"]                   # both spellings are the same
version = "latest"                       # (the default, spelled out)

[packages."apt:nginx"]                   # exact pin, as dpkg reports it
version = "1.22.1-9"

[packages."apt:vim-tiny"]                # removal
present = false
```

| Attribute | Default | Description |
|---|---|---|
| `version` | `"latest"` | `"latest"` only ensures presence (newer candidates are not looked for — no per-run network check). An explicit version pins exactly: it is compared against dpkg's `${Version}` (epoch-qualified, e.g. `"2:1.0-1"`) and repaired with `--allow-downgrades` when it differs. |
| `present` | `true` | `false` removes the package. A package left in `deinstall ok config-files` state counts as absent. |

Keys are validated at load time: a missing colon, an unknown manager or an
empty name is a load-time error.

---

### `[groups]` — groups

Keyed by group name, managed with shadow-utils.

```toml
[groups.deploy]
state = "present"                # the default, spelled out

[groups.legacy]
state = "absent"                 # groupdel
```

| Attribute | Default | Description |
|---|---|---|
| `state` | `"present"` | `"absent"` removes the group. Removing a group that is still a user's primary group fails with a hint (remove the user first — e.g. in an earlier tasks file). |

---

### `[users]` — users

Keyed by user name, managed with shadow-utils (probed via `getent`).
Missing users are created with the declared attributes; for existing
users, only *explicitly set* attributes are enforced — drift is repaired
with a single `usermod`.

```toml
[users.deploy]
group = "deploy"                 # primary group (default: a group named
groups = ["docker"]              # after the user); supplementary groups
shell = "/bin/bash"              # are ADDITIVE — only missing memberships
comment = "deployment account"   # are added, others are kept
home = "/srv/deploy"             # home drift is moved with usermod -m -d

[users.temp]
state = "absent"                 # userdel
remove_home = true               # userdel -r: delete the home directory too
```

| Attribute | Default | Description |
|---|---|---|
| `group` | group named after the user | Primary group; must exist (see `[groups]`). |
| `groups` | — | Supplementary groups, additive only. |
| `shell` | `/bin/sh` (at creation) | Login shell. |
| `comment` | — | GECOS comment. |
| `create_home` | `true` (at creation) | `useradd -m`/`-M`. |
| `home` | `/home/<name>` (at creation) | Home directory; when repaired on an existing user, its contents move. |
| `state` | `"present"` | `"absent"` removes the user. |
| `remove_home` | `false` | With `state = "absent"`: also delete the home directory. |

---

### `[services]` — systemd services

Keyed by unit name. Queries `systemctl is-active` / `is-enabled` and acts
only on mismatch; `restarted`/`reloaded` always act. With `src` or
`template` the unit file itself is managed first.

```toml
[services.nginx]
state = "started"
enabled = true

[services."my_service"]          # unit file rendered from a template
state = "started"
template = "templates/my_service.service.tmpl"
vars = { service_user = "example" }   # local context (template only)

[services."second_service"]      # unit file copied verbatim
state = "enabled"
src = "services/second.service"
```

| Attribute | Default | Description |
|---|---|---|
| `state` | — | `started`, `stopped`, `restarted`, `reloaded` or `enabled` (ensure boot enablement without touching the running state). |
| `enabled` | — | Boolean; ensures the unit is (not) enabled at boot. |
| `src` | — | Manage the unit file: copy this file verbatim (binary-safe, checksum-compared), path relative to the defining tasks file. Mutually exclusive with `template`. |
| `template` | — | Manage the unit file: render this template with the host's variable scope (like `[files]`'s `template`). |
| `vars` | — | Table; a local variable context merged over the host scope for the rendering (local values win). Only meaningful with `template`. |

The managed unit file lives at `/etc/systemd/system/<name>` (`.service`
appended when the name has no suffix). On drift it is written and followed
by `systemctl daemon-reload`; a running service is **not** restarted —
use `state = "restarted"` to apply a new unit definition. Check mode
reports the would-be write without touching the host.

---

### `[compose]` — Docker Compose stacks

Keyed by the stack's project directory (absolute). The key injects `dir`;
`file` names the compose file — relative means inside `dir`, so the
natural pairing is a `[files]` entry deploying `<dir>/<file>` first
(files run long before compose). The host needs the `docker` CLI with
the compose plugin and a reachable container engine.

```toml
[compose."/srv/app"]
file = "compose.yml"                # required; relative: inside dir
project = "myapp"                   # default: lowercased basename of dir
services = ["backend", "db"]        # default: every service the file enables
state = "running"                   # running (default) | stopped | absent

pull = "missing"                    # missing (default) | always | never
build = "auto"                      # auto (default) | always | never
recreate = "auto"                   # auto (default) | always | never
wait = true                         # wait for running/healthy after up
wait_timeout = 300                  # cap for that wait, in seconds
timeout = 30                        # stop/shutdown timeout, in seconds

remove_orphans = true               # stopped: drop containers whose
                                    # service left the compose model
remove_volumes = true               # absent: also remove named volumes
remove_images = true                # absent: also remove service images
```

| Attribute | Default | Description |
|---|---|---|
| `file` | required | The compose file. Absolute, or relative to `dir` (`dir/file`). |
| `state` | `running` | `running` runs `compose up --detach`; `stopped` runs `compose stop`; `absent` runs `compose down`. |
| `project` | derived | Project name passed as `-p`; the default is what compose itself derives: the lowercased `dir` basename, everything outside `[a-z0-9_-]` removed. An explicit name must match `[a-z0-9][a-z0-9_-]*`. |
| `services` | all | Subset of the file's services (unknown names are errors). Empty or absent means every service the selected file enables (compose excludes profile-gated services). |
| `pull` | `missing` | `--pull` policy for `up`: `missing`, `always` or `never`. |
| `build` | `auto` | `always` adds `--build`, `never` adds `--no-build`. |
| `recreate` | `auto` | `always` adds `--force-recreate`, `never` adds `--no-recreate`. |
| `wait` | `true` | Add `--wait` to `up`, so it returns only once every selected service runs (and passes its healthcheck). |
| `wait_timeout` | — | `--wait-timeout`, in seconds. Only meaningful with `wait = true` / `state = "running"`. |
| `timeout` | — | `-t`, the stop/shutdown timeout in seconds, passed to `up`, `stop` and `down`. |
| `remove_orphans` | `false` | With `state = "stopped"`: remove containers of the project whose service is no longer in the compose model, through the container engine (`docker rm -f`). |
| `remove_volumes` | `false` | With `state = "absent"`: also remove the project's named volumes (`down --volumes`). |
| `remove_images` | `false` | With `state = "absent"`: also remove the services' images (`down --rmi all`). |

Idempotence is probe-then-act, read-only:

- `running`: for every selected service, a container that is running,
  healthy (when its service defines a healthcheck — no healthcheck means
  running is all that can hold) and whose `com.docker.compose.config-hash`
  label equals the canonical `docker compose config --hash` value. Any
  drift — missing or stopped container, stale config hash, unhealthy
  container — triggers one `up --detach` with the policy flags above,
  after which the probe is re-run and any remaining drift fails the host.
- `stopped`: acts only when a selected service still has a running
  container. Containers, networks and volumes are preserved.
- `absent`: probes the container engine for anything carrying the
  project's label (containers, networks, and — with `remove_volumes` —
  named volumes) and is a no-op when nothing exists; the compose file is
  only read when something actually has to go.

Check mode reports the would-be `up`/`stop`/`down` without running it.
The probes themselves always run, so a missing compose file or an
unreachable engine is reported even in check mode.

---

### `[execute]` — command checks

Keyed by a unique task name. Runs a shell command **in the defining tasks
file's directory** (relative paths resolve next to the file that declares
the job) and asserts on its exit status and/or output. A passing job
reports `ok` and never `changed`; a failed assertion fails the host with
the actual status/output. Execute jobs are checks by nature: they run even
in check mode, so keep mutating commands out of them.

```toml
[execute."check if debian"]
run = "source /etc/os-release; echo $ID"
output = "debian"                         # exact match on trimmed output

[execute."port is listening"]
run = "ss -tln | grep -q ':8080 '"
exit_status = 0

[execute."not a crash"]
run = "pgrep -x app"
exit_status = { not = 1 }                 # anything but 1

[execute."load is sane"]
run = "cat /proc/loadavg | cut -d' ' -f1"
exit_status = { cond = "< 4" }            # operator and value

[execute."mentions version"]
run = "app --version"
output = { contains = "1.2." }            # substring

[execute."version format"]
run = "app --version"
output = { matches = "^1\\.\\d+\\.\\d+$" } # regex
```

| Attribute | Default | Description |
|---|---|---|
| `run` | required | The shell command; templated like every string. |
| `exit_status` | `0` | An integer, `{ not = N }`, or `{ cond = "OP N" }` with OP one of `==`, `!=`, `<`, `<=`, `>`, `>=`. |
| `output` | — | A string (exact match on the trimmed output), `{ contains = "..." }`, or `{ matches = "regex" }` (invalid patterns are load-time errors). |
