/// Tests for tachy.runner, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.runner;

import tachy.runner;

import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : File;

unittest // resolveTasksFiles: directories map to main.pravic
{
    auto dir = buildPath(tempDir, "tachy_runner_ut", "proj");
    if (!exists(dir)) mkdirRecurse(dir);
    {
        auto f = File(buildPath(dir, "main.pravic"), "w");
        f.write("[files.\"/tmp/x\"]\n");
        f.close();
    }

    // directory argument -> main.pravic inside it
    auto r = resolveTasksFiles([dir]);
    assert(r.length == 1 && r[0] == buildPath(dir, "main.pravic"));

    // trailing slash on the directory behaves the same
    r = resolveTasksFiles([dir ~ "/"]);
    assert(r.length == 1 && canFind(r[0], "main.pravic"));

    // plain file and missing paths pass through untouched
    r = resolveTasksFiles(["site/other.pravic", "missing.pravic"]);
    assert(r == ["site/other.pravic", "missing.pravic"]);

    // no argument: main.pravic in the current directory
    r = resolveTasksFiles([]);
    assert(r == ["main.pravic"]);
}
