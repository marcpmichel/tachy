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
