
# Testing

- a "testing.internal" host is available for remote and safe testing via ssh using root@testing.internal
- unit testing: silly can use an annotation as a test name (i.e. `@("test it works")` ) just before every `unittest` block. use that instead of comments.


# Code
- use the DOX framework described in AGENTS.md
- prefer K&R curly braces placement when adding new code


# Behavior

- if something is not clear enough, ask the human operator
- do not write python code to make changes to the source code : prefer D scripts (run them with rdmd or a shebang line) or classic unix tools (sed, awk, vi).

