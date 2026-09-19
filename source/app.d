module app;

import std.getopt : getopt, GetOptException;
import std.string : split, strip;

import std.stdio : stderr, writeln;

import tachy.errors;
import tachy.generate;
import tachy.runner;
import tachy.upgrade : runUpgrade;
import tachy.web;
import tachy.webdoc;


/// The command word: the first positional argument of every invocation.
enum Cmd
{
    apply,
    check,
    hosts,
    generate,
    upgrade,
    webui,
    webdoc,
    man,
    showVersion, // the word is "version", reserved in D as a keyword
    help,
}

/// Map a command word; `a`/`c`/`g`/`v` are the short forms of the four
/// common commands (apply, check, generate, version) — the rest take
/// none. Anything else is an error naming the commands.
Cmd parseCommand(string word) @safe pure
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
        case "upgrade":
            return Cmd.upgrade;
        case "version":
        case "v":
            return Cmd.showVersion;
        case "help":
            return Cmd.help;
        default:
            throw new TachyError("unknown command '" ~ word
                ~ "' (commands: apply (a), check (c), hosts, generate (g),"
                ~ " upgrade, webui, webdoc, man, version (v), help)");
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
        const bool color = helpColors(opts);

        if (wantHelp || args.length < 2)
        {
            // `-h` after a command word shows that command's screen
            // ("tachy apply -h"); without a command word, the short help.
            if (args.length >= 2)
            {
                try
                {
                    printCommandHelp(parseCommand(args[1]), color);
                    return 0;
                }
                catch (TachyError)
                {
                }
            }
            printHelp(color);
            return 0;
        }

        // The first positional argument is the command; options may
        // appear before or after it (getopt permutes them away).
        final switch (parseCommand(args[1]))
        {
            case Cmd.apply:
            case Cmd.check:
                opts.checkMode = args[1] == "check" || args[1] == "c";
                if (args.length < 3)
                {
                    // an incomplete invocation shows the command's screen
                    printCommandHelp(parseCommand(args[1]), color);
                    stderr.writeln("tachy: missing hosts selection "
                        ~ "(comma-separated host names or @tags, or \"all\")");
                    return 1;
                }
                opts.selection = args[2];
                // A tasks file argument may be a directory (its
                // main.pravic is the entry point); with no argument,
                // main.pravic in the current directory is used.
                opts.tasksFiles = resolveTasksFiles(args[3 .. $]);
                if (!opts.inventoryPath.length)
                    opts.inventoryPath = "inventory.pravic";
                if (opts.directReport.length && !opts.direct)
                    throw new TachyError("--direct-report requires --direct");

                return runTachy(opts);
            case Cmd.hosts:
                if (args.length < 3)
                {
                    printCommandHelp(Cmd.hosts, color);
                    stderr.writeln("tachy: missing sub-command "
                        ~ "(\"hosts list [<selection>]\" or \"hosts info <host>\")");
                    return 1;
                }
                return runHosts(args[2 .. $], opts);
            case Cmd.generate:
                if (args.length < 3)
                {
                    printCommandHelp(Cmd.generate, color);
                    stderr.writeln("tachy: missing <what> and <path> "
                        ~ "(key, task, config or project)");
                    return 1;
                }
                return runGenerate(args[2 .. $]);
            case Cmd.upgrade:
                // One step: check, ask (unless --yes), download, replace.
                if (args.length > 2)
                    throw new TachyError("upgrade takes no sub-commands — just run"
                        ~ " \"tachy upgrade\" (add --yes to skip the confirmation)");
                return runUpgrade(opts, tachyVersion, args[2 .. $]);
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
            case Cmd.man:
                printMan(color);
                return 0;
            case Cmd.showVersion:
                printVersion();
                return 0;
            case Cmd.help:
                if (args.length >= 3)
                {
                    printCommandHelp(parseCommand(args[2]), color);
                    return 0;
                }
                printHelp(color);
                return 0;
        }
    }
    catch (GetOptException e)
    {
        stderr.writeln("tachy: ", e.msg);
        printHelp(helpColors(opts));
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

private immutable string optionEntriesSrc = import("assets/optionEntries.txt");

/// One options entry: the command words it is relevant to (empty —
/// tagged `@*` — means every command) and its help line verbatim.
private struct OptionEntry
{
    string[] commands;
    string line;
}

/// The options entries of optionEntries.txt, in order.  A `@`-line
/// before an entry tags it with the command words the option is
/// relevant to (`@*`: every command); the entry line itself follows,
/// indented, and stays verbatim.  Long entries may continue with
/// further indented (non-`@`, non-two-space) lines.
private OptionEntry[] optionEntryList() @safe pure
{
    import std.algorithm.searching : startsWith;
    import std.string : lineSplitter, split;
    OptionEntry[] r;
    string[] pending;
    foreach (line; lineSplitter(optionEntriesSrc))
    {
        if (!line.length)
            continue;
        if (line.startsWith("@"))
        {
            foreach (token; split(line))
                if (token != "@*")
                    pending ~= token[1 .. $];
            continue;
        }
        if (line.startsWith("  ") || !r.length)
        {
            r ~= OptionEntry(pending, line);
            pending = null;
        }
        else
            r[$ - 1].line ~= "\n" ~ line; // continuation of the previous entry
    }
    return r;
}

/// Every option entry in asset order: the Options block of the general
/// help and of the man OPTIONS section (the complete reference).
string optionEntriesText() @safe pure
{
    import std.algorithm.iteration : map;
    import std.array : join;
    return optionEntryList().map!(e => e.line).join("\n");
}

/// The Options block of one command's screen: only the entries tagged
/// for that command (untagged entries are on every screen).
private string commandOptionsText(Cmd c) @safe pure
{
    import std.algorithm.iteration : filter, map;
    import std.array : join;
    import std.algorithm.searching : canFind;
    const string word = commandWord(c);
    return optionEntryList()
        .filter!(e => !e.commands.length || e.commands.canFind(word))
        .map!(e => e.line).join("\n");
}

private enum commandsBlock = "__Commands:__\n" ~ commandEntries;

private string optionsBlock() @safe pure
{
    return "__Options:__\n" ~ optionEntriesText();
}

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
    import std.string : strip;
    return helpHead.strip ~ "\n\n" ~ commandsBlock.strip ~ "\n\n"
        ~ optionsBlock().strip ~ "\n\n" ~ helpTail.strip;
}

// ---------------------------------------------------------------------------
// Per-command help screens and the assets' micro markup.
//
// The help and screen assets carry a tiny markdown-like markup —
// `**bold**` and `` `code` `` — that the printers render as ANSI codes
// on a tty (or with --color) and strip when colors are off.  Each
// command has a screen in the mise/clap shape: a one-line description,
// the Usage line, the command's body from assets/commandScreens.txt
// (`=== <command> ===` sections), the shared options block and a
// footer.  `tachy help <command>` and `<command> -h` print it; an
// incomplete invocation (`tachy apply` with no selection) shows it
// instead of a bare error.
// ---------------------------------------------------------------------------

private immutable string commandScreensSrc = import("assets/commandScreens.txt");

/// The `=== <command> ===` sections of commandScreens.txt, keyed by
/// command word.
private string[string] commandScreens() @safe pure
{
    string[string] r;
    string current;
    import std.algorithm.searching : startsWith, endsWith;
    import std.string : lineSplitter, strip;
    foreach (line; lineSplitter(commandScreensSrc))
    {
        const s = strip(line);
        if (s.startsWith("=== ") && s.endsWith(" ==="))
        {
            current = s[4 .. $ - 4];
            r[current] = null;
            continue;
        }
        if (current.length)
            r[current] ~= line ~ "\n";
    }
    return r;
}

/// The command word of a Cmd ("version" for Cmd.showVersion).
private string commandWord(Cmd c) @safe pure nothrow
{
    final switch (c)
    {
        case Cmd.apply: return "apply";
        case Cmd.check: return "check";
        case Cmd.hosts: return "hosts";
        case Cmd.generate: return "generate";
        case Cmd.upgrade: return "upgrade";
        case Cmd.webui: return "webui";
        case Cmd.webdoc: return "webdoc";
        case Cmd.man: return "man";
        case Cmd.showVersion: return "version";
        case Cmd.help: return "help";
    }
}

/// The one-line description a command carries in the general help.
private string commandOneLiner(Cmd c) @safe pure nothrow
{
    final switch (c)
    {
        case Cmd.apply: return "Apply the tasks files to the selected hosts";
        case Cmd.check: return "Check mode: report would-be changes without applying anything";
        case Cmd.hosts: return "Inspect hosts: \"hosts list [<selection>]\", \"hosts info <host>\"";
        case Cmd.generate: return "Write scaffolding: age keys, sample tasks/config/project files, shell completions";
        case Cmd.upgrade: return "Upgrade tachy to the latest GitHub release";
        case Cmd.webui: return "Start a local web console: a graphical version of this CLI";
        case Cmd.webdoc: return "Serve the built-in documentation as a local web site";
        case Cmd.man: return "Print the full manual, unix man-page style";
        case Cmd.showVersion: return "Print the version (the build date, YY.mm.dd)";
        case Cmd.help: return "Show this help, or \"tachy help <command>\" for one command";
    }
}

/// The one-line description of a command, by command word.
string commandOneLinerText(string word) @safe pure
{
    return commandOneLiner(parseCommand(word));
}

/// The Usage line(s) of a command's screen (without the label): the
/// command word bold, placeholders colored — the clap/mise scheme.
private string commandSynopsis(Cmd c) @safe pure nothrow
{
    final switch (c)
    {
        case Cmd.apply:
            return "**tachy apply** `[options] <selection> [<tasks.pravic>...]`";
        case Cmd.check:
            return "**tachy check** `[options] <selection> [<tasks.pravic>...]`";
        case Cmd.hosts:
            return "**tachy hosts list** `[<selection>]`\n       **tachy hosts info** `<host>`";
        case Cmd.generate:
            return "**tachy generate** `<what> <path>`   # what: key, task, config, project\n"
                ~ "       **tachy generate completions** `<shell>`   # shell: bash, zsh, fish";
        case Cmd.upgrade:
            return "**tachy upgrade** `[-y|--yes]`";
        case Cmd.webui:
            return "**tachy webui** `[options]`";
        case Cmd.webdoc:
            return "**tachy webdoc** `[options]`";
        case Cmd.man:
            return "**tachy man**";
        case Cmd.showVersion:
            return "**tachy version**";
        case Cmd.help:
            return "**tachy help** `[command]`";
    }
}

/// One command's help screen, mise/clap shaped: the one-liner, Usage,
/// the command's body, the shared options block, the footer.
string commandHelpText(Cmd c) @safe pure
{
    const string word = commandWord(c);
    string s = commandOneLiner(c) ~ "\n\n";
    s ~= "__Usage:__ " ~ commandSynopsis(c) ~ "\n\n";
    if (auto body = word in commandScreens())
        s ~= *body;
    s ~= "\n__Options:__\n" ~ commandOptionsText(c) ~ "\n\n";
    s ~= "Run \"tachy man\" for the full manual.";
    return s;
}

/// Render the assets' micro markup — `__header__` (bold + underline),
/// `**literal**` (bold), `` `placeholder` `` (color) — as ANSI codes
/// when `color`, the markers stripped when not.  Unmatched markers
/// pass through verbatim.
string renderMarkup(string s, bool color) @safe pure
{
    import std.string : indexOf;
    string out_;
    size_t i;
    while (i < s.length)
    {
        string mark;
        string code;
        if (s[i] == '_' && i + 1 < s.length && s[i + 1] == '_')
        {
            mark = "__";
            code = "\033[1;4m";
        }
        else if (s[i] == '*' && i + 1 < s.length && s[i + 1] == '*')
        {
            mark = "**";
            code = "\033[1m";
        }
        else if (s[i] == '`')
        {
            mark = "`";
            code = "\033[36m";
        }
        if (mark is null)
        {
            out_ ~= s[i];
            i++;
            continue;
        }
        const ptrdiff_t close = indexOf(s[i + mark.length .. $], mark);
        if (close < 0)
        {
            out_ ~= s[i];
            i++;
            continue;
        }
        const content = s[i + mark.length .. i + mark.length + close];
        if (color)
            out_ ~= code ~ content ~ "\033[0m";
        else
            out_ ~= content;
        i = i + mark.length + close + mark.length;
    }
    return out_;
}

/// Whether help output may carry ANSI codes: a tty, or --color.
private bool helpColors(const RunOptions opts) @trusted
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;
        return opts.forceColor || isatty(1) != 0;
    }
    else
        return opts.forceColor;
}

private void printHelp(bool color)
{
    import std.stdio : stdout;
    stdout.writeln(renderMarkup(helpText(), color));
}

private void printMan(bool color)
{
    import std.stdio : stdout;
    stdout.writeln(renderMarkup(manText(), color));
}

private void printCommandHelp(Cmd c, bool color)
{
    import std.stdio : stdout;
    stdout.writeln(renderMarkup(commandHelpText(c), color));
}

/// One man-page banner line: TACHY(1) on both edges, centered text
/// between, padded to 80 columns.  Bold + underline via the micro
/// markup — the colorizing printer renders it, plain output strips it.
private string manBanner(string center) @safe pure
{
    import std.array : replicate;
    enum W = 80;
    enum edge = "TACHY(1)";
    const pad = (W - edge.length * 2 - center.length) / 2;
    return "__" ~ edge ~ " ".replicate(pad) ~ center
        ~ " ".replicate(W - edge.length * 2 - center.length - pad) ~ edge ~ "__";
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
    return "__" ~ title ~ "__\n" ~ manIndent(body) ~ "\n";
}

/// The man page's COMMANDS body, composed from the per-command screens
/// (single source with `tachy help <command>`): each command's
/// one-liner, usage and body.
private string manCommands() @safe pure
{
    import std.string : strip;
    const screens = commandScreens();
    string s;
    foreach (w; ["apply", "check", "hosts", "generate", "upgrade", "webui",
                 "webdoc", "man", "version"])
    {
        const c = parseCommand(w);
        s ~= w ~ "\n";
        s ~= manIndent(commandOneLiner(c)) ~ "\n";
        s ~= manIndent("usage: " ~ commandSynopsis(c)) ~ "\n";
        if (auto body = w in screens)
        {
            s ~= manIndent(strip(*body)) ~ "\n";
        }
    }
    return s;
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
        ~ manSection("COMMANDS", manCommands())
        ~ manSection("OPTIONS", optionEntriesText())
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
        "no-browser", "webui/webdoc: do not open the browser window (the bound URL is still printed)", &opts.noBrowser,
        "completion", "hosts list: print selection candidates (all, host names, @tags), one per line, for shell completions", &opts.completion,
        "y|yes", "with upgrade: skip the y/N confirmation and upgrade unattended", &opts.yes,
        "h|help", "show this help", &wantHelp,
    );
}
