/// Tests for app, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.app;

import app;

unittest // commands and options keep their contract
{
import std.algorithm.comparison : among;
import std.algorithm.searching : canFind, startsWith;
import std.exception : assertNotThrown, assertThrown;
import app : commandEntries;
import app : optionEntries;
import std.getopt : GetOptException;
import tachy.errors : TachyError;
import tachy.runner : RunOptions;

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
    assert(canFind(h, "tachy — Pravic-driven"));
    assert(canFind(h, "tachy <command> [options] <selection> [<tasks.pravic>...]"));
    assert(canFind(h, "Commands:"));
    assert(canFind(h, "Options:"));
    assert(canFind(h, "\"tachy man\""), "help must point at tachy man");
    foreach (deep; ["Every task is an idempotent", "Examples:",
        "INVENTORY FILE", "file /etc/app", "source order", "Projects",
        "graphical version of this CLI.  The projects listed"])
        assert(!canFind(h, deep), "help must not contain: " ~ deep);

    const m = manText();
    foreach (s; ["NAME", "SYNOPSIS", "DESCRIPTION", "COMMANDS", "OPTIONS",
        "EXAMPLES", "PROJECTS", "WEB UI", "WEB DOCS", "INVENTORY FILE",
        "TASKS FILE", "COMPOSITION", "VARIABLES", "EXECUTION ORDER"])
        assert(canFind(m, "\n" ~ s ~ "\n"), "man page lacks section " ~ s);
    assert(startsWith(m, "TACHY(1)"), "man page needs the TACHY(1) banner");
    // every non-blank line of the commands and options entries appears
    // in man (indented by its four-space body offset)
    import std.string : lineSplitter, strip;
    foreach (block; [commandEntries, optionEntries])
        foreach (l; block.lineSplitter)
            if (l.strip.length)
                assert(canFind(m, l.strip()), "man must document: " ~ l);
}

foreach (o; ["--keep-bundle", "--list-hosts", "--color", "--events",
    "--verbose", "--direct", "--settings", "--identity", "--address",
    "--port", "--direct-report"])
{
    RunOptions opts;
    bool wantHelp;
    // value-taking options need their value, or the command word is
    // eaten as the value
    string[] args = ["/tachy", o];
    if (among(o, "--settings", "--identity", "--address", "--port",
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
}
