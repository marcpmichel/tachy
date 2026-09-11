/// Tests for tachy.config, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.config;

import tachy.config;

import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import tachy.tests.envsync : envM;
import tachy.errors : TachyError;

@("discovery: explicit, env, cwd, xdg (first found wins)")
unittest
{
    auto base = buildPath(tempDir, "tachy_config_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(base);
    scope (exit) rmdirRecurse(base);

    // missing explicit path is an error
    {
        try
        {
            loadConfig(buildPath(base, "missing.pravic"));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
        {
            assert(canFind(e.msg, "does not exist"), e.msg);
        }
    }
    write(buildPath(base, "explicit.pravic"), "imports { paths = [\"d\"] }\n");
    mkdirRecurse(buildPath(base, "d"));
    auto s = loadConfig(buildPath(base, "explicit.pravic"));
    assert(s.importPaths.length == 1
        && s.importPaths[0] == buildPath(base, "d"), s.importPaths[0]);

    // XDG discovery (~-expanded and relative entries resolve against it)
    mkdirRecurse(buildPath(base, "home", ".config", "tachy"));
    write(buildPath(base, "home", ".config", "tachy", "config.pravic"),
        "imports { paths = [\"~/abs-ut\", \"rel\"] }\n");
    s = withEnv(["TACHY_CONFIG", "XDG_CONFIG_HOME", "HOME"],
        ["", "", buildPath(base, "home")],
        () => loadConfig(""));
    assert(canFind(s.file, ".config/tachy/config.pravic"), s.file);
    assert(s.importPaths.length == 2);
    assert(s.importPaths[1] == buildPath(base, "home", ".config",
        "tachy", "rel"));

    // explicit env var must exist
    try
    {
        withEnv(["TACHY_CONFIG", "XDG_CONFIG_HOME", "HOME"],
            [buildPath(base, "nope.pravic"), "", ""],
            () => loadConfig(""));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
    {
        assert(canFind(e.msg, "does not exist"), e.msg);
    }

    // empty XDG falls back to HOME
    mkdirRecurse(buildPath(base, "cfg", "tachy"));
    write(buildPath(base, "cfg", "tachy", "config.pravic"), "");

    s = withEnv(["TACHY_CONFIG", "XDG_CONFIG_HOME", "HOME"],
        ["", buildPath(base, "cfg"), buildPath(base, "home")],
        () => loadConfig(""));
    assert(canFind(s.file, buildPath(base, "cfg")));

    // cwd config.pravic is found before xdg
    {
        import std.file : chdir, getcwd;
        auto keep = getcwd();
        scope (exit) chdir(keep);
        chdir(base);
        write("config.pravic", "");
        s = withEnv(["TACHY_CONFIG", "XDG_CONFIG_HOME", "HOME"],
            ["", buildPath(base, "cfg"), buildPath(base, "home")],
            () => loadConfig(""));
        assert(s.file == "config.pravic", s.file);
    }
}

@("webui projects: resolution and shapes")
unittest
{
    auto base = buildPath(tempDir, "tachy_config_webui_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "cfg"));
    mkdirRecurse(buildPath(base, "site"));
    // hermetic + serialized HOME: `~` expansion is asserted against a
    // controlled value, and other threaded tests mutate HOME — the
    // whole span (set, load, assert, restore) holds the env lock.
    // Everything after the first load is explicit-path and reads no
    // environment.
    Config s;
    synchronized (envM)
    {
        const string savedHome = environment.get("HOME");
        environment["HOME"] = buildPath(base, "home");
        scope (exit) environment["HOME"] = savedHome;

        write(buildPath(base, "cfg", "s.pravic"),
            "webui { projects = [\"site\", \"~/home-site\", \"/abs/task.pravic\"] }\n");
        s = loadConfig(buildPath(base, "cfg", "s.pravic"));
        assert(s.webuiProjects.length == 3);
        assert(s.webuiProjects[0] == buildPath(base, "cfg", "site"),
            s.webuiProjects[0]); // relative to the config file
        assert(s.webuiProjects[1] == buildPath(base, "home", "home-site"),
            s.webuiProjects[1]); // ~ expanded
        assert(s.webuiProjects[2] == "/abs/task.pravic"); // absolute kept
    }
    // alongside imports, and missing entries are fine (the webui
    // reports existence per project)
    write(buildPath(base, "cfg", "both.pravic"),
        "imports { paths = [\"libs\"] }\nwebui { projects = [\"nope\"] }\n");
    s = loadConfig(buildPath(base, "cfg", "both.pravic"));
    assert(s.importPaths.length == 1 && s.webuiProjects.length == 1);

    // empty section is fine
    write(buildPath(base, "cfg", "empty.pravic"), "webui { }\n");
    s = loadConfig(buildPath(base, "cfg", "empty.pravic"));
    assert(s.webuiProjects.length == 0);

    // wrong shapes are load-time errors with file context
    foreach (content; [
        "webui { projects = \"site\" }\n",
        "webui { projects = [1] }\n",
        "webui { bogus = 1 }\n",
    ])
    {
        string msg;
        try
        {
            write(buildPath(base, "cfg", "bad.pravic"), content);
            loadConfig(buildPath(base, "cfg", "bad.pravic"));
            assert(false, "expected TachyError for: " ~ content);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "bad.pravic"), msg);
        assert(canFind(msg, "webui"), msg);
    }
}

// run `dg()` with environment variables temporarily overridden; holds
// the env lock so threaded tests cannot observe the transient values
private Config withEnv(string[] names, string[] values,
    Config delegate() dg) @trusted
{
    synchronized (envM) // set, run and restore are one atomic span
    {
        string[] saved;
        foreach (i, n; names)
        {
            saved ~= environment.get(n);
            environment[n] = values[i];
        }
        scope (exit)
            foreach (i, n; names)
            {
                if (saved[i].length) environment[n] = saved[i];
                else environment.remove(n);
            }
        return dg();
    }
}

@("parse errors: unknown keys, wrong shapes")
unittest
{
    auto base = buildPath(tempDir, "tachy_config_err_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(base);
    scope (exit) rmdirRecurse(base);

    foreach (content; [
        "bogus = 1\n",
        "vars { a = 1 }\n",
        "imports = 1\n",
        "imports { paths = \"libs\" }\n",
        "imports { paths = [1] }\n",
        "imports { bogus = 1 }\n",
    ])
    {
        string msg;
        try
        {
            write(buildPath(base, "s.pravic"), content);
            loadConfig(buildPath(base, "s.pravic"));
            assert(false, "expected TachyError for: " ~ content);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "s.pravic"), msg);
    }

    // imports without paths is fine
    write(buildPath(base, "s.pravic"), "imports { }\n");
    auto s = loadConfig(buildPath(base, "s.pravic"));
    assert(s.importPaths.length == 0);
}

// run `dg()` with environment variables temporarily overridden
private auto withEnv(string[] names, string[] values, alias dg)()
{
    string[] saved;
    foreach (i, n; names)
    {
        saved ~= environment.get(n);
        environment.set(n, values[i]);
    }
    scope (exit)
        foreach (i, n; names)
        {
            if (saved[i].length) environment.set(n, saved[i]);
            else environment.remove(n);
        }
    return dg();
}

@("identity entry: both spellings, resolution, shapes")
unittest
{
    auto base = buildPath(tempDir, "tachy_config_ident_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "cfg"));
    scope (exit) rmdirRecurse(base);

    // single form: the path is the key
    write(buildPath(base, "cfg", "single.pravic"), "identity \"key.txt\"\n");
    auto s = loadConfig(buildPath(base, "cfg", "single.pravic"));
    assert(s.identity == buildPath(base, "cfg", "key.txt"), s.identity);

    // group form: identity { path = "..." }
    write(buildPath(base, "cfg", "group.pravic"),
        "identity { path = \"key.txt\" }\n");
    s = loadConfig(buildPath(base, "cfg", "group.pravic"));
    assert(s.identity == buildPath(base, "cfg", "key.txt"), s.identity);

    // unquoted key spelling and absolute paths
    write(buildPath(base, "cfg", "unquoted.pravic"), "identity key.txt\n");
    s = loadConfig(buildPath(base, "cfg", "unquoted.pravic"));
    assert(s.identity == buildPath(base, "cfg", "key.txt"), s.identity);
    write(buildPath(base, "cfg", "abs.pravic"), "identity \"/abs/key.txt\"\n");
    s = loadConfig(buildPath(base, "cfg", "abs.pravic"));
    assert(s.identity == "/abs/key.txt");

    // alongside the other entries
    write(buildPath(base, "cfg", "all.pravic"),
        "identity \"key.txt\"\nimports { paths = [\"libs\"] }\n"
        ~ "webui { projects = [\"site\"] }\n");
    s = loadConfig(buildPath(base, "cfg", "all.pravic"));
    assert(s.identity.length && s.importPaths.length == 1
        && s.webuiProjects.length == 1);

    // wrong shapes and duplicates are load-time errors with context
    foreach (content; [
        "identity \"a.txt\"\nidentity \"b.txt\"\n",
        "identity { path = \"a.txt\" }\nidentity { path = \"b.txt\" }\n",
        "identity \"a.txt\"\nidentity { path = \"b.txt\" }\n",
        "identity { path = 1 }\n",
        "identity { bogus = \"x\" }\n",
        "identity \"k.txt\" = \"v\"\n",
        "identity \"k.txt\" { mode = \"0600\" }\n",
    ])
    {
        string msg;
        try
        {
            write(buildPath(base, "cfg", "bad.pravic"), content);
            loadConfig(buildPath(base, "cfg", "bad.pravic"));
            assert(false, "expected TachyError for: " ~ content);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "bad.pravic"), msg);
        assert(canFind(msg, "identity"), msg);
    }
}

@("effectiveIdentity: the flag supersedes the config entry")
unittest
{
    Config s;
    assert(effectiveIdentity("", s) == "");
    assert(effectiveIdentity("flag.txt", s) == "flag.txt");
    s.identity = "settings.txt";
    assert(effectiveIdentity("flag.txt", s) == "flag.txt");
    assert(effectiveIdentity("", s) == "settings.txt");
}
