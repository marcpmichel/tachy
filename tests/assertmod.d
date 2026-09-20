/// Tests for tachy.modules.assertmod (tests/ is compiled only under
/// `dub test`).  The module receives already-rendered parameters —
/// rendering against a host scope is runner.d's job, covered there —
/// so these tests pass literal values.
module tachy.tests.assertmod;

import tachy.modules.assertmod;
import tachy.modules;
import tachy.tests.fake;
import tachy.value : Val;
import tachy.errors : TachyError;

import std.algorithm.searching : canFind;
import std.exception : assertThrown;

private Val[string] P(string name, string value, Val[string] exp = null) {
    Val[string] p;
    p["name"] = Val(name);
    p["value"] = Val(value);
    foreach (string k, Val v; exp)
        p[k] = v;
    return p;
}

/// String convenience: wraps plain strings as a `Val` table for `P`.
private Val[string] E(string[string] exp) {
    Val[string] r;
    foreach (string k, string v; exp)
        r[k] = Val(v);
    return r;
}

private Val table(Val[string] entries) {
    Val t;
    t.kind = Val.Kind.table_;
    foreach (string k, Val v; entries)
        t.table_[k] = v;
    return t;
}

private Val arr(string[] items) {
    Val a;
    a.kind = Val.Kind.array_;
    foreach (s; items)
        a.array_ ~= Val(s);
    return a;
}

private string failMsg(Val[string] params) {
    auto t = new FakeTransport;
    try {
        runAssertModule(params, TaskContext(t, false, "fakehost", "/tmp"));
    } catch (TachyError e) {
        return e.msg;
    }
    assert(false, "expected the assertion to fail");
}

@("passing assertions: equals, contains, matches and compositions")
unittest {
    auto t = new FakeTransport;
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");

    // equals: exact match
    assert(!runAssertModule(P("p", "prod", E(["equals": "prod"])), ctx).changed);

    // contains and matches
    assert(!runAssertModule(P("c", "debian-12", E(["contains": "bian"])), ctx).changed);
    assert(!runAssertModule(P("m", "debian-12", E(["matches": `^debian-\d+$`])), ctx).changed);

    // several keys AND together
    assert(!runAssertModule(P("and", "prod-x",
        E(["contains": "prod", "matches": `^[a-z-]+$`])), ctx).changed);

    // not / any / all / none compose
    assert(!runAssertModule(P("n", "prod-x",
        ["contains": Val("prod"), "not": table(["contains": Val("test")])]), ctx).changed);
    assert(!runAssertModule(P("a", "ubuntu",
        ["any": arr(["debian", "ubuntu"])]), ctx).changed);

    // all: an array of patterns (here two contains, via nested tables)
    Val allT;
    allT.kind = Val.Kind.array_;
    allT.array_ ~= table(["contains": Val("prod")]);
    allT.array_ ~= table(["contains": Val("-x")]);
    assert(!runAssertModule(P("all", "prod-x", ["all": allT]), ctx).changed);
    assert(!runAssertModule(P("none", "all quiet",
        ["none": arr(["traceback", "panic"])]), ctx).changed);
    assert(t.commands.length == 0, "assert must not touch the transport");
}

@("failing assertion names the value and the expectation")
unittest {
    auto msg = failMsg(P("env", "staging", E(["equals": "prod"])));
    assert(canFind(msg, "assert 'env'"), msg);
    assert(canFind(msg, "value 'staging'"), msg);
    assert(canFind(msg, `does not satisfy exactly "prod"`), msg);

    // a composed expectation describes every part
    auto msg2 = failMsg(P("env", "prod",
        ["contains": Val("prod"), "not": table(["contains": Val("prod")])]));
    assert(canFind(msg2, `a substring "prod"`), msg2);
    assert(canFind(msg2, "not ("), msg2);

    // a regex expectation names its pattern
    auto msg3 = failMsg(P("v", "1.2", E(["matches": `^\d+\.\d+\.\d+$`])));
    assert(canFind(msg3, "a match of /"), msg3);
}

@("an assertion without expectations is an error, at run and load time")
unittest {
    Val[string] p;
    p["name"] = Val("x");
    p["value"] = Val("y");


    auto t = new FakeTransport;
    string msg;
    try {
        runAssertModule(p, TaskContext(t, false, "fakehost", "/tmp"));
        assert(false);
    } catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "needs at least one of"), msg);
    assert(canFind(msg, "'equals'"), msg);

    string msg2;
    try {
        validateModuleParams("assert", p, "ctx");
        assert(false);
    } catch (TachyError e)
        msg2 = e.msg;
    assert(canFind(msg2, "needs at least one of"), msg2);
}

@("load-time validation: value required, a string; regexes compile; keys checked")
unittest {
    // missing value
    Val[string] novalue;
    novalue["name"] = Val("x");
    novalue["equals"] = Val("x");
    assertThrown!(TachyError)(validateModuleParams("assert", novalue, "ctx"));

    // non-string value
    Val[string] badvalue;
    badvalue["name"] = Val("x");
    badvalue["value"] = Val(5L);
    badvalue["equals"] = Val("x");
    assertThrown!(TachyError)(validateModuleParams("assert", badvalue, "ctx"));

    // an invalid regex is a load-time error
    Val[string] badre;
    badre["name"] = Val("x");
    badre["value"] = Val("y");
    badre["matches"] = Val("(");
    assertThrown!(TachyError)(validateModuleParams("assert", badre, "ctx"));

    // unknown key
    Val[string] unk;
    unk["name"] = Val("x");
    unk["value"] = Val("y");
    unk["equals"] = Val("y");
    unk["bogus"] = Val("z");
    assertThrown!(TachyError)(validateModuleParams("assert", unk, "ctx"));
}

@("a check by nature: assert runs in check mode, never changed")
unittest {
    auto t = new FakeTransport;
    TaskContext ctx = TaskContext(t, true, "fakehost", "/tmp");
    auto r = runAssertModule(P("p", "prod", E(["equals": "prod"])), ctx);
    assert(!r.changed);
    assert(t.commands.length == 0);

    // a failing assertion fails the same way in check mode
    auto t2 = new FakeTransport;
    string msg;
    try {
        runAssertModule(P("p", "staging", E(["equals": "prod"])),
            TaskContext(t2, true, "fakehost", "/tmp"));
        assert(false);
    } catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "does not satisfy"), msg);
    assert(t2.commands.length == 0);
}

@("assertionExpectation strips the injected name and the value")
unittest {
    auto e = assertionExpectation(P("n", "v", E(["contains": "x"])), "ctx");
    assert(e.kind == Val.Kind.table_);
    assert(e.table_.length == 1 && "contains" in e.table_);

    // anything else travels: nested tables intact
    auto e2 = assertionExpectation(
        P("n", "v", E(["not": "x", "any": "y"])), "ctx");
    assert(e2.table_.length == 2);
}
