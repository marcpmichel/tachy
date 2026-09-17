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
enum Cmd
{
    apply,
    check,
    hosts,
    generate,
    webui,
    webdoc,
    man,
    showVersion, // the word is "version", reserved in D as a keyword
    help,
}

/// Map a command word; `a`/`c`/`g`/`v` are the short forms of the four
/// common commands (apply, check, generate, version) — the rest take
/// none. Anything else is an error naming the commands.
Cmd parseCommand(string word)
{
    switch (word)
    {
        case "apply":
        case "a":
            return Cmd.apply;
        case "check":
        case "c":
            return Cmd.check;
        case "hosts":
            return Cmd.hosts;
        case "generate":
        case "g":
            return Cmd.generate;
        case "webui":
            return Cmd.webui;
        case "webdoc":
            return Cmd.webdoc;
        case "man":
            return Cmd.man;
        case "version":
        case "v":
            return Cmd.showVersion;
        case "help":
            return Cmd.help;
        default:
            throw new TachyError("unknown command '" ~ word
                ~ "' (commands: apply (a), check (c), hosts, generate (g),"
                ~ " webui, webdoc, man, version (v), help)");
    }
}


// Under `dub test` (the "unittest" configuration) the silly test
// runner provides main; app.d then contributes only its module — its
// contract tests live in tests/app.d.
version (unittest)
{
}
else
{
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
                opts.checkMode = args[1] == "check" || args[1] == "c";
                if (args.length >= 3)
                {
                    opts.selection = args[2];
                    // A tasks file argument may be a directory (its
                    // main.pravic is the entry point); with no argument,
                    // main.pravic in the current directory is used.
                    opts.tasksFiles = resolveTasksFiles(args[3 .. $]);
                }
                if (!opts.inventoryPath.length)
                    opts.inventoryPath = "inventory.pravic";
                if (opts.directReport.length && !opts.direct)
                    throw new TachyError("--direct-report requires --direct");

                return runTachy(opts);
            case Cmd.hosts:
                return runHosts(args[2 .. $], opts);
            case Cmd.webui:
                // webui takes no positional arguments: the projects
                // come from config.pravic (webui projects) and runs
                // are started from the browser.
                if (args.length > 2)
                    throw new TachyError("webui takes no arguments (projects"
                        ~ " are configured in config.pravic, runs are started"
                        ~ " from the browser)");
                if (!opts.inventoryPath.length)
                    opts.inventoryPath = "inventory.pravic";
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
            case Cmd.showVersion:
                printVersion();
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
}

// ---------------------------------------------------------------------------
// Version.  The version is the build date, 'YY.mm.dd': dub's
// preBuildCommands keep source/assets/version current (rewritten only
// when the day changes, so same-day rebuilds stay no-ops) and it is
// embedded here with import(), like every other asset.  D reserves
// 'version' as a keyword, so the symbol is tachyVersion.
// ---------------------------------------------------------------------------

/// The tachy version: the build date, 'YY.mm.dd'.
immutable string tachyVersion = strip(import("assets/version"));

/// What the `version` command prints.
string versionText() @safe pure
{
    return "tachy " ~ tachyVersion;
}

private void printVersion()
{
    writeln(versionText());
}

// ---------------------------------------------------------------------------
// Help and manual.  `help` (and --help) prints the short form: the
// project line, the usage lines, the commands and the options.  `man`
// prints everything, formatted like a unix man page.  The text blocks
// live in source/assets/*.txt and are embedded at compile time with
// import() — one source for both outputs, so the two cannot drift.
// ---------------------------------------------------------------------------

private immutable string helpHead = import("assets/helpHead.txt");
immutable string commandEntries = import("assets/commandEntries.txt");
immutable string optionEntries = import("assets/optionEntries.txt");

private enum commandsBlock = "  Commands:\n" ~ commandEntries;

private enum optionsBlock = "  Options:\n" ~ optionEntries;

private immutable string helpTail = import("assets/helpTail.txt");
private immutable string manDescription = import("assets/manDescription.txt");
private immutable string manExamples = import("assets/manExamples.txt");
private immutable string projectsBody = import("assets/projectsBody.txt");
private immutable string webuiBody = import("assets/webuiBody.txt");
private immutable string webdocBody = import("assets/webdocBody.txt");
private immutable string inventoryBody = import("assets/inventoryBody.txt");
private immutable string tasksBody = import("assets/tasksBody.txt");
private immutable string compositionBody = import("assets/compositionBody.txt");
private immutable string variablesBody = import("assets/variablesBody.txt");
private immutable string orderBody = import("assets/orderBody.txt");

string helpText() @safe pure
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

string manText() @safe pure
{
    return manBanner("User Commands") ~ "\n\n"
        ~ manSection("NAME",
            "tachy — Pravic-driven configuration management (Ansible-like)")
        ~ manSection("SYNOPSIS",
            "tachy <command> [options] <selection> [<tasks.pravic>...]\n"
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
        "i|inventory", "PATH  inventory file (default: inventory.pravic)", &opts.inventoryPath,
        "v|verbose", "show executed commands, change details and command output (stdout/stderr)", &opts.verbose,
        "color", "force colored statuses even when stdout is not a tty", &opts.forceColor,
        "direct", "apply tasks files directly in this process, without bundling a project", &opts.direct,
        "direct-report", "PATH  with --direct: write \"ok changed failed\" counters to PATH", &opts.directReport,
        "events", "print one JSON event per line on stdout instead of text (machine mode)", &opts.events,
        "keep-bundle", "keep each host's temporary bundle directory after"
            ~ " the run, for inspection (project copy, generated"
            ~ " inventory, report)", &opts.keepBundle,
        "config", "PATH  optional config file: identity entry, imports search paths, webui projects, output format (default: TACHY_CONFIG, ./config.pravic, ~/.config/tachy/config.pravic)", &opts.config,
        "identity", "PATH  age identity for { age = ... } inventory vars; supersedes the config identity entry (default: AGE_IDENTITY, then ~/.ssh/id_ed25519)", &opts.identity,
        "address", "ADDR  webui/webdoc: address to bind (default 127.0.0.1)", &opts.webAddress,
        "port", "N  webui/webdoc: port to listen on (default: a random port between 10000 and 65534)", &opts.webPort,
        "h|help", "show this help", &wantHelp,
    );
}
