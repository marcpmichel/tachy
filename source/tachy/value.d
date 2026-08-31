module tachy.value;

/**
 * Runtime value used throughout tachy: a simplified TOML value.
 *
 * All configuration files (inventory, requirements, tasks) are parsed with the
 * TOML library and immediately converted to `Val` trees, so that the rest of
 * the code never depends on the TOML library's types.  Datetime values are
 * rejected: they have no use in configuration management here.
 */
import toml : parseTOML, TOMLDocument, TOMLValue, TOML_TYPE, TOMLException;

import tachy.errors;

struct Val
{
    enum Kind { string_, integer_, float_, boolean_, array_, table_ }

    Kind kind;

    // Plain fields instead of a union: clarity over 40 wasted bytes.
    string str_;
    long integer_;
    double float_;
    bool boolean_;
    Val[] array_;
    Val[string] table_;

    this(string v) { kind = Kind.string_; str_ = v; }
    this(long v) { kind = Kind.integer_; integer_ = v; }
    this(double v) { kind = Kind.float_; float_ = v; }
    this(bool v) { kind = Kind.boolean_; boolean_ = v; }

    /// How this value substitutes into a `{{ ... }}` template.
    string scalarToString() const
    {
        final switch (kind)
        {
            case Kind.string_: return str_;
            case Kind.integer_: import std.conv : text; return text(integer_);
            case Kind.float_: import std.format : format; return format!"%s"(float_);
            case Kind.boolean_: return boolean_ ? "true" : "false";
            case Kind.array_:
            case Kind.table_:
                throw new TachyError("a " ~ typeName() ~ " value cannot be substituted into a string");
        }
    }

    string typeName() const @safe pure nothrow
    {
        final switch (kind)
        {
            case Kind.string_: return "string";
            case Kind.integer_: return "integer";
            case Kind.float_: return "float";
            case Kind.boolean_: return "boolean";
            case Kind.array_: return "array";
            case Kind.table_: return "table";
        }
    }

    /// Human-readable form for error messages (strings quoted).
    string display() const
    {
        import std.array : appender;
        import std.string : join;
        final switch (kind)
        {
            case Kind.string_: return '"' ~ str_ ~ '"';
            case Kind.integer_:
            case Kind.float_:
            case Kind.boolean_:
                return scalarToString();
            case Kind.array_:
            {
                string[] parts;
                foreach (const ref e; array_)
                    parts ~= e.display();
                return "[" ~ join(parts, ", ") ~ "]";
            }
            case Kind.table_:
            {
                string[] parts;
                foreach (string k, const ref e; table_)
                    parts ~= k ~ " = " ~ e.display();
                return "{ " ~ join(parts, ", ") ~ " }";
            }
        }
    }
}

/// Convert a parsed TOML value into a `Val` tree.
Val toVal(in TOMLValue v)
{
    switch (v.type)
    {
        case TOML_TYPE.STRING: return Val(v.str);
        case TOML_TYPE.INTEGER: return Val(v.integer);
        case TOML_TYPE.FLOAT: return Val(v.floating);
        case TOML_TYPE.TRUE:
        case TOML_TYPE.FALSE: return Val(v.boolean);
        case TOML_TYPE.ARRAY:
        {
            Val r;
            r.kind = Val.Kind.array_;
            foreach (const TOMLValue e; v.array)
                r.array_ ~= toVal(e);
            return r;
        }
        case TOML_TYPE.TABLE:
        {
            Val r;
            r.kind = Val.Kind.table_;
            foreach (string k, const TOMLValue e; v.table)
                r.table_[k] = toVal(e);
            return r;
        }
        default:
            throw new TachyError("datetime values are not supported in tachy configuration files");
    }
}

/// Parse a TOML file into a `Val` table, wrapping errors with the file path.
/// Multi-line inline tables are accepted (see `joinInlineTables`) and so
/// are unquoted path keys in table headers (see `quotePathKeys`).
Val loadToml(string path)
{
    import std.file : readText;
    string src;
    try src = readText(path);
    catch (Exception e)
        throw new TachyError("cannot read '" ~ path ~ "': " ~ e.msg);

    try src = joinInlineTables(src);
    catch (TachyError e)
        throw new TachyError(path ~ ": " ~ e.msg);
    src = quotePathKeys(src);

    TOMLDocument doc;
    try doc = parseTOML(src);
    catch (TOMLException e)
        throw new TachyError(path ~ ": " ~ e.msg);

    Val root;
    root.kind = Val.Kind.table_;
    foreach (string k, const TOMLValue e; doc.table)
        root.table_[k] = toVal(e);
    return root;
}

/// TOML 1.0 forbids newlines inside inline tables, so the multi-line
/// spelling of a keyed entry (`"name" = {` ... `}` across lines) would
/// be rejected by the parser even though it is exactly equivalent to
/// the sub-table spelling.  This pass rewrites newlines (and comments)
/// inside unclosed inline tables into spaces, making the two spellings
/// interchangeable.  It is aware of strings (so braces and `#` inside
/// them are ignored) and reports an unterminated inline table with the
/// line where it was opened.
string joinInlineTables(string src) @safe pure
{
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import std.conv : text;
    auto app = appender!string;
    int depth;
    size_t openedAtLine = 1;
    size_t line = 1;
    size_t i = 0;
    char prev; // last significant character emitted
    while (i < src.length)
    {
        const char c = src[i];

        // Strings are copied verbatim (braces and '#' inside do not count).
        if (c == '"' || c == '\'')
        {
            const size_t start = i;
            i = skipTomlString(src, i);
            app.put(src[start .. i]);
            line += canFind(src[start .. i], '\n') ? 1 : 0;
            prev = src[i - 1];
            continue;
        }

        // Comments run to the end of the line; inside an inline table
        // they disappear along with the newline.
        if (c == '#')
        {
            size_t e = i;
            while (e < src.length && src[e] != '\n')
                e++;
            if (depth == 0)
            {
                app.put(src[i .. e]);
                prev = '#';
            }
            i = e;
            continue;
        }

        if (c == '{')
        {
            if (depth == 0)
                openedAtLine = line;
            depth++;
        }
        else if (c == '}')
            depth--;
        else if (c == '\n' && depth > 0)
        {
            // Join the lines: inline-table pairs are separated by a
            // comma, so insert one only where a separator is needed
            // (after a complete value, before another key — not right
            // after '{', ',', '=' or right before the closing '}').
            line++;
            i++;
            size_t n = i;
            while (n < src.length && (src[n] == ' ' || src[n] == '\t' || src[n] == '\r'))
                n++;
            const bool afterValue = prev && prev != '{' && prev != ',' && prev != '=' && prev != '[';
            const bool beforeKey = n < src.length && src[n] != '}';
            app.put(afterValue && beforeKey ? ", " : " ");
            continue;
        }

        if (c == '\n')
            line++;
        if (c != ' ' && c != '\t' && c != '\r')
            prev = c;
        app.put(c);
        i++;
    }

    if (depth > 0)
        throw new TachyError("unterminated inline table (missing '}') opened around line "
            ~ text(openedAtLine));
    return app.data;
}

/// Return the index just past the TOML string starting at `i`.
private size_t skipTomlString(string src, size_t i) @safe pure
{
    import std.algorithm.searching : startsWith;
    if (src[i .. $].startsWith(`"""`))
    {
        i += 3;
        while (i < src.length)
        {
            if (src[i .. $].startsWith(`"""`))
                return i + 3;
            if (src[i] == '\\')
                i++; // skip the escaped character (including \")
            i++;
        }
        return i; // unterminated: the parser reports it
    }
    if (src[i .. $].startsWith("'''"))
    {
        i += 3;
        while (i < src.length && !src[i .. $].startsWith("'''"))
            i++;
        return i < src.length ? i + 3 : i;
    }

    const char quote = src[i];
    i++;
    while (i < src.length)
    {
        if (quote == '"' && src[i] == '\\')
        {
            i += 2;
            continue;
        }
        if (src[i] == quote)
            return i + 1;
        if (src[i] == '\n')
            return i; // unterminated single-line string: parser reports
        i++;
    }
    return i;
}

/// TOML bare keys may only contain letters, digits, `_` and `-`, so a
/// path target written the natural way — `[files./tmp/myfile.txt]` —
/// is formally invalid.  This pass rewrites table headers, wrapping
/// the key in double quotes: `[files./tmp/myfile.txt]` becomes
/// `[files."/tmp/myfile.txt"]`, exactly equivalent to the documented
/// spellings.  The first segment that is neither a bare key nor
/// already quoted is taken as the start of the key: it and everything
/// up to the end of the header merge into one quoted key, because the
/// dots inside a path belong to the path.  Segments that would need
/// escaping (embedded quotes, backslashes, whitespace, control
/// characters) are left untouched, so genuinely broken headers still
/// get the parser's own error.  Only `[header]` and `[[header]]` lines
/// are considered; comments, strings and everything else are copied
/// verbatim.
string quotePathKeys(string src) @safe pure
{
    import std.array : appender;
    auto app = appender!string;
    size_t i = 0;
    bool lineStart = true; // only whitespace emitted on this line so far
    while (i < src.length)
    {
        const char c = src[i];
        if (c == '\n')
        {
            app.put(c);
            i++;
            lineStart = true;
            continue;
        }
        if (lineStart && (c == ' ' || c == '\t' || c == '\r'))
        {
            app.put(c);
            i++;
            continue;
        }
        if (lineStart && c == '[')
        {
            const size_t openLen = (i + 1 < src.length && src[i + 1] == '[') ? 2 : 1;
            size_t j = i + openLen;
            while (j < src.length && src[j] != ']' && src[j] != '\n')
            {
                if (src[j] == '"' || src[j] == '\'')
                    j = skipTomlString(src, j);
                else
                    j++;
            }
            if (j < src.length && src[j] == ']')
            {
                app.put(src[i .. i + openLen]);
                app.put(quoteHeaderKeys(src[i + openLen .. j]));
                app.put(']');
                i = j + 1;
                lineStart = false;
                continue;
            }
            // No closing ']' on the line: not a table header; the
            // parser reports it.
        }
        if (c == '"' || c == '\'')
        {
            // Strings (including multi-line ones) are copied verbatim;
            // a header-looking line inside them must not be touched.
            const size_t start = i;
            i = skipTomlString(src, i);
            app.put(src[start .. i]);
            lineStart = false;
            continue;
        }
        lineStart = false;
        app.put(c);
        i++;
    }
    return app.data;
}

/// Rewrite one table-header key path: bare and already-quoted segments
/// pass through, the first non-bare unquoted segment starts a single
/// merged, double-quoted key running to the end of the header.
private string quoteHeaderKeys(string content) @safe pure
{
    import std.array : join;
    import std.string : strip;

    // Split on unquoted dots, remembering each segment's raw extent so
    // the merge can take everything from a segment's start to the end.
    size_t[] starts, ends;
    {
        size_t segStart = 0;
        size_t i = 0;
        while (i < content.length)
        {
            if (content[i] == '"' || content[i] == '\'')
            {
                i = skipTomlString(content, i);
                continue;
            }
            if (content[i] == '.')
            {
                starts ~= segStart;
                ends ~= i;
                segStart = i + 1;
            }
            i++;
        }
        starts ~= segStart;
        ends ~= content.length;
    }

    string[] outSegs;
    foreach (size_t k, unused; starts)
    {
        const string seg = content[starts[k] .. ends[k]].strip();
        if (!isQuotableKey(seg) || isBareKey(seg) || isQuotedKey(seg))
        {
            outSegs ~= seg; // bare, quoted, or for the parser to reject
            continue;
        }
        // Path-like key: its dots are part of the path, so merge the
        // rest of the header into one quoted key.
        const string merged = content[starts[k] .. $].strip();
        outSegs ~= isQuotableKey(merged)
            ? '"' ~ merged ~ '"'
            : seg;
        break;
    }
    return outSegs.join(".");
}

private bool isBareKey(string s) @safe pure
{
    if (!s.length)
        return false;
    foreach (char c; s)
        if (!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
                || c >= '0' && c <= '9' || c == '_' || c == '-'))
            return false;
    return true;
}

private bool isQuotedKey(string s) @safe pure
{
    return s.length >= 2 && (s[0] == '"' || s[0] == '\'') && s[$ - 1] == s[0];
}

/// A key that can be embedded in double quotes without escaping:
/// non-empty, no quotes, backslashes, whitespace or control characters
/// (internal whitespace is never key intent — quote it yourself).
private bool isQuotableKey(string s) @safe pure
{
    if (!s.length)
        return false;
    foreach (char c; s)
        if (c == '"' || c == '\\' || c == ' ' || c == '\t' || c < 0x20 || c == 0x7F)
            return false;
    return true;
}

// ---------------------------------------------------------------------------
// Validated accessors used by the configuration parsers.
// ---------------------------------------------------------------------------

/// Reject keys not in `allowed` (typo detection).
void checkKeys(in Val[string] t, string[] allowed, string context)
{
    import std.algorithm.searching : canFind;
    import std.string : join;

    foreach (string k, const Val v; t)
    {
        if (!canFind(allowed, k))
            throw new TachyError(context ~ ": unknown key '" ~ k ~ "' (allowed: " ~ allowed.join(", ") ~ ")");
    }
}

/// Fresh copy of a table.  `Val` trees are treated as immutable after
/// construction; this only rebuilds the top-level associative array.
Val[string] dupTable(in Val[string] t) @trusted pure
{
    Val[string] r;
    foreach (string k, const Val v; t)
        r[k] = cast(Val) v;
    return r;
}

/// Sub-table `t[key]` or an empty table when absent (must be a table if present).
Val[string] optTable(in Val[string] t, string key, string context)
{
    auto pv = key in t;
    if (pv is null)
        return null;
    if ((*pv).kind != Val.Kind.table_)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be a table, not a " ~ (*pv).typeName());
    return dupTable((*pv).table_);
}

string optString(in Val[string] t, string key, string context, string def = null)
{
    auto pv = key in t;
    if (pv is null)
        return def;
    if ((*pv).kind != Val.Kind.string_)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be a string, not a " ~ (*pv).typeName());
    return (*pv).str_;
}

long optInt(in Val[string] t, string key, string context, long def = 0)
{
    auto pv = key in t;
    if (pv is null)
        return def;
    if ((*pv).kind != Val.Kind.integer_)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be an integer, not a " ~ (*pv).typeName());
    return (*pv).integer_;
}

string[] optStringArray(in Val[string] t, string key, string context)
{
    import std.string : join;
    auto pv = key in t;
    if (pv is null)
        return null;
    if ((*pv).kind != Val.Kind.array_)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be an array of strings, not a " ~ (*pv).typeName());
    string[] r;
    foreach (const e; (*pv).array_)
    {
        if (e.kind != Val.Kind.string_)
            throw new TachyError(context ~ ": '" ~ key ~ "' must contain only strings (got " ~ e.display() ~ ")");
        r ~= e.str_;
    }
    return r;
}

version (unittest)
{
    private Val parseVal(string src)
    {
        import tachy.errors;
        auto doc = parseTOML(src);
        Val r;
        r.kind = Val.Kind.table_;
        foreach (string k, const TOMLValue e; doc.table)
            r.table_[k] = toVal(e);
        return r;
    }

    unittest
    {
        auto v = parseVal("a = \"x\"\nb = 1\nc = 1.5\nd = true\ne = [1, 2]\n[f]\ng = \"h\"");
        assert(v.table_["a"].kind == Val.Kind.string_ && v.table_["a"].str_ == "x");
        assert(v.table_["b"].integer_ == 1);
        assert(v.table_["c"].kind == Val.Kind.float_);
        assert(v.table_["d"].boolean_);
        assert(v.table_["e"].array_.length == 2);
        assert(v.table_["e"].array_[1].integer_ == 2);
        assert(v.table_["f"].table_["g"].str_ == "h");
        assert(v.table_["b"].scalarToString() == "1");
        assert(v.table_["d"].scalarToString() == "true");
    }

    unittest
    {
        import std.exception : assertThrown;
        // Datetime values are rejected during TOML → Val conversion.
        assertThrown!(TachyError)(parseVal("when = 1979-05-27T07:32:00Z"));
    }

    unittest // joinInlineTables: multi-line inline tables parse like sub-tables
    {
        import std.algorithm.searching : canFind;
        import std.exception : assertThrown;

        // The two spellings must be exactly equivalent.
        const string inline_ = `
[execute]
"verify_os_is_debian" = {
  run = "grep ID /etc/os-release"
  exit_status = 0
  output = { contains = "debian" }
}`;
        const string subtable = `
[execute."verify_os_is_debian"]
run = "grep ID /etc/os-release"
exit_status = 0
output = { contains = "debian" }`;

        auto a = parseVal(joinInlineTables(inline_));
        auto b = parseVal(subtable);
        auto ea = a.table_["execute"].table_["verify_os_is_debian"].table_;
        auto eb = b.table_["execute"].table_["verify_os_is_debian"].table_;
        assert(ea["run"].str_ == eb["run"].str_);
        assert(ea["exit_status"].integer_ == 0);
        assert(ea["output"].table_["contains"].str_ == "debian");

        // Comments inside the inline table disappear with the newline.
        auto c = parseVal(joinInlineTables("k = {\n  a = 1 # note\n}\n"));
        assert(c.table_["k"].table_["a"].integer_ == 1);

        // Braces and '#' inside strings do not count; '#' at top level stays.
        auto d = parseVal(joinInlineTables(
            `s = "brace { and # inside" # trailing`
            ~ "\n" ~ `t = { a = "}" }` ~ "\n"));
        assert(d.table_["s"].str_ == "brace { and # inside");
        assert(d.table_["t"].table_["a"].str_ == "}");

        // Newlines in top-level (multi-line) arrays are preserved.
        auto e = parseVal(joinInlineTables("list = [\n  1,\n  2,\n]\n"));
        assert(e.table_["list"].array_.length == 2);

        // Multi-line basic strings pass through untouched.
        auto f = parseVal(joinInlineTables("m = \"\"\"\nline\n\"\"\"\n"));
        assert(f.table_["m"].str_ == "line\n");

        // Unterminated inline table: clear error with the opening line.
        string msg;
        try
        {
            joinInlineTables("a = 1\nk = {\n  x = 1\n");
            assert(false, "expected TachyError");
        }
        catch (TachyError err)
            msg = err.msg;
        assert(canFind(msg, "unterminated inline table"), msg);
        assert(canFind(msg, "line 2"), msg);
    }

    unittest // quotePathKeys: unquoted path keys in table headers
    {
        import std.algorithm.searching : canFind;
        import std.exception : assertThrown;

        // The user-facing spelling parses exactly like the quoted one.
        auto v = parseVal(quotePathKeys(`
[vars]
x = 1

[files./tmp/some_secret.txt]
template = "some_secret.tmpl"
`));
        assert(v.table_["vars"].table_["x"].integer_ == 1);
        assert(v.table_["files"].table_["/tmp/some_secret.txt"]
            .table_["template"].str_ == "some_secret.tmpl");

        // Dots inside the path belong to the path, not the key path.
        auto w = parseVal(quotePathKeys("[files./etc/nginx.conf]\n"));
        assert("/etc/nginx.conf" in w.table_["files"].table_);

        // Already-quoted keys and bare keys are untouched (and still
        // nest the standard way).
        auto q = parseVal(quotePathKeys(
            `[files."/tmp/quoted.txt"]` ~ "\n" ~ "[hosts.web1.vars]\n"));
        assert("/tmp/quoted.txt" in q.table_["files"].table_);
        assert("vars" in q.table_["hosts"].table_["web1"].table_);

        // Array-of-tables headers rewrite the same way and keep parsing
        // identically to the quoted spelling (tachy rejects array
        // tables later anyway). Headers with surrounding spaces too.
        assert(quotePathKeys("[[files./tmp/x]]\n") == `[[files."/tmp/x"]]` ~ "\n");
        assert(parseVal(`[[files."/tmp/x"]]`).table_["files"].kind
            == parseVal(quotePathKeys("[[files./tmp/x]]")).table_["files"].kind);
        assert(quotePathKeys("  [files./tmp/x]  \n") == `  [files."/tmp/x"]  ` ~ "\n");

        // Trailing comments survive; comment-looking headers do not
        // rewrite; quoted segments with brackets do not confuse the
        // header-end scan.
        assert(quotePathKeys("[files./tmp/x] # c\n") == `[files."/tmp/x"] # c` ~ "\n");
        assert(quotePathKeys("# [files./tmp/x]\n") == "# [files./tmp/x]\n");
        auto qb = parseVal(quotePathKeys(`[files."weird]key"]` ~ "\n"));
        assert("weird]key" in qb.table_["files"].table_);

        // Header-looking lines inside strings and values stay verbatim.
        auto s = parseVal(quotePathKeys(
            `s = "[files./tmp/x]"` ~ "\n" ~ "m = \"\"\"\n[files./tmp/y]\n\"\"\"\n"));
        assert(s.table_["s"].str_ == "[files./tmp/x]");
        assert(s.table_["m"].str_ == "[files./tmp/y]\n");

        // Genuinely invalid headers still fail with the parser's error.
        assertThrown!(Exception)(parseVal(quotePathKeys("[files.a b./x]\n")));
    }
    unittest
    {
        auto v = parseVal("a = 1\nbad = 2");
        import std.exception : assertThrown, assertNotThrown;
        assertNotThrown(checkKeys(v.table_, ["a", "bad"], "ctx"));
        assertThrown!(TachyError)(checkKeys(v.table_, ["a"], "ctx"));
        assert(optString(v.table_, "missing", "ctx", "dflt") == "dflt");
        assertThrown!(TachyError)(optString(v.table_, "a", "ctx", "dflt")); // integer, not string
    }
}
