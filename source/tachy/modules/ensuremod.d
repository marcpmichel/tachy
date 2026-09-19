module tachy.modules.ensuremod;

/**
 * `ensure` module — run a shell command on the host and check its exit
 * status and/or its output:
 *
 *     ensure.run         = "source /etc/os-release; echo $ID"  (required)
 *     ensure.args        = [ "one", "two" ]      # literal arguments appended
 *                                                # to the command (one element
 *                                                # is one argument, even with
 *                                                # spaces inside)
 *     ensure.exit_status = 0                     # expected status (default 0)
 *                           # or { not = 1 }       # anything but 1
 *                           # or { cond = "< 1" }  # an operator and a value
 *     ensure.output      = "debian"              # exact (trimmed) output
 *                           # or { contains = "deb" }      # substring
 *                           # or { matches = "^debian.*$" } # regular expression
 *
 * Entries are keyed by a unique task name, like every managed resource.
 * The command runs through the host's transport in the defining tasks
 * file's directory (like `file.src`: relative paths resolve next to the
 * file that declares the job); the job passes ("ok", never "changed")
 * when every assertion holds and fails with a descriptive error
 * otherwise.  Ensure jobs are checks by
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

TaskResult runEnsureModule(Val[string] params, TaskContext ctx)
{
    const string name = requireStr(params, "name", "ensure");
    const string runCmd = requireStr(params, "run", "ensure");

    ExitExpectation exitExp = ExitExpectation.equal(0);
    if (auto p = "exit_status" in params)
        exitExp = parseExitStatus(*p,  "ensure '" ~ name ~ "'");

    bool checkOutput;
    OutputExpectation outputExp;
    if (auto p = "output" in params)
    {
        outputExp = parseOutput(*p,  "ensure '" ~ name ~ "'");
        checkOutput = true;
    }

    // `args` appends literal arguments (space-separated) after the
    // command: each element is shell-quoted, so one element stays one
    // argument even when it contains spaces.
    string argTail;
    if (auto p = "args" in params)
    {
        if ((*p).kind != Val.Kind.array_)
            throw new TachyError("ensure '" ~ name ~ "': 'args' must be an array of"
                ~ " strings, not a " ~ (*p).typeName());
        foreach (const ref e; (*p).array_)
        {
            if (e.kind != Val.Kind.string_)
                throw new TachyError("ensure '" ~ name ~ "': 'args' entries must be"
                    ~ " strings, not a " ~ e.typeName());
            argTail ~= " " ~ shQuote(e.str_);
        }
    }

    // The command runs in the defining tasks file's directory, like
    // file.src: relative paths resolve next to the file that declares
    // the job, not against the process cwd (the project root).
    const string cmd = ctx.tasksFileDir.length
        ? "cd " ~ shQuote(ctx.tasksFileDir) ~ " && " ~ runCmd ~ argTail
        : runCmd ~ argTail;

    string[] details;
    details ~= "cmd: " ~ cmd;

    // Checks by nature: ensure jobs run even in check mode.
    auto r = ctx.transport.run(cmd);
    const string got = r.outText.strip;
    const string errOut = r.errText.strip;

    // Both streams travel as the job's verbose payload (`-v` shows
    // them); the failure messages below quote the stdout (or stderr
    // when stdout is empty), since that is what the assertions test.
    if (got.length)
        details ~= "stdout: " ~ excerpt(got);
    if (errOut.length)
        details ~= "stderr: " ~ excerpt(errOut);

    if (!exitExp.matches(r.status))
        throw new TachyError( "ensure '" ~ name ~ "': exit status " ~ text(r.status)
            ~ ", expected " ~ exitExp.describe()
            ~ (got.length ? "; output: '" ~ excerpt(got) ~ "'"
                : errOut.length ? "; stderr: '" ~ excerpt(errOut) ~ "'" : ""));
    if (checkOutput && !outputExp.matches(got))
        throw new TachyError( "ensure '" ~ name ~ "': output '" ~ excerpt(got)
            ~ "' does not satisfy " ~ outputExp.describe());

    TaskResult res;
    res.changed = false;
    res.msg = "exit " ~ text(r.status);
    res.details = details;
    return res;
}

/// Cap an output excerpt so error messages stay readable (shared with
/// the `http` module's body assertions).
string excerpt(string s) @safe pure
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
