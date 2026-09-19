/// Tests for tachy.upgrade: the pure parts (URL/version parsing,
/// comparison) and the assembled upgrade flow.  Every step with a
/// side effect has a swappable hook; the live `tachy upgrade` against
/// the real repository is verified end-to-end separately.
module tachy.tests.upgrade;

import tachy.upgrade;

import std.exception : assertThrown;
import std.algorithm.searching : canFind;
import tachy.errors : TachyError;
import tachy.runner : RunOptions;
import tachy.tests.envsync : envM;

@("latestFromEffectiveUrl: strips the tag prefix and the v")
unittest
{
    assert(latestFromEffectiveUrl(
        "https://github.com/marcpmichel/tachy/releases/tag/v26.09.20") == "26.09.20");
    assert(latestFromEffectiveUrl(
        "https://github.com/marcpmichel/tachy/releases/tag/1.2.3") == "1.2.3");
    assert(latestFromEffectiveUrl(
        "https://github.com/marcpmichel/tachy/releases/tag/v0.1.0-rc1") == "0.1.0-rc1");

    // no /tag/ in the URL is an error naming the URL
    assertThrown!TachyError(latestFromEffectiveUrl(
        "https://github.com/marcpmichel/tachy/releases/latest"));
    assertThrown!TachyError(latestFromEffectiveUrl(
        "https://github.com/marcpmichel/tachy/releases/tag/"));
}

@("compareVersions: segment-wise numeric ordering")
unittest
{
    assert(compareVersions("26.09.17", "26.09.17") == 0);
    assert(compareVersions("26.09.17", "26.09.20") < 0);
    assert(compareVersions("26.09.20", "26.09.17") > 0);
    // numeric, not lexicographic: 9 < 10 even though "9" > "10"
    assert(compareVersions("26.9.10", "26.10.1") < 0);
    // missing segments count as zero
    assert(compareVersions("26.09", "26.09.0") == 0);
    assert(compareVersions("26.09", "26.08.9") > 0);
    // next century sorts after this one
    assert(compareVersions("99.12.31", "00.01.01") > 0);

    // junk is an error naming the version
    assertThrown!TachyError(compareVersions("abc", "1.2.3"));
}

@("runUpgrade: takes no sub-commands any more")
unittest
{
    latestReleaseHook = () => "26.09.17";
    scope (exit) latestReleaseHook = null;

    foreach (args; [ ["check"], ["install"], ["now"] ])
    {
        string msg;
        try
            runUpgrade(RunOptions(), "26.09.17", args);
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "takes no sub-commands"), msg);
    }
}

@("runUpgrade: same version reports and touches nothing")
unittest
{
    latestReleaseHook = () => "26.09.17";
    scope (exit) latestReleaseHook = null;
    downloadReleaseHook = (url, tmp) { throw new Error("must not download"); };
    scope (exit) downloadReleaseHook = null;
    confirmHook = (q) { throw new Error("must not ask"); };
    scope (exit) confirmHook = null;

    assert(runUpgrade(RunOptions(), "26.09.17", []) == 0);
}

@("runUpgrade: a newer installed build reports and touches nothing")
unittest
{
    latestReleaseHook = () => "26.09.16";
    scope (exit) latestReleaseHook = null;
    downloadReleaseHook = (url, tmp) { throw new Error("must not download"); };
    scope (exit) downloadReleaseHook = null;

    assert(runUpgrade(RunOptions(), "26.09.17", []) == 0);
}

@("runUpgrade: an update without a terminal and without --yes is refused")
unittest
{
    version (Posix)
    {
        latestReleaseHook = () => "99.99.99";
        scope (exit) latestReleaseHook = null;
        downloadReleaseHook = (url, tmp) { throw new Error("must not download"); };
        scope (exit) downloadReleaseHook = null;

        // force fd 0 to a non-tty regardless of how the suite is run
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.unistd : close, dup, dup2;
        const devnull = open("/dev/null", O_RDONLY);
        assert(devnull >= 0);
        const saved = dup(0);
        dup2(devnull, 0);
        scope (exit)
        {
            dup2(saved, 0);
            close(saved);
            close(devnull);
        }

        string msg;
        try
            runUpgrade(RunOptions(), "26.09.17", []);
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "--yes"), msg);
    }
}

@("runUpgrade: a declined prompt cancels without downloading")
unittest
{
    latestReleaseHook = () => "99.99.99";
    scope (exit) latestReleaseHook = null;
    string question;
    confirmHook = (q)
    {
        question = q;
        return false;
    };
    scope (exit) confirmHook = null;
    downloadReleaseHook = (url, tmp) { throw new Error("must not download"); };
    scope (exit) downloadReleaseHook = null;

    assert(runUpgrade(RunOptions(), "26.09.17", []) == 0);
    assert(canFind(question, "[y/N]"), question);
}

@("runUpgrade: an accepted prompt upgrades like --yes")
unittest
{
    latestReleaseHook = () => "99.99.99";
    scope (exit) latestReleaseHook = null;
    confirmHook = (q) => true;
    scope (exit) confirmHook = null;

    string url;
    string tmpPath;
    downloadReleaseHook = (u, tmp)
    {
        url = u;
        tmpPath = tmp;
        writeFakeRelease(tmp);
    };
    scope (exit) downloadReleaseHook = null;
    string gotTmp;
    string gotExe;
    replaceHook = (tmp, exe)
    {
        gotTmp = tmp;
        gotExe = exe;
    };
    scope (exit) replaceHook = null;

    synchronized (envM) // the pid-derived temp path is shared by all tests
    {
        assert(runUpgrade(RunOptions(), "26.09.17", []) == 0);
        assert(canFind(url, "/releases/download/v99.99.99/tachy-99.99.99-linux-amd64"), url);
        assert(gotExe == thisExePath());
        // the temp file sits next to the binary (same filesystem, atomic
        // rename) and carries the verified bytes
        import std.path : dirName, baseName;
        assert(dirName(gotTmp) == dirName(thisExePath()));
        assert(canFind(baseName(gotTmp), ".tachy-upgrade-"), gotTmp);
        assert(read(gotTmp) == fakeReleaseBytes());
        assert(gotTmp == tmpPath);
    }
}

@("runUpgrade: --yes downloads, verifies and replaces without asking")
unittest
{
    latestReleaseHook = () => "99.99.99";
    scope (exit) latestReleaseHook = null;
    confirmHook = (q) { throw new Error("must not ask with --yes"); };
    scope (exit) confirmHook = null;

    downloadReleaseHook = (url, tmp) { writeFakeRelease(tmp); };
    scope (exit) downloadReleaseHook = null;
    string gotTmp;
    string gotExe;
    replaceHook = (tmp, exe)
    {
        gotTmp = tmp;
        gotExe = exe;
    };
    scope (exit) replaceHook = null;

    RunOptions opts;
    opts.yes = true;
    synchronized (envM) // the pid-derived temp path is shared by all tests
    {
        assert(runUpgrade(opts, "26.09.17", []) == 0);
        assert(gotExe == thisExePath());
        assert(read(gotTmp) == fakeReleaseBytes());
    }
}

@("runUpgrade: a broken download fails and leaves no temp file behind")
unittest
{
    latestReleaseHook = () => "99.99.99";
    scope (exit) latestReleaseHook = null;

    downloadReleaseHook = (url, tmp)
    {
        import std.file : write;
        write(tmp, "not a tachy binary");
    };
    scope (exit) downloadReleaseHook = null;
    replaceHook = (tmp, exe) { throw new Error("must not replace"); };
    scope (exit) replaceHook = null;

    import core.sys.posix.unistd : getpid;
    import std.conv : text;
    import std.path : buildPath, dirName;
    import std.file : exists;
    const exe = thisExePath();
    const leakedTmp = buildPath(dirName(exe),
        ".tachy-upgrade-" ~ text(getpid()) ~ ".tmp");

    RunOptions opts;
    opts.yes = true;
    synchronized (envM) // the pid-derived temp path is shared by all tests
    {
        string msg;
        try
            runUpgrade(opts, "26.09.17", []);
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "99.99.99"), msg);
        assert(!exists(leakedTmp), "the failed download must be cleaned up");
    }
}

@("defaultReplace: renames the download over the target")
unittest
{
    import std.file : mkdir, write, read, remove, exists, tempDir;
    import std.path : buildPath;
    import core.sys.posix.unistd : getpid;
    import std.conv : text;

    const dir = buildPath(tempDir, "tachy-upgrade-test-" ~ text(getpid()));
    mkdir(dir);
    scope (exit)
    {
        if (exists(buildPath(dir, "target")))
            remove(buildPath(dir, "target"));
        remove(dir);
    }

    const target = buildPath(dir, "target");
    const fresh = buildPath(dir, "fresh");
    write(target, "old bytes");
    write(fresh, "new bytes");
    defaultReplace(fresh, target);
    assert(read(target) == "new bytes");
    assert(!exists(fresh));
}

// --- helpers -----------------------------------------------------------

import std.file : thisExePath, read, write;

/// A stand-in release binary: a script that answers `version` exactly
/// like the real one, so the verify step accepts it.
private string fakeReleaseBytes() @safe pure
{
    return "#!/bin/sh\necho \"tachy 99.99.99\"\n";
}

private void writeFakeRelease(in string path) @trusted
{
    write(path, fakeReleaseBytes());
}
