module tachy.http;

/**
 * A minimal HTTP/1.1 client on plain TCP sockets — the query tool behind
 * the `http` directive, written directly on std.socket (no libcurl, no
 * external processes): one socket write for the request, one
 * deadline-bounded read for the answer.
 *
 * Deliberately small: plain `http://` only (no TLS), no redirects, no
 * keep-alive (every request carries `Connection: close`), bodies framed
 * by Content-Length, the chunked coding or server close.  One `timeout`
 * bounds the whole query — connect, send and receive share a deadline
 * enforced with select(2) — and a response larger than `maxBodyBytes`
 * is an error, not a memory grab.
 */
import core.time : Duration, MonoTime;
import std.algorithm.searching : canFind, startsWith;
import std.array : Appender, appender;
import std.conv : ConvException, text, to;
import std.socket : Address, Socket, SocketSet, SocketType, ProtocolType,
    SocketOption, SocketOptionLevel, formatSocketError, getAddress;
import std.string : icmp, indexOf, splitLines, stripLeft, stripRight, toLower;

import tachy.errors;

/// Response bodies above this size are rejected (health payloads, not mirrors).
enum size_t maxBodyBytes = 16 * 1024 * 1024;

struct HttpTarget
{
    string host;    // as spelled (IPv6 literals without brackets)
    string target;  // request target: path ["?" query], "/" when the URL has none
    ushort port;
}

struct HttpResponse
{
    int status;
    string reason;
    string body;
}

// ---------------------------------------------------------------------------
// URLs and request validation (the run-time authority; the `http` module
// pre-checks literal values at load time for early typo detection).
// ---------------------------------------------------------------------------

/// Parse an `http://host[:port][/path][?query][#fragment]` URL.  `https`
/// is rejected naming the plain-http limitation; the fragment is dropped
/// (it never travels to a server).
HttpTarget parseHttpTarget(string url, string context)
{
    if (url.length >= 8 && !icmp(url[0 .. 8], "https://"))
        throw new TachyError(context ~ ": '" ~ url
            ~ "': https is not supported (plain http only)");
    if (url.length < 7 || icmp(url[0 .. 7], "http://"))
        throw new TachyError(context ~ ": '" ~ url
            ~ "' is not an http URL (expected http://host[:port]/path)");

    string rest = url[7 .. $];
    size_t authorityEnd = rest.length;
    foreach (immutable i, immutable char c; rest)
        if (c == '/' || c == '?' || c == '#')
        {
            authorityEnd = i;
            break;
        }
    const string authority = rest[0 .. authorityEnd];
    rest = rest[authorityEnd .. $];

    // [host][:port], IPv6 literals in brackets
    string host, portStr;
    if (authority.startsWith("["))
    {
        const size_t close = authority.indexOf(']');
        if (close == cast(size_t) -1)
            throw new TachyError(context ~ ": '" ~ url ~ "': unterminated IPv6 address");
        host = authority[1 .. close];
        if (authority.length > close + 1)
        {
            if (authority[close + 1] != ':')
                throw new TachyError(context ~ ": '" ~ url
                    ~ "': garbage after the IPv6 address");
            portStr = authority[close + 2 .. $];
        }
    }
    else
    {
        const size_t colon = authority.indexOf(':');
        host = colon == cast(size_t) -1
            ? authority : authority[0 .. colon];
        portStr = colon == cast(size_t) -1
            ? null : authority[colon + 1 .. $];
    }
    if (!host.length)
        throw new TachyError(context ~ ": '" ~ url ~ "': empty host");

    ushort port = 80;
    if (portStr !is null)
    {
        if (!portStr.length)
            throw new TachyError(context ~ ": '" ~ url ~ "': empty port");
        try port = portStr.to!ushort;
        catch (ConvException)
            throw new TachyError(context ~ ": '" ~ url ~ ": invalid port \""
                ~ portStr ~ "\"");
        if (port == 0)
            throw new TachyError(context ~ ": '" ~ url ~ ": invalid port \"0\"");
    }

    // Drop the fragment; an empty or query-only path is "/".
    const size_t hash = rest.indexOf('#');
    if (hash != cast(size_t) -1)
        rest = rest[0 .. hash];
    if (!rest.length || rest[0] == '?')
        rest = "/" ~ rest;

    HttpTarget t;
    t.host = host;
    t.port = port;
    t.target = rest;
    return t;
}

/// RFC 7230 token characters (methods and header names are tokens).
private bool isTokenChar(char c) @safe pure nothrow
{
    if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
        return true;
    foreach (immutable good; "!#$%&'*+-.^_`|~")
        if (c == good)
            return true;
    return false;
}

/// A method is a non-empty token ("GET", "POST", ...).  Throws on
/// anything else, so an accidental typo cannot smuggle request framing.
void validateMethod(string method, string context)
{
    if (method.length)
    {
        bool ok = true;
        foreach (immutable char c; method)
            if (!isTokenChar(c))
            {
                ok = false;
                break;
            }
        if (ok)
            return;
    }
    throw new TachyError(context ~ ": 'type' must be an HTTP method token like"
        ~ " \"GET\" or \"POST\", not \"" ~ method ~ "\"");
}

/// A header entry is "Name=Value" with a token name and a value free of
/// control characters (no request smuggling through parameters).
void validateHeader(string header, string context)
{
    const size_t eq = header.indexOf('=');
    if (eq == 0 || eq == cast(size_t) -1)
        throw new TachyError(context ~ ": 'headers' entries must look like"
            ~ " \"Name=Value\", not \"" ~ header ~ "\"");
    foreach (immutable char c; header[0 .. eq])
        if (!isTokenChar(c))
            throw new TachyError(context ~ ": header name \"" ~ header[0 .. eq]
                ~ "\" is not a valid header name (in \"" ~ header ~ "\")");
    foreach (immutable char c; header[eq + 1 .. $])
        if (c < ' ' || c == 0x7F)
            throw new TachyError(context ~ ": header value in \"" ~ header
                ~ "\" must not contain control characters");
}

// ---------------------------------------------------------------------------
// The query itself.
// ---------------------------------------------------------------------------

/// Submit one request and read the whole answer.  `data` may be `null`
/// (no body, no Content-Length) or any string including the empty string
/// (a zero-length body, sent with `Content-Length: 0`).
HttpResponse httpQuery(string method, string url, in string[] headers,
    string data, Duration timeout, string context)
{
    validateMethod(method, context);
    foreach (immutable h; headers)
        validateHeader(h, context);
    auto t = parseHttpTarget(url, context);

    Address[] addrs;
    try addrs = getAddress(t.host, t.port);
    catch (Exception e)
        throw new TachyError(context ~ ": cannot resolve '" ~ t.host ~ "': " ~ e.msg);

    const MonoTime deadline = MonoTime.currTime + timeout;
    auto sock = dial(addrs, deadline, timeout, context);
    scope (exit) sock.close();

    const string request = buildRequest(method, t, headers, data);
    sendAll(sock, cast(const(ubyte)[]) request, deadline, timeout, context);
    return readResponse(sock, method, deadline, timeout, context);
}

/// Connect to the first address that answers within the deadline
/// (non-blocking connect + select, then the pending socket error).
private Socket dial(Address[] addrs, MonoTime deadline, Duration timeout,
    string context) @trusted
{
    string lastErr = "no address to connect to";
    foreach (addr; addrs)
    {
        auto sock = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.TCP);
        sock.blocking = false;
        try sock.connect(addr);
        catch (Exception e)
        {
            sock.close();
            lastErr = e.msg;
            continue;
        }
        for (;;)
        {
            auto wset = new SocketSet;
            wset.add(sock);
            const int n = Socket.select(null, wset, null, remaining(deadline, timeout, context));
            if (n > 0)
            {
                if (auto err = pendingError(sock))
                {
                    sock.close();
                    lastErr = err;
                    break; // next address
                }
                return sock;
            }
            if (n < 0)
                continue; // interrupted: select again
            throw timedOut(timeout, context);
        }
    }
    throw new TachyError(context ~ ": cannot connect: " ~ lastErr);
}

/// Send everything, waiting while the socket would block.
private void sendAll(Socket sock, const(ubyte)[] data, MonoTime deadline,
    Duration timeout, string context) @trusted
{
    size_t off;
    while (off < data.length)
    {
        const ptrdiff_t n = sock.send(data[off .. $]);
        if (n > 0)
        {
            off += cast(size_t) n;
            continue;
        }
        waitReady(sock, true, deadline, timeout, context);
    }
}

/// Read one buffer's worth; 0 means the peer closed its end.
private size_t recvSome(Socket sock, ubyte[] dst, MonoTime deadline,
    Duration timeout, string context) @trusted
{
    for (;;)
    {
        const ptrdiff_t n = sock.receive(dst);
        if (n >= 0)
            return cast(size_t) n;
        waitReady(sock, false, deadline, timeout, context);
    }
}

/// Block until the socket is readable (or writable, for `forWrite`),
/// bounding the wait by the shared deadline.  A pending socket error —
/// refused connection, reset, and the like — surfaces here.
private void waitReady(Socket sock, bool forWrite, MonoTime deadline,
    Duration timeout, string context) @trusted
{
    for (;;)
    {
        auto set = new SocketSet;
        set.add(sock);
        const Duration left = remaining(deadline, timeout, context);
        const int n = forWrite
            ? Socket.select(null, set, null, left)
            : Socket.select(set, null, null, left);
        if (n > 0)
        {
            if (auto err = pendingError(sock))
                throw new TachyError(context ~ ": " ~ err);
            return;
        }
        if (n < 0)
            continue; // interrupted: select again
        throw timedOut(timeout, context);
    }
}

private Duration remaining(MonoTime deadline, Duration timeout, string context)
{
    const Duration left = deadline - MonoTime.currTime;
    if (left <= Duration.zero)
        throw timedOut(timeout, context);
    return left;
}

private TachyError timedOut(Duration timeout, string context)
{
    immutable secs = timeout.total!"seconds";
    return new TachyError(context ~ ": timed out after "
        ~ (secs ? text(secs) ~ "s" : text(timeout)));
}

/// The socket's pending error as text, read and cleared once (null when
/// the socket is clean — a plain would-block never reaches the caller).
private string pendingError(Socket sock) @trusted
{
    int err;
    sock.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, err);
    // SO_ERROR is read-and-clear: format this value, do not fetch again.
    return err ? formatSocketError(err) : null;
}

private string buildRequest(string method, in HttpTarget t,
    in string[] headers, string data) @safe pure
{
    string hostHeader = canFind(t.host, ':') ? "[" ~ t.host ~ "]" : t.host;
    if (t.port != 80)
        hostHeader ~= ":" ~ text(t.port);

    auto out_ = appender!(char[]);
    out_.put(method);
    out_.put(' ');
    out_.put(t.target);
    out_.put(" HTTP/1.1\r\nHost: ");
    out_.put(hostHeader);
    out_.put("\r\nUser-Agent: tachy\r\n");
    foreach (immutable h; headers)
    {
        const size_t eq = h.indexOf('=');
        out_.put(h[0 .. eq]);
        out_.put(": ");
        out_.put(h[eq + 1 .. $]);
        out_.put("\r\n");
    }
    if (data !is null)
    {
        out_.put("Content-Length: ");
        out_.put(text(data.length));
        out_.put("\r\n");
    }
    out_.put("Connection: close\r\n\r\n");
    if (data !is null && data.length)
        out_.put(data);
    return out_.data.idup;
}

// ---------------------------------------------------------------------------
// Response reading: head first, then the body by its framing.
// ---------------------------------------------------------------------------

private HttpResponse readResponse(Socket sock, string method,
    MonoTime deadline, Duration timeout, string context) @trusted
{
    const bool noBody = method == "HEAD";
    auto buf = appender!(ubyte[])();
    size_t headEnd; // offset just past the blank line, once found
    while (true)
    {
        headEnd = findHeadEnd(buf.data);
        if (headEnd != size_t.max)
            break;
        recvMore(sock, buf, deadline, timeout, context,
            "connection closed before the response head");
    }

    const string head = cast(string) buf.data[0 .. headEnd - 4]; // without the blank line
    auto parsed = parseHead(head, context);
    const(ubyte)[] rest = buf.data[headEnd .. $];

    string body;
    if (noBody)
    {
        // Nothing follows a HEAD answer whatever the headers claim.
    }
    else if (parsed.chunked)
    {
        auto pending = rest;
        while (!decodeChunked(pending, body, context))
            pending ~= recvMore(sock, buf, deadline, timeout, context,
                "connection closed inside the response body");
    }
    else if (parsed.contentLength != size_t.max)
    {
        while (rest.length < parsed.contentLength)
            rest ~= recvMore(sock, buf, deadline, timeout, context,
                "connection closed inside the response body");
        body = cast(string) rest[0 .. parsed.contentLength];
    }
    else
    {
        for (;;)
        {
            auto chunk = new ubyte[65536];
            if (recvSome(sock, chunk, deadline, timeout, context) == 0)
                break;
            buf.put(chunk);
            enforceBodyCap(buf.data.length, context);
        }
        body = cast(string) buf.data[headEnd .. $];
    }

    HttpResponse r;
    r.status = parsed.status;
    r.reason = parsed.reason;
    r.body = body;
    return r;
}

/// Read more bytes into `buf` (and return them); `closedMsg` names the
/// failure when the peer hangs up instead.
private const(ubyte)[] recvMore(Socket sock, ref Appender!(ubyte[]) buf,
    MonoTime deadline, Duration timeout, string context, string closedMsg) @trusted
{
    auto chunk = new ubyte[65536];
    const size_t n = recvSome(sock, chunk, deadline, timeout, context);
    if (n == 0)
        throw new TachyError(context ~ ": " ~ closedMsg);
    buf.put(chunk[0 .. n]);
    enforceBodyCap(buf.data.length, context);
    return chunk[0 .. n];
}

private void enforceBodyCap(size_t total, string context) @safe pure
{
    if (total > maxBodyBytes)
        throw new TachyError(context ~ ": response larger than "
            ~ text(maxBodyBytes) ~ " bytes");
}

/// Offset just past the first CRLFCRLF, or size_t.max when the head is
/// still incomplete.
private size_t findHeadEnd(in ubyte[] data) @safe pure nothrow
{
    for (size_t i = 0; i + 3 < data.length; i++)
        if (data[i] == '\r' && data[i + 1] == '\n'
            && data[i + 2] == '\r' && data[i + 3] == '\n')
            return i + 4;
    return size_t.max;
}

private struct ResponseHead
{
    int status;
    string reason;
    bool chunked;
    size_t contentLength = size_t.max;
}

private ResponseHead parseHead(string head, string context) @safe pure
{
    TachyError fail(string msg) @safe pure
    {
        return new TachyError(context ~ ": malformed response: " ~ msg);
    }

    const size_t eol = head.indexOf("\r\n");
    const string statusLine = eol == cast(size_t) -1 ? head : head[0 .. eol];
    // "HTTP/1.x NNN [reason]"
    const size_t sp1 = statusLine.indexOf(' ');
    const size_t sp2 = statusLine.indexOf(' ', sp1 + 1);
    if (sp1 == cast(size_t) -1 || statusLine.length < 10
        || statusLine[0 .. 5] != "HTTP/" || statusLine[6] != '.'
        || (sp2 == cast(size_t) -1 ? statusLine.length : sp2) - sp1 != 4
        || !statusLine[sp1 + 1].isDigit || !statusLine[sp1 + 2].isDigit
        || !statusLine[sp1 + 3].isDigit)
        throw fail("status line \"" ~ statusLine ~ "\"");

    ResponseHead r;
    r.status = (statusLine[sp1 + 1] - '0') * 100
        + (statusLine[sp1 + 2] - '0') * 10
        + (statusLine[sp1 + 3] - '0');
    r.reason = sp2 == cast(size_t) -1 ? "" : statusLine[sp2 + 1 .. $];

    foreach (line; head.splitLines()[1 .. $])
    {
        const size_t colon = line.indexOf(':');
        if (colon == cast(size_t) -1)
            throw fail("header line \"" ~ line ~ "\"");
        const string name = toLower(line[0 .. colon]);
        const string value = stripLeft(line[colon + 1 .. $]);
        if (name == "content-length")
        {
            try r.contentLength = stripRight(value).to!size_t;
            catch (ConvException)
                throw fail("Content-Length \"" ~ value ~ "\"");
            if (r.contentLength > maxBodyBytes)
                throw new TachyError(context ~ ": response larger than "
                    ~ text(maxBodyBytes) ~ " bytes (Content-Length "
                    ~ text(r.contentLength) ~ ")");
        }
        else if (name == "transfer-encoding" && canFind(toLower(value), "chunked"))
            r.chunked = true;
    }
    return r;
}

private bool isDigit(char c) @safe pure nothrow
{
    return c >= '0' && c <= '9';
}

/// Decode a chunked body from `data` in place; true once the terminating
/// zero chunk arrived (trailers are ignored — the connection closes).
/// Throws on framing that is present but malformed; returns false while
/// more bytes are needed.
private bool decodeChunked(ref const(ubyte)[] data, ref string body,
    string context) @safe pure
{
    for (;;)
    {
        const size_t nl = findCRLF(data);
        if (nl == size_t.max)
            return false;
        size_t size;
        size_t digits;
        foreach (immutable i, immutable ubyte b; data[0 .. nl])
        {
            const int v = hexVal(cast(char) b);
            if (v < 0)
                break; // chunk extensions after ';'
            size = size * 16 + cast(size_t) v;
            digits = i + 1;
        }
        if (!digits)
            throw new TachyError(context ~ ": malformed chunked response:"
                ~ " chunk size \"" ~ bytesToString(data[0 .. nl]) ~ "\"");
        if (size > maxBodyBytes)
            throw new TachyError(context ~ ": response larger than "
                ~ text(maxBodyBytes) ~ " bytes");
        data = data[nl + 2 .. $];
        if (size == 0)
            return true;
        if (data.length < size + 2)
            return false;
        if (data[size] != '\r' || data[size + 1] != '\n')
            throw new TachyError(context ~ ": malformed chunked response:"
                ~ " chunk body not terminated by CRLF");
        body ~= bytesToString(data[0 .. size]);
        data = data[size + 2 .. $];
    }
}

private string bytesToString(in ubyte[] b) @trusted pure nothrow
{
    return cast(string) b;
}

private size_t findCRLF(in const(ubyte)[] data) @safe pure nothrow
{
    for (size_t i = 0; i + 1 < data.length; i++)
        if (data[i] == '\r' && data[i + 1] == '\n')
            return i;
    return size_t.max;
}

private int hexVal(char c) @safe pure nothrow
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}
