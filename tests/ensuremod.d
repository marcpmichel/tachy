/// Tests for tachy.modules.ensuremod, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.ensuremod;

import tachy.modules.ensuremod;

import std.exception : assertThrown;
import tachy.transport : LocalTransport;
import tachy.modules : TaskContext, validateModuleParams;
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
    auto r = runEnsureModule(p, ctx);
    assert(!r.changed && r.msg == "exit 0");

    // default expectation is exit 0
    Val[string] p2;
    p2["name"] = Val("true");
    p2["run"] = Val("true");
    assert(!runEnsureModule(p2, ctx).changed);

    // contains
    Val[string] p3;
    p3["name"] = Val("c");
    p3["run"] = Val("echo debian11");
    Val c;
    c.kind = Val.Kind.table_;
    c.table_["contains"] = Val("deb");
    p3["output"] = c;
    assert(!runEnsureModule(p3, ctx).changed);

    // matches
    Val[string] p4;
    p4["name"] = Val("m");
    p4["run"] = Val("echo debian-12");
    Val m;
    m.kind = Val.Kind.table_;
    m.table_["matches"] = Val("^debian-\\d+$");
    p4["output"] = m;
    assert(!runEnsureModule(p4, ctx).changed);

    // { not = 1 } accepts other codes
    Val[string] p5;
    p5["name"] = Val("n");
    p5["run"] = Val("exit 3");
    Val n;
    n.kind = Val.Kind.table_;
    n.table_["not"] = Val(1L);
    p5["exit_status"] = n;
    auto r5 = runEnsureModule(p5, ctx);
    assert(!r5.changed && r5.msg == "exit 3");

    // { cond = "<= 2" } range
    Val[string] p6;
    p6["name"] = Val("cd");
    p6["run"] = Val("exit 2");
    Val cd;
    cd.kind = Val.Kind.table_;
    cd.table_["cond"] = Val("<= 2");
    p6["exit_status"] = cd;
    assert(!runEnsureModule(p6, ctx).changed);
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
    auto r = runEnsureModule(p, ctx);
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
            runEnsureModule(p, ctx);
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

@("args appends literal arguments to the command")
unittest
{
    import std.algorithm.searching : canFind;
    import std.array : join;

    auto ctx = ctxLocal;

    Val[string] p;
    p["name"] = Val("three");
    p["run"] = Val("count() { echo $#; }; count");
    Val args;
    args.kind = Val.Kind.array_;
    args.array_ ~= Val("one");
    args.array_ ~= Val("two");
    args.array_ ~= Val("three");
    p["args"] = args;
    Val three;
    three.kind = Val.Kind.string_;
    three.str_ = "3";
    p["output"] = three;
    auto r = runEnsureModule(p, ctx);
    assert(!r.changed && r.msg == "exit 0", r.msg);

    // one element is one argument, even with spaces inside
    Val[string] q;
    q["name"] = Val("quoted");
    q["run"] = Val("count() { echo $#; }; count");
    Val qa;
    qa.kind = Val.Kind.array_;
    qa.array_ ~= Val("a b");
    qa.array_ ~= Val("c");
    q["args"] = qa;
    Val two;
    two.kind = Val.Kind.string_;
    two.str_ = "2";
    q["output"] = two;
    assert(runEnsureModule(q, ctx).msg == "exit 0");

    // the echoed values show the arguments arrived whole and in order
    Val[string] e;
    e["name"] = Val("echo");
    e["run"] = Val("echo");
    e["args"] = qa;
    Val exact;
    exact.kind = Val.Kind.string_;
    exact.str_ = "a b c";
    e["output"] = exact;
    auto r3 = runEnsureModule(e, ctx);
    assert(!r3.changed, r3.msg);
    assert(canFind(r3.details.join("\n"), "echo 'a b' 'c'"), r3.details.join("\n"));
}

@("args: empty array, templated entries, shape errors")
unittest
{
    import std.algorithm.searching : canFind;
    import tachy.vars : renderParams;

    auto ctx = ctxLocal;

    // an empty args appends nothing
    Val[string] p;
    p["name"] = Val("empty");
    p["run"] = Val("true");
    Val none;
    none.kind = Val.Kind.array_;
    p["args"] = none;
    assert(!runEnsureModule(p, ctx).changed);

    // entries render like every string
    Val[string] v;
    v["greeting"] = Val("hello");
    Val[string] p2;
    p2["name"] = Val("tpl");
    p2["run"] = Val("echo");
    Val ta;
    ta.kind = Val.Kind.array_;
    ta.array_ ~= Val("{{ greeting }}");
    p2["args"] = ta;
    Val exact;
    exact.kind = Val.Kind.string_;
    exact.str_ = "hello";
    p2["output"] = exact;
    assert(!runEnsureModule(renderParams(p2, v), ctx).changed);

    // load-time shape errors
    Val[string] bad;
    bad["name"] = Val("x");
    bad["run"] = Val("true");
    bad["args"] = Val("one");
    string msg;
    try
    {
        validateModuleParams("ensure", bad, "tasks.pravic: line 3");
        assert(false);
    }
    catch (TachyError e) msg = e.msg;
    assert(canFind(msg, "'args' must be an array of strings"), msg);

    Val intArr;
    intArr.kind = Val.Kind.array_;
    intArr.array_ ~= Val(3L);
    bad["args"] = intArr;
    try
    {
        validateModuleParams("ensure", bad, "tasks.pravic: line 3");
        assert(false);
    }
    catch (TachyError e) msg = e.msg;
    assert(canFind(msg, "'args' entries must be strings"), msg);
}

@("ensure captures both streams as the verbose payload")
unittest
{
    import std.algorithm.searching : canFind;
    import std.array : join;

    auto ctx = ctxLocal;

    Val[string] p;
    p["name"] = Val("both");
    p["run"] = Val("printf 'to-out\\n'; printf 'to-err\\n' >&2");
    auto r = runEnsureModule(p, ctx);
    assert(!r.changed);
    assert(canFind(r.details.join("\n"), "stdout: to-out"), r.details.join("\n"));
    assert(canFind(r.details.join("\n"), "stderr: to-err"), r.details.join("\n"));

    // a failing command with only stderr quotes the stderr
    Val[string] p2;
    p2["name"] = Val("err");
    p2["run"] = Val("echo problems >&2; exit 3");
    string msg;
    try
        runEnsureModule(p2, ctx);
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "exit status 3"), msg);
    assert(canFind(msg, "stderr: 'problems'"), msg);
}

private Val outTable(Val[string] entries)
{
    Val t;
    t.kind = Val.Kind.table_;
    t.table_ = entries;
    return t;
}

private Val outAny(Val[] entries)
{
    Val a;
    a.kind = Val.Kind.array_;
    a.array_ = entries;
    return a;
}

@("composed output expectations: and, not, any")
unittest
{
    import std.algorithm.searching : canFind;

    auto ctx = ctxLocal;

    // Runs `cmd` with the given output expectation: null on success,
    // the TachyError message on failure.
    string run(Val output, string cmd = "echo debian")
    {
        Val[string] p;
        p["name"] = Val("composed");
        p["run"] = Val(cmd);
        p["output"] = output;
        try
        {
            runEnsureModule(p, ctx);
            return null;
        }
        catch (TachyError e)
            return e.msg;
    }

    // several keys: all must hold
    assert(run(outTable(["contains": Val("deb"), "matches": Val("^deb.*$")])) is null);
    auto msg = run(outTable(["contains": Val("deb"), "matches": Val("^ub.*$")]));
    assert(canFind(msg, `does not satisfy a substring "deb" and a match of /^ub.*$/`), msg);

    // not negates one pattern; a bare string is the exact shape
    assert(run(outTable(["not": outTable(["contains": Val("ubuntu")])])) is null);
    assert(run(outTable(["not": outTable(["contains": Val("debian")])]), "echo ubuntu") is null);
    msg = run(outTable(["not": Val("debian")]));
    assert(canFind(msg, `does not satisfy not (exactly "debian")`), msg);

    // any: one listed pattern suffices
    assert(run(outTable(["any": outAny([Val("debian"), outTable(["matches": Val("^ub")])])])) is null);
    assert(run(outTable(["any": outAny([Val("debian"), outTable(["matches": Val("^ub")])])]),
        "echo ubuntu") is null);
    msg = run(outTable(["any": outAny([Val("debian"), outTable(["matches": Val("^ub")])])]),
        "echo arch");
    assert(canFind(msg, `does not satisfy any of [exactly "debian", a match of /^ub/]`), msg);

    // nesting: any of a negation and an atom
    assert(run(outTable(["any": outAny([outTable(["not": Val("debian")]), Val("x")])]),
        "echo arch") is null);
    msg = run(outTable(["any": outAny([outTable(["not": Val("debian")]), Val("x")])]));
    assert(canFind(msg, `any of [not (exactly "debian"), exactly "x"]`), msg);

    // mixed conjunction: a positive atom and a negation
    assert(run(outTable(["contains": Val("deb"), "not": outTable(["contains": Val("sid")])]),
        "echo debian bookworm") is null);
    msg = run(outTable(["contains": Val("deb"), "not": outTable(["contains": Val("sid")])]),
        "echo debian sid");
    assert(canFind(msg, `does not satisfy a substring "deb" and not (a substring "sid")`), msg);

    // all: AND over an array — the way to require two same-kind patterns
    Val both = outTable(["all": outAny([outTable(["contains": Val("active")]),
        outTable(["contains": Val("running")])])]);
    assert(run(both, "echo 'ActiveState=active SubState=running'") is null);
    msg = run(both, "echo 'ActiveState=active SubState=stopped'");
    assert(canFind(msg, `does not satisfy a substring "active" and a substring "running"`), msg);

    // none: no listed pattern may hold
    Val clean = outTable(["none": outAny([Val("error"), outTable(["matches": Val("^fail")])])]);
    assert(run(clean, "echo all good") is null);
    msg = run(clean, "echo fail overheat");
    assert(canFind(msg, `does not satisfy none of [exactly "error", a match of /^fail/]`), msg);
}

@("composed output: parse errors and deterministic describe")
unittest
{
    import std.algorithm.searching : canFind;

    string parseErr(Val v)
    {
        try
        {
            parseOutput(v, "ctx");
            return null;
        }
        catch (TachyError e)
            return e.msg;
    }

    // unknown keys stay strict
    auto msg = parseErr(outTable(["nope": Val(1L)]));
    assert(canFind(msg, "'output' takes only 'contains', 'matches', 'not', 'any', 'all' and 'none', not 'nope'"), msg);

    // an empty table can never pass: load-time error, not a runtime surprise
    Val[string] noneT;
    assert(canFind(parseErr(outTable(noneT)), "'output' must not be an empty table"));

    // not takes exactly one pattern
    assert(canFind(parseErr(outTable(["not": Val(42L)])), "'not' takes one pattern"), msg);
    msg = parseErr(outTable(["not": outTable(["matches": Val("[unclosed")])]));
    assert(canFind(msg, "ctx, in 'not': invalid regular expression"), msg);

    // any/all/none take non-empty pattern arrays
    assert(canFind(parseErr(outTable(["any": Val("x")])), "'any' takes an array of patterns"));
    Val[] none;
    assert(canFind(parseErr(outTable(["any": outAny(none)])), "'any' needs at least one pattern"));
    assert(canFind(parseErr(outTable(["all": Val("x")])), "'all' takes an array of patterns"));
    assert(canFind(parseErr(outTable(["all": outAny(none)])), "'all' needs at least one pattern"));
    assert(canFind(parseErr(outTable(["none": Val("x")])), "'none' takes an array of patterns"));
    assert(canFind(parseErr(outTable(["none": outAny(none)])), "'none' needs at least one pattern"));
    msg = parseErr(outTable(["none": outAny([Val(42L)])]));
    assert(canFind(msg, "'none' entries must be strings or tables"), msg);
    msg = parseErr(outTable(["any": outAny([Val(42L)])]));
    assert(canFind(msg, "'any' entries must be strings or tables"), msg);
    // a bad nested pattern names its path through the composition
    msg = parseErr(outTable(["any": outAny([outTable(["nope": Val(1L)])])]));
    assert(canFind(msg, "ctx, in 'any': 'output' takes only"), msg);

    // nested regexes still compile at load time
    assert(parseErr(outTable(["any": outAny([outTable(["matches": Val("^x$")])])])) is null);

    // single-shape tables keep their exact describe wording
    assert(parseOutput(outTable(["contains": Val("deb")]), "ctx").describe() == `a substring "deb"`);
    assert(parseOutput(Val("debian"), "ctx").describe() == `exactly "debian"`);

    // the describe order is the fixed shape order, never the table's hash order
    Val all = outTable([
        "none": outAny([Val("g")]),
        "all": outAny([outTable(["contains": Val("f")])]),
        "any": outAny([Val("d")]),
        "not": outTable(["contains": Val("c")]),
        "matches": Val("b"),
        "contains": Val("a"),
    ]);
    assert(parseOutput(all, "ctx").describe()
        == `a substring "a" and a match of /b/ and not (a substring "c") and any of [exactly "d"] and a substring "f" and none of [exactly "g"]`);
}
