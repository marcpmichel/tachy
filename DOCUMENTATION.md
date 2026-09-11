# tachy — documentation

## Purpose

tachy is a small, agentless configuration-management tool: you describe the
state machines should be in — packages installed, files written, users
created, services running — in **Pravic tasks files** (tachy's own
configuration language, specified in `LANGUAGE.md`), and tachy makes it so,
idempotently. Run it twice and the second run changes nothing.

Core ideas:

- **Idempotent "ensure" jobs.** Every managed resource is a statement keyed
  by its target (a path, a package name, a user…). tachy inspects the
  current state first and only acts — and reports `changed` — when it
  differs. Check mode (`tachy check`) reports would-be changes without
  touching anything.
- **One binary, no agent.** For every selected host, tachy copies the
  project directory — and itself — to a temporary directory on the host and
  runs the copy there, over SSH (or locally). The remote host needs nothing
  but a POSIX shell with GNU coreutils, `tar`, and systemd for services.
  Controller and hosts must be linux/amd64 (the copied binary is the
  controller's own).
- **Source order.** Jobs run in the order their statements appear in the
  file — dependencies are yours to sequence: a `directory` statement above
  the files that live in it, a user's primary `group` above the `user`, a
  health `ensure` between the statements it checks.
- **Everything is shell.** All inspection and mutation is expressed as
  POSIX shell commands with strict quoting, built and executed through one
  transport; nothing is decoded or interpreted in between (file copies are
  byte-exact and compared by checksum).

### A simple example

`inventory.pravic` — the hosts:

```pravic
var site_owner = "www-data"       # global variable, lowest precedence

host web1 {
    address = "192.168.1.10"
    user = "root"
    tags = ["web"]
}

host web2 {
    address = "192.168.1.11"
    user = "root"
    tags = ["web"]
}
```

`main.pravic` — the state (a tasks file's parent directory is its
*project*), with `index.html.tmpl` next to it containing
`hello {{ site_owner }} on port {{ http_port }}`:

```pravic
var http_port = 8080              # tasks-file variables

directory /srv/www {
    mode = "0755"
    owner = "{{ site_owner }}"
}

file /srv/www/index.html {
    template = "index.html.tmpl"  # rendered with the variables above
    mode = "0644"
}

ensure "content rendered" {
    run = "cat /srv/www/index.html"
    output = { contains = "hello" }
}
```

Run it against a tag:

```sh
$ tachy apply '@web'
== main.pravic | hosts: web1, web2
web1 | changed         | directory /srv/www: created directory; owner root -> www-data
web1 | changed         | file /srv/www/index.html: created file
web1 | ok              | ensure content rendered: exit 0
web2 | changed         | directory /srv/www: created directory; owner root -> www-data
web2 | changed         | file /srv/www/index.html: created file
web2 | ok              | ensure content rendered: exit 0
-- main.pravic: ok=2 changed=4 failed=0
```

A second run prints `ok=6 changed=0 failed=0` — nothing left to do.

---

## Command line

```
tachy <command> [options] <selection> [<tasks.pravic>...]
```

- The first argument is a **command** word:

  | Command | Description |
  |---|---|
  | `apply` | Apply the tasks files to the selected hosts. |
  | `check` | Check mode: report the changes that would be made, apply nothing. `ensure` jobs still run — they are checks by nature. |
  | `hosts` | Inspect hosts without running anything — see [hosts](#hosts). |
  | `generate` | Create something new — see [generate](#generate). |
  | `webui` | Start a local web server, a graphical version of the CLI — see [Web UI](#web-ui-tachy-webui). |
  | `webdoc` | Serve this documentation as a browsable web site — see [Web docs](#web-docs-tachy-webdoc). |
  | `man` | Print the full built-in manual, unix man-page style — see [man](#man). |
  | `version` | Print the version: the build date, `YY.mm.dd` — see [version](#version). |
  | `help` | Show the short help: project and usage lines, commands, options (same as `--help`). |

- `<selection>` is a comma-separated list of host names and `@tag`
  selectors; the special selector `all` matches every host.
  Examples: `web1`, `web1,web2`, `@web,@db`, `@web,buildbox`, `all`.
- A tasks-file argument may be a **directory**: its `main.pravic` is the
  entry point. With no tasks-file argument at all, `main.pravic` in the
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
| `-i, --inventory PATH` | Inventory file (default: `inventory.pravic`). |
| `-v, --verbose` | Show executed commands and change details under each job line. |
| `--keep-bundle` | Keep each host's temporary bundle directory after the run (project copy, generated inventory, report) and print its location — for debugging. |
| `--direct` | Apply tasks files directly in this process, without bundling a project (this is how the copied binary runs on each host). |
| `--direct-report P` | With `--direct`: write `ok changed failed` counters to P. |
| `--events` | Print one JSON event per line on stdout instead of text (machine mode). |
| `--config PATH` | Optional config file (see [config](#config-configpravic)); default: `TACHY_CONFIG`, then `./config.pravic`, then `~/.config/tachy/config.pravic`. |
| `--identity PATH` | Age identity for `{ age = ... }` inventory vars and `file` sources marked `age = true`; supersedes the config file's `identity` entry. Default: that entry, then `AGE_IDENTITY` (path or key material), then `~/.ssh/id_ed25519` (age accepts ssh keys). |
| `--color` | Force colored statuses even when stdout is not a tty. |
| `--address ADDR`, `--port PORT` | Webui/webdoc only: address (default 127.0.0.1) and port to listen on. The default port (and `0`) is a random port between 10000 and 65534 — both commands are localhost conveniences; the bound URL is printed, and tachy tries to open it in the local browser (`gio open`, best-effort). |

### hosts

`tachy hosts` inspects the inventory; it never contacts a host and
needs no tasks file. It honours `-i/--inventory` and `--identity`
like every other command.

- `tachy hosts list [<selection>]` — lists the hosts a selection
  matches (default: `all`), one line per host with its connection
  target. This replaces the former `--list-hosts` option (removed).
- `tachy hosts info <host>` — one host's attributes: `connection`,
  `address`, `user`, `port`, `key` and `tags` (set keys plus the
  connection/port defaults), then its effective variables — global
  `<` host, sorted by name, values in Pravic syntax. Age-marked vars
  are decrypted on the controller like in a run, so pass
  `--identity`, the config `identity` entry or `AGE_IDENTITY` to
  see them.

Example: `tachy hosts list`, `tachy hosts list @web`,
`tachy hosts info web1`.


### generate

`tachy generate <what> <path>` creates scaffolding on the controller; it
never contacts a host and never overwrites an existing file.

- `tachy generate key <path>` — a new age key pair: the `age-keygen`
  binary writes the identity to `<path>` (mode 0600; it refuses to
  overwrite) and tachy relays the public key. The identity decrypts
  `{ age = ... }` inventory vars and `age = true` file sources (pass it
  with `--identity <path>` or `AGE_IDENTITY`); encrypt secrets with the
  printed public key: `age -r <pubkey> -o secret.age`. Requires
  `age-keygen` (it ships with the age package) on the controller.
- `tachy generate task <path>` — a commented sample tasks file exercising
  the common directives (`var`, `directory`, `file`, `ensure`, composition
- `tachy generate config <path>` — a commented sample config file
  (see [config](#config-configpravic)).

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

### version

`tachy version` prints the version: the build date in `YY.mm.dd` form
(for example `26.09.11`). The date lives in `source/assets/version`,
stamped in by dub's pre-build commands — only the `version` command
reads it, and rebuilding on a later day picks up the new date
automatically.

### Config (config.pravic)

Optional; read once at the start of every `apply`/`check` (and once
when the webui server starts). Discovery, first found wins:
`--config PATH`, the `TACHY_CONFIG` variable, `./config.pravic`,
then `$XDG_CONFIG_HOME/tachy/config.pravic` (default
`~/.config/tachy/config.pravic`). An explicit `--config` path or
`TACHY_CONFIG` that does not exist is an error; with no file found
anywhere, settings are empty. Unknown keys in the file are load-time
errors (strict). Today it holds the age `identity` entry and two
sections:

The top-level `identity` entry names the age identity file decrypting
`{ age = ... }` inventory vars and `age = true` file sources —
`identity "key.txt"` or `identity { path = "key.txt" }`, both forms
equivalent; a second entry is a load-time error. `--identity`
supersedes it; with neither, resolution falls back to `AGE_IDENTITY`,
then `~/.ssh/id_ed25519`. Like every config entry the path is
`~`-expanded and relative to the config file's directory.

| Section | Keys | Meaning |
|---|---|---|
| `imports` | `paths` | Array of directories searched, in order, for `import` keys that do not resolve relative to their defining tasks file (first existing match wins; unresolved keys keep the defining-relative path, which the deploy-time existence check reports). Entries are `~`-expanded; relative entries resolve against the config file's directory, never the cwd. |
| `webui` | `projects` | Array of project paths offered by [`tachy webui`](#web-ui-tachy-webui) in the browser. A directory is a project whose entry point is its `main.pravic`; a plain file is used as the entry point directly. Entries resolve like `imports.paths` (`~`-expanded, relative to the config file); existence is not required at load time — the interface reports missing paths per project. |

```pravic
identity "key.txt"

imports {
    paths = ["libs", "~/.config/tachy/imports"]
}

webui {
    projects = ["~/Code/site"]
}
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
self-contained: applies and `file.src`/`template` paths resolve inside
the copied project — `import` is the sanctioned way to pull external
files into the bundle.

### Web UI (tachy webui)

`tachy webui [--address ADDR] [--port PORT]` starts a local web server
(a random port between 10000 and 65534 by default — the bound
`http://127.0.0.1:<port>` URL is printed, and tachy tries to open it in
the local browser, `gio open`, best-effort) that is a graphical version
of the CLI:

- **Projects**: the `webui` `projects` list of config.pravic becomes
  a clickable sidebar (a directory is a project entered through its
  `main.pravic`; missing paths show struck through). The config file
  is read once when the server starts — restart it after editing it.
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
as a small web site (a random port between 10000 and 65534 by default,
like the webui — the URL is printed and the browser open is attempted)
— the same
ad-hoc web server as the webui and its stylesheet (`webui/app.css`:
one CSS for both sites, so the docs share the console's dark theme),
read-only:

- **One page per section**: `##` groups become menu groups (their page
  holds the group's intro), each `###` becomes a page inside its group;
  the left menu lists them in reading order.
- **Internal links work across pages**: `#anchor` links are resolved
  against every heading and rewritten to the page holding their
  target (both the hyphenated and the compact spelling, e.g.
  `#config-configpravic` and `#configconfigpravic`).
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

A tasks file is a sequence of **statements**, one per line — every
directive is an independent instruction (the full grammar lives in
`LANGUAGE.md`). Plural directives have two equivalent forms:

```pravic
files {                             # group form: a block of entries
    /etc/hosts { owner = "root" }
}

file /etc/other { owner = "root" }  # single form: the key inline
```

Keys are the targets; path keys need no quotes (`file /etc/nginx.conf
{ ... }`, `package apt:nginx { ... }`) — quote only spaces, braces and
templates. Block entries separate by commas and/or newlines; comments
are `#`. An instruction with no attributes may omit the braces
(`directory /tmp/two`, `import "../task2"`).

**Jobs run in source order**: the order statements appear in is the
order they execute, and `var`/`import` statements are not jobs — they
take effect file-wide. What a fixed order used to guarantee is now the
author's to express: a `directory` statement above the files that live
in it, a user's primary `group` above the `user`, a health `ensure`
between the statements it checks.

Every string — parameter values **and statement keys** — is templated with
`{{ name }}` / `{{ table.key }}` before use; `{{ inventory_hostname }}`
always holds the current host's name. Unknown variables and reference
cycles are hard errors.

Managing the same target twice for the same kind anywhere in a composition
(applies, the same file) is a load-time error.

---

### `var` / `vars` — variables

Variables for this file's jobs and everything it composes. Precedence:
global `var` (inventory) < host vars < apply chain < this file's own
statements. Entries may read the environment of the process loading the
file — the controller for inventory vars, the host for tasks-file vars in
bundled runs:

```pravic
var domain = "example.org"
var port = 8080
var db_host = { env = "DB_HOST" }                        # from the environment
var db_fallback = { env = "DB_HOST", default = "localhost" }
var secret_var = { env = "SECRET_VAR", from = ".env" }   # from a dotenv file
```

| Entry | Description |
|---|---|
| `{ age = "path" }` | Inventory vars only: replaced by the age-decrypted content of `path` (relative to the inventory; one trailing newline stripped). Decrypted on the controller with the identity from `--identity PATH`, the config `identity` entry, `AGE_IDENTITY` (path or key material — stdin, never on disk) or `~/.ssh/id_ed25519`; cannot combine with `env`/`default`/`from`; plaintext must be valid UTF-8. |
| `{ env = "NAME" }` | Replaced by the environment variable `NAME`. Unset without a `default` is an error; set-but-empty resolves to the empty string. |
| `{ env = "NAME", from = "path" }` | Same, but the value is looked up in the dotenv file at `path` (relative to the declaring file) instead of the process environment; the environment is not consulted. `KEY=VALUE` lines, `#` comments, blank lines, optional `export ` prefix, single-line quoted values (double quotes process `\n \t \r \f \b \" \' \\`, single quotes are literal); empty values count, later keys win, malformed lines are errors naming file and line. `default` covers a key the file does not define; in bundled runs the file is read on the host, so it must live inside the project. |

---

### `apply` — composition

Composes another tasks file **at the statement's position**, binding
variables for it:

```pravic
apply "tasks/base.pravic" {          # bindings as the entry's keys
    env = "prod"
}

apply "tasks/net.pravic" {           # ...or grouped under vars (the same thing)
    vars { iface = "eth0" }
}
```

Scopes chain and flow forward through the composition: an applied
file's own vars and its bindings are visible to every statement after
the apply (statements *before* it do not see them). Composition
cycles are detected and reported. An entry naming an existing directory
uses its `main.pravic` — the same entry-point convention as a directory
argument on the command line.

| Spelling | Meaning |
|---|---|
| `key = "value"` (entry keys) | The binding for the composed file. |
| `vars { ... }` sub-block | Same binding, grouped. Mixing both for one variable is an ambiguity error. |

### `import` — external files in the bundle

Bundled mode only. An `import` statement names a file or directory
outside the project (absolute, or relative to the defining tasks file,
like every path) that is copied into the bundle next to the project
copy under its **base name** — so `src`, `template` and `run`
references resolve on the host:

```pravic
import ../shared/install_gogs

file /opt/gogs/setup.sh {
    src = "install_gogs/setup.sh"   # reads the imported copy
    mode = "0755"
}
```

Imports take no parameters (so the braces are optional). A key that does not
resolve relative to its defining file is searched in the
[config](#config-configpravic) `imports` paths. Sources are validated on
the controller at deploy time (existence, and a destination that does
not collide with project content or another import — imports never
overwrite anything). Direct runs (`--direct`, including the on-host
inner run, where the copies already sit inside the project) parse and
ignore the directive.

**Composing imported tasks files.** An `apply` whose path falls
under — or names — a declared import's destination does not exist on the
controller — so it *defers*: the controller skips it at load time, and
the on-host inner run composes it there, with its variable binding, at
the apply's position in the file (a directory entry resolves to its
`main.pravic`, as everywhere). If the file is readable locally
after all, it composes normally:

```pravic
import ../tasks/install_gogs

apply install_gogs/gogs.pravic {     # deferred: composed on the host
    gogs_user = "deployer"           # bindings flow into it
}
```

Consequences: controller-side validation cannot see inside a deferred
subtree (the on-host load catches errors there, failing only that
host), and a manual `--direct` run without a bundle skips deferred
entries with a warning on stderr.

---

### `directory` — directories

Keyed by absolute path. Created with parent directories when missing;
mode/owner/group enforced on every run.

```pravic
directory /srv/app {
    mode = "0755"
    owner = "app"
    group = "app"
}

directory /srv/old {                # removal
    state = "absent"
}
```

| Attribute | Default | Description |
|---|---|---|
| `state` | `"directory"` | `"directory"` ensures it exists; `"absent"` removes whatever is there (`rm -rf`). |
| `mode` | — | Octal string (`"0755"`) or integer (`0o755`). |
| `owner`, `group` | — | User/group names, enforced with chown. |

---

### `file` — files, links, removal

Keyed by path. Four mutually exclusive content sources — `content`,
`src`, `template`, and the `line`/`block` pair — plus `state`:

```pravic
file /etc/app/app.conf {            # literal content, templated inline
    content = "port = {{ http_port }}\n"
    mode = "0644"
    owner = "root"
}

file /usr/local/bin/tool {          # verbatim copy from the project
    src = "files/tool"              # (binary-safe; compared by checksum)
    mode = "0755"
}

file /etc/nginx/site.conf {         # rendered from a template file
    template = "site.conf.tmpl"     # {{ vars }} resolved with the host scope
}

file /etc/sysctl.d/99-forward.conf {   # ensure one line is present
    line = "net.ipv4.ip_forward = 1"
}

file /etc/hosts.deny {              # ensure a contiguous block of lines
    block = """
sshd: ALL
ALL: LOCAL
"""
}

file /etc/default/legacy {          # symlink: src is the target
    state = "link"
    src = "/etc/default/legacy.new"
}

file /tmp/stale.conf {              # removal of whatever is there
    state = "absent"
}
```

| Attribute | Default | Description |
|---|---|---|
| `state` | `"file"` | `"file"`, `"link"` (`src` is the link target), `"absent"` (removes the path). |
| `content` | — | The exact file content; `{{ }}` rendered inline. |
| `src` | — | Copy this project file verbatim — byte-exact, binary files (keyrings, archives) included. Presence/drift is detected by comparing sha256 checksums, so file content never travels back over the transport. |
| `age` | — | Boolean marking `src` as age-encrypted: the plaintext is decrypted on the controller (identity from `--identity`, the config `identity` entry, `AGE_IDENTITY` or `~/.ssh/id_ed25519`, like `{ age = ... }` vars) and deployed byte-exact — binary secrets fit, unlike in variables. Not templated, no newline stripping. Requires `src`, `state = "file"` only; in bundled runs the controller ships the plaintext inside the temporary bundle over the ciphertext copy (the identity never travels). See [Secrets](#secrets-age). |
| `template` | — | Path to a template file (like `src`, resolved relative to the defining tasks file); its content is rendered with the variable scope and becomes the managed content. |
| `line` | — | Ensure this line is present anywhere in the file (whole-line match); appended, newline-terminated, only when missing. |
| `block` | — | Same for a contiguous block of lines, in order. |
| `mode` | — | Octal string or integer. |
| `owner`, `group` | — | Enforced after content. |

With no content source at all, the entry only ensures the file exists.
`src` and `template` resolve inside the project (also in bundled runs);
so must an `age`-marked `src`, for the same reason.

---

### `package` — system packages

Keyed by `"<manager>:<name>"`; only `apt` is implemented for now. State is
probed read-only with `dpkg-query`; mutations run `apt-get install -y` /
`remove -y` with `DEBIAN_FRONTEND=noninteractive`, so installs never block
on configuration prompts.

```pravic
package apt:curl { }                # install if missing

package apt:nginx {
    version = "latest"              # (the default, spelled out)
}

package apt:nginx {
    version = "1.22.1-9"            # exact pin, as dpkg reports it
}

package apt:vim-tiny {              # removal
    present = false
}
```

| Attribute | Default | Description |
|---|---|---|
| `version` | `"latest"` | `"latest"` only ensures presence (newer candidates are not looked for — no per-run network check). An explicit version pins exactly: it is compared against dpkg's `${Version}` (epoch-qualified, e.g. `"2:1.0-1"`) and repaired with `--allow-downgrades` when it differs. |
| `present` | `true` | `false` removes the package. A package left in `deinstall ok config-files` state counts as absent. |

Keys are validated at load time: a missing colon, an unknown manager or an
empty name is a load-time error.

---

### `group` — groups

Keyed by group name, managed with shadow-utils.

```pravic
group deploy {
    state = "present"               # the default, spelled out
}

group legacy {
    state = "absent"                # groupdel
}
```

| Attribute | Default | Description |
|---|---|---|
| `state` | `"present"` | `"absent"` removes the group. Removing a group that is still a user's primary group fails with a hint (remove the user first — e.g. in a statement above it). |

---

### `user` — users

Keyed by user name, managed with shadow-utils (probed via `getent`).
Missing users are created with the declared attributes; for existing
users, only *explicitly set* attributes are enforced — drift is repaired
with a single `usermod`.

```pravic
user deploy {
    group = "deploy"                # primary group (default: a group named
    groups = ["docker"]             # after the user); supplementary groups
    shell = "/bin/bash"             # are ADDITIVE — only missing memberships
    comment = "deployment account"  # are added, others are kept
    home = "/srv/deploy"            # home drift is moved with usermod -m -d
}

user temp {
    state = "absent"                # userdel
    remove_home = true              # userdel -r: delete the home directory too
}
```

| Attribute | Default | Description |
|---|---|---|
| `group` | group named after the user | Primary group; must exist (see `group`). |
| `groups` | — | Supplementary groups, additive only. |
| `shell` | `/bin/sh` (at creation) | Login shell. |
| `comment` | — | GECOS comment. |
| `create_home` | `true` (at creation) | `useradd -m`/`-M`. |
| `home` | `/home/<name>` (at creation) | Home directory; when repaired on an existing user, its contents move. |
| `state` | `"present"` | `"absent"` removes the user. |
| `remove_home` | `false` | With `state = "absent"`: also delete the home directory. |

---

### `service` — systemd services

Keyed by unit name. Queries `systemctl is-active` / `is-enabled` and acts
only on mismatch; `restarted`/`reloaded` always act. With `src` or
`template` the unit file itself is managed first.

```pravic
service nginx {
    state = "started"
    enabled = true
}

service my_service {                # unit file rendered from a template
    state = "started"
    template = "templates/my_service.service.tmpl"
    vars { service_user = "example" }   # local context (template only)
}

service second_service {            # unit file copied verbatim
    state = "enabled"
    src = "services/second.service"
}
```

| Attribute | Default | Description |
|---|---|---|
| `state` | — | `started`, `stopped`, `restarted`, `reloaded` or `enabled` (ensure boot enablement without touching the running state). |
| `enabled` | — | Boolean; ensures the unit is (not) enabled at boot. |
| `src` | — | Manage the unit file: copy this file verbatim (binary-safe, checksum-compared), path relative to the defining tasks file. Mutually exclusive with `template`. |
| `template` | — | Manage the unit file: render this template with the host's variable scope (like `file`'s `template`). |
| `vars` | — | Table; a local variable context merged over the host scope for the rendering (local values win). Only meaningful with `template`. |

The managed unit file lives at `/etc/systemd/system/<name>` (`.service`
appended when the name has no suffix). On drift it is written and followed
by `systemctl daemon-reload`; a running service is **not** restarted —
use `state = "restarted"` to apply a new unit definition. Check mode
reports the would-be write without touching the host.

---

### `compose` — Docker Compose stacks

Keyed by the stack's project directory (absolute). The key injects `dir`;
`file` names the compose file — relative means inside `dir`, so the
natural pairing is a `file` statement deploying `<dir>/<file>` first
(statements run in source order). The host needs the `docker` CLI with
the compose plugin and a reachable container engine.

```pravic
compose /srv/app {
    file = "compose.yml"            # required; relative: inside dir
    project = "myapp"               # default: lowercased basename of dir
    services = ["backend", "db"]    # default: every service the file enables
    state = "running"               # running (default) | stopped | absent

    pull = "missing"                # missing (default) | always | never
    build = "auto"                  # auto (default) | always | never
    recreate = "auto"               # auto (default) | always | never
    wait = true                     # wait for running/healthy after up
    wait_timeout = 300              # cap for that wait, in seconds
    timeout = 30                    # stop/shutdown timeout, in seconds

    remove_orphans = true           # stopped: drop containers whose
                                    # service left the compose model
    remove_volumes = true           # absent: also remove named volumes
    remove_images = true            # absent: also remove service images
}
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

### `ensure` — command checks

Keyed by a unique task name. Runs a shell command **in the defining tasks
file's directory** (relative paths resolve next to the file that declares
the job) and asserts on its exit status and/or output. A passing job
reports `ok` and never `changed`; a failed assertion fails the host with
the actual status/output. `ensure` jobs are checks by nature: they run even
in check mode, so keep mutating commands out of them.

```pravic
ensure "is debian" {
    run = "source /etc/os-release; echo $ID"
    output = "debian"              # exact match on trimmed output
}

ensure "port is listening" {
    run = "ss -tln | grep -q ':8080 '"
    exit_status = 0
}

ensure "not a crash" {
    run = "pgrep -x app"
    exit_status = { not = 1 }      # anything but 1
}

ensure "load is sane" {
    run = "cat /proc/loadavg | cut -d' ' -f1"
    exit_status = { cond = "< 4" } # operator and value
}

ensure "mentions version" {
    run = "app --version"
    output = { contains = "1.2." } # substring
}

ensure "version format" {
    run = "app --version"
    output = { matches = "^1\\.\\d+\\.\\d+$" }   # regex
}
```

| Attribute | Default | Description |
|---|---|---|
| `run` | required | The shell command; templated like every string. |
| `exit_status` | `0` | An integer, `{ not = N }`, or `{ cond = "OP N" }` with OP one of `==`, `!=`, `<`, `<=`, `>`, `>=`. |
| `output` | — | A string (exact match on the trimmed output), `{ contains = "..." }`, or `{ matches = "regex" }` (invalid patterns are load-time errors). |

## Secrets (age)

Secrets never sit in plain tasks or inventory files. Two mechanisms,
one identity: `--identity PATH`, the `identity` entry in
[config](#config-configpravic) (superseded by the flag), the
`AGE_IDENTITY` environment variable (an existing file path, or raw key
material — fed to age on stdin, never written to disk), or by default
`~/.ssh/id_ed25519` (age accepts ed25519 ssh keys natively, so the
deployment key can double as the decryption key; encrypt with
`age -R ~/.ssh/id_ed25519.pub`). Decryption happens on the controller
only — the identity never travels inside a bundle.

**Vars** (inventory only — tasks-file vars resolve on hosts, which hold
no identity): an entry of the form `{ age = "file.age" }` is replaced
by the decrypted content of the named file (path relative to the
inventory; one trailing newline stripped, so
`echo secret | age -r … > f.age` files work as-is). Plaintext must be
valid UTF-8; markers cannot combine with `env`/`default`/`from`, and a
failed decryption is a load-time error naming the entry and file.

```pravic
vars {
    db_password = { age = "secrets/db_password.age" },
}
```

**Files** (binary-safe): a `file` source marked `age = true` is
decrypted on the controller and deployed byte-exact — keyrings, TLS
keys and other binary secrets that cannot fit variables. The plaintext
is not templated and nothing is stripped.

```pravic
file /etc/tls/web1.key {
    src = "secrets/web1.key.age"
    age = true
    mode = "0600"
}
```

In bundled runs the controller decrypts the source when building each
host's temporary bundle and writes the plaintext over the ciphertext
copy — the same trust the generated inventory already extends to
decrypted vars, and `--keep-bundle` retains it. With `--direct` (no
bundle) the source is decrypted in-process with the same identity
resolution, so a still-encrypted source there is an error naming the
identity options. The source path resolves like `src` (relative to the
defining tasks file) and must live inside the project — or under an
`import` destination: when the composition defers applies there, the
controller mirrors the bundle's layout in a temporary staging directory
(project entries plus landed imports, as symlinks) and composes the
entry file again in that mirror — a shadow composition that sees the
deferred subtree exactly as the on-host run will, so its `age = true`
sources are decrypted and shipped like any other (and errors in the
deferred subtree surface on the controller, before hosts are
contacted).

## Editor syntax

`syntax/pravic.vim` in the repository is a Vim and Neovim syntax file
for Pravic. It mirrors the grammar in LANGUAGE.md: directive keywords
carry the parser's own boundary guard (`vars-foo` and `varsite` stay
plain keys), bare tokens in key position are highlighted as keys and
targets, strings know their four kinds with `{{ ... }}` templates and
escapes, numbers follow the TOML lexical layer, and `#` starts a
comment. To use it, copy the file to `~/.vim/syntax/` (Neovim:
`~/.config/nvim/syntax/`) and detect the filetype once in your vimrc or
init file:

```vim
autocmd BufNewFile,BufRead *.pravic setfiletype pravic
```

Then every `main.pravic`, `inventory.pravic` and `config.pravic`
opens colorized.
