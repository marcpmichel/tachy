


- tachy test [project]: check syntax and variables of the config, inventory and tasks files of the given project (or ./main.tachy if present and no project given)
  or is it redundant with 'check' ??


- accept shorter names for the cli commands:
  a for apply
  g for generate
  c for check
  t for test
 do not use shorter names for other commands as they are less used.

 - implement an 'upgrade' command that self-updates based on a hard-coded github link (choosing the latest release binary)

- tasks: when <condition> for tasks (i.e. when = {{ myvar }} (only truthy/falsy, no expression to keep it simple )

- callbacks : run a task after a service changed its state

- download ? 
  1. use the existing http : `http { download: <path> }` 
  2. or add a new 'download' `download <url> { path=<path> }`
  or nothing as it's not an idempotent task or a check and can be achieved with an 'ensure'
