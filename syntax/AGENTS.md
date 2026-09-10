# AGENTS.md — syntax/

## Purpose

Editor syntax coloring for Pravic ([LANGUAGE.md](../LANGUAGE.md)).
Vim/Neovim format only, for now.

## Ownership

- `pravic.vim` — the Vim/Neovim syntax definition for `*.pravic`
  files: directive keywords with the grammar's `!KeyChar` guard,
  bare/quoted keys and targets, the TOML 1.0 value layer (strings,
  numbers, booleans), `{{ ... }}` templates, comments.

## Local Contracts

- `pravic.vim` tracks LANGUAGE.md in lockstep: the keyword list, the
  bare-key character class, string/number lexical rules and comment
  syntax change there, never only here.
- No additional editors/formats in this directory without a TODO.md
  entry (the current entry said "only vim/neovim for now").

## Work Guidance

- Structure: `pravicKey` (a bare token followed by `=`, `{`, `,`, `}`,
  `#` or end of line — the grammar has no bare values) is defined
  first; numbers/booleans/keywords follow, because at the same position
  the later item wins (and `syn keyword` always beats a match), which
  resolves `8080`, `true`, `inf` and `vars { var = 1 }` correctly.
- The keyword match implements `keyword !KeyChar` from the grammar via
  a `\ze` guard set, so keys like `file-max` or `varsite` never light
  up as keywords.

## Verification

- Verified headlessly by synID assertions in both vim and nvim over a
  sample exercising every construct (recorded in DONE.md); no automated
  check is wired up yet.

## Child DOX Index

- (none)
