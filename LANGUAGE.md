# Pravic — tachy's configuration language

Status: **the language tachy implements.** The parser lives in
 `source/tachy/parser.d` (a hand-written recursive descent of the grammar
 below); every tasks, inventory and config file is Pravic, and TOML
 support is gone.  File extension `.pravic` (`main.pravic`,
 `inventory.pravic`, `config.pravic`); a directory entry point is its
 `main.pravic`.

## The name

**Pravic** is the constructed language of Anarres in Ursula K. Le Guin's
*The Dispossessed* — the same Hainish cycle that gave configuration
management the *ansible*. Pravic was designed to be minimal and to have
no possessives: a language for stating what is, not who owns it. That is
the right spirit for a configuration language: plain shared declarations.

Runners-up, in case Pravic is vetoed: **Ekumen** (the league of worlds —
independent members, one federation; a file is a federation of
independent statements), **Hain** (the origin world), **Kesh**
(*Always Coming Home*).

## Design

TOML's table headers make a file one anonymous data blob: `[vars]` opens
a table that silently extends until the next header, order carries no
meaning, and the two equivalent spellings of a keyed entry need a
preprocessing pass to stay interchangeable. Pravic replaces headers with
**statements**: every directive is an independent instruction, one per
line, in one of two shapes.

**Group form** — a directive whose name is plural, opening a block of
keyed entries (targets to parameter tables), the plural of the TOML
spelling:

```pravic
vars {
    MYVAR = "myvalue",
    port = 8080,
}
```

**Single form** — one entry as one instruction: the singular keyword,
the key inline, then the entry's body. For scalar-valued directives
(`var`) the body is `= value`; for table-valued directives it is a
brace block:

```pravic
var MYVAR = "myvalue"
file /etc/app.conf { mode = "0644" }
service nginx { state = "started", enabled = true }
```

An instruction with no attributes may omit the braces entirely:
`directory /tmp/two` and `import "../task2"` are complete statements,
in either form (`directories { /tmp/two }` says the same thing).

Every plural directive has both forms; they merge (two `var` statements
and one `vars` block naming the same variable is a duplicate-key error,
exactly as inside a single block). Directives with no plural —
`apply`, `ensure`, `compose`, `import` — only ever appear in the
single form, with the key inline, since they are keyed too. `webui`,
config's `imports` and config's `output` are group-form blocks whose
entries are plain data (no keyed targets), so they have no single
form. Config's `identity`
spells both forms with one word: `identity "key.txt"` (the path is the
key) and `identity { path = "key.txt" }` — a `{` after the keyword
picks the group form.

The **value layer is unchanged**: strings, integers, floats, booleans,
arrays and tables use TOML 1.0 lexical rules verbatim, so existing
parameter values copy across mechanically. Datetimes stay rejected (as
today). What changes is only structure syntax:

- `{ ... }` blocks are natively multi-line — entries are separated by
  commas and/or newlines, a trailing comma is allowed (the
  `joinInlineTables` preprocessing becomes the language itself).
- A block that would be empty may be omitted: `directory /tmp/two` is
  `directory /tmp/two { }`, in statements and in group entries alike.
  Only an empty block is omittable — anything after the key that is
  neither `{` nor `=` stays an error.
- Unquoted keys are opaque strings, not dotted paths: any character
  except whitespace, structural punctuation, quotes, `#`, `\` and
  control characters. `file /etc/nginx.conf { ... }` and
  `package apt:nginx { ... }` need no quotes (the `quotePathKeys`
  preprocessing becomes the language itself). Nesting is expressed by a
  brace block, never by dots in a key; keys containing `{{ ... }}`
  templates keep their quotes, as today.
- Keys are templated after parsing, exactly as today; `{{ name }}` in a
  quoted key or value behaves identically.
- Directive keywords are reserved only in statement position; as keys
  (`var vars = 1`, an entry named `files`) they are plain data.
- No dotted keys, no array-of-tables (`[[...]]`), no bare-key
  restriction, no datetimes — nothing tachy uses is lost.

One statement per line: a newline terminates a statement (newlines
inside braces and brackets are transparent). Comments are `#` to the
end of the line, everywhere a space may appear.

**Statements run in source order.** There is no fixed directive order
and no sorting by key: jobs execute in the order their statements
appear, and an `apply` composes its file at the statement's position.
`var`/`vars` and `import` are not jobs — they take effect
file-wide regardless of position. What the old fixed order used to
guarantee is now the author's to express: a `directory` statement
above the files that live in it, a user's primary `group` above the
`user`, a health `ensure` between the statements it checks.
Duplicate targets are still load-time errors.

## Grammar

A parsing expression grammar (W3C/pegged notation): `←` defines,
`/` is ordered choice (first match wins), `? * +` are repetition,
`!` is negative lookahead, `'…'` literals, `[…]` classes. The ordered
choice is what makes the keyword/path-key boundary mechanical:
keywords are tried with a `!KeyChar` guard, so `varsite` fails to parse
as `var site` and long/short spellings (`vars`/`var`) never collide.
A keyword registered in both sets (`identity`) takes its group form
when a `{` follows the keyword, its single form otherwise.
```peg
PravicFile   ← WS StmtList? WS EOF
StmtList     ← Stmt (LineEnd+ Stmt)*

GroupKeyword ← ( 'vars' / 'files' / 'directories' / 'packages'
               / 'groups' / 'users' / 'services' / 'repos' / 'asserts'
               / 'hosts' / 'imports' / 'webui' / 'identity' / 'output' ) !KeyChar
SingleKeyword ← ( 'var' / 'file' / 'directory' / 'package'
                / 'group' / 'user' / 'service' / 'host'
                / 'apply' / 'assert' / 'ensure' / 'compose' / 'import'
                / 'identity' / 'probe' / 'repo' / 'debug' ) !KeyChar
Block        ← '{' WS Entries? WS '}'
Entries      ← Entry (BSep Entry)* BSep?
Entry        ← Key HS (Block / Eq / EndOfEntry)   -- or nothing: no attributes
EndOfEntry   ← &(LineEnd / ',' / '}' / EOF)
Eq           ← '=' WS Value
BSep         ← WS ',' WS / LineEnd+ HS        -- comma and/or newline

Array        ← '[' WS (Value (ASep Value)* (WS ',')?)? ']'
ASep         ← WS ',' WS                      -- commas required between elements
Value        ← String / Float / Integer / Boolean / Array / Block
             / Choose                                         -- var assignations only
Choose       ← 'choose' !KeyChar String Block                 -- bare form, after '='
             / '{' WS 'choose' !KeyChar String Block WS '}'   -- wrapped form

Key          ← Basic / Literal / BareKey
BareKey      ← KeyChar+
KeyChar      ← !([ \t\r\n"'{}[]=,#\\] / [\x00-\x1F\x7F]) Char

String       ← MLBasic / Basic / MLLiteral / Literal
Basic        ← '"' BasicChar* '"'
BasicChar    ← EscSeq / !('"' / '\\' / '\n') Char
Literal      ← "'" (!("'" / '\n') Char)* "'"
MLBasic      ← '"""' Newline? MLBasicChar* '"""'
MLBasicChar  ← LineCont / EscSeq / !'"""' Char
MLLiteral    ← "'''" Newline? (!"'''" Char)* "'''"
EscSeq       ← '\\' ( 'b' / 't' / 'n' / 'f' / 'r' / '"' / '\\'
                     / 'u' HexDig HexDig HexDig HexDig
                     / 'U' HexDig HexDig HexDig HexDig HexDig HexDig HexDig HexDig )
LineCont     ← '\\' WS LineEnd WS              -- trims whitespace to next line

Float        ← [+-]? ( DecDigits (Frac Exp? / Exp) / 'inf' / 'nan' )
Integer      ← [+-]? ( '0x' HexDig (HexDig / '_')*
                     / '0o' [0-7] ([0-7] / '_')*
                     / '0b' [01]  ([01]  / '_')*
                     / DecInt )
DecInt       ← '0' / [1-9] (Digit / '_')*
DecDigits    ← Digit (Digit / '_')*
Frac         ← '.' DecDigits
Exp          ← [eE] [+-]? DecDigits
Digit        ← [0-9]
HexDig       ← [0-9A-Fa-f]
Boolean      ← 'true' / 'false'

HS           ← ([ \t\r] / Comment)*           -- horizontal skip, never '\n'
Comment      ← '#' (!'\n' Char)*
LineEnd      ← HS '\n'
WS           ← LineEnd* HS                    -- full skip, newlines transparent
Newline      ← '\n'
Char         ← any character
EOF          ← !Char
```

String semantics beyond the productions above (escape processing,
multi-line leading-newline trim, up to two unescaped quotes before the
closing `"""`) are TOML 1.0's, unchanged. `Value` tries `Float` before
`Integer` so `1.5`/`1e3` cannot split; arrays require commas between
elements (as in TOML) while blocks accept commas and/or newlines
(mirroring today's preprocessor-joined inline tables). A negative
(`var X { a = 1 b = 2 }`) is a parse error, not two entries.

`EndOfEntry` is the omitted-empty-block rule above made mechanical: an
entry with no attributes may simply end where it stands, so
`directory /tmp/two`, `package apt:curl` and `import "../task2"` need
no `{ }` — but `directory /tmp/two mode = "0755"` is a parse error,
not two statements.

`Choose` is a value form, not a statement: it is available only inside
a var assignation — the `var`/`vars` statements of tasks and inventory
files and the `vars` blocks of inventory `host` entries; a `choose`
anywhere else (job parameters, apply bindings, host attributes, config
entries) is a load-time error.  The block's entries are the cases:
their keys the patterns, and the `_` key the mandatory default (a
choose without `_` is a parse error, and `_` is reserved — a pattern
cannot be spelled `_`).  The selector must be a quoted string, usually
a `"{{ ... }}"` template.  Evaluation is lazy and scoped: at `{{ ... }}`
render time the selector is rendered first (against the scope doing the
rendering — per host in bundled runs), matched exactly against the
patterns, and the matching case's value is taken (the default when
nothing matches); the chosen value then renders in turn, so case
values may hold `{{ ... }}` references and even nested `choose`s.  A
choose stored in an inventory variable travels to hosts serialized
back to this same spelling inside the generated one-host inventory.

## Directive inventory

Same keys and the same validation strictness as before. Which
directives a file may use is decided by the loader (grammar accepts
the union, semantic pass rejects strays, e.g. `hosts` in a tasks
stay load-time errors with file context. Every `{{ ... }}` reference
(template files included) is additionally dry-rendered on the
controller against each selected host's effective variables before
anything is deployed — an undefined variable fails there, naming the
entry and the host.

Tasks files:

| Directive | Group form | Single form |
|---|---|---|
| variables | `vars { NAME = value }` | `var NAME = value` / `var NAME { ... }` |
| files | `files { target { ... } }` | `file target { ... }` |
| directories | `directories { ... }` | `directory target { ... }` |
| packages | `packages { ... }` | `package "mgr:name" { ... }` |
| groups | `groups { ... }` | `group name { ... }` |
| users | `users { ... }` | `user name { ... }` |
| services | `services { ... }` | `service unit { ... }` |
| repositories | `repos { ... }` | `repo target { ... }` |
| compose stacks | — | `compose /srv/stack { ... }` |
| command checks | — | `ensure "task name" { run = "..." }` — asserts on exit status/output; runs even in dry-run mode |
| assertions | `asserts { "name" = { ... } }` | `assert "name" { value = "...", ... }` — tests the rendered `value` against `ensure`'s `output` patterns (`equals`/`contains`/`matches`, composed with `not`/`any`/`all`/`none`); variables only, no host contact; runs even in dry-run mode |
| messages | — | `debug "message"` — prints the (templated) message as a job line, never fails and never changes anything; no attributes; runs even in dry-run mode |
| HTTP checks | — | `http "url" { ... }` — submits a request (`type`, `headers`, `data`) and asserts on status (`code`) and body (`output`, `ensure`'s shapes); `http://`/`https://`; redirects followed by default (up to 10), `redirects` = `"no"` or `{ max = N }`; `insecure` = true accepts invalid certificates |
| composition | — | `apply "path" { bindings }` — composes at its position; bindings as entry keys or grouped in a `vars` sub-block; a path under an `import` destination composes on the host |
| bundle imports | — | `import "path"` — no parameters (the braces are optional) |

Inventory files add `hosts { name { ... } }` / `host name { ... }`
(entries: `address`, `user`, `port`, `key`, `connection`, `tags`,
`vars`) and share `vars`/`var`. Config files use `identity "path"`
and `identity { path = "path" }` (both forms), plus `imports {
paths = [...] }`, `webui { projects = [...] }` and `output {
format = "flat" | "tree" }` — group form only.

## Examples

The README site example (`site/main.pravic`) — both former TOML
spellings become one:

```pravic
vars {
    domain = "example.org",
}

apply "base.pravic" {
    site_name = "main",
}

file "{{ doc_root }}/index.html" {
    template = "files/index.tmpl",
    mode = "0644",
}

file "{{ doc_root }}/robots.txt" {
    content = "User-agent: *\n",
    mode = "0644",
}

service nginx {
    state = "started",
    enabled = true,
}
```

`site/base.pravic`:

```pravic
var doc_root = "/srv/www"

# templated keys keep their quotes — braces are not bare-key characters
directory "{{ doc_root }}" {
    mode = "0755",
}
```

Checks between jobs, environment variables, imports:

```pravic
ensure "is debian" {
    run = "source /etc/os-release; echo $ID"
    output = "debian"
}

# output composes: several keys in one table all must hold,
# `not` negates one pattern, `any`/`all`/`none` hold when
# one/all/none of an array's patterns do
ensure "stable release" {
    run = "grep VERSION_CODENAME /etc/os-release"
    output = { contains = "bookworm", not = { contains = "sid" } }
}

ensure "debian family" {
    run = "source /etc/os-release; echo $ID"
    output = { any = ["debian", "ubuntu"] }
}

ensure "not a crash" {
    run = "pgrep -x app"
    exit_status = { not = 1 }
}

asserts {
    "port is the default" = { value = "{{ http_port }}", equals = "8080" }
    "sane environment"    = { value = "{{ deploy_env }}",
                              contains = "prod", not = { contains = "test" } }
}

service nginx {
    state = "started",
}

ensure "answers on port 80" {          # sits between jobs: source order
    run = "curl -fsS http://localhost/",
    exit_status = 0,
}

vars {
    db_fallback = { env = "DB_HOST", default = "localhost" },
    secret = { env = "SECRET_VAR", from = ".env" },
    host_ip = { run = "hostname -I" },                    # a command's stdout
    diag = { run = 'echo "error" >&2', stream = "stderr" },
}

import "../shared/install_gogs"

file /opt/gogs/setup.sh {
    src = "install_gogs/setup.sh"
    mode = "0755"
}
```

`choose` — a switch/case value, only inside a var assignation (both
spellings; `_` is the mandatory default):

```pravic
var country_code = "FR"

var label = {
    choose "{{ country_code }}" {
        "FR" = "France"
        "IT" = "Italy"
        _    = "Other"
    }
}

var test = { choose "{{ country_code }}" { "FR" = "France", "IT" = "Italy", _ = "Other" } }

file "/srv/www/welcome.txt" {
    content = "welcome to {{ label }}",
}
```

Inventory:

```pravic
vars {
    admin_key = { age = "secrets/admin.age" },
}

hosts {
    web1 {
        address = "192.0.2.10",
        tags = ["web", "prod"],
        vars { role = "primary" },
    }
}

host web2 {
    address = "192.0.2.11",
    tags = ["web"],
    vars { role = "secondary" },
}
```

Config:

```pravic
identity "key.txt"

imports {
    paths = ["/opt/tachy/shared"],
}

webui {
    projects = ["/srv/site"],
}

output {
    format = "tree",
}
```

## Semantics notes (decided)

1. **Duplicate statements.** The same directive key stated twice in one
   file (any mix of forms) is a parse error naming both lines — which
   makes duplicate targets and variables impossible to state within a
   file; across a composition the loader's duplicate-target detection
   still applies.  The same file applied from two different files
   remains legal.
2. **Implementation.** A hand-written recursive-descent parser in
   `source/tachy/parser.d` (the grammar above maps 1:1; chosen over
   `pegged` for `file: line N:` errors and zero dependencies) feeding
   the existing `Val` trees plus an ordered statement list.  One hard
   cutover: `loadToml` became `loadPravic`, the fixed per-file job
   order, its key sorting and the hooks are gone (jobs run in
   statement order), `joinInlineTables`/`quotePathKeys` and the
   `toml` dependency were deleted, and `generate` output, fixtures and
   the doc trio switched in the same change.
