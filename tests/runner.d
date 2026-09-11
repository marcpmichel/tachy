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

unittest // collectDecryptedFiles: controller-side decryption of age-marked src
{
import tachy.errors : TachyError;
import std.conv : text;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath, dirName;
import tachy.models : loadTasksFile;
import tachy.project : DecryptedFile;
import tachy.value : Val;
import tachy.vars : AgeIdentity, ageDecrypt;

auto dir = buildPath(tempDir, "tachy_runner_age_ut");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(buildPath(dir, "secrets"));
scope (exit) rmdirRecurse(dir);

auto mainFile = buildPath(dir, "main.pravic");
{
    import std.stdio : File;
    auto f = File(mainFile, "w");
    f.write(`
file /etc/a.key { src = "secrets/shared.age", age = true }
file /etc/b.key { src = "secrets/shared.age", age = true }
file /etc/c.key { src = "secrets/c.age", age = true }
file /etc/d.key { src = "secrets/{{ host }}.age", age = true }
`);
    f.close();
}
write(buildPath(dir, "secrets", "shared.age"), "age-encryption.org/v1\nshared\n");
write(buildPath(dir, "secrets", "c.age"), "age-encryption.org/v1\nc\n");
write(buildPath(dir, "secrets", "web1.age"), "age-encryption.org/v1\nweb1\n");
write(buildPath(dir, "id.txt"), "# identity\n");

int calls;
auto saved = ageDecrypt;
scope (exit) ageDecrypt = saved;
ageDecrypt = (string agePath, in AgeIdentity identity, string where)
{
    calls++;
    return "PLAIN:" ~ agePath;
};

auto loaded = loadTasksFile(mainFile);
Val[string] hostVars;
hostVars["host"] = Val("web1");

string[string] cache;
auto files = collectDecryptedFiles(loaded, hostVars, dir,
    buildPath(dir, "id.txt"), cache);

// three unique sources: shared (deduped across two jobs), c, and the
// host-templated web1 — each decrypted exactly once
assert(files.length == 3, text(files.length));
assert(calls == 3, text(calls));
foreach (ref const f; files)
{
    if (f.relPath == "secrets/shared.age")
        assert(f.bytes == "PLAIN:" ~ buildPath(dir, "secrets", "shared.age"));
    else if (f.relPath == "secrets/c.age")
        assert(f.bytes == "PLAIN:" ~ buildPath(dir, "secrets", "c.age"));
    else if (f.relPath == "secrets/web1.age")
        assert(f.bytes == "PLAIN:" ~ buildPath(dir, "secrets", "web1.age"));
    else
        assert(false, f.relPath);
}

// the cache serves a second host without re-decrypting
auto more = collectDecryptedFiles(loaded, hostVars, dir,
    buildPath(dir, "id.txt"), cache);
assert(more.length == 3 && calls == 3);

// a source outside the project is refused: it could not be shipped
{
    import std.file : mkdirRecurse;
    mkdirRecurse(buildPath(tempDir, "tachy_runner_age_ut_out"));
    scope (exit) rmdirRecurse(buildPath(tempDir, "tachy_runner_age_ut_out"));
    write(buildPath(tempDir, "tachy_runner_age_ut_out", "x.age"), "x");
    {
        import std.stdio : File;
        auto f = File(mainFile, "w");
        f.write(`
file /tmp/x { src = "../../tachy_runner_age_ut_out/x.age", age = true }
`);
        f.close();
    }
    auto l2 = loadTasksFile(mainFile);
    string[string] cache2;
    string msg;
    try
    {
        collectDecryptedFiles(l2, null, dir, buildPath(dir, "id.txt"), cache2);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "must live inside the project directory"), msg);
    assert(canFind(msg, "main.pravic"), msg);
}
}
