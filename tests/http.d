/// Tests for tachy.http — the std.socket HTTP/1.1 client behind the
/// `http` directive, exercised against a one-shot listener in-process.
module tachy.tests.http;

import tachy.errors : TachyError;
import tachy.http;

import core.thread : Thread;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.conv : text;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketShutdown, SocketType;

/// One-shot test server: listens on 127.0.0.1 at a random port, accepts
/// a single connection, records the raw request bytes, then answers with
/// `response` and closes (EOF-delimiting unframed bodies).  `silent`
/// records the request and keeps the connection open without answering
/// (timeout tests) until the client hangs up.
final class OneShotServer
{
    private Socket listener;
    private Thread worker;
    private string response_;
    private bool silent_;
    private string urlBase_;
    private ushort port_;
    private shared bool served_;
    package string received;

    this(string response, bool silent = false)
    {
        response_ = response;
        silent_ = silent;
        listener = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(1);
        // Capture the port while the listener is certainly alive: the
        // worker thread closes it once its one connection is served.
        port_ = (cast(InternetAddress) listener.localAddress).port;
        urlBase_ = "http://127.0.0.1:" ~ text(port_);
        worker = new Thread(&serve);
        worker.isDaemon = true;
        worker.start();
    }

    /// A URL for this server (the random port captured at bind, any path).
    string url(string path) const
    {
        return urlBase_ ~ path;
    }

    ushort port() const
    {
        return port_;
    }

    /// Wait (bounded) for the connection to have been served, so a
    /// failing test cannot hang the runner on a never-made connection.
    void done()
    {
        import core.time : MonoTime, msecs, seconds;
        const end = MonoTime.currTime + 10.seconds;
        while (!served_ && MonoTime.currTime < end)
            Thread.sleep(10.msecs);
    }

    private void serve()
    {
        auto sock = listener.accept();
        scope (exit)
        {
            sock.close();
            listener.close();
        }
        string req;
        scope (exit) served_ = true;
        while (!requestComplete(req))
        {
            auto buf = new ubyte[4096];
            const ptrdiff_t n = sock.receive(buf);
            if (n <= 0)
                break;
            req ~= cast(string) buf[0 .. n];
        }
        received = req;
        if (silent_)
        {
            // Hold the connection open until the client gives up.
            auto sink = new ubyte[16];
            while (sock.receive(sink) > 0) {}
            return;
        }
        sock.send(cast(const(ubyte)[]) response_);
        sock.shutdown(SocketShutdown.SEND);
    }

    /// A request is complete once its head ended and the Content-Length
    /// body (if any) fully arrived.
    private static bool requestComplete(in string req) @safe pure
    {
        import std.string : indexOf, toLower;
        const size_t end = req.indexOf("\r\n\r\n");
        if (end == cast(size_t) -1)
            return false;
        const string head = req[0 .. end];
        foreach (line; head.splitHeadLines())
        {
            const size_t colon = line.indexOf(':');
            if (colon == cast(size_t) -1)
                continue;
            if (toLower(line[0 .. colon]) != "content-length")
                continue;
            import std.conv : to;
            import std.string : strip;
            const size_t want = line[colon + 1 .. $].strip.to!size_t;
            return req.length - end - 4 >= want;
        }
        return true;
    }
}

private string[] splitHeadLines(in string head) @safe pure
{
    import std.string : splitLines;
    return head.splitLines();
}

private string failMsg(void delegate() dg)
{
    try
    {
        dg();
        return null;
    }
    catch (TachyError e)
        return e.msg;
}

@("GET: request shape, status line, Content-Length body")
unittest
{
    import core.time : seconds;
    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
    scope (exit) srv.done();

    auto resp = httpQuery("GET", srv.url("/x?y=1"), [], null, 5.seconds, "ctx");
    assert(resp.status == 200 && resp.reason == "OK", text(resp.status));
    assert(resp.body == "hello", resp.body);

    assert(srv.received.startsWith("GET /x?y=1 HTTP/1.1\r\n"), srv.received);
    import std.string : indexOf;
    const ushort port = srv.port;
    assert(canFind(srv.received, "Host: 127.0.0.1:" ~ text(port) ~ "\r\n"), srv.received);
    assert(canFind(srv.received, "Connection: close\r\n"), srv.received);
    assert(!canFind(srv.received, "Content-Length"), srv.received); // no body sent
}

@("POST: data and headers travel verbatim")
unittest
{
    import core.time : seconds;
    auto srv = new OneShotServer("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok");
    scope (exit) srv.done();

    auto resp = httpQuery("POST", srv.url("/api"),
        ["Content-Type=application/json", "X-Custom=a b"],
        "{\"x\":1}", 5.seconds, "ctx");
    assert(resp.status == 201 && resp.reason == "Created");
    assert(resp.body == "ok");

    assert(srv.received.startsWith("POST /api HTTP/1.1\r\n"), srv.received);
    assert(canFind(srv.received, "Content-Type: application/json\r\n"), srv.received);
    assert(canFind(srv.received, "X-Custom: a b\r\n"), srv.received);
    assert(canFind(srv.received, "Content-Length: 7\r\n"), srv.received);
    assert(srv.received.endsWith("{\"x\":1}"), srv.received);
}

@("chunked and close-delimited bodies")
unittest
{
    import core.time : seconds;

    auto srv = new OneShotServer(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        ~ "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    scope (exit) srv.done();
    auto resp = httpQuery("GET", srv.url("/chunked"), [], null, 5.seconds, "ctx");
    assert(resp.status == 200 && resp.body == "hello world", resp.body);

    // No framing at all: the body is everything until the server closes.
    auto srv2 = new OneShotServer("HTTP/1.1 200\r\n\r\nraw tail");
    scope (exit) srv2.done();
    auto resp2 = httpQuery("GET", srv2.url("/"), [], null, 5.seconds, "ctx");
    assert(resp2.status == 200 && resp2.reason == "" && resp2.body == "raw tail",
        text(resp2.status) ~ " '" ~ resp2.body ~ "'");
}

@("HEAD answers carry no body, whatever Content-Length claims")
unittest
{
    import core.time : seconds;
    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n");
    scope (exit) srv.done();
    auto resp = httpQuery("HEAD", srv.url("/h"), [], null, 5.seconds, "ctx");
    assert(resp.status == 200 && resp.body is null);
}

@("timeouts and transport errors surface as TachyError")
unittest
{
    import core.time : seconds;

    // A server that never answers: the deadline fires.
    auto silent = new OneShotServer("", true);
    auto msg = failMsg({
        httpQuery("GET", silent.url("/slow"), [], null, 1.seconds, "ctx");
    });
    assert(canFind(msg, "timed out after 1s"), msg);
    silent.done(); // returns once the client gave up and closed

    msg = failMsg({ httpQuery("GET", "https://example.com/", [], null, 1.seconds, "ctx"); });
    assert(canFind(msg, "https is not supported"), msg);

    msg = failMsg({ httpQuery("GET", "ftp://example.com/", [], null, 1.seconds, "ctx"); });
    assert(canFind(msg, "is not an http URL"), msg);

    msg = failMsg({
        httpQuery("GET", "http://no-such-host.invalid/", [], null, 5.seconds, "ctx");
    });
    assert(canFind(msg, "cannot resolve"), msg);

    auto garbage = new OneShotServer("this is not http\r\n\r\n");
    scope (exit) garbage.done();
    msg = failMsg({
        httpQuery("GET", garbage.url("/"), [], null, 5.seconds, "ctx");
    });
    assert(canFind(msg, "malformed response"), msg);
}

@("URL parsing: ports, IPv6 brackets, paths, fragments")
unittest
{
    auto t = parseHttpTarget("http://example.com", "ctx");
    assert(t.host == "example.com" && t.port == 80 && t.target == "/");

    t = parseHttpTarget("http://example.com:8080", "ctx");
    assert(t.port == 8080 && t.target == "/");

    t = parseHttpTarget("http://example.com/a/b?x=1#frag", "ctx");
    assert(t.port == 80 && t.target == "/a/b?x=1", t.target);

    t = parseHttpTarget("http://example.com?x=1", "ctx");
    assert(t.target == "/?x=1", t.target);

    t = parseHttpTarget("http://[::1]:9000/h", "ctx");
    assert(t.host == "::1" && t.port == 9000 && t.target == "/h");

    auto msg = failMsg({ parseHttpTarget("http://host:notaport/", "ctx"); });
    assert(canFind(msg, "invalid port"), msg);

    msg = failMsg({ parseHttpTarget("http://host:0/", "ctx"); });
    assert(canFind(msg, "invalid port \"0\""), msg);

    msg = failMsg({ parseHttpTarget("http://[::1/h", "ctx"); });
    assert(canFind(msg, "unterminated IPv6"), msg);

    msg = failMsg({ parseHttpTarget("http:///path", "ctx"); });
    assert(canFind(msg, "empty host"), msg);
}

@("request validation: methods and header entries")
unittest
{
    validateMethod("GET", "ctx");
    validateMethod("PROPFIND", "ctx");
    auto msg = failMsg({ validateMethod("GET NOW", "ctx"); });
    assert(canFind(msg, "must be an HTTP method"), msg);
    msg = failMsg({ validateMethod("", "ctx"); });
    assert(canFind(msg, "must be an HTTP method"), msg);

    validateHeader("Content-Type=application/json", "ctx");
    validateHeader("X-Empty=", "ctx");
    msg = failMsg({ validateHeader("NoEqualsSign", "ctx"); });
    assert(canFind(msg, "must look like"), msg);
    msg = failMsg({ validateHeader("=value", "ctx"); });
    assert(canFind(msg, "must look like"), msg);
    msg = failMsg({ validateHeader("Bad Name=v", "ctx"); });
    assert(canFind(msg, "not a valid header name"), msg);
    msg = failMsg({ validateHeader("X-A=v\r\nX-B: w", "ctx"); });
    assert(canFind(msg, "control characters"), msg);
}
