/// Tests for tachy.generate, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.generate;

import tachy.generate;

import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.path : buildPath;
import tachy.errors : TachyError;

@("runGenerate argument validation")
unittest
{
    foreach (args; [cast(string[])[], ["key"], ["key", "a", "b"],
        ["cert", "x"]])
    {
        string msg;
        try
        {
            runGenerate(args);
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "generate"), msg);
    }
    // empty paths are rejected by both generators
    assertThrown!TachyError(runGenerate(["key", ""]));
    assertThrown!TachyError(runGenerate(["task", ""]));
}

@("generate completions: shell validation, asset output, drift guard")
unittest
{
    import tachy.generate : completionBash, completionFish, completionZsh;

    // unknown and missing shells are errors naming the valid ones
    string msg;
    try
    {
        completionsText("tcsh");
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "bash, zsh or fish"), msg);

    try
    {
        completionsText("");
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "bash, zsh or fish"), msg);

    // the output per shell is exactly the embedded asset
    assert(completionsText("bash") == completionBash);
    assert(completionsText("zsh") == completionZsh);
    assert(completionsText("fish") == completionFish);

    // drift guard: every command word, sub-command word and registered
    // option must appear in each script, or the asset is stale —
    // update all three together with the CLI surface
    foreach (shell, script; ["bash": completionBash, "zsh": completionZsh,
                             "fish": completionFish])
    {
        foreach (w; ["apply", "check", "hosts", "generate", "webui",
                     "webdoc", "man", "version", "help", "upgrade",
                     "list", "info", "key", "task", "config", "project",
                     "completions", "bash", "zsh", "fish"])
            assert(canFind(script, w),
                shell ~ " completion lacks command word " ~ w);
        // fish spells long options with -l (checked below)
        if (shell == "fish")
            continue;
        foreach (o; ["--inventory", "--verbose", "--color", "--direct",
                     "--direct-report", "--events", "--keep-bundle",
                     "--config", "--identity", "--address", "--port",
                     "--no-browser", "--completion", "--yes", "--help"])
            assert(canFind(script, o),
                shell ~ " completion lacks option " ~ o);
    }

    // short forms: bare words in bash, brace forms in zsh, -s in fish
    foreach (s; ["-i", "-v", "-y", "-h"])
    {
        assert(canFind(completionBash, s), "bash completion lacks " ~ s);
        assert(canFind(completionZsh, s), "zsh completion lacks " ~ s);
        assert(canFind(completionFish, "-s " ~ s[1 .. $]),
            "fish completion lacks -s " ~ s[1 .. $]);
    }
    // fish spells long options with -l
    foreach (o; ["inventory", "verbose", "color", "direct",
                 "direct-report", "events", "keep-bundle", "config",
                 "identity", "address", "port", "no-browser",
                 "completion", "yes", "help"])
        assert(canFind(completionFish, "-l " ~ o), "fish completion lacks -l " ~ o);

    // the dynamic selection source is wired into every script
    foreach (shell, script; ["bash": completionBash, "zsh": completionZsh,
                             "fish": completionFish])
        assert(canFind(script, "hosts list --completion"),
            shell ~ " completion must call hosts list --completion");
}

@("generateTask writes a loadable sample and never overwrites")
unittest
{
    import tachy.models : loadTasksFile;

    auto dir = buildPath(tempDir, "tachy_generate_ut");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    const string path = buildPath(dir, "main.pravic");
    assert(generateTask(path) == 0);
    assert(exists(path));
    assert(canFind(readText(path), "{{ inventory_hostname }}"));

    // the sample is a valid tasks file: it loads like any other
    auto loaded = loadTasksFile(path);
    assert(loaded.jobs.length >= 3);

    // second generation refuses to overwrite
    string msg;
    try
    {
        generateTask(path);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "already exists"), msg);
}

@("generate config: loadable sample, no overwrite")
unittest
{
    import tachy.config : loadConfig;

    auto dir = buildPath(tempDir, "tachy_generate_config_ut");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    const string path = buildPath(dir, "config.pravic");
    assert(runGenerate(["config", path]) == 0);
    auto s = loadConfig(path);
    assert(s.importPaths.length == 0); // entries are commented out
    assert(s.webuiProjects.length == 0); // so are these
    assertThrown!TachyError(runGenerate(["config", path]));
}

@("generate project: scaffold, loadability, no overwrite, '.' fills cwd")
unittest
{
    import tachy.config : loadConfig;
    import tachy.inventory : Inventory;
    import tachy.models : loadTasksFile;

    auto base = buildPath(tempDir, "tachy_generate_project_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(base);
    scope (exit) rmdirRecurse(base);

    // a named folder is created and filled with the three samples
    const string dir = buildPath(base, "demo");
    assert(runGenerate(["project", dir]) == 0);
    foreach (f; ["inventory.pravic", "main.pravic", "config.pravic"])
        assert(exists(buildPath(dir, f)), f);

    // all three samples load like any project's files
    auto inv = Inventory.load(buildPath(dir, "inventory.pravic"), "");
    auto hosts = inv.select("all");
    assert(hosts.length == 1 && hosts[0].name == "example", hosts[0].name);
    assert(hosts[0].address == "tachy.example.com");
    assert(hosts[0].tags.canFind("demo"));
    assert(inv.select("@demo").length == 1); // the sample tag selects
    assert(loadTasksFile(buildPath(dir, "main.pravic")).jobs.length >= 3);
    auto s = loadConfig(buildPath(dir, "config.pravic"));
    assert(s.importPaths.length == 0 && s.webuiProjects.length == 0
        && s.outputFormat == "flat"); // entries are commented out

    // second generation refuses to overwrite, naming the file
    string msg;
    try
    {
        runGenerate(["project", dir]);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "already exists"), msg);

    // a partially populated folder refuses too, naming the existing
    // file, and never overwrites the sentinels (all three or nothing)
    import std.file : write;
    auto partial = buildPath(base, "partial");
    mkdirRecurse(partial);
    foreach (f; ["inventory.pravic", "main.pravic", "config.pravic"])
    {
        write(buildPath(partial, f), "sentinel"); // one more each round
        msg = "";
        try
        {
            runGenerate(["project", partial]);
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "already exists"), msg);
        assert(canFind(msg, ".pravic"), msg); // names the offending file
        foreach (g; ["inventory.pravic", "main.pravic", "config.pravic"])
            if (exists(buildPath(partial, g)))
                assert(readText(buildPath(partial, g)) == "sentinel", g);
    }

    // '.' fills the current directory
    import tachy.tests.envsync : envM;
    synchronized (envM) // chdir is process-global
    {
        import std.file : chdir, getcwd;
        auto keep = getcwd();
        scope (exit) chdir(keep);
        chdir(base);
        assert(runGenerate(["project", "."]) == 0);
        foreach (f; ["inventory.pravic", "main.pravic", "config.pravic"])
            assert(exists(f), f);
        assertThrown!TachyError(runGenerate(["project", "."]));
    }

    // empty path is rejected
    assertThrown!TachyError(runGenerate(["project", ""]));
}
