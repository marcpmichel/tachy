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
  differs. Check mode (`-c`) reports would-be changes without touching
  anything.
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
$ tachy '@web'
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
tachy [options] <selection> [<tasks.toml>...]
```

- `<selection>` is a comma-separated list of host names and `@tag`
  selectors; the special selector `all` matches every host.
  Examples: `web1`, `web1,web2`, `@web,@db`, `@web,buildbox`, `all`.
- A tasks-file argument may be a **directory**: its `main.toml` is the
  entry point. With no tasks-file argument at all, `main.toml` in the
  current directory is used. Either way, the entry file's parent directory
  is the project that gets copied to each host.
- Exit code is `0` when everything succeeded, `1` when anything failed
  (unknown option, load error, unreachable host, failed job…). A failing
  host is dropped for the rest of its tasks file; other hosts continue.

### Options

| Option | Description |
|---|---|
| `-i, --inventory PATH` | Inventory file (default: `inventory.toml`). |
| `-c, --check` | Check mode: report the changes that would be made, apply nothing. Execute jobs still run — they are checks by nature. |
| `-v, --verbose` | Show executed commands and change details under each job line. |
| `--list-hosts` | List the hosts matching the selection, then exit. |
| `--keep-bundle` | Keep each host's temporary bundle directory after the run (project copy, generated inventory, report) and print its location — for debugging. |
| `--direct` | Apply tasks files directly in this process, without bundling a project. (This is how the copied binary runs on each host; use it manually for local execution.) |
| `--direct-report PATH` | With `--direct`: suppress headers/footers and write `ok changed failed` counters to PATH (machine mode). |
| `--color` | Force colored statuses even when stdout is not a tty (forwarded to the run on each host). |
| `-h, --help` | Show the help. |

### What a run does

For every selected host (bundled mode, the default) tachy creates
`/tmp/tachy.XXXXXXXXXX` on the host (respecting `TMPDIR`) containing a
copy of the project, a copy of the tachy binary, and a generated one-host
inventory carrying the host's variables; it then executes the copied
binary there. The bundle is removed when the run finishes — check mode
deploys and removes a bundle too but manages nothing. A project must be
self-contained: includes and `file.src`/`template` paths resolve inside
the copied project.

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
services, `[after.services]`, execute** — by key within each kind — with
`[includes]` running before all of them and `[apply]` after. Directories
precede files so a file can live in a directory the same file manages;
packages follow files so an apt repository config can be laid down first;
groups precede users so a user's primary group can be ensured in the same
file.

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
| scalar / table / array | Value(s), available as `{{ name }}`, `{{ table.key }}`. Variables may reference other variables; cycles are errors. |
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
the composition. Composition cycles are detected and reported.

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
only on mismatch; `restarted`/`reloaded` always act.

```toml
[services.nginx]
state = "started"
enabled = true

[services.app]
state = "restarted"              # acts on every run
```

| Attribute | Default | Description |
|---|---|---|
| `state` | — | `started`, `stopped`, `restarted` or `reloaded`. |
| `enabled` | — | Boolean; ensures the unit is (not) enabled at boot. |

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
