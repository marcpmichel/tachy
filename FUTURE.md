
 - implement an 'upgrade' command that self-updates based on a hard-coded github link (choosing the latest release binary)

- tasks: when <condition> for tasks (i.e. when = {{ myvar }} (only truthy/falsy, no expression to keep it simple )

- callbacks : run a task after a service changed its state

- download ? 
  1. use the existing http : `http { download: <path> }` 
  2. or add a new 'download' `download <url> { path=<path> }`
  or nothing as it's not an idempotent task or a check and can be achieved with an 'ensure'
