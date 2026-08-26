
# TODO

5. In the <selection> argument of the command-line (list of hosts or tags) :change the tag identification character from '#' to '@'. ( because, as noted, the shell interprets '#' as a comment)

6. [apply]: add the "apply" directive that is doing the same thing as the "include" directive but respects the order of execution of directives in the task files.

7. [file]: Add the "line" and "block" attributes to the file directive : this would ensure that a given line/block is present in the target file. "line" and "block" are mutually exclusive and also exclusive with the "content" and "src" attributes.

8. Introduce the concept of "project" : in the command-line, take note of the parent directory of the task file passed as an argument and copy it to the host (in a temporary location) as a 'project' directory. The tachy binary should be also copied along and executed there (either remotely or locally). If no task file is passed, assume "main.toml". Note: Do not worry about other operating systems or architectures for now; it will only work for linux amd64 for now.


# DONE

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
     the includer's own jobs can use variables from its includes. Include
     cycles are detected and rejected.
