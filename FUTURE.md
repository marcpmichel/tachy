
## improve existing

- improve code : 
  * dfmt pass ?
  * split large functions ( log switch/case statements: extract to functions )

- improve documentation
  * improve css
  * improve line lengths, paragraph formatting ( avoid big paragraph blobs )

- multiline strings: remove spaces from the first line

- improve bash completion: after 'tachy apply myhost', [TAB] does not start file autocomplete

## conditions

- Add a `when <condition expression>` attribute for all tasks, conditioning their execution. Does this require a new 'skipped' status ?

Examples:

  ```
  ensure "linux" {
    when = { run = "uname -s", equals: "Linux" }
    run = "cat /proc/cmdline"
  }
  ```

  ```
  ensure "postgresql-server package" {
    when = "{{ use_postgres_server }}"
    run = "apt install postgresql-server"
  }
  ```

- add 'result' to store result of all statements to vars ???



## asynchronicity ?

- callbacks : run a task after a service changed its state

