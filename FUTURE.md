
## improve existing

- improve code : 
  * dfmt pass ?
  * split large functions ( log switch/case statements: extract to functions )

- improve documentation
  * improve css
  * improve line lengths, paragraph formatting ( avoid big paragraph blobs )

- pravic parsing: add multiline strings: calculate the identation of the first line and remove this many spaces for the following lines.

- improve bash completion: after 'tachy apply myhost', [TAB] does not start file autocomplete

- add a 'task' command to parse and execute an inline task (string) instead of reading a pravic file.
  ```
  tachy task <host> "package apt:htop"
  ```

  ```
  tachy task <host> 'file /tmp/test { content="hello" }'
  ```
  
  Is this silly ? Without it, one just have to create a tiny tasks file "mytask.pravic" with the tasks and use the apply command on it.


## conditions

- Add a `when <condition expression>` attribute for most tasks, conditioning their execution. Does this require a new 'skipped' status ?

Examples:

  ```
  ensure "linux" {
    when = { run = "uname -s", equals: "Linux" }
    run = "cat /proc/cmdline"
  }
  ```

  ```
  package "apt:postgresql-server" {
    when = "{{ use_postgres_server }}"
  }

  probe https://google.com {
    when = "{{ check_internet_access }}"
  }

  ```


- add 'result' to assign results of all statements to vars ???
```
  package 'apt:htop' {
    result = "htop_install" # htop_install.version, htop_install.installed, ...
  }

```




## asynchronicity ?

- callbacks : run a task after a service changed its state

