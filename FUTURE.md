
## improve existing


## conditions

- Extract the string comparison of the "output" attribute of 'ensure' as it will be used by other statements, let's call it "condition expression".

- Improve the "condition expression" by adding a "not" operator.

- Add the assert statement i.e. `assert <condition expression>`

- Tasks: add a `when <condition expression>` attribute for all tasks, conditioning their execution. Does this require a new 'skipped' status ?


## asynchronicity ?

- callbacks : run a task after a service changed its state

