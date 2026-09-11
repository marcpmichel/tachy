/// Tests for tachy.modules.checkmod, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.checkmod;

import tachy.modules.checkmod;

import std.exception : assertThrown;
import tachy.transport : LocalTransport;
import tachy.modules : TaskContext;
import tachy.value : Val;
import tachy.errors : TachyError;

private TaskContext ctxLocal()
{
    TaskContext ctx = TaskContext(new LocalTransport, false, "localhost", "/tmp");
    return ctx;
}

@("passing assertions")
unittest
{
    auto ctx = ctxLocal;

    Val[string] p;
    p["name"] = Val("os");
    p["run"] = Val("printf 'debian\\n'");
    p["exit_status"] = Val(0L);
    p["output"] = Val("debian");
    auto r = runCheckModule(p, ctx);
    assert(!r.changed && r.msg == "exit 0");

    // default expectation is exit 0
    Val[string] p2;
    p2["name"] = Val("true");
    p2["run"] = Val("true");
    assert(!runCheckModule(p2, ctx).changed);

    // contains
    Val[string] p3;
    p3["name"] = Val("c");
    p3["run"] = Val("echo debian11");
    Val c;
    c.kind = Val.Kind.table_;
    c.table_["contains"] = Val("deb");
    p3["output"] = c;
    assert(!runCheckModule(p3, ctx).changed);

    // matches
    Val[string] p4;
    p4["name"] = Val("m");
    p4["run"] = Val("echo debian-12");
    Val m;
    m.kind = Val.Kind.table_;
    m.table_["matches"] = Val("^debian-\\d+$");
    p4["output"] = m;
    assert(!runCheckModule(p4, ctx).changed);

    // { not = 1 } accepts other codes
    Val[string] p5;
    p5["name"] = Val("n");
    p5["run"] = Val("exit 3");
    Val n;
    n.kind = Val.Kind.table_;
    n.table_["not"] = Val(1L);
    p5["exit_status"] = n;
    auto r5 = runCheckModule(p5, ctx);
    assert(!r5.changed && r5.msg == "exit 3");

    // { cond = "<= 2" } range
    Val[string] p6;
    p6["name"] = Val("cd");
    p6["run"] = Val("exit 2");
    Val cd;
    cd.kind = Val.Kind.table_;
    cd.table_["cond"] = Val("<= 2");
    p6["exit_status"] = cd;
    assert(!runCheckModule(p6, ctx).changed);
}

@("run executes in the defining tasks file's directory")
unittest
{
    import std.file : exists, mkdirRecurse, tempDir, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "tachy_execmod_ut");
    if (!exists(dir)) mkdirRecurse(dir);
    write(buildPath(dir, "marker.txt"), "next-to-the-tasks-file\n");

    TaskContext ctx = TaskContext(new LocalTransport, false, "localhost", dir);
    Val[string] p;
    p["name"] = Val("rel");
    p["run"] = Val("cat marker.txt");
    p["output"] = Val("next-to-the-tasks-file");
    auto r = runCheckModule(p, ctx);
    assert(!r.changed && r.msg == "exit 0", r.msg);
}

@("failing assertions")
unittest
{
    auto ctx = ctxLocal;

    string fail(Val[string] p)
    {
        try
        {
            runCheckModule(p, ctx);
            return null;
        }
        catch (TachyError e)
            return e.msg;
    }

    Val[string] p;
    p["name"] = Val("bad-exit");
    p["run"] = Val("exit 7");
    auto msg = fail(p);
    import std.algorithm.searching : canFind;
    assert(canFind(msg, "exit status 7, expected 0"), msg);

    p["exit_status"] = Val(7L);
    assert(fail(p) is null);

    Val n;
    n.kind = Val.Kind.table_;
    n.table_["not"] = Val(7L);
    p["exit_status"] = n;
    msg = fail(p);
    assert(canFind(msg, "expected not 7"), msg);

    Val cd;
    cd.kind = Val.Kind.table_;
    cd.table_["cond"] = Val("< 7");
    p["exit_status"] = cd;
    msg = fail(p);
    assert(canFind(msg, "expected < 7"), msg);

    Val[string] q;
    q["name"] = Val("bad-output");
    q["run"] = Val("echo ubuntu");
    q["output"] = Val("debian");
    msg = fail(q);
    assert(canFind(msg, "does not satisfy exactly \"debian\""), msg);

    Val c;
    c.kind = Val.Kind.table_;
    c.table_["contains"] = Val("deb");
    q["output"] = c;
    msg = fail(q);
    assert(canFind(msg, "substring \"deb\""), msg);

    Val m;
    m.kind = Val.Kind.table_;
    m.table_["matches"] = Val("^deb.*$");
    q["output"] = m;
    msg = fail(q);
    assert(canFind(msg, "match of /^deb.*$/"), msg);
}

@("parse errors")
unittest
{
    import std.algorithm.searching : canFind;

    string msg;
    try
    {
        parseExitStatus(Val(1.5), "ctx");
        assert(false);
    }
    catch (TachyError e) msg = e.msg;
    assert(canFind(msg, "'exit_status' must be"), msg);

    Val bad;
    bad.kind = Val.Kind.table_;
    bad.table_["nope"] = Val(1L);
    try
    {
        parseExitStatus(bad, "ctx");
        assert(false);
    }
    catch (TachyError e) msg = e.msg;
    assert(canFind(msg, "'exit_status' must be"), msg);

    Val bcond;
    bcond.kind = Val.Kind.table_;
    bcond.table_["cond"] = Val("< banana");
    try
    {
        parseExitStatus(bcond, "ctx");
        assert(false);
    }
    catch (TachyError e) msg = e.msg;
    assert(canFind(msg, "'cond' must be an operator"), msg);

    Val bre;
    bre.kind = Val.Kind.table_;
    bre.table_["matches"] = Val("[unclosed");
    try
    {
        parseOutput(bre, "ctx");
        assert(false);
    }
    catch (TachyError e) msg = e.msg;
    assert(canFind(msg, "invalid regular expression"), msg);

    Val bout;
    bout.kind = Val.Kind.integer_;
    try
    {
        parseOutput(bout, "ctx");
        assert(false);
    }
    catch (TachyError e) msg = e.msg;
    assert(canFind(msg, "'output' must be"), msg);
}
