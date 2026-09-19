
## improve existing

- Add a --no-browser for the webui and webdoc commands : disable the spawning of a browser window

- Display only relevant options in the commands-specific help screens.
  for example: --colors or --events has no sense for the webui command
  Said another way : do no display irrelevant options in the help screens.

## conditions

- Extract the string comparison of the "output" attribute of 'ensure' as it will be used by other statements, let's call it "condition expression".

- Improve the "condition expression" by adding a "not" operator.

- Add the assert statement i.e. `assert <condition expression>`

- Tasks: add a `when <condition expression>` attribute for all tasks, conditioning their execution. Does this require a new 'skipped' status ?


## asynchronicity ?

- callbacks : run a task after a service changed its state

