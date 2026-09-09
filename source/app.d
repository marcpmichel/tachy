module app;

import std.getopt : getopt, GetOptException;
import std.string : split, strip;

import std.stdio : stderr, writeln;

import tachy.errors;
import tachy.generate;
import tachy.runner;
import tachy.web;
import tachy.webdoc;


/// The command word: the first positional argument of every invocation.
private enum Cmd
{
    apply,
    check,
    generate,
    webui,
    webdoc,
    man,
    help,
}

/// Map a command word; anything else is an error naming the commands.
Cmd parseCommand(string word)
{
    switch (word)
    {
        case "apply":
            return Cmd.apply;
        case "check":
            return Cmd.check;
        case "webdoc":
            return Cmd.webdoc;
        case "man":
            return Cmd.man;
        case "help":
            return Cmd.help;
        default:
            throw new TachyError("unknown command '" ~ word
                ~ "' (commands: apply, check, generate, webui, webdoc, man, help)");
    }
}

int main(string[] args)
{
    RunOptions opts;
    bool wantHelp;

    try
    {
        parseOptions(args, opts, wantHelp);

        if (wantHelp || args.length < 2)
        {
            printHelp();
            return 0;
        }

        // The first positional argument is the command; options may
        // appear before or after it (getopt permutes them away).
        final switch (parseCommand(args[1]))
        {
            case Cmd.apply:
            case Cmd.check:
                opts.checkMode = args[1] == "check";
                if (args.length >= 3)
                {
                    opts.selection = args[2];
                    // A tasks file argument may be a directory (its
                    // main.toml is the entry point); with no argument,
                    // main.toml in the current directory is used.
                    opts.tasksFiles = resolveTasksFiles(args[3 .. $]);
                }
                if (!opts.inventoryPath.length)
                    opts.inventoryPath = "inventory.toml";
                if (opts.directReport.length && !opts.direct)
                    throw new TachyError("--direct-report requires --direct");

                return runTachy(opts);
            case Cmd.webui:
                // webui takes no positional arguments: the projects
                // come from settings.toml ([webui] projects) and runs
                // are started from the browser.
                if (args.length > 2)
                    throw new TachyError("webui takes no arguments (projects"
                        ~ " are configured in settings.toml, runs are started"
                        ~ " from the browser)");
                if (!opts.inventoryPath.length)
                    opts.inventoryPath = "inventory.toml";
                return runWebUi(opts);
            case Cmd.webdoc:
                // webdoc takes no positional arguments: it serves the
                // documentation compiled into this binary.
                if (args.length > 2)
                    throw new TachyError("webdoc takes no arguments (it"
                        ~ " serves the documentation compiled into this"
                        ~ " binary)");
                return runWebDoc(opts);
            case Cmd.generate:
                return runGenerate(args[2 .. $]);
            case Cmd.man:
                printMan();
                return 0;
            case Cmd.help:
                printHelp();
                return 0;
        }
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

// ---------------------------------------------------------------------------
// Help and manual.  `help` (and --help) prints the short form: the
// project line, the usage lines, the commands and the options.  `man`
// prints everything, formatted like a unix man page.  The blocks below
// are the single source of both, so the two cannot drift apart.
// ---------------------------------------------------------------------------

private enum helpHead =
"tachy — TOML-driven configuration management (Ansible-like)

  tachy <command> [options] <selection> [<tasks.toml>...]
  tachy webui [options]
  tachy webdoc [options]";

private enum commandEntries =
"    apply       apply tasks to the selected hosts
    check       check mode: report changes without applying them
    generate    create something: \"generate key <path>\" writes a new
                age key pair, \"generate task <path>\" a sample tasks
                file, \"generate settings <path>\" a sample settings
                file (all refuse to overwrite)
    webui       start a local web server: a graphical version of this
                CLI
    webdoc      start a local web server serving this documentation as
                a browsable site
    man         show the full manual, unix man-page style
    help        show this help";

private enum optionEntries =
"    -i, --inventory PATH   Inventory file (default: inventory.toml)
    -v, --verbose          Show executed commands and change details
        --list-hosts       List hosts matching the selection, then exit
        --direct           Apply tasks files directly in this process,
                           without bundling a project (this is how the
                           copied binary runs on each host)
        --direct-report P  With --direct: write \"ok changed failed\"
                           counters to P
        --events           Print one JSON event per line on stdout instead
                           of text (machine mode): with --direct, the
                           local run's own events; otherwise the raw
                           events streamed live from each host, wrapped in
                           the controller's fileStart/fileDone events
        --keep-bundle      Keep each host's temporary bundle directory
                           after the run, for inspection (project copy,
                           generated inventory, report)
        --settings PATH     Optional settings file ([imports] search
                           paths, [webui] projects); default:
                           TACHY_SETTINGS, then settings.toml in the
                           current directory, then
                           ~/.config/tachy/settings.toml
        --identity PATH    Age identity for { age = ... } inventory vars;
                           default: AGE_IDENTITY (path or key material),
                           then ~/.ssh/id_ed25519 (age accepts ssh keys)
        --color            Force colored statuses even when stdout is not
                           a tty (forwarded to the run on each host)
        --address ADDR     Webui/webdoc only: address to bind (default
                           127.0.0.1; an IP — use 0.0.0.0 to listen on
                           every interface)
        --port PORT        Webui/webdoc only: port to listen on (default
                           8080; 0 picks a free port)
    -h, --help             Show this help";

private enum commandsBlock = "  Commands:\n" ~ commandEntries;

private enum optionsBlock = "  Options:\n" ~ optionEntries;

private enum helpTail =
"  The full manual — selection syntax, projects, the web console and
  web docs, the inventory and tasks file reference, variables and the
  execution order — is one command away: \"tachy man\".";

private enum manDescription =
"Every task is an idempotent \"ensure\" job; running a tasks file twice
applies changes only the first time.

A tasks file argument may be a directory: its \"main.toml\" is then the
entry point. With no tasks file at all, \"main.toml\" in the current
directory is used.

<selection> is a comma-separated list of host names and tags; a tag is
written as @tag.  The special selector \"all\" matches every host.
Examples: \"web1\", \"web1,web2\", \"@web,@db\", \"@web,buildbox\", \"all\"";

private enum manExamples =
"  tachy apply @web req/web
  tachy check @web req/web
  tachy generate key key.txt
  tachy generate task main.toml
  tachy generate settings settings.toml
  tachy webui
  tachy webdoc
  tachy man";

private enum projectsBody =
"The parent directory of a tasks file is its project.  For every
selected host, tachy copies the project (and the tachy binary itself)
to a temporary directory on the host and runs the copied binary
there, where it applies the copied tasks file over a local connection.
A project must be self-contained: includes and file src paths are
resolved inside the copied project; the [import] directive is the
sanctioned way to pull in files from outside.  Bundles are removed
after the run (--keep-bundle leaves them in place for inspection);
check mode still deploys and removes a bundle but manages nothing.
Controller and hosts must be linux/amd64 for now.";

private enum webuiBody =
"Starts a local web server (default: http://127.0.0.1:8080) that is a
graphical version of this CLI.  The projects listed in the [webui]
projects entry of settings.toml (a directory uses its main.toml)
become clickable; pick a host selection, run apply or check on it,
and watch each job line appear live — the page follows the run's
events (the same stream as --events) as the remote executor finishes
each job.  The interface (HTML, CSS, JavaScript) is embedded in the
binary at compile time: one binary, no external files, no framework.
The server executes real runs and binds to localhost only by default
— anyone who can reach the port can run tachy.";

private enum webdocBody =
"Serves the documentation as a small web site on a local web server
(default: http://127.0.0.1:8080): one page per section, with a left
menu to pick one.  The pages are generated from the DOCUMENTATION.md
embedded in the binary at compile time, so they always document the
binary being run.  The server is read-only.";

private enum inventoryBody =
"  [hosts.web1]
  address = \"192.168.1.10\"        # default: host name
  user = \"deploy\"                 # ssh user
  http_port = 80

  [vars]                          # optional global variables
  admin = \"root\"";

private enum tasksBody =
"  [files.\"/etc/app/app.conf\"]     # state (default file; link/absent), content,
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
  state = \"started\"               # reloaded/enabled), enabled = true;
  enabled = true                  # src/template manage the unit file
                                  # itself (/etc/systemd/system/...):
  [services.\"my_service\"]         # template renders it with the host
  template = \"my.service.tmpl\"    # scope plus the entry's local
  vars = { user = \"www\" }         # vars = { ... } (template only);
  state = \"started\"               # src copies a file verbatim

  [compose.\"/srv/app\"]             # Docker Compose stacks, keyed by
  file = \"compose.yml\"              # project dir (absolute); file names the
  state = \"running\"                 # compose file (relative: inside dir);
                                    # project overrides the derived name
                                    # (lowercased dir basename); services
                                    # = [\"web\"] selects a subset (default:
                                    # every service the file enables);
                                    # state: running (default) | stopped |
                                    # absent — running checks each selected
                                    # service's runtime, health and compose
                                    # config-hash label before acting;
  pull = \"missing\"                  # missing (default) | always | never
  build = \"auto\"                    # auto (default) | always | never
  recreate = \"auto\"                 # auto (default) | always | never
  wait = true                        # wait for running/healthy after up
                                    # (wait_timeout caps it; timeout is the
                                    # stop/shutdown timeout, in seconds)
  remove_orphans = true              # stopped: drop containers that left
                                    # the compose model; absent:
  remove_volumes = true              #   also remove named volumes and
  remove_images = true               #   service images

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
  [files./etc/hosts]              # the same entry, header style";

private enum compositionBody =
"A tasks file may include or apply others, each directive entry
carrying its own vars (outer vars < directive vars < composed file's
[vars]):
  [vars]
  domain = \"example.org\"

  [includes.\"tasks/base.toml\"]    # runs BEFORE this file's own jobs
  env = \"prod\"                    # the entry's keys are the bindings;

  [apply]
  \"tasks/extra.toml\" = { env = \"dev\" }   # runs AFTER this file's own jobs
  \"files.toml\" = { vars = { three = \"three\" } }  # or grouped under
                                  # 'vars' (same thing, either directive)

  A composition entry naming an existing directory uses its main.toml,
  like a directory argument on the command line.

  [import.tasks/install_gogs]     # bundled mode only: copy an external
                                  # file or directory into the bundle as
                                  # its base name (project/install_gogs),
                                  # so src/template/run can use it on the
                                  # host; [includes]/[apply] entries
                                  # inside it — or naming it — that are
                                  # missing locally are composed on the
                                  # host
                                  # — a bare name that does not resolve
                                  # here is searched in the [imports]
                                  # paths of settings.toml";

private enum variablesBody =
"Precedence: global [vars] < host vars < include chain < file [vars].
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
Inventory [vars] may also hold { age = \"file.age\" }: replaced by that
file's age-decrypted content (one trailing newline stripped), on the
controller, with the identity from --identity, AGE_IDENTITY or
~/.ssh/id_ed25519.  Binary secrets are not supported in variables.";

private enum orderBody =
"Includes first (sorted by path), then own jobs —
directories, files, [before.packages], packages, [after.packages],
[before.accounts], groups, users, [after.accounts], [before.services],
services, [after.services], compose, execute — then applies (sorted by
path).
Execute jobs are checks by nature: they run even in check mode and never
report \"changed\". Groups run before users (a user's primary group must
exist); to remove both, drop the user in an earlier tasks file.
Hooks — [before.<group>] and [after.<group>] with group one of packages,
accounts (groups+users) or services — are execute-style checks keyed by
task name; they run at their group's position in the file's order,
whether or not the group has entries.
Managing the same target twice anywhere in a composition is an error.";

private string helpText() @safe pure
{
    return helpHead ~ "\n\n" ~ commandsBlock ~ "\n\n" ~ optionsBlock ~ "\n\n"
        ~ helpTail;
}

private void printHelp()
{
    writeln(helpText());
}

/// One man-page banner line: TACHY(1) on both edges, centered text
/// between, padded to 80 columns.
private string manBanner(string center) @safe pure
{
    import std.array : replicate;
    enum W = 80;
    enum edge = "TACHY(1)";
    const pad = (W - edge.length * 2 - center.length) / 2;
    return edge ~ " ".replicate(pad) ~ center
        ~ " ".replicate(W - edge.length * 2 - center.length - pad) ~ edge;
}

/// Indent every non-blank line of a body block by four spaces, the
/// man-page body offset.
private string manIndent(string body) @safe pure
{
    import std.string : lineSplitter;
    string out_;
    foreach (line; body.lineSplitter)
        out_ ~= line.length ? "    " ~ line ~ "\n" : "\n";
    return out_;
}

private string manSection(string title, string body) @safe pure
{
    return title ~ "\n" ~ manIndent(body) ~ "\n";
}

private string manText() @safe pure
{
    return manBanner("User Commands") ~ "\n\n"
        ~ manSection("NAME",
            "tachy — TOML-driven configuration management (Ansible-like)")
        ~ manSection("SYNOPSIS",
            "tachy <command> [options] <selection> [<tasks.toml>...]\n"
            ~ "tachy webui [options]\ntachy webdoc [options]")
        ~ manSection("DESCRIPTION", manDescription)
        ~ manSection("COMMANDS", commandEntries)
        ~ manSection("OPTIONS", optionEntries)
        ~ manSection("EXAMPLES", manExamples)
        ~ manSection("PROJECTS", projectsBody)
        ~ manSection("WEB UI", webuiBody)
        ~ manSection("WEB DOCS", webdocBody)
        ~ manSection("INVENTORY FILE", inventoryBody)
        ~ manSection("TASKS FILE", tasksBody)
        ~ manSection("COMPOSITION", compositionBody)
        ~ manSection("VARIABLES", variablesBody)
        ~ manSection("EXECUTION ORDER", orderBody)
        ~ manBanner("User Commands");
}

private void printMan()
{
    writeln(manText());
}

/// Option registration, extracted from main so a unittest can verify
/// every documented option stays registered (keep-bundle once vanished
/// from getopt while still listed in the help).
void parseOptions(ref string[] args, ref RunOptions opts, ref bool wantHelp)
{
    getopt(
        args,
        "i|inventory", "PATH  inventory file (default: inventory.toml)", &opts.inventoryPath,
        "v|verbose", "show executed commands and change details", &opts.verbose,
        "list-hosts", "list hosts matching the selection, then exit", &opts.listHosts,
        "color", "force colored statuses even when stdout is not a tty", &opts.forceColor,
        "direct", "apply tasks files directly in this process, without bundling a project", &opts.direct,
        "direct-report", "PATH  with --direct: write \"ok changed failed\" counters to PATH", &opts.directReport,
        "events", "print one JSON event per line on stdout instead of text (machine mode)", &opts.events,
        "keep-bundle", "keep each host's temporary bundle after the run (debugging)", &opts.keepBundle,
        "settings", "PATH  optional settings file (default: TACHY_SETTINGS, ./settings.toml, ~/.config/tachy/settings.toml)", &opts.settings,
        "identity", "PATH  age identity for { age = ... } inventory vars (default: AGE_IDENTITY, then ~/.ssh/id_ed25519)", &opts.identity,
        "address", "ADDR  webui/webdoc: address to bind (default 127.0.0.1)", &opts.webAddress,
        "port", "N  webui/webdoc: port to listen on (default 8080)", &opts.webPort,
        "h|help", "show this help", &wantHelp,
    );
}

version (unittest) unittest // commands and options keep their contract
{
    import std.algorithm.searching : canFind, startsWith;
    import std.exception : assertNotThrown, assertThrown;

    // the seven command words parse; anything else names the commands
    assert(parseCommand("apply") == Cmd.apply);
    assert(parseCommand("check") == Cmd.check);
    assert(parseCommand("generate") == Cmd.generate);
    assert(parseCommand("webui") == Cmd.webui);
    assert(parseCommand("webdoc") == Cmd.webdoc);
    assert(parseCommand("man") == Cmd.man);
    assert(parseCommand("help") == Cmd.help);
    {
        string msg;
        try
        {
            parseCommand("@web");
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "unknown command '@web'"), msg);
        assert(canFind(msg, "apply, check, generate, webui, webdoc, man, help"), msg);
    }

    // help stays short; man carries the full reference
    {
        const h = helpText();
        assert(canFind(h, "tachy — TOML-driven"));
        assert(canFind(h, "tachy <command> [options] <selection> [<tasks.toml>...]"));
        assert(canFind(h, "Commands:"));
        assert(canFind(h, "Options:"));
        assert(canFind(h, "\"tachy man\""), "help must point at tachy man");
        foreach (deep; ["Every task is an idempotent", "Examples:",
            "Inventory file", "[files.", "Execution order", "Projects",
            "graphical version of this CLI.  The projects listed"])
            assert(!canFind(h, deep), "help must not contain: " ~ deep);

        const m = manText();
        foreach (s; ["NAME", "SYNOPSIS", "DESCRIPTION", "COMMANDS", "OPTIONS",
            "EXAMPLES", "PROJECTS", "WEB UI", "WEB DOCS", "INVENTORY FILE",
            "TASKS FILE", "COMPOSITION", "VARIABLES", "EXECUTION ORDER"])
            assert(canFind(m, "\n" ~ s ~ "\n"), "man page lacks section " ~ s);
        assert(startsWith(m, "TACHY(1)"), "man page needs the TACHY(1) banner");
        // the commands and options of the short help appear verbatim in man
        assert(canFind(m, commandEntries), "man must document the commands");
        assert(canFind(m, optionEntries), "man must document the options");
    }

    foreach (o; ["--keep-bundle", "--list-hosts", "--color", "--events",
        "--verbose", "--direct", "--settings", "--address", "--port"])
    {
        RunOptions opts;
        bool wantHelp;
        string[] args = ["/tachy", o, "webui"];
        assertNotThrown!GetOptException(parseOptions(args, opts, wantHelp),
            "option no longer registered: " ~ o);
    }
    {
        RunOptions opts;
        bool wantHelp;
        string[] args = ["/tachy", "-i", "inv.toml", "--direct-report", "r",
            "--identity", "k.txt", "-h", "check", "localhost"];
        assertNotThrown!GetOptException(parseOptions(args, opts, wantHelp));
        assert(opts.inventoryPath == "inv.toml");
        assert(opts.directReport == "r");
        assert(opts.identity == "k.txt");
        assert(wantHelp);
    }
    {
        RunOptions opts;
        bool wantHelp;
        string[] args = ["/tachy", "--address", "0.0.0.0", "--port", "9000",
            "webui"];
        assertNotThrown!GetOptException(parseOptions(args, opts, wantHelp));
        assert(opts.webAddress == "0.0.0.0");
        assert(opts.webPort == 9000);
    }
    // -c/--check was replaced by the check command
    {
        RunOptions opts;
        bool wantHelp;
        string[] args = ["/tachy", "--check", "apply", "localhost"];
        assertThrown!GetOptException(parseOptions(args, opts, wantHelp),
            "--check must no longer be an option (use: tachy check)");
    }
}
