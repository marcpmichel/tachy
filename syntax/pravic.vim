" Vim syntax file
" Language:      Pravic — tachy's configuration language (LANGUAGE.md)
" Maintainer:    the tachy project
" Last Change:   2026-09-10
" Filenames:     *.pravic
" Install:       copy to ~/.vim/syntax/ (Neovim: ~/.config/nvim/syntax/)
"                and detect the filetype, e.g. in ~/.vimrc / init.vim:
"                  autocmd BufNewFile,BufRead *.pravic setfiletype pravic

if exists('b:current_syntax')
  finish
endif

" Pravic is statements, one per line: a directive keyword, then a key and
" a body.  Keys are bare tokens (any characters except whitespace and
" structural punctuation) or quoted strings; values use TOML 1.0 lexical
" rules.  The grammar has no bare values, so a bare token in key position
" is highlighted as a key: anything but a number, a boolean or a guarded
" keyword.

" Keys and targets: a bare token followed by '=', '{', ',', '}', '#'
" (trailing comment) or end of line (braceless statements such as
" `directory /tmp/two`, or a braceless group entry).
syn match pravicKey /\v[^ \t\r\n"'{}\[\]=#,\\][^ \t\r\n"'{}\[\]=#,\\]*\ze\s*%([={,#}]|$)/ display

" Values — the TOML 1.0 lexical layer, datetimes excepted (Pravic has
" none).  Defined after pravicKey: at the same position the later item
" wins, so `8080` is a number, not a key.
syn keyword pravicBoolean true false
syn match pravicInteger /[+-]\=\<0x[[:xdigit:]]\%(_\=[[:xdigit:]]\)*\>/ display
syn match pravicInteger /[+-]\=\<0o[0-7]\%(_\=[0-7]\)*\>/ display
syn match pravicInteger /[+-]\=\<0b[01]\%(_\=[01]\)*\>/ display
syn match pravicInteger /[+-]\=\<\%(0\|[1-9]\%(_\=\d\)*\)\>/ display
syn match pravicFloat /[+-]\=\<\d\%(_\=\d\)*\.\d\%(_\=\d\)*\>/ display
syn match pravicFloat /[+-]\=\<\d\%(_\=\d\)*\%(\.\d\%(_\=\d\)*\)\=[eE][+-]\=\d\%(_\=\d\)*\>/ display
syn match pravicFloat /[+-]\=\<\%(inf\|nan\)\>/ display
syn match pravicOperator /=/ display
syn match pravicDelimiter /[{}[\],]/ display

" Strings: basic, literal, and their multi-line forms.  Multi-line forms
" are defined last so they win at a `"""` position.
syn match pravicEscape /\\[btnfr"/\\]/ display contained
syn match pravicEscape /\\u\x\{4}/ contained
syn match pravicEscape /\\U\x\{8}/ contained
syn match pravicLineEscape /\\$/ contained
syn match pravicTemplate /{{.\{-}}}/ display contained
syn region pravicString oneline start=/"/ skip=/\\\\\|\\"/ end=/"/ contains=pravicEscape,pravicTemplate
syn region pravicString oneline start=/'/ end=/'/ contains=pravicTemplate
syn region pravicString start=/"""/ end=/"""/ contains=pravicEscape,pravicLineEscape,pravicTemplate
syn region pravicString start=/'''/ end=/'''/ contains=pravicTemplate

" Comments: '#' to end of line, everywhere a space may appear.
syn keyword pravicTodo TODO FIXME XXX BUG contained
syn match pravicComment /#.*/ contains=@Spell,pravicTodo

" Directive keywords, guarded exactly like the parser guards them
" (LANGUAGE.md: keyword !KeyChar): a keyword is one only when not
" followed by a bare-key character, so `vars-foo` and `varsite` stay
" plain keys.  Defined last: it also wins the tie against pravicKey when
" an entry is literally named like a directive (`vars { var = 1 }`).
syn match pravicKeyword /\v<(vars|var|files|file|directories|directory|packages|package|groups|group|users|user|services|service|hosts|host|imports|import|webui|apply|ensure|compose)\ze%([ \t\r\n"'{}\[\]=#,\\]|$)/ display

hi def link pravicComment Comment
hi def link pravicTodo Todo
hi def link pravicKeyword Keyword
hi def link pravicKey Identifier
hi def link pravicString String
hi def link pravicEscape SpecialChar
hi def link pravicLineEscape SpecialChar
hi def link pravicTemplate PreProc
hi def link pravicBoolean Boolean
hi def link pravicInteger Number
hi def link pravicFloat Float
hi def link pravicOperator Operator
hi def link pravicDelimiter Delimiter

syn sync fromstart

let b:current_syntax = 'pravic'

" vim: et sw=2 sts=2
