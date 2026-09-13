module tachy.modules.httpmod;

/**
 * `http` module — submit one HTTP request and assert on the answer.
 * tachy.http does the querying (a client written on std.socket: no curl,
 * no transport commands):
 *
 *     http.url      = "http://localhost:8080/health"  (the statement key)
 *     http.type     = "GET"            # any HTTP method token
 *     http.headers  = ["Content-Type=application/json"]
 *     http.data     = "{\"x\": 1}"     # request body, sent verbatim
 *     http.code     = 200              # expected status (default 200)
 *     http.output   = "ok" / { contains = "ok" } / { matches = "^ok$" }
 *     http.timeout  = 10               # seconds for the whole query
 *
 * The request is issued by the tachy process running the job — on the
 * managed host in bundled runs (the default), on the controller for
 * --direct runs; plain http only (no TLS), no redirects.  Like `ensure`,
 * these jobs are checks by nature: they run even in check mode, report
 * `ok` when the status and (optionally) the body satisfy the
 * expectations, and never report `changed`.  `output` is the response
 * body compared after trimming surrounding whitespace — the same shapes
 * `ensure` accepts.
 */
import std.algorithm.searching : canFind;
import std.conv : text;
import std.string : strip;

import tachy.errors;
import tachy.http : httpQuery, validateHeader, validateMethod;
import tachy.modules : TaskContext, TaskResult, requireStr;
import tachy.modules.ensuremod : excerpt, OutputExpectation, parseOutput;
import tachy.value : Val;

private enum defaultTimeoutSecs = 10;

/// Load-time key/type checks (values may still contain templates; the
/// run re-checks everything rendered).
void validateHttpParams(in Val[string] params, string context)
{
    if (auto p = "type" in params)
    {
        if ((*p).kind != Val.Kind.string_)
            throw new TachyError(context ~ ": 'type' must be a string (an HTTP"
                ~ " method), not a " ~ (*p).typeName());
        // Templated methods are validated again at run time.
        if (!canFind((*p).str_, "{{"))
            validateMethod((*p).str_, context);
    }
    if (auto p = "headers" in params)
    {
        if ((*p).kind != Val.Kind.array_)
            throw new TachyError(context ~ ": 'headers' must be an array of"
                ~ " \"Name=Value\" strings, not a " ~ (*p).typeName());
        foreach (const ref h; (*p).array_)
        {
            if (h.kind != Val.Kind.string_)
                throw new TachyError(context ~ ": 'headers' entries must be"
                    ~ " strings, not a " ~ h.typeName());
            if (!canFind(h.str_, "{{"))
                validateHeader(h.str_, context);
        }
    }
    if (auto p = "data" in params)
        if ((*p).kind != Val.Kind.string_)
            throw new TachyError(context ~ ": 'data' must be a string, not a "
                ~ (*p).typeName());
    checkStatusCode(params, "code", context);
    if (auto p = "timeout" in params)
    {
        if ((*p).kind != Val.Kind.integer_)
            throw new TachyError(context ~ ": 'timeout' must be an integer"
                ~ " number of seconds, not a " ~ (*p).typeName());
        if ((*p).integer_ <= 0)
            throw new TachyError(context ~ ": 'timeout' must be positive, not "
                ~ text((*p).integer_));
    }
    if (auto p = "output" in params)
        parseOutput(*p, context);
}

private void checkStatusCode(in Val[string] params, string key, string context)
{
    auto p = key in params;
    if (p is null)
        return;
    if ((*p).kind != Val.Kind.integer_)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be an integer HTTP"
            ~ " status like 200 or 404, not a " ~ (*p).typeName());
    const int code = cast(int) (*p).integer_;
    if (code < 100 || code > 599)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be an HTTP status"
            ~ " between 100 and 599, not " ~ text(code));
}

TaskResult runHttpModule(Val[string] params, TaskContext ctx)
{
    const string url = requireStr(params, "url", "http");
    const string what = "http '" ~ url ~ "'";

    const string method = optMethod(params);
    validateMethod(method, what); // catches templated values after rendering

    string[] headers;
    if (auto p = "headers" in params)
    {
        if ((*p).kind != Val.Kind.array_)
            throw new TachyError(what ~ ": 'headers' must be an array of"
                ~ " \"Name=Value\" strings, not a " ~ (*p).typeName());
        foreach (const ref h; (*p).array_)
        {
            if (h.kind != Val.Kind.string_)
                throw new TachyError(what ~ ": 'headers' entries must be"
                    ~ " strings, not a " ~ h.typeName());
            headers ~= h.str_;
        }
        foreach (immutable h; headers)
            validateHeader(h, what); // re-checked: entries may be templated
    }

    string data;
    if (auto p = "data" in params)
    {
        if ((*p).kind != Val.Kind.string_)
            throw new TachyError(what ~ ": 'data' must be a string, not a "
                ~ (*p).typeName());
        data = (*p).str_;
    }

    int expectedCode = 200;
    if ("code" in params)
    {
        checkStatusCode(params, "code", what);
        expectedCode = cast(int) params["code"].integer_;
    }

    int timeoutSecs = defaultTimeoutSecs;
    if (auto p = "timeout" in params)
    {
        if ((*p).kind != Val.Kind.integer_ || (*p).integer_ <= 0)
            throw new TachyError(what ~ ": 'timeout' must be a positive"
                ~ " number of seconds");
        timeoutSecs = cast(int) (*p).integer_;
    }

    bool checkOutput;
    OutputExpectation outputExp;
    if (auto p = "output" in params)
    {
        outputExp = parseOutput(*p, what);
        checkOutput = true;
    }

    string[] details;
    details ~= method ~ " " ~ url;

    // Checks by nature: the query runs even in check mode.
    import core.time : dur;
    auto resp = httpQuery(method, url, headers,
        ("data" in params) ? data : null, dur!"seconds"(timeoutSecs), what);

    const string body = resp.body.strip;
    if (body.length)
        details ~= "output: " ~ excerpt(body);

    if (resp.status != expectedCode)
        throw new TachyError(what ~ ": status " ~ text(resp.status)
            ~ ", expected " ~ text(expectedCode)
            ~ (body.length ? "; output: '" ~ excerpt(body) ~ "'" : ""));
    if (checkOutput && !outputExp.matches(body))
        throw new TachyError(what ~ ": output '" ~ excerpt(body)
            ~ "' does not satisfy " ~ outputExp.describe());

    TaskResult res;
    res.changed = false;
    res.msg = text(resp.status) ~ (resp.reason.length ? " " ~ resp.reason : "");
    res.details = details;
    return res;
}

private string optMethod(in Val[string] params)
{
    auto p = "type" in params;
    if (p is null)
        return "GET";
    if ((*p).kind != Val.Kind.string_)
        throw new TachyError("http: 'type' must be a string (an HTTP method),"
            ~ " not a " ~ (*p).typeName());
    return (*p).str_;
}
