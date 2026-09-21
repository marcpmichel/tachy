module tachy.modules.probemod;

/**
 * `probe` module — submit one HTTP request and assert on the answer.
 * tachy.http does the querying (the `requests` package: no curl,
 * no transport commands):
 *
  *     probe.url      = "http://localhost:8080/health"  (the statement key)
  *     probe.type     = "GET"            # any HTTP method token
  *     probe.headers  = ["Content-Type=application/json"]
  *     probe.data     = "{\"x\": 1}"     # request body, sent verbatim
  *     probe.code     = 200              # expected status (default 200)
  *     probe.output   = "ok" / { contains = "ok" } / { matches = "^ok$" }
 *                    # ensure's shapes, composed the same way: several
 *                    # keys AND together, `not` negates, `any`/`all`/
 *                    # `none` quantify over an array of patterns
  *     probe.timeout  = 10               # seconds for the whole query
  *     probe.redirects = "no"            # redirects are followed by default
 *                    = { max = 3 }     # (up to 10); "no" disables, or cap
 *                                      # them at N
  *     probe.insecure = true             # accept invalid certificates
 *                                      # (self-signed and the like)
 *
 * The request is issued by the tachy process running the job — on the
 * managed host in bundled runs (the default), on the controller for
 * --direct runs; `http://` or `https://` (TLS from the system OpenSSL).
 * Redirects are followed by default, up to `defaultMaxRedirects` (10);
 * `redirects = "no"` shows the check the redirect answer itself, and
 * `redirects = { max = N }` sets another cap.  Like `ensure`,
 * these jobs are checks by nature: they run even in check mode, report
 * `ok` when the status and (optionally) the body satisfy the
 * expectations, and never report `changed`.  `output` is the response
 * body compared after trimming surrounding whitespace — the same
 * shapes `ensure` accepts, composed the same way (several keys AND
 * together, `not`, `any`).
 */
import std.algorithm.searching : canFind;
import std.conv : text;
import std.string : strip;

import tachy.errors;
import tachy.http : defaultMaxRedirects, httpQuery, validateHeader,
    validateMethod;
import tachy.modules : TaskContext, TaskResult, requireStr;
import tachy.modules.ensuremod : excerpt, OutputExpectation, parseOutput;
import tachy.value : Val;

private enum defaultTimeoutSecs = 10;

/// Load-time key/type checks (values may still contain templates; the
/// run re-checks everything rendered).
void validateProbeParams(in Val[string] params, string context)
{
    if(auto p = "type" in params) {
        if((*p).kind != Val.Kind.string_)
            throw new TachyError(context ~ ": 'type' must be a string (an HTTP"
                    ~ " method), not a " ~ (*p).typeName());
        // Templated methods are validated again at run time.
        if(!canFind((*p).str_, "{{"))
            validateMethod((*p).str_, context);
    }
    if(auto p = "headers" in params) {
        if((*p).kind != Val.Kind.array_)
            throw new TachyError(context ~ ": 'headers' must be an array of"
                    ~ " \"Name=Value\" strings, not a " ~ (*p).typeName());
        foreach(const ref h; (*p).array_) {
            if(h.kind != Val.Kind.string_)
                throw new TachyError(context ~ ": 'headers' entries must be"
                        ~ " strings, not a " ~ h.typeName());
            if(!canFind(h.str_, "{{"))
                validateHeader(h.str_, context);
        }
    }
    if(auto p = "data" in params)
        if((*p).kind != Val.Kind.string_)
            throw new TachyError(context ~ ": 'data' must be a string, not a "
                    ~ (*p).typeName());
    checkStatusCode(params, "code", context);
    if(auto p = "timeout" in params) {
        if((*p).kind != Val.Kind.integer_)
            throw new TachyError(context ~ ": 'timeout' must be an integer"
                    ~ " number of seconds, not a " ~ (*p).typeName());
        if((*p).integer_ <= 0)
            throw new TachyError(context ~ ": 'timeout' must be positive, not "
                    ~ text((*p).integer_));
    }
    if(auto p = "output" in params)
        parseOutput(*p, context);
    if(auto p = "insecure" in params)
        if((*p).kind != Val.Kind.boolean_)
            throw new TachyError(context ~ ": 'insecure' must be a boolean,"
                    ~ " not a " ~ (*p).typeName());
    if(auto p = "redirects" in params) {
        if((*p).kind == Val.Kind.string_) {
            // templated strings are re-checked after rendering
            if(!canFind((*p).str_, "{{"))
                redirectsLimit(*p, context);
        } else if((*p).kind == Val.Kind.table_)
            redirectsLimit(*p, context);
        else
            throw new TachyError(context ~ ": 'redirects' must be \"no\" or"
                    ~ " a { max = N } table, not a " ~ (*p).typeName());
    }
}

private void checkStatusCode(in Val[string] params, string key, string context)
{
    auto p = key in params;
    if(p is null)
        return;
    if((*p).kind != Val.Kind.integer_)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be an integer HTTP"
                ~ " status like 200 or 404, not a " ~ (*p).typeName());
    const int code = cast(int)(*p).integer_;
    if(code < 100 || code > 599)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be an HTTP status"
                ~ " between 100 and 599, not " ~ text(code));
}

TaskResult runProbeModule(Val[string] params, TaskContext ctx)
{
    const string url = requireStr(params, "url", "probe");
    const string what = "probe '" ~ url ~ "'";

    const string method = optMethod(params);
    validateMethod(method, what); // catches templated values after rendering

    string[] headers;
    if(auto p = "headers" in params) {
        if((*p).kind != Val.Kind.array_)
            throw new TachyError(what ~ ": 'headers' must be an array of"
                    ~ " \"Name=Value\" strings, not a " ~ (*p).typeName());
        foreach(const ref h; (*p).array_) {
            if(h.kind != Val.Kind.string_)
                throw new TachyError(what ~ ": 'headers' entries must be"
                        ~ " strings, not a " ~ h.typeName());
            headers ~= h.str_;
        }
        foreach(immutable h; headers)
            validateHeader(h, what); // re-checked: entries may be templated
    }

    string data;
    if(auto p = "data" in params) {
        if((*p).kind != Val.Kind.string_)
            throw new TachyError(what ~ ": 'data' must be a string, not a "
                    ~ (*p).typeName());
        data = (*p).str_;
    }

    int expectedCode = 200;
    if("code" in params) {
        checkStatusCode(params, "code", what);
        expectedCode = cast(int) params["code"].integer_;
    }

    int timeoutSecs = defaultTimeoutSecs;
    if(auto p = "timeout" in params) {
        if((*p).kind != Val.Kind.integer_ || (*p).integer_ <= 0)
            throw new TachyError(what ~ ": 'timeout' must be a positive"
                    ~ " number of seconds");
        timeoutSecs = cast(int)(*p).integer_;
    }

    uint maxRedirects = defaultMaxRedirects;
    if(auto p = "redirects" in params)
        maxRedirects = redirectsLimit(*p, what);

    bool insecure;
    if(auto p = "insecure" in params)
        insecure = (*p).boolean_;

    bool checkOutput;
    OutputExpectation outputExp;
    if(auto p = "output" in params) {
        outputExp = parseOutput(*p, what);
        checkOutput = true;
    }

    string[] details;
    details ~= method ~ " " ~ url;
    if("redirects" in params)
        details ~= maxRedirects == 0 ? "redirects: no" : "redirects: max " ~ text(maxRedirects);
    if(insecure)
        details ~= "tls: insecure";

    // Checks by nature: the query runs even in check mode.
    import core.time : dur;

    auto resp = httpQuery(method, url, headers,
            ("data" in params) ? data : null, dur!"seconds"(timeoutSecs), what,
            maxRedirects, insecure);

    const string body = resp.body.strip;
    if(body.length)
        details ~= "output: " ~ excerpt(body);

    if(resp.status != expectedCode)
        throw new TachyError(what ~ ": status " ~ text(resp.status)
                ~ ", expected " ~ text(expectedCode)
                ~ (body.length ? "; output: '" ~ excerpt(body) ~ "'" : ""));
    if(checkOutput && !outputExp.matches(body))
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
    if(p is null)
        return "GET";
    if((*p).kind != Val.Kind.string_)
        throw new TachyError("probe: 'type' must be a string (an HTTP method),"
                ~ " not a " ~ (*p).typeName());
    return (*p).str_;
}

/// The redirect cap a `redirects` value stands for: the string "no"
/// means none; a table holds exactly `{ max = N }` with a non-negative
/// integer.  Validated again at run time (values may be templated).
private uint redirectsLimit(in Val v, string what)
{
    if(v.kind == Val.Kind.string_) {
        if(v.str_ == "no")
            return 0;
        throw new TachyError(what ~ ": 'redirects' must be \"no\", not \""
                ~ v.str_ ~ "\"");
    }

    foreach(immutable k, const ref e; v.table_)
        if(k != "max")
            throw new TachyError(what ~ ": 'redirects' accepts only"
                    ~ " { max = N }, not the key \"" ~ k ~ "\"");
    auto m = "max" in v.table_;
    if(m is null)
        throw new TachyError(what ~ ": 'redirects' table needs a 'max' key");
    if((*m).kind != Val.Kind.integer_)
        throw new TachyError(what ~ ": 'redirects.max' must be an integer"
                ~ " redirect cap, not a " ~ (*m).typeName());
    if((*m).integer_ < 0)
        throw new TachyError(what ~ ": 'redirects.max' must be non-negative,"
                ~ " not " ~ text((*m).integer_));
    return cast(uint)(*m).integer_;
}
