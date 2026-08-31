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
            "color", "force colored statuses even when stdout is not a tty", &opts.forceColor,
            "direct", "apply tasks files directly in this process, without bundling a project", &opts.direct,
            "direct-report", "PATH  with --direct: write \"ok changed failed\" counters to PATH", &opts.directReport,
            "keep-bundle", "keep each host's temporary bundle after the run (debugging)", &opts.keepBundle,
            "h|help", "show this help", &wantHelp,
        );

        if (wantHelp)
        {
            printHelp();
            return 0;
        }

        if (args.length < 2)
        {
            printHelp();
            return 1;
        }
        opts.selection = args[1];
        // A tasks file argument may be a directory (its tachy.toml is the
        // entry point); with no argument, tachy.toml in the current
        // directory is used.
        opts.tasksFiles = resolveTasksFiles(args[2 .. $]);
        if (!opts.inventoryPath.length)
            opts.inventoryPath = "inventory.toml";
        if (opts.directReport.length && !opts.direct)
            throw new TachyError("--direct-report requires --direct");

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

  tachy [options] <selection> [<tasks.toml>...]

  <selection> is a comma-separated list of host names and tags; a tag is
  written as @tag.  The special selector \"all\" matches every host.
  Examples: \"web1\", \"web1,web2\", \"@web,@db\", \"@web,buildbox\", \"all\"

  A tasks file argument may be a directory: its \"main.toml\" is then the
  entry point.  With no tasks file at all, \"main.toml\" in the current
  directory is used.

  Every task is an idempotent \"ensure\" job; running a tasks file twice
  applies changes only the first time.

Projects:
  The parent directory of a tasks file is its project.  For every
  selected host, tachy copies the project (and the tachy binary itself)
  to a temporary directory on the host and runs the copied binary
  there, where it applies the copied tasks file over a local connection.
  A project must be self-contained: includes and file src paths are
  resolved inside the copied project.  Bundles are removed after the
  run (--keep-bundle leaves them in place for inspection); check mode
  still deploys and removes a bundle but manages
  nothing.  Controller and hosts must be linux/amd64 for now.

Options:
  -i, --inventory PATH   Inventory file (default: inventory.toml)
  -c, --check            Check mode: report changes without applying them
  -v, --verbose          Show executed commands and change details
      --list-hosts       List hosts matching the selection, then exit
      --direct           Apply tasks files directly in this process,
                         without bundling a project (this is how the
                         copied binary runs on each host)
      --direct-report P  With --direct: write \"ok changed failed\"
                         counters to P
      --keep-bundle      Keep each host's temporary bundle directory
                         after the run, for inspection (project copy,
                         generated inventory, report)
      --color            Force colored statuses even when stdout is not
                         a tty (forwarded to the run on each host)
  -h, --help             Show this help

Inventory file (inventory.toml):
  [hosts.web1]
  address = \"192.168.1.10\"        # default: host name
  user = \"deploy\"                 # ssh user
  port = 22
  key = \"~/.ssh/id_ed25519\"
  connection = \"ssh\"              # \"ssh\" (default) or \"local\"
  tags = [\"web\", \"front\"]         # selection: tachy '@web' ...
  [hosts.web1.vars]
  http_port = 80

  [vars]                          # optional global variables
  admin = \"root\"

Tasks file — managed resources are table keys:
  [files.\"/etc/app/app.conf\"]     # state (default file; link/absent), content,
  content = \"port = {{ http_port }}\"  # src (copy), template (render its
  mode = \"0644\"                    # {{ vars }}), line, block, mode (octal),
                                    # owner, group; line/block ensure a line or
                                    # a contiguous block of lines is present
  [directories.\"/etc/app\"]        # state (default directory; absent), mode,
  mode = \"0755\"                    # owner, group

  [packages.\"apt:curl\"]              # key is \"<manager>:<name>\" (only apt);
  version = \"latest\"                 # default \"latest\" just ensures presence;
                                    # an explicit version pins it exactly
                                    # (epoch-qualified, as dpkg reports it).
                                    # present = false removes (default true)

  [groups.epices]                 # state (default present; absent removes)
  state = \"present\"

  [users.deploy]                  # shadow-utils accounts; group defaults to
  group = \"epices\"                # a group named after the user, groups
  groups = [\"docker\"]             # only ADD memberships, shell defaults to
  shell = \"/bin/bash\"             # /bin/sh at creation, create_home to true;
  comment = \"epices user\"         # state=absent removes (remove_home = true
  home = \"/home/epices\"           # also deletes the home directory)

  [services.app]                  # state (started/stopped/restarted/
  state = \"started\"               # reloaded), enabled
  enabled = true

  [execute.\"check if debian\"]    # run a shell command and check it:
  run = \"source /etc/os-release; echo $ID\"
                                  # (runs in the defining file's dir)

  exit_status = 0                 # int | { not = N } | { cond = \"< 1\" }
  output = \"debian\"               # string | { contains = \"deb\" }
                                  # | { matches = \"^debian.*$\" }

  [after.services.\"answer on port 80\"]   # hooks: same shape as
  run = \"curl -fsS http://localhost/\"    # [execute], keyed by task
  exit_status = 0                          # name, wrapping a job group
                                           # (packages, accounts, services)

  Both spellings work, and in table headers the quotes around a path
  key are optional (dots after the first non-bare segment belong to
  the path):
  [files]
  \"/etc/hosts\" = { owner = \"root\", mode = \"0644\" }
  [files./etc/hosts]              # the same entry, header style

Composition — a tasks file may include or apply others, each directive
entry carrying its own vars (outer vars < directive vars < composed
file's [vars]):
  [vars]
  domain = \"example.org\"

  [includes.\"tasks/base.toml\"]    # runs BEFORE this file's own jobs
  env = \"prod\"                    # the entry's keys are the bindings;

  [apply]
  \"tasks/extra.toml\" = { env = \"dev\" }   # runs AFTER this file's own jobs
  \"files.toml\" = { vars = { three = \"three\" } }  # or grouped under
                                  # 'vars' (same thing, either directive)

Variables:
  Precedence: global [vars] < host vars < include chain < file [vars].
  Strings are templated with {{ name }} / {{ table.key }}; the builtin
  {{ inventory_hostname }} holds the current host name.
  A [vars] entry of the form { env = \"NAME\" } (optionally
  { env = \"NAME\", default = \"...\", from = \".env\" }) is replaced by
  the value of that environment variable — read from the dotenv file
  named by 'from' (relative to the declaring file) instead of the
  process environment when given — or the default when it is unset:
  inventory [vars] read the controller's environment, tasks-file
  [vars] the environment of the process that loads them (the host, in
  bundled mode).  An unset variable without a default is an error.

Execution order: includes first (sorted by path), then own jobs —
directories, files, [before.packages], packages, [after.packages],
[before.accounts], groups, users, [after.accounts], [before.services],
services, [after.services], execute — then applies (sorted by path).
Execute jobs are checks by nature: they run even in check mode and never
report \"changed\". Groups run before users (a user's primary group must
exist); to remove both, drop the user in an earlier tasks file.
Hooks — [before.<group>] and [after.<group>] with group one of packages,
accounts (groups+users) or services — are execute-style checks keyed by
task name; they run at their group's position in the file's order,
whether or not the group has entries.
Managing the same target twice anywhere in a composition is an error.");
}
