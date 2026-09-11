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
