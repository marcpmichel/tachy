module tachy.value;

/**
 * Runtime value used throughout tachy: a simplified structured-data value.
 *
 * Configuration files (inventory, tasks, settings) are written in Pravic —
 * tachy's own configuration language, specified in `LANGUAGE.md` — and
 * parsed by `tachy.parser` into `Val` trees plus an ordered statement
 * list, so the rest of the code never sees the parser's own types.
 * Datetime values do not exist in Pravic; there is no use for them in
 * configuration management.
 *
 * A parsed file (`PracticDoc`) is a sequence of `PracticStmt`s in source
 * order — the canonical directive `kind`, the entry `key`, the entry's
 * `Val` value and the 1-based source `line` for error context.  The
 * validated accessors below are how the configuration loaders read
 * parameter tables.
 */
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

    this(string v) @safe pure nothrow { kind = Kind.string_; str_ = v; }
    this(long v) @safe pure nothrow { kind = Kind.integer_; integer_ = v; }
    this(double v) @safe pure nothrow { kind = Kind.float_; float_ = v; }
    this(bool v) @safe pure nothrow { kind = Kind.boolean_; boolean_ = v; }

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

/// One top-level statement, in source order.  Group-form blocks expand
/// to one statement per entry (the entry's line is kept).
struct PracticStmt
{
    string kind;   // canonical directive: "vars", "files", ..., "apply", "ensure", "compose", "import", "hosts", "imports", "webui"
    string key;    // the entry's key (target, variable, path, ...)
    Val value;     // the entry's value: parameter table (block) or scalar (`= value`)
    size_t line;   // 1-based source line of the entry, for error context
}

/// A parsed Pravic file: its statements, in source order.
struct PracticDoc
{
    PracticStmt[] stmts;
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

