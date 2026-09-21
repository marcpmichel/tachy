module tachy.http;

/**
 * The HTTP client behind the `probe` directive and the `upgrade`
 * command: the `requests` dub package driving plain `http://` and
 * `https://` alike — TLS comes from the system OpenSSL, dlopened at
 * first https use, with peer verification against the default CA
 * store.  No external processes are ever spawned.
 *
 * Small by policy: `httpQuery` — the directive's tool — follows
 * redirects by default, up to `defaultMaxRedirects` (the `redirects`
 * attribute tunes or disables that), buffers the whole body (capped at
 * `maxBodyBytes`) and maps every failure onto a TachyError carrying
 * `context`; `insecure` turns certificate verification off for
 * self-signed or otherwise invalid server certificates (TLS itself
 * stays on).  `httpDownload` — the
 * `upgrade` tool — follows redirects (release assets bounce to the
 * CDN) under the larger `maxDownloadBytes` cap and writes the file
 * only after a complete 200 answer.  Methods and header entries are
 * validated here (`validateMethod`/`validateHeader` — the same rules
 * the `probe` module pre-checks at load time), and only `http`/`https`
 * URLs travel.
 */
import core.time : Duration;
import std.conv : text;
import std.string : icmp, indexOf, representation, strip;

import requests : HTTPResponse, Request, Response, TimeoutException;

import tachy.errors;

/// Response bodies above this size are rejected (health payloads, not mirrors).
enum size_t maxBodyBytes = 16 * 1024 * 1024;

/// Redirects followed by default before giving up (the `requests`
/// library's own standard cap).
enum uint defaultMaxRedirects = 10;

/// Downloads above this size are rejected (the release binary is a few
/// megabytes; the cap keeps a runaway answer from eating the machine).
enum size_t maxDownloadBytes = 64 * 1024 * 1024;

struct HttpResponse {
    int status;
    string reason;
    string body;
}

// ---------------------------------------------------------------------------
// Request validation (the run-time authority; the `probe` module
// pre-checks literal values at load time for early typo detection).
// ---------------------------------------------------------------------------

/// RFC 7230 token characters (methods and header names are tokens).
private bool isTokenChar(char c) @safe pure nothrow {
    if((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
        return true;
    foreach(immutable good; "!#$%&'*+-.^_`|~")
        if(c == good)
            return true;
    return false;
}

/// A method is a non-empty token ("GET", "POST", ...).  Throws on
/// anything else, so an accidental typo cannot smuggle request framing.
void validateMethod(string method, string context) {
    if(method.length) {
        bool ok = true;
        foreach(immutable char c; method)
            if(!isTokenChar(c)) {
                ok = false;
                break;
            }
        if(ok)
            return;
    }
    throw new TachyError(context ~ ": 'type' must be an HTTP method token like"
            ~ " \"GET\" or \"POST\", not \"" ~ method ~ "\"");
}

/// A header entry is "Name=Value" with a token name and a value free of
/// control characters (no request smuggling through parameters).
void validateHeader(string header, string context) {
    const size_t eq = header.indexOf('=');
    if(eq == 0 || eq == cast(size_t)-1)
        throw new TachyError(context ~ ": 'headers' entries must look like"
                ~ " \"Name=Value\", not \"" ~ header ~ "\"");
    foreach(immutable char c; header[0 .. eq])
        if(!isTokenChar(c))
            throw new TachyError(context ~ ": header name \"" ~ header[0 .. eq]
                    ~ "\" is not a valid header name (in \"" ~ header ~ "\")");
    foreach(immutable char c; header[eq + 1 .. $])
        if(c < ' ' || c == 0x7F)
            throw new TachyError(context ~ ": header value in \"" ~ header
                    ~ "\" must not contain control characters");
}

/// Only http and https travel: anything else is a spelling error, not
/// a request the library should interpret (it would also accept ftp).
private void enforceScheme(string url, string context) @safe pure {
    const bool ok = (url.length >= 7 && !icmp(url[0 .. 7], "http://"))
        || (url.length >= 8 && !icmp(url[0 .. 8], "https://"));
    if(!ok)
        throw new TachyError(context ~ ": '" ~ url
                ~ "' is not an http(s) URL (expected http:// or https://)");
}

// ---------------------------------------------------------------------------
// The query itself.
// ---------------------------------------------------------------------------

/// Submit one request and read the whole answer.  `data` may be `null`
/// (no body, no Content-Type) or any string including the empty string
/// (a zero-length body).  Redirects are followed up to `maxRedirects`
/// (0 means: the answer of the exact URL is the answer).
HttpResponse httpQuery(string method, string url, in string[] headers,
        string data, Duration timeout, string context,
        uint maxRedirects = defaultMaxRedirects, bool insecure = false) {
    auto rs = perform(method, url, headers, data, timeout, maxBodyBytes,
            maxRedirects, context, insecure);
    HttpResponse r;
    r.status = rs.code;
    r.body = cast(string) rs.responseBody.data;
    if(auto hr = cast(HTTPResponse) rs)
        r.reason = reasonOf(hr.status_line(), rs.code);
    return r;
}

/// Download the body of an `http://` or `https://` URL into a file,
/// following redirects (GitHub release assets bounce to the CDN).
/// `headers` use the same "Name=Value" spelling as `httpQuery`.  A
/// non-200 status, a timeout, an oversized body or a transport failure
/// throws with `context` and writes nothing.
void httpDownload(string url, string path, in string[] headers,
        Duration timeout, string context) @trusted {
    auto rs = perform("GET", url, headers, null, timeout, maxDownloadBytes,
            defaultMaxRedirects, context);
    if(rs.code != 200)
        throw new TachyError(context ~ ": cannot download '" ~ url
                ~ "': status " ~ text(rs.code));
    import std.file : write;

    write(path, rs.responseBody.data);
}

/// One request through the `requests` package, failures mapped onto
/// TachyError: `maxRedirects` is 0 for queries (the raw answer is the
/// point) and 10 for downloads (follow to the CDN); `maxBytes` bounds
/// the buffered body both by Content-Length and by bytes received.
private Response perform(string method, string url, in string[] headers,
        string data, Duration timeout, size_t maxBytes, uint maxRedirects,
        string context, bool insecure = false) @trusted {
    validateMethod(method, context);
    foreach(immutable h; headers)
        validateHeader(h, context);
    enforceScheme(url, context);

    auto rq = Request();
    rq.timeout = timeout;
    rq.keepAlive = false; // one query, one connection ("Connection: close");
    // unframed responses then end at the server's EOF
    rq.maxRedirects = maxRedirects;
    rq.maxContentLength = maxBytes;
    if(insecure)
        rq.sslSetVerifyPeer(false); // TLS stays on, certificates don't

    // "Name=Value" entries become library headers; a body goes through
    // execute's contentType slot (empty means: send no Content-Type
    // unless the caller supplied one).  A User-Agent is only a default.
    string[string] extra;
    string contentType;
    bool haveUA;
    foreach(immutable h; headers) {
        const size_t eq = h.indexOf('=');
        const string name = h[0 .. eq];
        if(!icmp(name, "Content-Type"))
            contentType = h[eq + 1 .. $];
        else {
            haveUA = haveUA || !icmp(name, "User-Agent");
            extra[name] = h[eq + 1 .. $];
        }
    }
    if(!haveUA)
        extra["User-Agent"] = "tachy";
    if(extra.length)
        rq.addHeaders(extra);

    try {
        if(data is null) return rq.execute(method, url);
        // A flat array keeps the wire shape of the query tool: the body
        // travels with Content-Length, never chunked.
        return rq.execute(method, url, data.representation, contentType);
    } catch(TimeoutException e)
        throw new TachyError(context ~ ": '" ~ url ~ "' timed out after "
                ~ secs(timeout) ~ ": " ~ e.msg);
    catch(Exception e)
        throw new TachyError(context ~ ": " ~ e.msg);
}

/// "HTTP/1.1 200 OK" -> "OK" (the text after the three-digit code).
private string reasonOf(string statusLine, int status) @safe pure {
    const needle = text(status) ~ " ";
    const ptrdiff_t idx = statusLine.indexOf(needle);
    return idx >= 0 ? statusLine[idx + needle.length .. $].strip : "";
}

private string secs(Duration d) @safe pure {
    immutable s = d.total!"seconds";
    return s ? text(s) ~ "s" : text(d);
}
