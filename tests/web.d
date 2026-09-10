/// Tests for tachy.web, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.web;

import tachy.web;

import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import tachy.errors : TachyError;
import std.format;
import core.thread : Thread;

unittest // parseHead: request line, headers, query
{
    auto req = parseHead("GET /api/events/r3?since=9 HTTP/1.1\r\n"
        ~ "Host: localhost\r\n"
        ~ "Last-Event-ID: 42\r\n"
        ~ "\r\n");
    assert(req.method == "GET");
    assert(req.path == "/api/events/r3");
    assert(req.query == "since=9");
    assert(req.headers["host"] == "localhost");
    assert(req.headers["last-event-id"] == "42");

    foreach (bad; ["", "GET\r\n\r\n", "GET no-slash HTTP/1.1\r\n\r\n",
        "GET / FTP\r\n\r\n", "GET / HTTP/1.1\r\nBadHeader\r\n\r\n"])
        assertThrown!TachyError(parseHead(bad), bad);
}

unittest // splitPath + router: literals, params, 404, 405
{
    assert(splitPath("/") == []);
    assert(splitPath("/api/events/r1") == ["api", "events", "r1"]);

    auto router = new Router;
    router.add("GET", "/a/b", (req, p) => jsonBody("literal"));
    router.add("GET", "/a/:x/c", (req, p) => jsonBody("param " ~ p["x"]));

    auto mk(in string method, in string path)
    {
        Request r = new Request;
        r.method = method;
        r.path = path;
        return r;
    }
    assert(router.dispatch(mk("GET", "/a/b")).body == "literal");
    assert(router.dispatch(mk("GET", "/a/zz/c")).body == "param zz");
    assert(router.dispatch(mk("GET", "/nope")).status == 404);
    assert(router.dispatch(mk("POST", "/a/b")).status == 405);
    // a deeper path does not match a shorter pattern
    assert(router.dispatch(mk("GET", "/a/b/x")).status == 404);
}

unittest // parseStringObject: happy paths and every error
{
    auto f = parseStringObject(`{"project":"/p","selection":"all","mode":"check"}`);
    assert(f["project"] == "/p" && f["selection"] == "all" && f["mode"] == "check");

    assert(parseStringObject("{}").length == 0);
    assert(parseStringObject("  {  \"a\" : \"b\" }  ")["a"] == "b");

    // escapes, incl. \uXXXX and round-tripping with jsonEscStr
    auto g = parseStringObject(`{"a":"line\n\t\"q\" \\ ok é"}`);
    assert(g["a"] == "line\n\t\"q\" \\ ok é");
    assert(parseStringObject(`{"a":"\u0041bc"}`)["a"] == "Abc");
    assert(parseStringObject(`{"a":` ~ jsonEscStr("x\ty\"z") ~ `}`)["a"] == "x\ty\"z");

    foreach (bad; [``, `[]`, `{`, `{"a"`, `{"a":}`, `{"a":1}`, `{"a":"b",}`,
        `{"a":"b"} trailing`, `{"a":"b","a":"c"}`, `{"a":"unterminated}`])
        assertThrown!TachyError(parseStringObject(bad), bad);
}

unittest // Run: folding, wire records, finish is the last record
{
    import tachy.events : evFileStart, evJob;

    auto run = new Run("r1", "/p", "all", "apply");
    run.appendEvent(evFileStart("main.toml", ["h1"]));
    run.appendEvent(evJob("h1", "main.toml", "file /tmp/x", "changed", "created"));
    run.appendEvent(evJob("h1", "main.toml", "e", "ok", "m"));
    run.appendEvent(evJob("h1", "main.toml", "e2", "failed", "m"));
    run.appendLog("some stderr line");
    run.finish(1);

    synchronized (run.m)
    {
        assert(run.records.length == 6);
        assert(canFind(run.records[$ - 1], `"done":true,"exit":1`));
        assert(run.ok == 1 && run.changed == 1 && run.failed == 1);
        assert(run.done);
        foreach (rec; run.records[0 .. 4])
            assert(canFind(rec, `"ts":`));
        assert(canFind(run.records[0], `"ev":{"t":"fileStart"`));
        assert(canFind(run.records[4], `"log":"some stderr line"`));
    }

    assert(canFind(runJson(run), `"status":"finished"`));
    assert(canFind(runJson(run), `"project":"/p"`));
    assert(canFind(runJson(run), `"failed":1`));
}

unittest // sseFrame shape
{
    assert(sseFrame(7, `{"a":1}`) == "id: 7\ndata: {\"a\":1}\n\n");
}

unittest // loopback: end-to-end request/response over a real socket
{
    import std.socket : InternetAddress, TcpSocket;

    auto router = new Router;
    router.add("GET", "/x", (req, p) => jsonBody("{\"ok\":true}"));
    router.add("POST", "/echo", (req, p) => jsonBody(req.body));
    router.add("GET", "/sse", (req, p)
    {
        auto r = new Response;
        r.contentType = "text/event-stream";
        r.stream = (ChunkSink send)
        {
            send(sseFrame(0, `{"a":1}`));
            send(sseFrame(1, `{"b":2}`));
        };
        return r;
    });

    auto listener = bindListener("127.0.0.1", 0);
    const ushort port = (cast(InternetAddress) listener.localAddress()).port;
    auto server = new Thread({ serveForever(listener, router); });
    server.isDaemon = true;
    server.start();

    string roundtrip(in char[] raw)
    {
        auto c = new TcpSocket;
        c.connect(new InternetAddress("127.0.0.1", port));
        sendAll(c, raw);
        string got;
        char[1024] buf;
        for (;;)
        {
            const ptrdiff_t n = c.receive(buf);
            if (n <= 0)
                break;
            got ~= buf[0 .. n];
        }
        c.close();
        return got;
    }

    // GET with headers: body arrives whole, connection closes
    auto got = roundtrip("GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(canFind(got, "200 OK"), got);
    assert(canFind(got, "application/json"), got);
    assert(canFind(got, "{\"ok\":true}"), got);
    assert(canFind(got, "Connection: close"), got);
    assert(canFind(got, "Content-Length:"), got);

    // POST body per Content-Length reaches the handler untouched
    const string body = `{"hello":"world"}`;
    got = roundtrip(format!"POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: %d\r\n\r\n%s"(
        body.length, body));
    assert(canFind(got, body), got);

    // SSE: frames stream, then the connection closes
    got = roundtrip("GET /sse HTTP/1.1\r\nHost: t\r\n\r\n");
    assert(canFind(got, "text/event-stream"), got);
    assert(canFind(got, "id: 0\ndata: {\"a\":1}\n\n"), got);
    assert(canFind(got, "id: 1\ndata: {\"b\":2}\n\n"), got);

    // 404 and a malformed head
    assert(canFind(roundtrip("GET /nope HTTP/1.1\r\n\r\n"), "404"));
    assert(canFind(roundtrip("garbage\r\n\r\n"), "400"));
}
