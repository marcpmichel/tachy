module app;

import std.getopt : getopt, GetOptException;
import std.string : split, strip;
import std.stdio : stderr, writeln;

import tachy.errors;
import tachy.runner;

int main(string[] args)
{
    RunOptions opts;
    bool wantHelp;

    try
    {
        getopt(
            args,
            "i|inventory", "PATH  inventory file (default: inventory.toml)", &opts.inventoryPath,
            "c|check", "check mode: report changes without applying them", &opts.checkMode,
            "v|verbose", "show executed commands and change details", &opts.verbose,
            "list-hosts", "list hosts matching the selection, then exit", &opts.listHosts,
            "h|help", "show this help", &wantHelp,
        );

        if (wantHelp)
        {
            printHelp();
            return 0;
        }

        if (args.length < 3)
        {
            printHelp();
            return 1;
        }
        opts.selection = args[1];
        opts.tasksFiles = args[2 .. $].dup;
        if (!opts.inventoryPath.length)
            opts.inventoryPath = "inventory.toml";

        return runTachy(opts);
    }
    catch (GetOptException e)
    {
        stderr.writeln("tachy: ", e.msg);
        printHelp();
        return 1;
    }
    catch (TachyError e)
    {
        stderr.writeln("tachy: ", e.msg);
        return 1;
    }
    catch (Exception e)
    {
        stderr.writeln("tachy: internal error: ", e.msg);
        return 1;
    }
}

private void printHelp()
{
    writeln(
"tachy — TOML-driven configuration management (Ansible-like)

Usage:
  tachy [options] <selection> <tasks.toml> [more tasks files...]

  <selection> is a comma-separated list of host names and tags; a tag is
  written as #tag.  The special selector \"all\" matches every host.
  Examples: \"web1\", \"web1,web2\", \"#web,#db\", \"#web,buildbox\", \"all\"
  (remember to quote #tags — your shell treats # as a comment.)

Every task is an idempotent \"ensure\" job; running a tasks file twice
applies changes only the first time.

Options:
  -i, --inventory PATH   Inventory file (default: inventory.toml)
  -c, --check            Check mode: report changes without applying them
  -v, --verbose          Show executed commands and change details
      --list-hosts       List hosts matching the selection, then exit
  -h, --help             Show this help

Inventory file (inventory.toml):
  [hosts.web1]
  address = \"192.168.1.10\"        # default: host name
  user = \"deploy\"                 # ssh user
  port = 22
  key = \"~/.ssh/id_ed25519\"
  connection = \"ssh\"              # \"ssh\" (default) or \"local\"
  tags = [\"web\", \"front\"]         # selection: tachy '#web' ...
  [hosts.web1.vars]
  http_port = 80

  [vars]                          # optional global variables
  admin = \"root\"

Tasks file — managed resources are table keys:
  [files.\"/etc/app/app.conf\"]     # state (default file; link/absent), content,
  content = \"port = {{ http_port }}\"  # src, mode (octal), owner, group
  mode = \"0644\"

  [directories.\"/etc/app\"]        # state (default directory; absent), mode,
  mode = \"0755\"                    # owner, group

  [services.app]                  # state (started/stopped/restarted/
  state = \"started\"               # reloaded), enabled
  enabled = true

  Both spellings work:
  [files]
  \"/etc/hosts\" = { owner = \"root\", mode = \"0644\" }

Composition — a tasks file may include others, each with its own vars
(outer vars < include vars < included file's [vars]):
  [vars]
  domain = \"example.org\"

  [includes.\"tasks/base.toml\"]
  env = \"prod\"

  [includes]
  \"tasks/extra.toml\" = { env = \"dev\" }

Variables:
  Precedence: global [vars] < host vars < include chain < file [vars].
  Strings are templated with {{ name }} / {{ table.key }}; the builtin
  {{ inventory_hostname }} holds the current host name.

Execution order: includes first (sorted by path), then own jobs (files,
directories, services; by key).  Managing the same target twice anywhere
in a composition is an error.");
}
