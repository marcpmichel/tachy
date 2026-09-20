/// Tests for tachy.http — the requests-based HTTP client behind the
/// `probe` directive and `upgrade`, exercised against a one-shot
/// listener in-process (plain http; TLS itself is covered by the
/// real-network upgrade run).
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
    private shared uint nconn_;
    private shared uint served_;
    package string received;

    this(string response, bool silent = false, uint nconn = 1)
    {
        response_ = response;
        silent_ = silent;
        nconn_ = nconn;
        listener = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(cast(int) nconn);
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

    /// Wait (bounded) for every expected connection to have been
    /// served, so a failing test cannot hang the runner on a
    /// never-made connection.
    void done()
    {
        import core.time : MonoTime, msecs, seconds;
        const end = MonoTime.currTime + 10.seconds;
        while (served_ < nconn_ && MonoTime.currTime < end)
            Thread.sleep(10.msecs);
    }

    private void serve()
    {
        scope (exit) listener.close();
        foreach (immutable i; 0 .. nconn_)
            serveOne();
    }

    private void serveOne()
    {
        auto sock = listener.accept();
        scope (exit)
        {
            sock.close();
            import core.atomic : atomicFetchAdd;
            atomicFetchAdd(served_, 1u);
        }
        string req;
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

@("GET: status, reason, body, path and custom header travel")
unittest
{
    import core.time : seconds;
    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
    scope (exit) srv.done();

    auto resp = httpQuery("GET", srv.url("/x?y=1"), ["X-Token=abc"], null,
        5.seconds, "ctx");
    assert(resp.status == 200 && resp.reason == "OK", text(resp.status));
    assert(resp.body == "hello", resp.body);

    assert(srv.received.startsWith("GET /x?y=1 HTTP/1.1\r\n"), srv.received);
    assert(canFind(srv.received, "X-Token: abc\r\n"), srv.received);
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
    assert(srv.received.endsWith("{\"x\":1}"), srv.received);
}

@("POST: no Content-Type appears unless the caller sends one")
unittest
{
    import core.time : seconds;
    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    scope (exit) srv.done();

    httpQuery("POST", srv.url("/silent"), [], "{}", 5.seconds, "ctx");
    assert(!canFind(srv.received, "Content-Type"), srv.received);
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
    assert(resp.status == 200 && resp.body.length == 0);
}

@("httpQuery follows redirects by default; max 0 sees the raw answer")
unittest
{
    import core.time : seconds;
    auto target = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc");
    scope (exit) target.done();
    auto hop = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ target.url("/real") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop.done();
    auto hop2 = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ target.url("/real") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop2.done();

    auto raw = httpQuery("GET", hop2.url("/jump"), [], null, 5.seconds,
        "ctx", 0);
    assert(raw.status == 302 && raw.reason == "Found", text(raw.status));

    auto resp = httpQuery("GET", hop.url("/jump"), [], null, 5.seconds, "ctx");
    assert(resp.status == 200 && resp.reason == "OK" && resp.body == "abc",
        text(resp.status) ~ " '" ~ resp.body ~ "'");
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

    msg = failMsg({
        httpQuery("GET", "http://no-such-host.invalid/", [], null, 5.seconds, "ctx");
    });
    assert(msg !is null && canFind(msg, "no-such-host.invalid"), msg);

    auto garbage = new OneShotServer("this is not http\r\n\r\n");
    scope (exit) garbage.done();
    msg = failMsg({
        httpQuery("GET", garbage.url("/"), [], null, 5.seconds, "ctx");
    });
    assert(msg !is null && canFind(msg, "ctx"), msg);

    msg = failMsg({ httpQuery("GET", "ftp://example.com/", [], null, 5.seconds, "ctx"); });
    assert(canFind(msg, "is not an http(s) URL"), msg);
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

// ---------------------------------------------------------------------------
// httpDownload — the upgrade command's download, exercised over plain
// http; the TLS leg is covered by the real-network upgrade run.
// ---------------------------------------------------------------------------

string downloadScratchDir()
{
    import core.atomic : atomicFetchAdd;
    import std.conv : text;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    static shared int seq;
    auto dir = buildPath(tempDir, "tachy_httpdl_ut"
        ~ text(atomicFetchAdd(seq, 1)));
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

@("httpDownload: the body lands in the file, custom headers travel")
unittest
{
    import core.time : seconds;
    import std.file : read, rmdirRecurse;
    import std.path : buildPath;
    auto srv = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
    scope (exit) srv.done();
    auto dir = downloadScratchDir();
    scope (exit) rmdirRecurse(dir);
    const path = buildPath(dir, "out.bin");

    httpDownload(srv.url("/f"), path, ["X-Token=abc"], 5.seconds, "ctx");
    assert(cast(string) read(path) == "hello");
    assert(canFind(srv.received, "X-Token: abc\r\n"), srv.received);
    assert(srv.received.startsWith("GET /f HTTP/1.1\r\n"), srv.received);
}

@("httpDownload: redirects are followed to the final body")
unittest
{
    import core.time : seconds;
    import std.file : read, rmdirRecurse;
    import std.path : buildPath;
    auto target = new OneShotServer("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc");
    scope (exit) target.done();
    auto hop = new OneShotServer("HTTP/1.1 302 Found\r\nLocation: "
        ~ target.url("/real") ~ "\r\nContent-Length: 0\r\n\r\n");
    scope (exit) hop.done();

    auto dir = downloadScratchDir();
    scope (exit) rmdirRecurse(dir);
    const path = buildPath(dir, "out.bin");

    httpDownload(hop.url("/jump"), path, [], 5.seconds, "ctx");
    assert(cast(string) read(path) == "abc");
}

@("httpDownload: non-200 fails and writes nothing")
unittest
{
    import core.time : seconds;
    import std.file : exists, rmdirRecurse;
    import std.path : buildPath;
    auto srv = new OneShotServer("HTTP/1.1 404 Not Found\r\nContent-Length: 4\r\n\r\nnope");
    scope (exit) srv.done();
    auto dir = downloadScratchDir();
    scope (exit) rmdirRecurse(dir);
    const path = buildPath(dir, "out.bin");

    const msg = failMsg({
        httpDownload(srv.url("/missing"), path, [], 5.seconds, "ctx");
    });
    assert(canFind(msg, "status 404"), msg);
    assert(!exists(path), "a failed download must not leave a file");
}

@("httpDownload: oversized bodies are rejected")
unittest
{
    import core.time : seconds;
    import std.file : exists, rmdirRecurse;
    import std.path : buildPath;
    auto srv = new OneShotServer(
        "HTTP/1.1 200 OK\r\nContent-Length: 99999999999\r\n\r\n");
    scope (exit) srv.done();
    auto dir = downloadScratchDir();
    scope (exit) rmdirRecurse(dir);
    const path = buildPath(dir, "out.bin");

    const msg = failMsg({
        httpDownload(srv.url("/big"), path, [], 5.seconds, "ctx");
    });
    assert(canFind(msg, "maxContentLength"), msg);
    assert(!exists(path), "a failed download must not leave a file");
}

@("httpDownload: a stalled server times out as TachyError")
unittest
{
    import core.time : seconds;
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    auto silent = new OneShotServer("", true);
    auto dir = downloadScratchDir();
    scope (exit) rmdirRecurse(dir);
    const path = buildPath(dir, "out.bin");

    const msg = failMsg({
        httpDownload(silent.url("/slow"), path, [], 1.seconds, "ctx");
    });
    assert(canFind(msg, "timed out"), msg);
    silent.done(); // returns once the client gave up and closed
}

@("httpDownload: header entries are validated before the request")
unittest
{
    import core.time : seconds;
    const msg = failMsg({
        httpDownload("http://127.0.0.1:1/x", "/tmp/never", ["Bad Name=v"],
            5.seconds, "ctx");
    });
    assert(canFind(msg, "not a valid header name"), msg);
}
