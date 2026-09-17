module tachy.events;

/**
 * Execution events, and their rendering, decoupled from the job loop.
 *
 * The job loop (the producer, wherever it runs — this process in direct
 * mode, the copied binary on a host in bundled mode) emits one `JobEvent`
 * per observable step; consumers turn them into output.  `TextRenderer`
 * reproduces the classic tachy text lines from events, so rendering
 * exists exactly once: direct mode renders in process, the bundled inner
 * run serializes events as one JSON object per line (`eventLine`) on
 * stdout and the controller parses (`parseEventLine`) and renders them
 * live as they arrive over the transport stream.
 *
 * Events carry execution metadata (per-job duration) alongside the
 * display fields, so consumers can aggregate or re-render freely.
 */
import std.algorithm.searching : startsWith;
import std.array : Appender, appender, join;
import std.format : format;

import tachy.errors;
import tachy.signals : signalName;

private bool startsWithChanged(string status) @safe pure
{
    return status.length >= 7 && status[0 .. 7] == "changed";
}
/// One observable step of a run.
struct JobEvent
{
    enum Kind : ushort { fileStart, job, fileDone }

    Kind kind;
    // fileStart / fileDone
    string file;        // tasks file as spelled on the command line
    string[] hosts;     // fileStart: selected host names
    ulong ok, changed, failed; // fileDone counters
    bool check;         // fileDone: check mode suffix
    // job
    string host;        // host the job ran on
    string label;       // "file /etc/x", "check name", or an error origin
    string status;      // ok | changed | changed (check) | failed
    string msg;         // one-line summary or error message
    string[] details;   // verbose details (-v)
    ulong ms;           // execution duration in milliseconds
    int sig;            // fileDone: signal that interrupted the run (0 = none)
}

/// Builds the three event shapes.
JobEvent evFileStart(string file, string[] hosts)
{
    JobEvent ev;
    ev.kind = JobEvent.Kind.fileStart;
    ev.file = file;
    ev.hosts = hosts;
    return ev;
}

JobEvent evJob(string host, string file, string label, string status, string msg,
    string[] details = null, ulong ms = 0)
{
    JobEvent ev;
    ev.kind = JobEvent.Kind.job;
    ev.host = host;
    ev.file = file;
    ev.label = label;
    ev.status = status;
    ev.msg = msg;
    ev.details = details;
    ev.ms = ms;
    return ev;
}

JobEvent evFileDone(string file, ulong ok, ulong changed, ulong failed, bool check,
    int sig = 0)
{
    JobEvent ev;
    ev.kind = JobEvent.Kind.fileDone;
    ev.file = file;
    ev.ok = ok;
    ev.changed = changed;
    ev.failed = failed;
    ev.check = check;
    ev.sig = sig;
    return ev;
}

/// Counts a job event into ok/changed/failed counters (an aggregator).
void foldCounters(ref const JobEvent ev, ref ulong ok, ref ulong changed, ref ulong failed)
{
    if (ev.kind != JobEvent.Kind.job)
        return;
    if (ev.status == "failed")
        failed++;
    else if (ev.status.startsWithChanged())
        changed++;
    else
        ok++;
}

/// Renders events as tachy text output: `== file | hosts` headers,
/// padded `host | status | label: msg` job lines (statuses colored on a
/// tty) with indented `-v` details, and `-- file: ok=…` footers.  In
/// flat mode (the default) every job line repeats its host name; in
/// tree mode the jobs group under a host line instead — the host prints
/// once when its first job arrives (hosts run one after another, so a
/// job event from a new host opens its group) and the job lines indent
/// beneath it:
///
///     == main.pravic | hosts: web1, web2
///     web1
///       changed         | file /srv/www: created file
///       ok              | ensure rendered: exit 0
///     web2
///       ok              | file /srv/www: file present
///
/// `sink` receives complete lines (newline appended); if events can
/// arrive from several threads it must be internally synchronized.
struct TextRenderer
{
    private void delegate(string line) emit;
    private bool tty_;
    private bool verbose_;
    private bool tree_;
    private size_t nameWidth_;
    private string treeHost_;   // tree mode: host whose group is open

    this(void delegate(string line) sink, bool tty, bool verbose,
        bool tree = false)
    {
        emit = sink;
        tty_ = tty;
        verbose_ = verbose;
        tree_ = tree;
    }

    void handle(JobEvent ev)
    {
        final switch (ev.kind)
        {
            case JobEvent.Kind.fileStart:
                nameWidth_ = 0;
                treeHost_ = null; // each file re-announces its hosts
                foreach (h; ev.hosts)
                    nameWidth_ = h.length > nameWidth_ ? h.length : nameWidth_;
                put(format!"== %s | hosts: %s"(ev.file, ev.hosts.join(", ")));
                break;
            case JobEvent.Kind.job:
                if (tree_ && ev.host != treeHost_)
                {
                    treeHost_ = ev.host;
                    put(ev.host);
                }
                jobLine(ev.host, ev.label, ev.status, ev.msg);
                if (verbose_)
                    foreach (d; ev.details)
                        put((tree_ ? "      " : "    ") ~ d);
                break;
            case JobEvent.Kind.fileDone:
                put(format!"-- %s: ok=%d changed=%d failed=%d%s%s"(ev.file, ev.ok,
                    ev.changed, ev.failed,
                    ev.check ? " (check mode, nothing applied)" : "",
                    ev.sig ? " (interrupted by " ~ signalName(ev.sig)
                        ~ ", stopped early)" : ""));
                break;
        }
    }

    private void put(string line)
    {
        emit(line ~ "\n");
    }

    private void jobLine(string host, string label, string status, string msg)
    {
        string color;
        if (tty_)
        {
            if (status == "failed")
                color = "\033[31m";
            else if (status.startsWithChanged())
                color = "\033[33m";
            else if (status == "ok")
                color = "\033[32m";
        }
        const string reset = tty_ ? "\033[0m" : "";
        string line = tree_ ? "  " : format!"%-*s | "(nameWidth_, host);
        if (color.length)
            line ~= color;
        line ~= format!"%-16s"(status);
        if (color.length)
            line ~= reset;
        line ~= "| " ~ label;
        if (msg.length)
            line ~= ": " ~ msg;
        put(line);
    }
}

// ---------------------------------------------------------------------------
// NDJSON serialization: one flat JSON object per line.
// ---------------------------------------------------------------------------

/// Serialize an event as one JSON object on a single line.
string eventLine(ref const JobEvent ev) @safe pure
{
    auto app = appender!string;
    app.put("{\"t\":\"");
    app.put(kindName(ev.kind));
    app.put("\"");
    final switch (ev.kind)
    {
        case JobEvent.Kind.fileStart:
            jsonStr(app, "file", ev.file);
            jsonKey(app, "hosts");
            app.put('[');
            foreach (i, h; ev.hosts)
            {
                if (i) app.put(',');
                jsonString(app, h);
            }
            app.put(']');
            break;
        case JobEvent.Kind.job:
            jsonStr(app, "host", ev.host);
            jsonStr(app, "file", ev.file);
            jsonStr(app, "label", ev.label);
            jsonStr(app, "status", ev.status);
            jsonStr(app, "msg", ev.msg);
            jsonKey(app, "details");
            app.put('[');
            foreach (i, d; ev.details)
            {
                if (i) app.put(',');
                jsonString(app, d);
            }
            app.put(']');
            app.put(",\"ms\":");
            app.put(ulongText(ev.ms));
            break;
        case JobEvent.Kind.fileDone:
            jsonStr(app, "file", ev.file);
            app.put(",\"ok\":");
            app.put(ulongText(ev.ok));
            app.put(",\"changed\":");
            app.put(ulongText(ev.changed));
            app.put(",\"failed\":");
            app.put(ulongText(ev.failed));
            jsonBool(app, "check", ev.check);
            if (ev.sig)
            {
                app.put(",\"sig\":");
                app.put(ulongText(ev.sig));
            }
            break;
    }
    app.put("}");
    return app.data;
}

private string ulongText(ulong v) @safe pure
{
    import std.conv : text;
    return text(v);
}

private string kindName(JobEvent.Kind k) @safe pure nothrow
{
    final switch (k)
    {
        case JobEvent.Kind.fileStart: return "fileStart";
        case JobEvent.Kind.job: return "job";
        case JobEvent.Kind.fileDone: return "fileDone";
    }
}

private void jsonStr(ref Appender!string app, string key, string value) @safe pure
{
    app.put(",\"");
    app.put(key);
    app.put("\":");
    jsonString(app, value);
}

private void jsonBool(ref Appender!string app, string key, bool value) @safe pure
{
    app.put(",\"");
    app.put(key);
    app.put("\":");
    app.put(value ? "true" : "false");
}

/// Key prefix for a value emitted by the caller (arrays).
private void jsonKey(ref Appender!string app, string key) @safe pure
{
    app.put(",\"");
    app.put(key);
    app.put("\":");
}

private void jsonString(App)(ref App app, string s) @safe pure
{
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
}

/// Parse one event line produced by `eventLine`.  Returns false when the
/// line is not an event (remote noise on the stream); a malformed event
/// line is a hard error naming the problem.
bool parseEventLine(string line, ref JobEvent ev)
{
    import std.string : stripLeft;
    string s = line.stripLeft();
    if (!s.length || s[0] != '{')
        return false;
    ev = JobEvent.init;

    JsonParser p = JsonParser(s);
    p.expect('{');
    string kind;
    while (p.peek() != '}')
    {
        const string key = p.parseString();
        p.expect(':');
        switch (key)
        {
            case "t": kind = p.parseString(); break;
            case "file": ev.file = p.parseString(); break;
            case "hosts": ev.hosts = p.parseStringArray(); break;
            case "host": ev.host = p.parseString(); break;
            case "label": ev.label = p.parseString(); break;
            case "status": ev.status = p.parseString(); break;
            case "msg": ev.msg = p.parseString(); break;
            case "details": ev.details = p.parseStringArray(); break;
            case "ms": ev.ms = p.parseUlong(); break;
            case "ok": ev.ok = p.parseUlong(); break;
            case "changed": ev.changed = p.parseUlong(); break;
            case "failed": ev.failed = p.parseUlong(); break;
            case "check": ev.check = p.parseBool(); break;
            case "sig": ev.sig = cast(int) p.parseUlong(); break;
            default: throw new TachyError("event line: unknown key '" ~ key ~ "'");
        }
        if (p.peek() == ',')
            p.next();
    }
    switch (kind)
    {
        case "fileStart": ev.kind = JobEvent.Kind.fileStart; break;
        case "job": ev.kind = JobEvent.Kind.job; break;
        case "fileDone": ev.kind = JobEvent.Kind.fileDone; break;
        case null:
            throw new TachyError("event line: missing \"t\" key");
        default:
            throw new TachyError("event line: unknown event type \"" ~ kind ~ "\"");
    }
    return true;
}

/// Minimal reader for the flat objects `eventLine` writes: strings,
/// string arrays, unsigned integers, booleans.
private struct JsonParser
{
    string s;
    size_t pos;

    void next()
    {
        pos++;
    }

    char peek()
    {
        skipWs();
        if (pos >= s.length)
            throw new TachyError("event line: truncated");
        return s[pos];
    }

    void skipWs()
    {
        while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t'))
            pos++;
    }

    void expect(char c)
    {
        if (peek() != c)
            throw new TachyError("event line: expected '" ~ c ~ "'");
        pos++;
    }

    string parseString()
    {
        expect('"');
        auto app = appender!string;
        while (pos < s.length)
        {
            char c = s[pos++];
            if (c == '"')
                return app.data;
            if (c != '\\')
            {
                app.put(c);
                continue;
            }
            if (pos >= s.length)
                break;
            char e = s[pos++];
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
                    if (pos + 4 > s.length)
                        throw new TachyError("event line: truncated \\u escape");
                    app.put(parseHex4(s[pos .. pos + 4]));
                    pos += 4;
                    break;
            }
        }
        throw new TachyError("event line: unterminated string");
    }

    string[] parseStringArray()
    {
        expect('[');
        string[] r;
        while (peek() != ']')
        {
            r ~= parseString();
            if (peek() == ',')
                next();
        }
        next(); // ']'
        return r;
    }

    ulong parseUlong()
    {
        skipWs();
        size_t start = pos;
        while (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
            pos++;
        if (pos == start)
            throw new TachyError("event line: expected a number");
        import std.conv : to;
        try
            return to!ulong(s[start .. pos]);
        catch (Exception e)
            throw new TachyError("event line: bad number: " ~ e.msg);
    }

    bool parseBool()
    {
        skipWs();
        if (s.length - pos >= 4 && s[pos .. pos + 4] == "true")
        {
            pos += 4;
            return true;
        }
        if (s.length - pos >= 5 && s[pos .. pos + 5] == "false")
        {
            pos += 5;
            return false;
        }
        throw new TachyError("event line: expected true or false");
    }

    private dchar parseHex4(string hex)
    {
        import std.conv : to, ConvException;
        try
            return cast(dchar) to!ushort(hex, 16);
        catch (ConvException e)
            throw new TachyError("event line: bad \\u escape '" ~ hex ~ "'");
    }
}

// ---------------------------------------------------------------------------
