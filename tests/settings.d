/// Tests for tachy.settings, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.settings;

import tachy.settings;

import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import tachy.tests.envsync : envM;
import tachy.errors : TachyError;

@("discovery: explicit, env, cwd, xdg (first found wins)")
unittest
{
    auto base = buildPath(tempDir, "tachy_settings_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(base);
    scope (exit) rmdirRecurse(base);

    // missing explicit path is an error
    {
        try
        {
            loadSettings(buildPath(base, "missing.pravic"));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
        {
            assert(canFind(e.msg, "does not exist"), e.msg);
        }
    }
    write(buildPath(base, "explicit.pravic"), "imports { paths = [\"d\"] }\n");
    mkdirRecurse(buildPath(base, "d"));
    auto s = loadSettings(buildPath(base, "explicit.pravic"));
    assert(s.importPaths.length == 1
        && s.importPaths[0] == buildPath(base, "d"), s.importPaths[0]);

    // XDG discovery (~-expanded and relative entries resolve against it)
    mkdirRecurse(buildPath(base, "home", ".config", "tachy"));
    write(buildPath(base, "home", ".config", "tachy", "settings.pravic"),
        "imports { paths = [\"~/abs-ut\", \"rel\"] }\n");
    s = withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
        ["", "", buildPath(base, "home")],
        () => loadSettings(""));
    assert(canFind(s.file, ".config/tachy/settings.pravic"), s.file);
    assert(s.importPaths.length == 2);
    assert(s.importPaths[1] == buildPath(base, "home", ".config",
        "tachy", "rel"));

    // explicit env var must exist
    try
    {
        withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
            [buildPath(base, "nope.pravic"), "", ""],
            () => loadSettings(""));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
    {
        assert(canFind(e.msg, "does not exist"), e.msg);
    }

    // empty XDG falls back to HOME
    mkdirRecurse(buildPath(base, "cfg", "tachy"));
    write(buildPath(base, "cfg", "tachy", "settings.pravic"), "");

    s = withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
        ["", buildPath(base, "cfg"), buildPath(base, "home")],
        () => loadSettings(""));
    assert(canFind(s.file, buildPath(base, "cfg")));

    // cwd settings.pravic is found before xdg
    {
        import std.file : chdir, getcwd;
        auto keep = getcwd();
        scope (exit) chdir(keep);
        chdir(base);
        write("settings.pravic", "");
        s = withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
            ["", buildPath(base, "cfg"), buildPath(base, "home")],
            () => loadSettings(""));
        assert(s.file == "settings.pravic", s.file);
    }
}

@("webui projects: resolution and shapes")
unittest
{
    auto base = buildPath(tempDir, "tachy_settings_webui_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "cfg"));
    mkdirRecurse(buildPath(base, "site"));
    // hermetic + serialized HOME: `~` expansion is asserted against a
    // controlled value, and other threaded tests mutate HOME — the
    // whole span (set, load, assert, restore) holds the env lock.
    // Everything after the first load is explicit-path and reads no
    // environment.
    Settings s;
    synchronized (envM)
    {
        const string savedHome = environment.get("HOME");
        environment["HOME"] = buildPath(base, "home");
        scope (exit) environment["HOME"] = savedHome;

        write(buildPath(base, "cfg", "s.pravic"),
            "webui { projects = [\"site\", \"~/home-site\", \"/abs/task.pravic\"] }\n");
        s = loadSettings(buildPath(base, "cfg", "s.pravic"));
        assert(s.webuiProjects.length == 3);
        assert(s.webuiProjects[0] == buildPath(base, "cfg", "site"),
            s.webuiProjects[0]); // relative to the settings file
        assert(s.webuiProjects[1] == buildPath(base, "home", "home-site"),
            s.webuiProjects[1]); // ~ expanded
        assert(s.webuiProjects[2] == "/abs/task.pravic"); // absolute kept
    }
    // alongside imports, and missing entries are fine (the webui
    // reports existence per project)
    write(buildPath(base, "cfg", "both.pravic"),
        "imports { paths = [\"libs\"] }\nwebui { projects = [\"nope\"] }\n");
    s = loadSettings(buildPath(base, "cfg", "both.pravic"));
    assert(s.importPaths.length == 1 && s.webuiProjects.length == 1);

    // empty section is fine
    write(buildPath(base, "cfg", "empty.pravic"), "webui { }\n");
    s = loadSettings(buildPath(base, "cfg", "empty.pravic"));
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
            loadSettings(buildPath(base, "cfg", "bad.pravic"));
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
private Settings withEnv(string[] names, string[] values,
    Settings delegate() dg) @trusted
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
    auto base = buildPath(tempDir, "tachy_settings_err_ut");
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
            loadSettings(buildPath(base, "s.pravic"));
            assert(false, "expected TachyError for: " ~ content);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "s.pravic"), msg);
    }

    // imports without paths is fine
    write(buildPath(base, "s.pravic"), "imports { }\n");
    auto s = loadSettings(buildPath(base, "s.pravic"));
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
