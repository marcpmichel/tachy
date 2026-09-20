/// Tests for tachy.modules.probemod — the `probe` directive's module:
/// assertions on status and body, parameter validation, check-mode
/// behavior.  The queries go to the in-process OneShotServer.
module tachy.tests.probemod;

import tachy.errors : TachyError;
import tachy.modules : TaskContext, validateModuleParams;
import tachy.modules.probemod : runProbeModule;
import tachy.tests.fake : FakeTransport;
import tachy.tests.http : OneShotServer;
import tachy.value : Val;

import std.algorithm.searching : canFind, endsWith, startsWith;

private TaskContext ctxLocal(bool checkMode = false)
{
    TaskContext ctx = TaskContext(new FakeTransport, checkMode, "localhost", "/tmp");
    return ctx;
}

private Val[string] baseParams(string url)
{
    Val[string] p;
    p["url"] = Val(url);
    return p;
}

private Val tableOf(string key, Val v)
{
    Val t;
    t.kind = Val.Kind.table_;
    t.table_[key] = v;
    return t;
}

private Val arrayOf(string v)
{
    Val a;
    a.kind = Val.Kind.array_;
    a.array_ ~= Val(v);
    return a;
}

@("passing checks: status, default code, never changed")
unittest
{

    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok\n");
    scope (exit) srv.done();
    auto p = baseParams(srv.url("/health"));
    auto r = runProbeModule(p, ctxLocal);
    assert(!r.changed && r.msg == "200 OK", r.msg);
    assert(canFind(r.details[0], "GET " ~ srv.url("/health")), r.details[0]);

    // an explicit code that matches, plus a body assertion
    auto srv2 = new OneShotServer("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok");
    scope (exit) srv2.done();
    Val[string] p2 = baseParams(srv2.url("/make"));
    p2["type"] = Val("POST");
    p2["code"] = Val(201L);
    p2["output"] = Val("ok");
    r = runProbeModule(p2, ctxLocal);
    assert(!r.changed && r.msg == "201 Created", r.msg);

    // checks by nature: the query runs even in check mode
    auto srv3 = new OneShotServer("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
    scope (exit) srv3.done();
    Val[string] p3 = baseParams(srv3.url("/drain"));
    p3["code"] = Val(204L);
    r = runProbeModule(p3, ctxLocal(true));
    assert(!r.changed && r.msg == "204 No Content", r.msg);
}

@("failing checks: status mismatch and body assertions")
unittest
{
    auto srv = new OneShotServer("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot here\n");
    scope (exit) srv.done();

    auto p = baseParams(srv.url("/gone"));
    try
    {
        runProbeModule(p, ctxLocal);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        assert(canFind(e.msg, "status 404, expected 200"), e.msg);

    // matching code, failing body expectation (trimmed, like ensure)
    auto srv2 = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nubuntu");
    scope (exit) srv2.done();
    Val[string] p2 = baseParams(srv2.url("/os"));
    p2["output"] = tableOf("contains", Val("debian"));
    try
    {
        runProbeModule(p2, ctxLocal);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        assert(canFind(e.msg, "does not satisfy a substring \"debian\""), e.msg);

    // one connection per server: a fresh one for the second query
    auto srv3 = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nubuntu");
    scope (exit) srv3.done();
    p2["url"] = Val(srv3.url("/os"));
    p2["output"] = tableOf("matches", Val("^deb.*$"));
    try
    {
        runProbeModule(p2, ctxLocal);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        assert(canFind(e.msg, "match of /^deb.*$/"), e.msg);
}

@("type, headers and data reach the wire")
unittest
{
    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    scope (exit) srv.done();

    Val[string] p = baseParams(srv.url("/api"));
    p["type"] = Val("PUT");
    p["headers"] = arrayOf("X-Tachy=1");
    p["data"] = Val("payload");
    auto r = runProbeModule(p, ctxLocal);
    assert(!r.changed);

    assert(srv.received.startsWith("PUT /api HTTP/1.1\r\n"), srv.received);
    assert(canFind(srv.received, "X-Tachy: 1\r\n"), srv.received);
    assert(canFind(srv.received, "Content-Length: 7\r\n"), srv.received);
    assert(srv.received.endsWith("payload"), srv.received);
}

@("errors carry the url; timeouts come from the deadline")
unittest
{
    import core.time : seconds;
    auto srv = new OneShotServer("", true);
    Val[string] p = baseParams(srv.url("/slow"));
    p["timeout"] = Val(1L);
    try
    {
        runProbeModule(p, ctxLocal);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
    {
        import std.conv : text;
        assert(canFind(e.msg, "probe '" ~ srv.url("/slow") ~ "'"), e.msg);
        assert(canFind(e.msg, "timed out after 1s"), e.msg);
    }
    srv.done();

    // an empty body is sent (Content-Length: 0), unlike no body at all
    auto srv2 = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    scope (exit) srv2.done();
    Val[string] q = baseParams(srv2.url("/empty"));
    q["data"] = Val("");
    runProbeModule(q, ctxLocal);
    assert(canFind(srv2.received, "Content-Length: 0\r\n"), srv2.received);
}

@("redirects: followed by default; \"no\" disables; { max = N } caps")
unittest
{
    auto target = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
        false, 3);
    scope (exit) target.done();
    auto hop = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ target.url("/real") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop.done();
    auto hop2 = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ target.url("/real") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop2.done();
    auto hop3 = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ target.url("/real") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop3.done();

    // default: the final answer is asserted
    auto r = runProbeModule(baseParams(hop.url("/jump")), ctxLocal);
    assert(r.msg == "200 OK", r.msg);

    // "no": the check sees the redirect itself — so say code = 302
    Val[string] p2 = baseParams(hop2.url("/jump"));
    p2["redirects"] = Val("no");
    p2["code"] = Val(302L);
    auto r2 = runProbeModule(p2, ctxLocal);
    assert(r2.msg == "302 Found", r2.msg);
    assert(canFind(r2.details[1], "redirects: no"), r2.details[1]);

    // { max = N }: followed under the cap
    Val[string] p3 = baseParams(hop3.url("/jump"));
    p3["redirects"] = tableOf("max", Val(5L));
    auto r3 = runProbeModule(p3, ctxLocal);
    assert(r3.msg == "200 OK", r3.msg);
    assert(canFind(r3.details[1], "redirects: max 5"), r3.details[1]);
}

@("redirects: an exhausted cap fails the job")
unittest
{
    auto target = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc");
    scope (exit) target.done();
    auto hop2 = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ target.url("/real") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop2.done();
    auto hop1 = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ hop2.url("/two") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop1.done();

    Val[string] p = baseParams(hop1.url("/one"));
    p["redirects"] = tableOf("max", Val(1L));
    try
    {
        runProbeModule(p, ctxLocal);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        assert(canFind(e.msg, "maxRedirects"), e.msg);
}

@("insecure: boolean only, plumbed as the tls flag")
unittest
{
    // over plain http the flag is a no-op; it must still travel
    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    scope (exit) srv.done();
    Val[string] p = baseParams(srv.url("/tls"));
    p["insecure"] = Val(true);
    auto r = runProbeModule(p, ctxLocal);
    assert(r.msg == "200 OK", r.msg);
    assert(canFind(r.details[1], "tls: insecure"), r.details[1]);

    void reject(Val v, string needle)
    {
        Val[string] bad = baseParams("http://localhost/");
        bad["insecure"] = v;
        try
        {
            validateModuleParams("probe", bad, "ctx");
            assert(false, "expected TachyError: " ~ needle);
        }
        catch (TachyError e)
            assert(canFind(e.msg, needle), e.msg ~ " (wanted '" ~ needle ~ "')");
    }
    reject(Val("yes"), "'insecure' must be a boolean");
    reject(Val(1L), "'insecure' must be a boolean");

    Val[string] ok = baseParams("http://localhost/");
    ok["insecure"] = Val(false);
    validateModuleParams("probe", ok, "ctx");
}

@("redirects: load-time validation of the attribute shapes")
unittest
{
    void reject(Val[string] p, string needle)
    {
        try
        {
            validateModuleParams("probe", p, "ctx");
            assert(false, "expected TachyError: " ~ needle);
        }
        catch (TachyError e)
            assert(canFind(e.msg, needle), e.msg ~ " (wanted '" ~ needle ~ "')");
    }

    Val[string] p = baseParams("http://localhost/");
    p["redirects"] = Val("later");
    reject(p, "'redirects' must be \"no\"");

    p["redirects"] = Val(5L);
    reject(p, "must be \"no\" or a { max = N } table");

    p["redirects"] = tableOf("max", Val("three"));
    reject(p, "'redirects.max' must be an integer");

    p["redirects"] = tableOf("max", Val(-1L));
    reject(p, "non-negative");

    p["redirects"] = tableOf("limit", Val(3L));
    reject(p, "accepts only { max = N }");

    p["redirects"] = tableOf("max", Val(0L));
    validateModuleParams("probe", p, "ctx"); // 0 is a legal cap (= "no")
    p["redirects"] = Val("no");
    validateModuleParams("probe", p, "ctx");
}

@("load-time validation: unknown keys, wrong types, ranges")
unittest
{
    void reject(Val[string] p, string needle)
    {
        try
        {
            validateModuleParams("probe", p, "ctx");
            assert(false, "expected TachyError: " ~ needle);
        }
        catch (TachyError e)
            assert(canFind(e.msg, needle), e.msg ~ " (wanted '" ~ needle ~ "')");
    }

    Val[string] p; // no url: it is injected from the statement key
    p["type"] = Val("GET");
    reject(p, "'url' is required");

    Val[string] unknown = baseParams("http://localhost/");
    unknown["verb"] = Val("GET");
    reject(unknown, "unknown key 'verb'");

    Val[string] badType = baseParams("http://localhost/");
    badType["type"] = Val(1L);
    reject(badType, "'type' must be a string");

    Val[string] badVerb = baseParams("http://localhost/");
    badVerb["type"] = Val("GET NOW");
    reject(badVerb, "must be an HTTP method");

    Val[string] badHeaders = baseParams("http://localhost/");
    badHeaders["headers"] = Val("X=1");
    reject(badHeaders, "'headers' must be an array");

    Val[string] badEntry = baseParams("http://localhost/");
    badEntry["headers"] = arrayOf("NoEquals");
    reject(badEntry, "must look like");

    Val[string] badData = baseParams("http://localhost/");
    badData["data"] = Val(1L);
    reject(badData, "'data' must be a string");

    Val[string] badCode = baseParams("http://localhost/");
    badCode["code"] = Val("200");
    reject(badCode, "'code' must be an integer");

    Val[string] outOfRange = baseParams("http://localhost/");
    outOfRange["code"] = Val(99L);
    reject(outOfRange, "between 100 and 599");

    Val[string] badTimeout = baseParams("http://localhost/");
    badTimeout["timeout"] = Val(0L);
    reject(badTimeout, "'timeout' must be positive");

    Val[string] badOutput = baseParams("http://localhost/");
    badOutput["output"] = tableOf("starts", Val("ok"));
    reject(badOutput, "'output' takes only 'equals', 'contains', 'matches', 'not', 'any', 'all' and 'none', not 'starts'");

    // templated values defer to run time: validation passes at load
    Val[string] templated = baseParams("http://localhost/");
    templated["type"] = Val("{{ verb }}");
    templated["headers"] = arrayOf("X-{{ name }}=1");
    validateModuleParams("probe", templated, "ctx");
}

@("run-time validation catches unrendered templates")
unittest
{
    Val[string] p = baseParams("http://localhost/");
    p["type"] = Val("{{ verb }}"); // what a failed render would look like
    try
    {
        runProbeModule(p, ctxLocal);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        assert(canFind(e.msg, "must be an HTTP method"), e.msg);
}
