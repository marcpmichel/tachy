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
Val loadToml(string path)
{
    import std.file : readText;
    string src;
    try src = readText(path);
    catch (Exception e)
        throw new TachyError("cannot read '" ~ path ~ "': " ~ e.msg);

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
