---
name: testing
description: tachy testing conventions — the testing.internal VM (root over ssh) for safe end-to-end runs, and silly's named @("...") annotation before every unittest block.
---

# Testing

- a "testing.internal" host is available for remote and safe testing via ssh using root@testing.internal
- unit testing: silly can use an annotation as a test name (i.e. `@("test it works")` ) just before every `unittest` block. use that instead of comments.
