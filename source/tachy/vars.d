module tachy.vars;

/**
 * Variable handling: deep merging of variable scopes and `{{ expr }}`
 * template rendering.
 *
 * Precedence (lowest to highest), mirroring the intuitive Ansible order:
 *   global `[vars]`  <  group vars (parents before children)  <  host vars
 *   <  requirement vars  <  include vars
 *
 * Rendering is lazy: variables may reference other variables; cycles are
 * detected and reported with the full reference chain.
 */
import std.algorithm.searching : canFind;
import std.array : appender, empty;
import std.string : indexOf, strip;

import tachy.errors;
import tachy.value;

/// Deep merge: `over` wins per leaf key; nested tables merge recursively.
/// Arrays and scalars replace.  Returns a fresh tree; inputs are untouched.
Val[string] deepMerge(in Val[string] base, in Val[string] over) @trusted pure
{
    Val[string] r;
    foreach (string k, const Val v; base)
        r[k] = cast(Val) v;
    foreach (string k, const Val v; over)
    {
        auto cur = k in r;
        if (cur !is null && (*cur).kind == Val.Kind.table_ && v.kind == Val.Kind.table_)
            (*cur).table_ = deepMerge((*cur).table_, v.table_);
        else
            r[k] = cast(Val) v;
    }
    return r;
}

/// Look up a dotted path like `nginx.port` in nested variable tables.
const(Val)* lookupPath(in Val[string] vars, string dottedPath) @safe pure
{
    import std.algorithm.iteration : splitter;
    const(Val)* cur;
    bool first = true;
    foreach (part; splitter(dottedPath, '.'))
    {
        if (first)
        {
            cur = part in vars;
            first = false;
        }
        else
        {
            if (cur is null || (*cur).kind != Val.Kind.table_)
                return null;
            cur = part in (*cur).table_;
        }
        if (cur is null)
            return null;
    }
    return cur;
}

/// Render `{{ expr }}` templates in `input` using `vars`.
string renderTemplate(string input, in Val[string] vars, string[] active = null)
{
    if (!canFind(input, "{{"))
        return input;

    auto app = appender!string;
    size_t i = 0;
    while (i < input.length)
    {
        const ptrdiff_t rel = indexOf(input[i .. $], "{{");
        if (rel < 0)
        {
            app.put(input[i .. $]);
            break;
        }
        const size_t open = i + cast(size_t) rel;
        app.put(input[i .. open]);

        const ptrdiff_t relClose = indexOf(input[open + 2 .. $], "}}");
        if (relClose < 0)
            throw new TachyError("unterminated '{{' in template: " ~ input);
        const size_t close = open + 2 + cast(size_t) relClose;

        const string expr = strip(input[open + 2 .. close]);
        if (expr.empty)
            throw new TachyError("empty '{{}}' template in: " ~ input);
        if (canFind(expr, "{{"))
            throw new TachyError("malformed template (nested '{{') in: " ~ input);

        app.put(resolveExpr(expr, vars, active));
        i = close + 2;
    }
    return app.data;
}

private string resolveExpr(string expr, in Val[string] vars, string[] active)
{
    import std.string : join;
    if (canFind(active, expr))
        throw new TachyError("variable cycle detected: " ~ active.join(" -> ") ~ " -> " ~ expr);

    auto v = lookupPath(vars, expr);
    if (v is null)
        throw new TachyError("undefined variable '" ~ expr ~ "'");

    final switch ((*v).kind)
    {
        case Val.Kind.string_:
            return renderTemplate((*v).str_, vars, active ~ expr);
        case Val.Kind.integer_:
        case Val.Kind.float_:
        case Val.Kind.boolean_:
            return (*v).scalarToString();
        case Val.Kind.array_:
        case Val.Kind.table_:
            throw new TachyError("variable '" ~ expr ~ "' is an " ~ (*v).typeName()
                ~ " and cannot be substituted into a string");
    }
}

/// Deep-copy `params`, rendering every string against `vars`.
Val[string] renderParams(in Val[string] params, in Val[string] vars) @trusted
{
    Val[string] r;
    foreach (string k, const Val v; params)
        r[k] = renderVal(v, vars);
    return r;
}

private Val renderVal(in Val v, in Val[string] vars) @trusted
{
    final switch (v.kind)
    {
        case Val.Kind.string_:
            return Val(renderTemplate(v.str_, vars));
        case Val.Kind.integer_:
        case Val.Kind.float_:
        case Val.Kind.boolean_:
            return cast(Val) v;
        case Val.Kind.array_:
        {
            Val r;
            r.kind = Val.Kind.array_;
            foreach (const e; v.array_)
                r.array_ ~= renderVal(e, vars);
            return r;
        }
        case Val.Kind.table_:
        {
            Val r;
            r.kind = Val.Kind.table_;
            foreach (string k, const e; v.table_)
                r.table_[k] = renderVal(e, vars);
            return r;
        }
    }
}

// ---------------------------------------------------------------------------

version (unittest) private
{
    Val[string] table(string k, Val v)
    {
        Val[string] t;
        t[k] = v;
        return t;
    }

    Val tbl(Val[string] t)
    {
        Val v;
        v.kind = Val.Kind.table_;
        v.table_ = t;
        return v;
    }
}

unittest // deepMerge precedence and nested table merge
{
    Val[string] base;
    base["a"] = Val("base-a");
    base["nested"] = tbl(table("x", Val(1L)));

    Val[string] over;
    over["b"] = Val("over-b");
    over["nested"] = tbl(table("y", Val(2L)));

    auto m = deepMerge(base, over);
    assert(m["a"].str_ == "base-a");
    assert(m["b"].str_ == "over-b");
    assert(m["nested"].table_["x"].integer_ == 1);
    assert(m["nested"].table_["y"].integer_ == 2);

    // scalar overrides scalar
    auto m2 = deepMerge(base, table("a", Val("over-a")));
    assert(m2["a"].str_ == "over-a");
}

unittest // renderTemplate basics
{
    Val[string] vars;
    vars["name"] = Val("web1");
    vars["port"] = Val(8080L);
    vars["tls"] = Val(true);
    vars["ratio"] = Val(1.5);
    vars["nginx"] = tbl(table("worker", Val(4L)));

    assert(renderTemplate("plain", vars) == "plain");
    assert(renderTemplate("{{ name }}", vars) == "web1");
    assert(renderTemplate("host={{name}}:{{port}}", vars) == "host=web1:8080");
    assert(renderTemplate("tls={{ tls }}", vars) == "tls=true");
    assert(renderTemplate("r={{ ratio }}", vars) == "r=1.5");
    assert(renderTemplate("{{ nginx.worker }} workers", vars) == "4 workers");
}

unittest // var referencing var, and cycle detection
{
    Val[string] vars;
    vars["a"] = Val("{{ b }}-suffix");
    vars["b"] = Val("base");

    assert(renderTemplate("{{ a }}", vars) == "base-suffix");

    Val[string] cyclic;
    cyclic["x"] = Val("{{ y }}");
    cyclic["y"] = Val("{{ x }}");
    import std.exception : assertThrown;
    assertThrown!(TachyError)(renderTemplate("{{ x }}", cyclic));
}

unittest // undefined variable and unterminated template
{
    import std.exception : assertThrown;
    Val[string] vars;
    vars["known"] = Val("v");
    assertThrown!(TachyError)(renderTemplate("{{ unknown }}", vars));
    assertThrown!(TachyError)(renderTemplate("{{ known ", vars));
    assertThrown!(TachyError)(renderTemplate("{{}}", vars));
}

unittest // renderParams deep rendering
{
    Val[string] params;
    params["path"] = Val("/srv/{{ site }}");
    params["opts"] = tbl(table("title", Val("{{ site }} page")));
    params["port"] = Val(80L);

    Val[string] vars;
    vars["site"] = Val("example");

    auto r = renderParams(params, vars);
    assert(r["path"].str_ == "/srv/example");
    assert(r["opts"].table_["title"].str_ == "example page");
    assert(r["port"].integer_ == 80);
}
