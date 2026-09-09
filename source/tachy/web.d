module tachy.web;

/**
 * The `webui` command: a local web server that is a graphical version
 * of the CLI — no web framework, no asset pipeline, everything in one
 * binary.
 *
 * The server (this module, a few hundred lines of `std.socket` plus a
 * thread per connection) serves three things:
 *
 *   - the browser application: `webui/index.html`, `app.js` and
 *     `app.css`, embedded in the binary at compile time with
 *     `import("...")` — plain HTML/CSS/ES2020, no build step;
 *   - a small JSON API: `GET /api/state` (projects from the `[webui]`
 *     section of settings.toml, inventory hosts and tags, past runs),
 *     `POST /api/run` (start `apply` or `check` on one project and a
 *     host selection) and `GET /api/events/<id>` (the run's progress
 *     as Server-Sent Events);
 *   - the runs themselves: each run spawns this very binary as
 *     `tachy <mode> --events ...` and turns its NDJSON event stream
 *     (the protocol the controller already speaks to the inner runs
 *     on every host) into SSE records — so the browser shows each job
 *     line live, exactly when the remote executor finishes the job.
 *     Child stderr and non-event stdout lines travel as `log` records
 *     so load errors and ssh noise stay visible.
 *
 * The server binds to 127.0.0.1 by default (`--address`/`--port`): it
 * executes real runs, so anyone who can reach the port can run tachy.
 */
import std.array : appender, join;
import std.conv : to, text;
import std.datetime.systime : Clock, SysTime;
import std.format : format;
import std.path : baseName;
import std.socket : AddressFamily, InternetAddress, Socket, TcpSocket;
import std.string : strip, stripLeft;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import tachy.errors;
import tachy.events : JobEvent, eventLine, foldCounters, parseEventLine;
import tachy.inventory : HostConfig, Inventory;
import tachy.runner : RunOptions;
import tachy.settings : Settings, loadSettings;
import tachy.transport : LocalTransport, shQuote;

/// Chunk sink handed to streamed responses (one call = one write).
private alias ChunkSink = void delegate(string chunk);

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

int runWebUi(const RunOptions opts) @trusted
{
    import std.stdio : stdout;

    if (opts.webPort < 0 || opts.webPort > 65535)
        throw new TachyError("--port must be between 0 and 65535");

    const Settings settings = loadSettings(opts.settings);
    auto app = new WebApp(opts, settings);

    auto listener = bindListener(opts.webAddress, cast(ushort) opts.webPort);
    auto addr = cast(InternetAddress) listener.localAddress();
    stdout.writefln("tachy webui listening on http://%s — Ctrl-C to stop",
        addr.toString());
    stdout.writefln("inventory: %s — projects: %s", opts.inventoryPath,
        settings.webuiProjects.length ? settings.webuiProjects.join(", ")
            : "none configured ([webui] projects in settings.toml)");
    stdout.flush();

    serveForever(listener, app.router);
    return 0;
}

// ---------------------------------------------------------------------------
// Application: routes and the run registry
// ---------------------------------------------------------------------------

private final class WebApp
{
    const RunOptions opts;
    const Settings settings;
    Router router;

    private Mutex regM; // guards runs/nextId
    private Run[] runs;
    private size_t nextId;

    this(const RunOptions opts, const Settings settings)
    {
        this.opts = opts;
        this.settings = settings;
        regM = new Mutex;
        router = new Router;

        router.add("GET", "/", (req, p) => asset(indexHtml, "text/html; charset=utf-8"));
        router.add("GET", "/app.js", (req, p) => asset(assetJs, "text/javascript; charset=utf-8"));
        router.add("GET", "/app.css", (req, p) => asset(assetCss, "text/css; charset=utf-8"));
        router.add("GET", "/favicon.ico", (req, p) => new Response); // empty 200
        router.add("GET", "/api/state", &apiState);
        router.add("POST", "/api/run", &apiRunPost);
        router.add("GET", "/api/events/:id", &apiEvents);
    }

    // -- GET /api/state ----------------------------------------------------

    private Response apiState(Request req, string[string] params)
    {
        string[] members;

        string[] projects;
        foreach (p; settings.webuiProjects)
            projects ~= projectJson(p);
        members ~= `"projects":[` ~ projects.join(",") ~ `]`;

        string[] hostsJson;
        string[] tagsAll;
        string invError;
        try
        {
            auto inv = Inventory.load(opts.inventoryPath, opts.identity);
            foreach (ref const h; inv.select("all"))
            {
                hostsJson ~= "{" ~ jstr("name", h.name)
                    ~ "," ~ jstr("desc", describeHostWeb(h))
                    ~ ",\"tags\":[" ~ mapJson(h.tags) ~ "]}";
                foreach (t; h.tags)
                    if (!canFindString(tagsAll, t))
                        tagsAll ~= t;
            }
            tagsAll.sortStrings();
        }
        catch (Exception e)
            invError = e.msg;
        members ~= jstr("inventoryError", invError);
        members ~= `"hosts":[` ~ hostsJson.join(",") ~ `]`;
        members ~= `"tags":[` ~ mapJson(tagsAll) ~ `]`;

        Run[] snapshot;
        synchronized (regM)
            snapshot = runs.dup;
        string[] runsJson;
        foreach (r; snapshot)
            runsJson ~= runJson(r);
        members ~= `"runs":[` ~ runsJson.join(",") ~ `]`;

        return jsonBody("{" ~ members.join(",") ~ "}");
    }

    // -- POST /api/run -----------------------------------------------------

    private Response apiRunPost(Request req, string[string] params)
    {
        string[string] fields;
        try
            fields = parseStringObject(req.body);
        catch (TachyError e)
            return errorJson(400, e.msg);
        foreach (k; fields.byKeyValue)
            if (!k.key.among3("project", "selection", "mode"))
                return errorJson(400, "unknown field '" ~ k.key ~ "'");
        foreach (k; ["project", "selection", "mode"])
            if (k !in fields)
                return errorJson(400, "missing field '" ~ k ~ "'");

        const string mode = fields["mode"];
        if (mode != "apply" && mode != "check")
            return errorJson(400, "'mode' must be \"apply\" or \"check\"");
        const string project = fields["project"];
        if (!canFindString(settings.webuiProjects, project))
            return errorJson(400, "unknown project '" ~ project
                ~ "' — configure it under [webui] projects in settings.toml");
        if (!pathExists(project))
            return errorJson(400, "project path '" ~ project ~ "' does not exist");

        const string selection = fields["selection"];
        if (!validSelection(selection))
            return errorJson(400, "'selection' must be a non-empty comma-separated"
                ~ " list of host names and @tags (\"all\"), 256 characters max");

        Run run;
        synchronized (regM)
        {
            run = new Run(format!"r%d"(++nextId), project, selection, mode);
            runs ~= run;
            while (runs.length > maxRuns)
            {
                synchronized (runs[0].m)
                    if (!runs[0].done)
                        break;
                runs = runs[1 .. $];
            }
        }
        startWorker(run, childCommand(project, selection, mode));
        return jsonBody("{" ~ jstr("id", run.id) ~ "}");
    }

    /// The command the run executes: this binary, the mode, `--events`
    /// and the same inventory/settings/identity the server was given —
    /// so a webui run behaves exactly like the same CLI invocation.
    private string childCommand(string project, string selection, string mode) @trusted
    {
        import std.file : thisExePath;
        string cmd = "exec " ~ shQuote(thisExePath) ~ " " ~ mode ~ " --events";
        cmd ~= " -i " ~ shQuote(opts.inventoryPath);
        if (opts.settings.length)
            cmd ~= " --settings " ~ shQuote(opts.settings);
        if (opts.identity.length)
            cmd ~= " --identity " ~ shQuote(opts.identity);
        return cmd ~ " " ~ shQuote(selection) ~ " " ~ shQuote(project);
    }

    // -- GET /api/events/:id (SSE) ------------------------------------------

    private Response apiEvents(Request req, string[string] params)
    {
        Run run;
        synchronized (regM)
            foreach (r; runs)
                if (r.id == params["id"])
                    run = r;
        if (run is null)
            return errorJson(404, "unknown run");

        size_t since = 0;
        if (auto lid = "last-event-id" in req.headers)
        {
            try
                since = to!size_t(*lid) + 1;
            catch (Exception e)
                since = 0; // malformed id: replay from the beginning
        }

        auto r = new Response;
        r.contentType = "text/event-stream";
        r.stream = (ChunkSink send) { Run.streamRun(run, since, send); };
        return r;
    }
}

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

private enum size_t maxRuns = 100;

private final class Run
{
    const string id;
    const string project;
    const string selection;
    const string mode;
    const SysTime started;

    Mutex m;                 // guards everything below
    private Condition cond;  // signalled on every appended record
    string[] records;        // wire JSON; the index is the SSE event id
    bool done;
    int exitStatus;
    ulong ok, changed, failed;
    SysTime finished;

    this(string id, string project, string selection, string mode)
    {
        this.id = id;
        this.project = project;
        this.selection = selection;
        this.mode = mode;
        this.started = Clock.currTime();
        m = new Mutex;
        cond = new Condition(m);
    }

    void appendEvent(const JobEvent ev)
    {
        synchronized (m)
        {
            records ~= format!"{\"ts\":%s,\"ev\":%s}"(nowMs(), eventLine(ev));
            foldCounters(ev, ok, changed, failed);
            cond.notifyAll();
        }
    }

    void appendLog(string line)
    {
        synchronized (m)
        {
            records ~= format!"{\"ts\":%s,\"log\":%s}"(nowMs(), jsonEscStr(line));
            cond.notifyAll();
        }
    }

    void finish(int status)
    {
        synchronized (m)
        {
            finished = Clock.currTime();
            exitStatus = status;
            records ~= format!"{\"ts\":%s,\"done\":true,\"exit\":%d}"(nowMs(), status);
            done = true;
            cond.notifyAll();
        }
    }

    /// Stream the records from `since` as SSE frames, following the run
    /// until it is finished and everything has been sent.  Blocks the
    /// connection thread; a 15 s idle timeout becomes a keepalive
    /// comment so browsers keep the stream open.
    static void streamRun(Run run, size_t since, ChunkSink send) @trusted
    {
        import core.time : seconds;
        size_t i = since;
        for (;;)
        {
            string[] batch;
            bool complete;
            bool idle;
            synchronized (run.m)
            {
                if (run.records.length <= i && !run.done)
                    idle = !run.cond.wait(15.seconds);
                if (run.records.length > i)
                {
                    batch = run.records[i .. $].dup;
                    i += batch.length;
                }
                complete = run.done && run.records.length <= i;
            }
            if (batch.length)
            {
                size_t n = i - batch.length;
                foreach (rec; batch)
                    send(sseFrame(n++, rec));
            }
            else if (idle)
                send(": keepalive\n\n");
            if (complete)
            {
                // a finished run's replay ends here; without this the
                // browser would reconnect (and re-drain) forever
                send("event: end\ndata: end\n\n");
                break;
            }
        }
    }
}

private string runJson(Run r) @trusted
{
    string status;
    string startedS, finishedS;
    int exitStatus;
    ulong ok, changed, failed;
    synchronized (r.m)
    {
        status = r.done ? "finished" : "running";
        startedS = isoMs(r.started);
        finishedS = r.done ? isoMs(r.finished) : "";
        exitStatus = r.exitStatus;
        ok = r.ok;
        changed = r.changed;
        failed = r.failed;
    }
    return "{" ~ jstr("id", r.id)
        ~ "," ~ jstr("project", r.project)
        ~ "," ~ jstr("selection", r.selection)
        ~ "," ~ jstr("mode", r.mode)
        ~ "," ~ jstr("status", status)
        ~ "," ~ jstr("started", startedS)
        ~ "," ~ jstr("finished", finishedS)
        ~ "," ~ jnum("exit", text(exitStatus))
        ~ "," ~ jnum("ok", text(ok))
        ~ "," ~ jnum("changed", text(changed))
        ~ "," ~ jnum("failed", text(failed))
        ~ "}";
}

/// ISO timestamp with the fractional seconds cut to milliseconds —
private string isoMs(SysTime t) @safe
{
    import std.algorithm.comparison : min;
    const string s = t.toISOExtString();
    const size_t dot = stdStringIndexOf(s, '.');
    if (dot == size_t.max)
        return s;
    size_t end = dot + 1;
    while (end < s.length && s[end] >= '0' && s[end] <= '9')
        end++;
    // keep at most three fractional digits, then the offset if any
    return s[0 .. dot] ~ s[dot .. min(dot + 4, end)] ~ s[end .. $];
}

private void startWorker(Run run, string cmd) @trusted
{
    auto t = new Thread({
        try
        {
            // The run is a normal CLI invocation whose stdout is the
            // NDJSON event stream (bundled --events mode); the
            // transport delivers lines live from both pipes.
            auto transport = new LocalTransport;
            auto r = transport.runStreaming(cmd, (string line, bool isErr)
            {
                if (isErr)
                {
                    run.appendLog(line);
                    return;
                }
                JobEvent ev;
                try
                {
                    if (parseEventLine(line, ev))
                    {
                        run.appendEvent(ev);
                        return;
                    }
                }
                catch (TachyError e)
                {
                    run.appendLog(line); // malformed event line: show it raw
                    return;
                }
                run.appendLog(line); // remote noise on stdout
            });
            run.finish(r.status);
        }
        catch (Exception e)
        {
            run.appendLog("webui: run failed to start: " ~ e.msg);
            run.finish(127);
        }
    });
    t.isDaemon = true;
    t.start();
}

// ---------------------------------------------------------------------------
// HTTP: a tiny ad-hoc server (a thread per connection, Connection: close)
// ---------------------------------------------------------------------------

final class Request
{
    string method;
    string path;
    string query;
    string[string] headers; // lowercased names
    string body;
}

alias Handler = Response delegate(Request req, string[string] params);

final class Response
{
    ushort status = 200;
    string contentType = "text/plain; charset=utf-8";
    string body;
    void delegate(ChunkSink send) stream; // set: streamed response (SSE)
}

final class Router
{
    private static struct Route
    {
        string method;
        string[] segs;
        Handler dg;
    }

    private Route[] routes;

    void add(string method, string pattern, Handler dg)
    {
        Route r = { method, splitPath(pattern), dg };
        routes ~= r;
    }

    Response dispatch(Request req)
    {
        const string[] segs = splitPath(req.path);
        bool pathMatched;
        foreach (ref r; routes)
        {
            string[string] params;
            if (!matchSegs(r.segs, segs, params))
                continue;
            pathMatched = true;
            if (r.method == req.method)
                return r.dg(req, params);
        }
        return pathMatched
            ? errorJson(405, "method not allowed")
            : errorJson(404, "no such resource");
    }
}

public TcpSocket bindListener(string address, ushort port) @trusted
{
    import std.socket : SocketOption, SocketOptionLevel;
    auto listener = new TcpSocket(AddressFamily.INET);
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    try
        listener.bind(new InternetAddress(address, port));
    catch (Exception e)
    {
        listener.close();
        throw new TachyError("cannot bind " ~ address ~ ":" ~ text(port)
            ~ ": " ~ e.msg);
    }
    listener.listen(64);
    return listener;
}

public void serveForever(TcpSocket listener, Router router) @trusted
{
    for (;;)
    {
        Socket sock;
        try
            sock = listener.accept();
        catch (Exception e)
            continue; // transient accept error: keep serving
        auto conn = new Conn(sock, router);
        auto t = new Thread(&conn.run);
        t.isDaemon = true;
        t.start();
    }
}

private final class Conn
{
    private Socket sock;
    private Router router;

    this(Socket sock, Router router)
    {
        this.sock = sock;
        this.router = router;
    }

    void run() @trusted
    {
        import core.time : seconds;
        import std.socket : SocketOption, SocketOptionLevel;
        scope (exit) sock.close();
        try
        {
            sock.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
            sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 30.seconds);
            sock.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 30.seconds);

            auto req = readRequest(sock);
            if (req is null)
                return; // peer closed, or the error response was sent
            auto resp = router.dispatch(req);
            writeResponse(sock, resp);
        }
        catch (Exception e)
        {
            // the connection died mid-flight; nothing to salvage
        }
    }
}

private enum size_t maxHead = 64 * 1024;
private enum size_t maxBody = 1024 * 1024;

private Request readRequest(Socket sock) @trusted
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

    string buf;
    while (!canFind(buf, "\r\n\r\n"))
    {
        if (buf.length > maxHead)
        {
            sendSimple(sock, 400, "request head too large");
            return null;
        }
        char[4096] chunk;
        const ptrdiff_t n = sock.receive(chunk);
        if (n <= 0)
            return null; // closed before a full head
        buf ~= chunk[0 .. n];
    }
    const size_t headEnd = cast(size_t) indexOf(buf, "\r\n\r\n") + 4;

    Request req;
    try
        req = parseHead(buf[0 .. headEnd]);
    catch (TachyError e)
    {
        sendSimple(sock, 400, e.msg);
        return null;
    }
    if (req.method != "GET" && req.method != "POST")
    {
        sendSimple(sock, 405, "only GET and POST are supported");
        return null;
    }

    if ("transfer-encoding" in req.headers)
    {
        sendSimple(sock, 400, "chunked request bodies are not supported");
        return null;
    }
    if (auto cl = "content-length" in req.headers)
    {
        long want;
        try
            want = to!long(*cl);
        catch (Exception e)
            want = -1;
        if (want < 0 || want > maxBody)
        {
            sendSimple(sock, 413, "request body too large");
            return null;
        }
        string body = buf[headEnd .. $];
        while (body.length < cast(size_t) want)
        {
            char[4096] chunk;
            const ptrdiff_t n = sock.receive(chunk);
            if (n <= 0)
                return null;
            body ~= chunk[0 .. n];
        }
        req.body = body[0 .. cast(size_t) want];
    }
    return req;
}

/// Parse "METHOD /path?query HTTP/1.x" plus header lines; names
/// lowercased.  Malformed input is a TachyError.
private Request parseHead(string head) @safe pure
{
    import std.algorithm.searching : startsWith;
    import std.array : split;
    import std.string : toLower;

    Request req = new Request;
    const string[] lines = split(head, "\r\n");
    if (!lines.length)
        throw new TachyError("empty request");
    const string[] parts = split(lines[0]);
    if (parts.length != 3 || !parts[0].length || !parts[1].startsWith("/")
        || !parts[2].startsWith("HTTP/"))
        throw new TachyError("malformed request line");
    req.method = parts[0];
    if (parts[1].length > 2048)
        throw new TachyError("request target too long");
    const size_t q = stdStringIndexOf(parts[1], '?');
    if (q == size_t.max)
    {
        req.path = parts[1];
        req.query = "";
    }
    else
    {
        req.path = parts[1][0 .. q];
        req.query = parts[1][q + 1 .. $];
    }
    foreach (line; lines[1 .. $])
    {
        if (!line.length)
            continue; // trailing empty after the final CRLFCRLF
        const size_t c = stdStringIndexOf(line, ':');
        if (c == 0 || c == size_t.max)
            throw new TachyError("malformed header line");
        req.headers[toLower(line[0 .. c]).stripLeft()] = line[c + 1 .. $].strip();
    }
    return req;
}

private void writeResponse(Socket sock, Response r) @trusted
{
    if (r.stream !is null)
    {
        sendAll(sock, "HTTP/1.1 200 OK\r\nContent-Type: " ~ r.contentType
            ~ "\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n");
        r.stream((string chunk) => sendAll(sock, chunk));
        return; // the stream ending closes the exchange
    }
    auto head = "HTTP/1.1 " ~ text(r.status) ~ " " ~ statusText(r.status)
        ~ "\r\nContent-Type: " ~ r.contentType
        ~ "\r\nContent-Length: " ~ text(r.body.length)
        ~ "\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n";
    sendAll(sock, head);
    if (r.body.length)
        sendAll(sock, r.body);
}

private void sendSimple(Socket sock, ushort status, string msg) @trusted
{
    try
        writeResponse(sock, errorJson(status, msg));
    catch (Exception e)
    {
    }
}

private void sendAll(Socket sock, const char[] data) @trusted
{
    size_t off;
    while (off < data.length)
    {
        const ptrdiff_t n = sock.send(data[off .. $]);
        if (n <= 0)
            throw new TachyError("connection closed by peer");
        off += n;
    }
}

private string statusText(ushort s) @safe pure nothrow
{
    switch (s)
    {
        case 200: return "OK";
        case 204: return "No Content";
        case 400: return "Bad Request";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 413: return "Payload Too Large";
        default: return "Error";
    }
}

private string[] splitPath(string path) @safe pure
{
    import std.array : array;
    import std.string : split;
    if (path == "/" || path.length == 0)
        return [];
    return path[1 .. $].split("/").array;
}

private bool matchSegs(in string[] pat, in string[] segs, ref string[string] params)
    @safe pure
{
    if (pat.length != segs.length)
        return false;
    foreach (i, p; pat)
    {
        if (p.length > 1 && p[0] == ':')
            params[p[1 .. $]] = segs[i];
        else if (p != segs[i])
            return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// JSON: writing (hand-rolled like events.d) and one strict parser for the
// flat all-strings objects POST /api/run accepts
// ---------------------------------------------------------------------------

private string jsonEscStr(string s) @safe pure
{
    auto app = appender!string;
    app.put('"');
    foreach (char c; s)
    {
        switch (c)
        {
            case '"': app.put("\\\""); break;
            case '\\': app.put("\\\\"); break;
            case '\n': app.put("\\n"); break;
            case '\r': app.put("\\r"); break;
            case '\t': app.put("\\t"); break;
            case '\b': app.put("\\b"); break;
            case '\f': app.put("\\f"); break;
            default:
                if (c < 0x20)
                    app.put(format!"\\u%04x"(c));
                else
                    app.put(c);
        }
    }
    app.put('"');
    return app.data;
}

private string jstr(string key, string v) @safe pure
{
    return "\"" ~ key ~ "\":" ~ jsonEscStr(v);
}

private string jnum(string key, string decimal) @safe pure
{
    return "\"" ~ key ~ "\":" ~ decimal;
}

private string sseFrame(size_t id, string data) @safe pure
{
    return format!"id: %d\ndata: %s\n\n"(id, data);
}

/// Parse a flat JSON object whose values are all strings.  Strict: a
/// malformed body is a TachyError naming the problem.
private string[string] parseStringObject(string body) @safe pure
{
    string[string] out_;
    size_t i = 0;

    void skipWs()
    {
        while (i < body.length && (body[i] == ' ' || body[i] == '\t'
            || body[i] == '\n' || body[i] == '\r'))
            i++;
    }
    void expect(char c, string what)
    {
        skipWs();
        if (i >= body.length || body[i] != c)
            throw new TachyError("request body: expected '" ~ text(c) ~ "' " ~ what);
        i++;
    }

    expect('{', "(a JSON object)");
    skipWs();
    if (i < body.length && body[i] == '}')
    {
        i++;
        skipWs();
        if (i != body.length)
            throw new TachyError("request body: trailing data");
        return out_;
    }
    for (;;)
    {
        skipWs();
        const string key = parseJsonString(body, i);
        if (key in out_)
            throw new TachyError("request body: duplicate field '" ~ key ~ "'");
        expect(':', "after a field name");
        skipWs();
        if (i >= body.length || body[i] != '"')
            throw new TachyError("request body: field '" ~ key
                ~ "' must be a string");
        out_[key] = parseJsonString(body, i);
        skipWs();
        if (i < body.length && body[i] == ',')
        {
            i++;
            continue;
        }
        expect('}', "(end of the object)");
        break;
    }
    skipWs();
    if (i != body.length)
        throw new TachyError("request body: trailing data");
    return out_;
}

/// One JSON string at body[i]; the same escapes `eventLine` writes.
private string parseJsonString(string s, ref size_t i) @safe pure
{
    if (i >= s.length || s[i] != '"')
        throw new TachyError("request body: expected a string");
    i++;
    auto app = appender!string;
    while (i < s.length)
    {
        char c = s[i++];
        if (c == '"')
            return app.data;
        if (c != '\\')
        {
            app.put(c);
            continue;
        }
        if (i >= s.length)
            break;
        char e = s[i++];
        final switch (e)
        {
            case '"': app.put('"'); break;
            case '\\': app.put('\\'); break;
            case '/': app.put('/'); break;
            case 'n': app.put('\n'); break;
            case 'r': app.put('\r'); break;
            case 't': app.put('\t'); break;
            case 'b': app.put('\b'); break;
            case 'f': app.put('\f'); break;
            case 'u':
                if (i + 4 > s.length)
                    throw new TachyError("request body: truncated \\u escape");
                app.put(hex4Char(s[i .. i + 4]));
                i += 4;
                break;
        }
    }
    throw new TachyError("request body: unterminated string");
}

private string hex4Char(string hex) @safe pure
{
    import std.conv : to;
    import std.utf : encode;
    dchar c = to!ushort(hex, 16);
    char[4] buf;
    const size_t n = encode(buf, c);
    return buf[0 .. n].idup;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

public Response asset(string content, string contentType)
{
    auto r = new Response;
    r.contentType = contentType;
    r.body = content;
    return r;
}

private Response jsonBody(string json)
{
    auto r = new Response;
    r.contentType = "application/json";
    r.body = json;
    return r;
}

private Response errorJson(ushort status, string msg)
{
    auto r = new Response;
    r.status = status;
    r.contentType = "application/json";
    r.body = "{" ~ jstr("error", msg) ~ "}";
    return r;
}

private string projectJson(string path) @trusted
{
    import std.file : exists, isDir;
    string kind = "missing";
    if (exists(path))
        kind = isDir(path) ? "directory" : "file";
    return "{" ~ jstr("name", baseName(path)) ~ "," ~ jstr("path", path)
        ~ "," ~ jstr("kind", kind) ~ "}";
}

private string describeHostWeb(in HostConfig h) @safe pure
{
    if (h.connection == "local")
        return "local";
    auto s = "ssh ";
    if (h.user.length)
        s ~= h.user ~ "@";
    s ~= h.address.length ? h.address : h.name;
    if (h.port != 22)
        s ~= text(":", h.port);
    return s;
}

private bool validSelection(string s) @safe pure
{
    if (!s.length || s.length > 256 || s[0] == '-')
        return false;
    foreach (char c; s)
        if (c < 0x20 || c == 0x7f)
            return false;
    return true;
}

private bool pathExists(string p) @trusted
{
    import std.file : exists;
    return exists(p);
}

private bool canFindString(in string[] hay, string needle) @safe pure
{
    foreach (s; hay)
        if (s == needle)
            return true;
    return false;
}

private string mapJson(in string[] items) @safe pure
{
    string[] parts;
    foreach (s; items)
        parts ~= jsonEscStr(s);
    return parts.join(",");
}

private void sortStrings(ref string[] s) @safe pure
{
    import std.algorithm.sorting : sort;
    s.sort();
}

private size_t stdStringIndexOf(string s, char c) @safe pure
{
    import std.string : indexOf;
    const auto r = indexOf(s, c);
    return r == -1 ? size_t.max : cast(size_t) r;
}

private bool among3(string s, string a, string b, string c) @safe pure nothrow
{
    return s == a || s == b || s == c;
}

/// Milliseconds since the Unix epoch (SysTime.stdTime counts hnsecs
/// since year 1601; the constant is the 1970 offset in hnsecs).
private long nowMs() @trusted nothrow
{
    return (Clock.currTime().stdTime - 116444736000000000L) / 10_000;
}

// ---------------------------------------------------------------------------
// The browser application, embedded at compile time — one binary, no
// external files (see source/tachy/webui/)
// ---------------------------------------------------------------------------

private enum string indexHtml = import("tachy/webui/index.html");
private enum string assetJs = import("tachy/webui/app.js");
private enum string assetCss = import("tachy/webui/app.css");

// ---------------------------------------------------------------------------

version (unittest)
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown;

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
}
