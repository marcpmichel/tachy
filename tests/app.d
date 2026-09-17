/// Tests for app, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.app;

import app;

@("commands and options keep their contract")
unittest
{
import std.algorithm.comparison : among;
import std.algorithm.searching : canFind, startsWith;
import std.exception : assertNotThrown, assertThrown;
import app : commandEntries;
import app : optionEntries;
import std.getopt : GetOptException;
import tachy.errors : TachyError;
import tachy.runner : RunOptions;

// the nine command words parse, and the four common ones take their
// short forms; anything else names the commands
assert(parseCommand("apply") == Cmd.apply);
assert(parseCommand("check") == Cmd.check);
assert(parseCommand("hosts") == Cmd.hosts);
assert(parseCommand("generate") == Cmd.generate);
assert(parseCommand("webui") == Cmd.webui);
assert(parseCommand("webdoc") == Cmd.webdoc);
assert(parseCommand("man") == Cmd.man);
assert(parseCommand("version") == Cmd.showVersion);
assert(parseCommand("help") == Cmd.help);
assert(parseCommand("a") == Cmd.apply);
assert(parseCommand("c") == Cmd.check);
assert(parseCommand("g") == Cmd.generate);
assert(parseCommand("v") == Cmd.showVersion);
// the short forms stop at the four common commands: every other
// single letter (the other command words' initials included) is an
// unknown command
foreach (w; ["h", "w", "m", "x"])
{
    string msg;
    try
    {
        parseCommand(w);
        assert(false, "expected TachyError for '" ~ w ~ "'");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "unknown command '" ~ w ~ "'"), msg);
}
{
    string msg;
    try
    {
        parseCommand("@web");
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "apply (a), check (c), hosts, generate (g),"), msg);
    assert(canFind(msg, "webui, webdoc, man, version (v), help"), msg);
}

// help stays short; man carries the full reference
{
    const h = helpText();
    assert(canFind(h, "tachy — Pravic-driven"));
    assert(canFind(h, "__Usage:__ **tachy** `<command>` `[options]` `[<args>...]`"));
    assert(canFind(h, "Commands:"));
    assert(canFind(h, "Options:"));
    assert(canFind(h, "\"tachy help <command>\""), "help must point at per-command help");
    assert(canFind(h, "\"tachy man\""), "help must point at tachy man");
    foreach (deep; ["Every task is an idempotent", "Examples:",
        "INVENTORY FILE", "file /etc/app", "source order", "Projects",
        "graphical version of this CLI.  The projects listed"])
        assert(!canFind(h, deep), "help must not contain: " ~ deep);

    const m = renderMarkup(manText(), false);
    foreach (s; ["NAME", "SYNOPSIS", "DESCRIPTION", "COMMANDS", "OPTIONS",
        "EXAMPLES", "PROJECTS", "WEB UI", "WEB DOCS", "INVENTORY FILE",
        "TASKS FILE", "COMPOSITION", "VARIABLES", "EXECUTION ORDER"])
        assert(canFind(m, "\n" ~ s ~ "\n"), "man page lacks section " ~ s);
    assert(startsWith(m, "TACHY(1)"), "man page needs the TACHY(1) banner");
    // the options entries appear in man verbatim, and every command's
    // one-line description appears in the composed COMMANDS section
    import std.string : lineSplitter, strip;
    foreach (l; optionEntries.lineSplitter)
        if (l.strip.length)
            assert(canFind(m, renderMarkup(l, false).strip()),
                "man must document: " ~ l);
    foreach (w; ["apply", "check", "hosts", "generate", "webui", "webdoc",
                 "man", "version"])
        assert(canFind(m, renderMarkup(commandOneLinerText(w), false)),
            "man COMMANDS lacks: " ~ w);
}

foreach (o; ["--keep-bundle", "--color", "--events", "--yes",
    "--verbose", "--direct", "--config", "--identity", "--address",
    "--port", "--direct-report"])
{
    RunOptions opts;
    bool wantHelp;
    // value-taking options need their value, or the command word is
    // eaten as the value
    string[] args = ["/tachy", o];
    if (among(o, "--config", "--identity", "--address", "--port",
            "--direct-report"))
        args ~= o == "--port" ? "9000" : "x";
    args ~= "webui";
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
// --list-hosts was replaced by the hosts command
{
    RunOptions opts;
    bool wantHelp;
    string[] args = ["/tachy", "--list-hosts", "apply", "localhost"];
    assertThrown!GetOptException(parseOptions(args, opts, wantHelp),
        "--list-hosts must no longer be an option (use: tachy hosts list)");
}
}

@("version is the build date and the version command prints it")
unittest
{
import std.algorithm.searching : canFind;
import std.regex : match, regex;

// the version comes from the embedded assets/version file: the build
// date, YY.mm.dd
assert(match(tachyVersion, regex(r"^\d{2}\.\d{2}\.\d{2}$")), tachyVersion);
assert(versionText() == "tachy " ~ tachyVersion);

// help and man carry the version entry
assert(canFind(helpText(), "**version (v)**  Print the version"), "help");
assert(canFind(manText(), "version"), "man");
}

@("render markup: bold and code, colored or stripped")
unittest
{
import app : renderMarkup;

// colors: markers become ANSI codes
assert(renderMarkup("**Usage:** `tachy man`", true)
    == "\033[1mUsage:\033[0m \033[36mtachy man\033[0m", renderMarkup("**Usage:** `tachy man`", true));
// headers are bold + underlined
assert(renderMarkup("__Commands:__", true) == "\033[1;4mCommands:\033[0m");
// colorless: markers are stripped
assert(renderMarkup("**Usage:** `tachy man`", false) == "Usage: tachy man");
// unmatched markers pass through verbatim
assert(renderMarkup("a ** b ` c", true) == "a ** b ` c");
assert(renderMarkup("a ** b ` c", false) == "a ** b ` c");
}

@("command screens: every command has a complete mise-style screen")
unittest
{
import app : commandHelpText, commandOneLinerText, parseCommand;
import std.algorithm.searching : canFind;

foreach (w; ["apply", "check", "hosts", "generate", "webui", "webdoc",
    "man", "version"])
{
    auto c = parseCommand(w);
    const s = commandHelpText(c);
    assert(canFind(s, commandOneLinerText(w)), s); // the one-liner header
    assert(canFind(s, "__Usage:__ **tachy " ~ w) || canFind(s, "__Usage:__ **tachy**"), s);
    assert(canFind(s, "__Options:__"), s);         // the shared options block
    assert(canFind(s, "--inventory"), s);
    assert(canFind(s, "tachy man\" for the full manual"), s);
    // the body exists and is more than the one-liner
    assert(s.length > 600, w ~ " screen too short");
}

// screens carry their body from commandScreens.txt
const hosts = commandHelpText(Cmd.hosts);
assert(canFind(hosts, "no host is contacted"), hosts);
const gen = commandHelpText(Cmd.generate);
assert(canFind(gen, "refuses to"), gen);

// help has no screen of its own (it prints the short help)
}
