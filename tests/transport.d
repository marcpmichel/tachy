/// Tests for tachy.transport, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.transport;

import tachy.transport;

unittest // local execution
{
    auto t = new LocalTransport;
    auto r = t.run("echo hi");
    assert(r.ok);
    assert(r.outText == "hi\n");
    auto bad = t.run("exit 3");
    assert(!bad.ok && bad.status == 3);
}

unittest // runStreaming: lines arrive while the command runs
{
    import std.conv : text;
    import std.datetime.stopwatch : StopWatch;

    auto t = new LocalTransport;
    string[] lines;
    bool[] errs;
    ulong[] stamps; // ticks at each line
    StopWatch clock;
    clock.start();

    auto r = t.runStreaming(
        "echo one; echo err-one >&2; sleep 0.4; echo two; printf no-newline",
        (string line, bool isErr)
        {
            synchronized (Object.classinfo)
            {
                lines ~= line;
                errs ~= isErr;
                stamps ~= clock.peek.total!"usecs";
            }
        });

    assert(r.ok, r.errText);
    assert(lines.length == 4, text(lines));
    // only relative stdout order is guaranteed: the stderr drain
    // thread may deliver its line at any position
    import std.algorithm.searching : canFind;
    import std.algorithm.searching : countUntil;
    const size_t iOne = lines.countUntil("one");
    const size_t iTwo = lines.countUntil("two");
    const size_t iNone = lines.countUntil("no-newline");
    assert(iOne < iTwo && iTwo < iNone, text(lines));
    assert(canFind(lines, "err-one"), text(lines));
    assert(r.outText == "one\ntwo\nno-newline", r.outText);
    assert(r.errText == "err-one\n");
    // streaming, not batched: "two" arrived well after "one"
    assert(stamps[iTwo] > stamps[iOne] + 300_000, text(stamps)); // usecs
}

unittest // stdin round trip
{
    auto t = new LocalTransport;
    auto r = t.runWithInput("cat > /tmp/.tachy_ut_pipe && cat /tmp/.tachy_ut_pipe", "payload-é\n");
    assert(r.ok);
    assert(r.outText == "payload-é\n");
    import std.file : remove;
    remove("/tmp/.tachy_ut_pipe");
}

unittest // shell quoting
{
    assert(shQuote("plain") == "'plain'");
    assert(shQuote("it's") == "'it'\\''s'");
    assert(shQuote("") == "''");
    auto t = new LocalTransport;
    auto r = t.run("echo " ~ shQuote("a b'c d$e"));
    assert(r.outText == "a b'c d$e\n");
}

unittest // statPath via local transport
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, write;
    import std.path : buildPath;
    import std.file : tempDir;
    auto dir = buildPath(tempDir, "tachy_transport_ut");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) if (exists(dir)) rmdirRecurse(dir);

    auto t = new LocalTransport;
    auto missing = statPath(t, buildPath(dir, "nope"));
    assert(missing.kind == StatKind.nonexistent);

    auto f = buildPath(dir, "f");
    import std.stdio : File;
    { auto fh = File(f, "w"); fh.write("x"); } // scope: deterministic flush
    chmod0(f, 384);
    auto st = statPath(t, f);
    assert(st.kind == StatKind.file);
    assert(st.mode == 384);
    assert(st.owner.length && st.group.length);

    version (linux)
    {
        symlink("/nonexistent-target", buildPath(dir, "broken"));
        auto lnk = statPath(t, buildPath(dir, "broken"));
        assert(lnk.kind == StatKind.link);
        assert(readLinkTarget(t, buildPath(dir, "broken")) == "/nonexistent-target");
    }
}

private void chmod0(string path, int mode)
{
    import std.conv : to;
    import std.process : execute;
    execute(["chmod", to!string(mode, 8), path]);
}
