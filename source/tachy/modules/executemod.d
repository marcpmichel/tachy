module tachy.modules.executemod;

/**
 * `execute` module — run a shell command on the host and check its exit
 * status and/or its output:
 *
 *     execute.run         = "source /etc/os-release; echo $ID"  (required)
 *     execute.exit_status = 0                     # expected status (default 0)
 *                           # or { not = 1 }       # anything but 1
 *                           # or { cond = "< 1" }  # an operator and a value
 *     execute.output      = "debian"              # exact (trimmed) output
 *                           # or { contains = "deb" }      # substring
 *                           # or { matches = "^debian.*$" } # regular expression
 *
 * Entries are keyed by a unique task name, like every managed resource.
 * The command runs through the host's transport in the defining tasks
 * file's directory (like `file.src`: relative paths resolve next to the
 * file that declares the job); the job passes ("ok", never "changed")
 * when every assertion holds and fails with a descriptive error
 * otherwise.  Execute jobs are checks by
 * nature and run even in check mode — keep mutating commands out of
 * them.  Output is compared after trimming surrounding whitespace.
 */
import std.array : join;
import std.conv : text, to;
import std.regex : Regex, RegexException, matchFirst, regex;
import std.string : indexOf, strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, requireStr;
import tachy.transport : shQuote;
import tachy.value : Val;

// ---------------------------------------------------------------------------
// Expectations (parsed at load time for early validation, evaluated at
// run time against the rendered values).
// ---------------------------------------------------------------------------

struct ExitExpectation
{
    enum Kind { equal, not_, cond }
    Kind kind;
    int value;   // equal / not_
    string op;   // cond: one of == != < <= > >=
    int cond;    // cond

    static ExitExpectation equal(int v) @safe pure nothrow
    {
        return ExitExpectation(Kind.equal, v, "==", v);
    }

    bool matches(int status) const @safe pure nothrow
    {
        final switch (kind)
        {
            case Kind.equal: return status == value;
            case Kind.not_: return status != value;
            case Kind.cond:
                if (op == "<") return status < cond;
                if (op == "<=") return status <= cond;
                if (op == ">") return status > cond;
                if (op == ">=") return status >= cond;
                if (op == "!=") return status != cond;
                return status == cond; // "=="
        }
    }

    string describe() const @safe pure nothrow
    {
        final switch (kind)
        {
            case Kind.equal: return text(value);
            case Kind.not_: return "not " ~ text(value);
            case Kind.cond: return op ~ " " ~ text(cond);
        }
    }
}

struct OutputExpectation
{
    enum Kind { exact, contains, matches }
    Kind kind;
    string text_;       // exact / contains
    string pattern;     // matches (source, for messages)
    private Regex!char re;

    bool matches(string output) const
    {
        final switch (kind)
        {
            case Kind.exact: return output == text_;
            case Kind.contains: return indexOf(output, text_) >= 0;
            case Kind.matches: return !matchFirst(output, re).empty;
        }
    }

    string describe() const @safe pure nothrow
    {
        final switch (kind)
        {
            case Kind.exact: return "exactly \"" ~ text_ ~ "\"";
            case Kind.contains: return "a substring \"" ~ text_ ~ "\"";
            case Kind.matches: return "a match of /" ~ pattern ~ "/";
        }
    }
}

/// `exit_status` accepts an integer, `{ not = N }` or `{ cond = "OP N" }`.
ExitExpectation parseExitStatus(in Val v, string context)
{
    ExitExpectation e;
    if (v.kind == Val.Kind.integer_)
        return ExitExpectation.equal(cast(int) v.integer_);

    if (v.kind == Val.Kind.table_ && v.table_.length == 1)
    {
        if (auto n = "not" in v.table_)
        {
            if ((*n).kind != Val.Kind.integer_)
                throw new TachyError(context ~ ": 'not' must be an integer, not a "
                    ~ (*n).typeName());
            e.kind = ExitExpectation.Kind.not_;
            e.value = cast(int) (*n).integer_;
            e.op = "==";
            e.cond = e.value;
            return e;
        }
        if (auto c = "cond" in v.table_)
        {
            if ((*c).kind != Val.Kind.string_)
                throw new TachyError(context ~ ": 'cond' must be a string like \"< 1\", not a "
                    ~ (*c).typeName());
            return parseCond((*c).str_, context);
        }
    }
    throw new TachyError(context ~ ": 'exit_status' must be an integer, "
        ~ "{ not = N } or { cond = \"OP N\" }, not " ~ v.display());
}

private ExitExpectation parseCond(string s, string context)
{
    import std.algorithm.searching : startsWith;
    string op = "==";
    string rest = strip(s);
    foreach (string candidate; ["<=", ">=", "!=", "==", "<", ">", "="])
        if (rest.startsWith(candidate))
        {
            op = candidate == "=" ? "==" : candidate;
            rest = strip(rest[candidate.length .. $]);
            break;
        }
    ExitExpectation e;
    e.kind = ExitExpectation.Kind.cond;
    e.op = op;
    try e.cond = to!int(rest);
    catch (Exception)
        throw new TachyError(context ~ ": 'cond' must be an operator and an"
            ~ " integer like \"< 1\", \"!= 0\" or \">= 2\", not \"" ~ s ~ "\"");
    e.value = e.cond;
    return e;
}

/// `output` accepts a string (exact match), `{ contains = "..." }` or
/// `{ matches = "..." }`.
OutputExpectation parseOutput(in Val v, string context)
{
    OutputExpectation o;
    if (v.kind == Val.Kind.string_)
    {
        o.kind = OutputExpectation.Kind.exact;
        o.text_ = v.str_;
        return o;
    }
    if (v.kind == Val.Kind.table_ && v.table_.length == 1)
    {
        if (auto c = "contains" in v.table_)
        {
            if ((*c).kind != Val.Kind.string_)
                throw new TachyError(context ~ ": 'contains' must be a string, not a "
                    ~ (*c).typeName());
            o.kind = OutputExpectation.Kind.contains;
            o.text_ = (*c).str_;
            return o;
        }
        if (auto m = "matches" in v.table_)
        {
            if ((*m).kind != Val.Kind.string_)
                throw new TachyError(context ~ ": 'matches' must be a string, not a "
                    ~ (*m).typeName());
            try o.re = regex((*m).str_);
            catch (RegexException e)
                throw new TachyError(context ~ ": invalid regular expression \""
                    ~ (*m).str_ ~ "\": " ~ e.msg);
            o.kind = OutputExpectation.Kind.matches;
            o.pattern = (*m).str_;
            return o;
        }
    }
    throw new TachyError(context ~ ": 'output' must be a string, "
        ~ "{ contains = \"...\" } or { matches = \"...\" }, not " ~ v.display());
}

// ---------------------------------------------------------------------------
// The module itself.
// ---------------------------------------------------------------------------

TaskResult runExecuteModule(Val[string] params, TaskContext ctx)
{
    const string name = requireStr(params, "name", "execute");
    const string runCmd = requireStr(params, "run", "execute");

    ExitExpectation exitExp = ExitExpectation.equal(0);
    if (auto p = "exit_status" in params)
        exitExp = parseExitStatus(*p, "execute '" ~ name ~ "'");

    bool checkOutput;
    OutputExpectation outputExp;
    if (auto p = "output" in params)
    {
        outputExp = parseOutput(*p, "execute '" ~ name ~ "'");
        checkOutput = true;
    }

    // The command runs in the defining tasks file's directory, like
    // file.src: relative paths resolve next to the file that declares
    // the job, not against the process cwd (the project root).
    const string cmd = ctx.tasksFileDir.length
        ? "cd " ~ shQuote(ctx.tasksFileDir) ~ " && " ~ runCmd
        : runCmd;

    string[] details;
    details ~= "cmd: " ~ cmd;

    // Checks by nature: execute jobs run even in check mode.
    auto r = ctx.transport.run(cmd);
    const string got = r.outText.strip;
    if (got.length)
        details ~= "output: " ~ excerpt(got);

    if (!exitExp.matches(r.status))
        throw new TachyError("execute '" ~ name ~ "': exit status " ~ text(r.status)
            ~ ", expected " ~ exitExp.describe()
            ~ (got.length ? "; output: '" ~ excerpt(got) ~ "'" : ""));
    if (checkOutput && !outputExp.matches(got))
        throw new TachyError("execute '" ~ name ~ "': output '" ~ excerpt(got)
            ~ "' does not satisfy " ~ outputExp.describe());

    TaskResult res;
    res.changed = false;
    res.msg = "exit " ~ text(r.status);
    res.details = details;
    return res;
}

/// Cap an output excerpt so error messages stay readable.
private string excerpt(string s) @safe pure
{
    import std.algorithm.searching : canFind;
    if (canFind(s, "\n"))
    {
        import std.string : splitLines;
        auto lines = splitLines(s);
        s = lines.length > 3 ? lines[0 .. 3].join(" ⏎ ") ~ " ⏎ …" : lines.join(" ⏎ ");
    }
    return s.length > 200 ? s[0 .. 200] ~ "…" : s;
}

// ---------------------------------------------------------------------------

version (unittest)
{
    import std.exception : assertThrown;
    import tachy.transport : LocalTransport;

    private TaskContext ctxLocal()
    {
        TaskContext ctx = TaskContext(new LocalTransport, false, "localhost", "/tmp");
        return ctx;
    }

    unittest // passing assertions
    {
        auto ctx = ctxLocal;

        Val[string] p;
        p["name"] = Val("os");
        p["run"] = Val("printf 'debian\\n'");
        p["exit_status"] = Val(0L);
        p["output"] = Val("debian");
        auto r = runExecuteModule(p, ctx);
        assert(!r.changed && r.msg == "exit 0");

        // default expectation is exit 0
        Val[string] p2;
        p2["name"] = Val("true");
        p2["run"] = Val("true");
        assert(!runExecuteModule(p2, ctx).changed);

        // contains
        Val[string] p3;
        p3["name"] = Val("c");
        p3["run"] = Val("echo debian11");
        Val c;
        c.kind = Val.Kind.table_;
        c.table_["contains"] = Val("deb");
        p3["output"] = c;
        assert(!runExecuteModule(p3, ctx).changed);

        // matches
        Val[string] p4;
        p4["name"] = Val("m");
        p4["run"] = Val("echo debian-12");
        Val m;
        m.kind = Val.Kind.table_;
        m.table_["matches"] = Val("^debian-\\d+$");
        p4["output"] = m;
        assert(!runExecuteModule(p4, ctx).changed);

        // { not = 1 } accepts other codes
        Val[string] p5;
        p5["name"] = Val("n");
        p5["run"] = Val("exit 3");
        Val n;
        n.kind = Val.Kind.table_;
        n.table_["not"] = Val(1L);
        p5["exit_status"] = n;
        auto r5 = runExecuteModule(p5, ctx);
        assert(!r5.changed && r5.msg == "exit 3");

        // { cond = "<= 2" } range
        Val[string] p6;
        p6["name"] = Val("cd");
        p6["run"] = Val("exit 2");
        Val cd;
        cd.kind = Val.Kind.table_;
        cd.table_["cond"] = Val("<= 2");
        p6["exit_status"] = cd;
        assert(!runExecuteModule(p6, ctx).changed);
    }

    unittest // run executes in the defining tasks file's directory
    {
        import std.file : exists, mkdirRecurse, tempDir, write;
        import std.path : buildPath;
        auto dir = buildPath(tempDir, "tachy_execmod_ut");
        if (!exists(dir)) mkdirRecurse(dir);
        write(buildPath(dir, "marker.txt"), "next-to-the-tasks-file\n");

        TaskContext ctx = TaskContext(new LocalTransport, false, "localhost", dir);
        Val[string] p;
        p["name"] = Val("rel");
        p["run"] = Val("cat marker.txt");
        p["output"] = Val("next-to-the-tasks-file");
        auto r = runExecuteModule(p, ctx);
        assert(!r.changed && r.msg == "exit 0", r.msg);
    }

    unittest // failing assertions
    {
        auto ctx = ctxLocal;

        string fail(Val[string] p)
        {
            try
            {
                runExecuteModule(p, ctx);
                return null;
            }
            catch (TachyError e)
                return e.msg;
        }

        Val[string] p;
        p["name"] = Val("bad-exit");
        p["run"] = Val("exit 7");
        auto msg = fail(p);
        import std.algorithm.searching : canFind;
        assert(canFind(msg, "exit status 7, expected 0"), msg);

        p["exit_status"] = Val(7L);
        assert(fail(p) is null);

        Val n;
        n.kind = Val.Kind.table_;
        n.table_["not"] = Val(7L);
        p["exit_status"] = n;
        msg = fail(p);
        assert(canFind(msg, "expected not 7"), msg);

        Val cd;
        cd.kind = Val.Kind.table_;
        cd.table_["cond"] = Val("< 7");
        p["exit_status"] = cd;
        msg = fail(p);
        assert(canFind(msg, "expected < 7"), msg);

        Val[string] q;
        q["name"] = Val("bad-output");
        q["run"] = Val("echo ubuntu");
        q["output"] = Val("debian");
        msg = fail(q);
        assert(canFind(msg, "does not satisfy exactly \"debian\""), msg);

        Val c;
        c.kind = Val.Kind.table_;
        c.table_["contains"] = Val("deb");
        q["output"] = c;
        msg = fail(q);
        assert(canFind(msg, "substring \"deb\""), msg);

        Val m;
        m.kind = Val.Kind.table_;
        m.table_["matches"] = Val("^deb.*$");
        q["output"] = m;
        msg = fail(q);
        assert(canFind(msg, "match of /^deb.*$/"), msg);
    }

    unittest // parse errors
    {
        import std.algorithm.searching : canFind;

        string msg;
        try
        {
            parseExitStatus(Val(1.5), "ctx");
            assert(false);
        }
        catch (TachyError e) msg = e.msg;
        assert(canFind(msg, "'exit_status' must be"), msg);

        Val bad;
        bad.kind = Val.Kind.table_;
        bad.table_["nope"] = Val(1L);
        try
        {
            parseExitStatus(bad, "ctx");
            assert(false);
        }
        catch (TachyError e) msg = e.msg;
        assert(canFind(msg, "'exit_status' must be"), msg);

        Val bcond;
        bcond.kind = Val.Kind.table_;
        bcond.table_["cond"] = Val("< banana");
        try
        {
            parseExitStatus(bcond, "ctx");
            assert(false);
        }
        catch (TachyError e) msg = e.msg;
        assert(canFind(msg, "'cond' must be an operator"), msg);

        Val bre;
        bre.kind = Val.Kind.table_;
        bre.table_["matches"] = Val("[unclosed");
        try
        {
            parseOutput(bre, "ctx");
            assert(false);
        }
        catch (TachyError e) msg = e.msg;
        assert(canFind(msg, "invalid regular expression"), msg);

        Val bout;
        bout.kind = Val.Kind.integer_;
        try
        {
            parseOutput(bout, "ctx");
            assert(false);
        }
        catch (TachyError e) msg = e.msg;
        assert(canFind(msg, "'output' must be"), msg);
    }
}
