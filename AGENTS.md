

# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

# Project

- tachy: Pravic-driven configuration management (Ansible-like) in D —
  see `README.md` (tour), `DOCUMENTATION.md` (full reference) and
  `LANGUAGE.md` (the Pravic spec); `dub.json` is the build manifest
  (DMD + dub, zero runtime dependencies; `silly` is the test-only
  dependency of its `unittest` configuration, which compiles `tests/`
  alongside `source/` — `stringImportPaths` embeds the app.d help/man
  text assets in `source/assets/`, the webui assets (`app.css` is
  shared with the webdoc pages) and the root `DOCUMENTATION.md`)
- `LANGUAGE.md` is the spec for **Pravic**, tachy's configuration
  language (implemented): directives as independent statements
  (`vars { ... }` block form, `var X = "v"` single form;
  `apply`/`ensure`/`compose`/`import` single form only), jobs run in
  statement order — no fixed order, no sorting; hooks and the group
  forms of `apply`/`ensure` do not exist, `execute` was renamed
  `check` then `ensure`, `include` became `apply`, and TOML support
  is gone (no dual reader ever shipped)
- CLI shape: `tachy <command> [options] <selection> [<tasks.pravic>...]`;
 command is one of `apply`, `check` (check mode; the old `-c` option is
 gone), `hosts` (`hosts list [<selection>]` — `all` when omitted,
 `hosts info <host>`; the old `--list-hosts` option is gone),
 `generate` (`generate key <path>`,
 `generate task <path>`, `generate config <path>`),
 `webui` (local web console; no selection — projects come from
 config.pravic `webui` projects, runs start from the browser),
 `webdoc` (serves the compiled-in DOCUMENTATION.md as a multi-page
 site; no selection, read-only), `man` (prints the full built-in
 manual, unix man-page style), `version` (prints the version — the
 build date `YY.mm.dd`, kept in `source/assets/version` and refreshed
 by dub's preBuildCommands) or
 `help` (short form only: usage lines, commands, options); selection
 mixes host names, `@tag` and `all`; default inventory
 `inventory.pravic`, default tasks file `main.pravic` (a directory
 argument maps to its `main.pravic`)
- `syntax/` ships editor syntax coloring for Pravic (Vim/Neovim
  `pravic.vim`, installed by hand — see README "Editor syntax")
- `sessions/` holds saved session records (inert artifacts, not inputs to code or docs)
- TODO.md / DONE.md are the task ledger: pending work arrives as TODO.md entries

# Durable workflow rules

- Task loop: perform the TODO.md entry, then move it to DONE.md as the next numbered item summarising implementation, tests and verification evidence (commands run, outcomes); leave TODO.md with just its header when empty
- Every user-visible behavior change updates the doc trio together: `--help` text in `source/app.d`, `README.md`, `DOCUMENTATION.md`
- Unit tests defend the contract (`dub test`); new resource/directive work gets a scripted-transport unittest plus an end-to-end run when feasible
- End-to-end verification uses the `testing.internal` VM over ssh as root (Debian 12; `/bin/sh` is dash — use `.` not `source`): keep checks read-only or scoped to `/tmp`, and clean the VM and local scratch up afterwards
- Task files and inventories are strict: unknown keys, undefined variables, duplicate targets, cycles and escaping includes are load-time errors with file context — keep new parsing equally strict
- Pravic equivalence contract: the group form (`vars { ... }`) and the
  single form (`var X = "v"`) must stay equivalent for every plural
  directive; blocks are natively multi-line (commas and/or newlines
  between entries), a block that would be empty may be omitted
  (`directory /tmp/x`), and unquoted path keys
  (`file /etc/x.conf { ... }`) are part of the language — parser
  behavior must keep matching `LANGUAGE.md`

# Child DOX Index

- `source/AGENTS.md` — the D implementation tree: CLI, orchestration, inventory/tasks loading, templating, transports, project bundles; it indexes `source/tachy/modules/AGENTS.md` (job modules) itself
- `syntax/AGENTS.md` — editor syntax coloring for Pravic (Vim/Neovim
  format): the `pravic.vim` contract against LANGUAGE.md
