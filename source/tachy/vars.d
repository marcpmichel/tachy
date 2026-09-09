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
/// Age decryption configuration for `{ age = ... }` variable markers:
/// whether they are allowed here, and an explicit identity path
/// (`--identity`).  Only inventory vars enable them — decryption must
/// happen on the controller, because the identity must never travel
/// inside a bundle.
struct AgeConfig
{
    bool enabled;
    string identity; // explicit identity file, or null for auto-detection
}

/// An age identity: a file path (age key or ssh private key — age
/// accepts the latter natively), or raw key material (fed to age on
/// stdin, never written to disk).
struct AgeIdentity
{
    string path;
    string material;

    static AgeIdentity fromPath(string p)
    {
        AgeIdentity id;
        id.path = p;
        return id;
    }

    static AgeIdentity fromMaterial(string m)
    {
        AgeIdentity id;
        id.material = m;
        return id;
    }
}

/// Decryption hook — the default runs the age binary; unittests replace
/// it so the suite does not depend on age being installed.
string delegate(string agePath, in AgeIdentity identity, string where) ageDecrypt =
    (string agePath, in AgeIdentity identity, string where) =>
        defaultAgeDecrypt(agePath, identity, where);

/// Resolve `{ env = "NAME", default = "...", from = "..." }` and
/// `{ age = "file.age" }` variable entries, replacing them with their
/// value.  Without `from` an env marker reads the environment of the
/// current process; with `from` it reads that dotenv file instead;
/// an age marker decrypts the named file (paths relative to the file
/// declaring the vars).  Called when a `[vars]` table is consumed:
/// inventory tables resolve on the controller (age markers enabled),
/// tasks-file tables in the environment of the process that loads them
/// (the host, in bundled mode — age markers are rejected there).
/// Nested tables are walked; scalars and arrays pass through.  A marker
/// naming a variable that has no value and no default is a hard error;
/// a set-but-empty value, from the environment or from a dotenv file,
/// resolves to the empty string (the default only covers a missing
/// value).
Val[string] resolveEnvVars(in Val[string] vars, string context,
    in AgeConfig age = AgeConfig.init) @trusted
{
    Val[string] r;
    string[string][string] dotenvCache; // resolved path -> parsed entries
    foreach (string k, const Val v; vars)
        r[k] = resolveEnvVal(v, context ~ ": vars." ~ k, context, dotenvCache, age);
    return r;
}

private Val resolveEnvVal(in Val v, string where, string context,
    ref string[string][string] dotenvCache, in AgeConfig age) @trusted
{
    import std.process : environment;
    if (v.kind != Val.Kind.table_)
        return cast(Val) v;

    // An age marker is a table of exactly { age = "path" } — it cannot
    // combine with the env/default/from family (it is self-contained:
    // a failed decryption is an error, not an absent value).
    if (auto a = "age" in v.table_)
    {
        if (v.table_.length != 1)
            throw new TachyError(where
                ~ ": 'age' cannot be combined with 'env', 'default' or 'from'");
        if ((*a).kind != Val.Kind.string_)
            throw new TachyError(where ~ ": 'age' must be a string, not a "
                ~ (*a).typeName());
        if (!age.enabled)
            throw new TachyError(where ~ ": 'age' markers are only supported"
                ~ " in inventory [vars] — they are decrypted on the controller"
                ~ " (tasks-file [vars] resolve on the host in bundled runs)");
        const string agePath = resolveDotenvPath((*a).str_, context);
        const AgeIdentity identity = resolveAgeIdentity(age.identity, where);
        string value;
        try
            value = ageDecrypt(agePath, identity, where);
        catch (TachyError e)
            throw new TachyError(where ~ ": " ~ e.msg);
        try
        {
            import std.utf : validate;
            validate(value);
        }
        catch (Exception)
            throw new TachyError(where ~ ": decrypted content of '" ~ agePath
                ~ "' is not valid UTF-8 (binary secrets are not supported"
                ~ " in variables)");
        // Secret files are usually created with one trailing newline;
        // strip it (and a CR before it) so templates see the secret.
        if (value.length && value[$ - 1] == '\n')
            value = value[0 .. $ - 1];
        if (value.length && value[$ - 1] == '\r')
            value = value[0 .. $ - 1];
        return Val(value);
    }

    // An env marker is a table whose keys are "env" plus any of
    // "default" and "from".  Tables with other keys are plain nested
    // tables.
    auto e = "env" in v.table_;
    bool marker = e !is null;
    foreach (string k, const Val _; v.table_)
        if (k != "env" && k != "default" && k != "from")
            marker = false;
    if (!marker)
    {
        Val r;
        r.kind = Val.Kind.table_;
        foreach (string k, const Val entry; v.table_)
            r.table_[k] = resolveEnvVal(entry, where ~ "." ~ k, context,
                dotenvCache, age);
        return r;
    }

    auto d = "default" in v.table_;
    auto from = "from" in v.table_;
    if ((*e).kind != Val.Kind.string_)
        throw new TachyError(where ~ ": 'env' must be a string, not a "
            ~ (*e).typeName());
    if (d !is null && (*d).kind != Val.Kind.string_)
        throw new TachyError(where ~ ": 'default' must be a string, not a "
            ~ (*d).typeName());
    if (from !is null && (*from).kind != Val.Kind.string_)
        throw new TachyError(where ~ ": 'from' must be a string, not a "
            ~ (*from).typeName());

    string value;
    bool have;
    string missing;
    if (from !is null)
    {
        const string path = resolveDotenvPath((*from).str_, context);
        have = dotenvLookup(path, (*e).str_, where, dotenvCache, value);
        missing = where ~ ": environment variable '" ~ (*e).str_
            ~ "' is not set in '" ~ path ~ "'";
    }
    else
    {
        value = environment.get((*e).str_);
        have = value !is null;
        missing = where ~ ": environment variable '" ~ (*e).str_ ~ "' is not set";
    }
    if (have)
        return Val(value);
    if (d !is null)
        return Val((*d).str_);
    throw new TachyError(missing);
}

/// Resolve a `from` path like any other tasks-file path: absolute
/// paths pass through, relative ones are relative to the directory of
/// the file declaring the `[vars]` table.
private string resolveDotenvPath(string from, string context) @trusted
{
    import std.path : buildPath, dirName, isAbsolute;
    return isAbsolute(from) ? from : buildPath(dirName(context), from);
}

/// Look up `key` in the dotenv file at `path`; the file is parsed at
/// most once per resolveEnvVars call.  Returns false when the file
/// does not define the key; `value` receives the entry otherwise.
private bool dotenvLookup(string path, string key, string where,
    ref string[string][string] dotenvCache, out string value) @trusted
{
    if (auto cached = path in dotenvCache)
    {
        if (auto hit = key in *cached)
        {
            value = *hit;
            return true;
        }
        return false;
    }
    import std.file : readText;
    string content;
    try
        content = readText(path);
    catch (Exception e)
        throw new TachyError(where ~ ": cannot read dotenv file '" ~ path
            ~ "': " ~ e.msg);
    string[string] entries = parseDotenv(content, where, path);
    dotenvCache[path] = entries;
    if (auto hit = key in entries)
    {

        value = *hit;
        return true;
    }
    return false;
}

/// Identity for `{ age = ... }` markers, in order: the explicit
/// `--identity` path, then the AGE_IDENTITY environment variable (an
/// existing file path, or raw key material), then the controller's
/// default ssh key — age accepts ed25519 ssh private keys natively.
/// Anything else is an error naming the three options.
private AgeIdentity resolveAgeIdentity(string explicitIdentity, string where) @trusted
{
    import std.file : exists;
    import std.path : buildPath;
    import std.process : environment;
    if (explicitIdentity.length)
    {
        if (!exists(explicitIdentity))
            throw new TachyError(where ~ ": age identity '" ~ explicitIdentity
                ~ "' does not exist");
        return AgeIdentity.fromPath(explicitIdentity);
    }
    const string envId = environment.get("AGE_IDENTITY");
    if (envId.length)
    {
        if (exists(envId))
            return AgeIdentity.fromPath(envId);
        if (isKeyMaterial(envId))
            return AgeIdentity.fromMaterial(envId);
        throw new TachyError(where ~ ": AGE_IDENTITY '" ~ envId
            ~ "' is neither an existing file (relative to the current"
            ~ " directory) nor age key material (AGE-SECRET-KEY-1... or"
            ~ " an ssh private key block)");
    }
    const string home = environment.get("HOME");
    if (home.length)
    {
        const string sshKey = buildPath(home, ".ssh", "id_ed25519");
        if (exists(sshKey))
            return AgeIdentity.fromPath(sshKey); // age accepts ssh keys natively
    }
    throw new TachyError(where ~ ": no age identity available: pass"
        ~ " --identity PATH, set AGE_IDENTITY to a path or key material,"
        ~ " or provide ~/.ssh/id_ed25519");
}

/// Recognize raw age key material: an `AGE-SECRET-KEY-1...` secret key
/// or an ssh private key block.  Anything else that is not an existing
/// path is a configuration error, not material to hand to age.
private bool isKeyMaterial(string s) @safe pure
{
    import std.algorithm.searching : canFind, startsWith;
    return s.startsWith("AGE-SECRET-KEY-1") || canFind(s, "PRIVATE KEY");
}

/// Run `age --decrypt` on `agePath`.  Key material (AGE_IDENTITY) is
/// fed to `/dev/stdin` — it is never written to disk.  stderr is
/// drained after stdout (age's error output is one short line).
private string defaultAgeDecrypt(string agePath, in AgeIdentity identity,
    string where) @trusted
{
    import std.array : appender;
    import std.conv : text;
    import std.process : Redirect, pipeProcess, wait;
    import std.string : strip;

    const string idArg = identity.path.length ? identity.path : "/dev/stdin";
    auto p = pipeProcess(["age", "--decrypt", "-i", idArg, agePath],
        Redirect.stdin | Redirect.stdout | Redirect.stderr);
    if (identity.material.length)
    {
        p.stdin.rawWrite(cast(const(ubyte)[]) identity.material);
        p.stdin.flush();
    }
    p.stdin.close(); // age sees EOF on the identity stream

    auto outApp = appender!(ubyte[]);
    auto buf = new ubyte[65536];
    for (;;)
    {
        auto n = p.stdout.rawRead(buf).length;
        if (n == 0) break;
        outApp.put(buf[0 .. n]);
    }
    string errText;
    {
        auto ebuf = new ubyte[4096];
        for (;;)
        {
            auto n = p.stderr.rawRead(ebuf).length;
            if (n == 0) break;
            errText ~= cast(string) ebuf[0 .. n];
        }
    }
    const int status = wait(p.pid);
    if (status != 0)
    {
        auto m = errText.strip;
        if (!m.length)
            m = "age exit status " ~ text(status);
        throw new TachyError("cannot decrypt '" ~ agePath ~ "': " ~ m);
    }
    return cast(string) outApp.data;
}

/// Parse dotenv content: `KEY=VALUE` lines, `# comments`, blank lines,
/// an optional `export ` prefix and single-line quoted values.
/// Whitespace around keys and unquoted values is trimmed; double
/// quotes honour the \n \t \r \f \b \" \' \\ escapes while single
/// quotes are literal; a `#` at the start of the value or after
/// whitespace ends an unquoted value; an empty value is a value;
/// later keys win.  Anything else is an error naming file and line.
private string[string] parseDotenv(string content, string where, string path)
    @trusted
{
    import std.conv : text;
    import std.string : indexOf, splitLines, strip;

    string[string] entries;
    foreach (size_t i, string raw; content.splitLines)
    {
        const string origin = where ~ ": " ~ path ~ ":" ~ text(i + 1) ~ ": ";
        string line = raw.strip();
        if (!line.length || line[0] == '#')
            continue;
        if (line.length > 7 && line[0 .. 7] == "export ")
            line = line[7 .. $].strip();
        const ptrdiff_t eq = indexOf(line, '=');
        if (eq <= 0)
            throw new TachyError(origin ~ "expected KEY=VALUE");
        const string key = line[0 .. eq].strip();
        if (!key.length || canFind(key, ' ') || canFind(key, '\t'))
            throw new TachyError(origin ~ "invalid key '" ~ key ~ "'");
        entries[key] = parseDotenvValue(line[eq + 1 .. $], origin);
    }
    return entries;
}

private string parseDotenvValue(string rest, string origin) @trusted
{
    import std.string : strip, stripLeft;
    const string v = rest.stripLeft();

    // Single-line quoted values: double quotes process escapes, single
    // quotes are literal (backslash included).  After the closing
    // quote only whitespace or a comment may follow.
    if (v.length && (v[0] == '"' || v[0] == '\''))
    {
        const char q = v[0];
        string r;
        for (size_t j = 1; j < v.length; ++j)
        {
            const char c = v[j];
            if (q == '"' && c == '\\' && j + 1 < v.length)
            {
                switch (v[j + 1])
                {
                    case 'n': r ~= '\n'; break;
                    case 't': r ~= '\t'; break;
                    case 'r': r ~= '\r'; break;
                    case 'f': r ~= '\f'; break;
                    case 'b': r ~= '\b'; break;
                    case '"': r ~= '"'; break;
                    case '\'': r ~= '\''; break;
                    case '\\': r ~= '\\'; break;
                    default:
                        throw new TachyError(origin ~ "unknown escape '\\"
                            ~ v[j + 1] ~ "' in quoted value");
                }
                ++j;
                continue;
            }
            if (c == q)
            {
                const string trailing = v[j + 1 .. $].strip();
                if (trailing.length && trailing[0] != '#')
                    throw new TachyError(origin
                        ~ "unexpected content after quoted value");
                return r;
            }
            r ~= c;
        }
        throw new TachyError(origin ~ "unterminated quoted value");
    }

    // Unquoted: a '#' at the start or after whitespace starts a
    // comment; otherwise it is part of the value.
    foreach (size_t j; 0 .. v.length)
        if (v[j] == '#' && (j == 0 || v[j - 1] == ' ' || v[j - 1] == '\t'))
            return v[0 .. j].strip();
    return v.strip();
}

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

unittest // resolveEnvVars: { env = "NAME" } markers
{
    import std.exception : assertThrown;
    import std.process : environment;

    environment["TACHY_UT_ENV"] = "from-env";
    environment["TACHY_UT_ENV_EMPTY"] = "";

    Val[string] vars;
    vars["plain"] = Val("literal");
    vars["something"] = tbl(table("env", Val("TACHY_UT_ENV")));
    vars["empty"] = tbl(table("env", Val("TACHY_UT_ENV_EMPTY")));
    vars["nested"] = tbl(table("inner", tbl(table("env", Val("TACHY_UT_ENV")))));
    Val arr;
    arr.kind = Val.Kind.array_;
    arr.array_ ~= tbl(table("env", Val("TACHY_UT_ENV"))); // arrays pass through
    vars["list"] = arr;

    auto r = resolveEnvVars(vars, "ctx.toml");
    assert(r["plain"].str_ == "literal");
    assert(r["something"].str_ == "from-env");
    assert(r["empty"].kind == Val.Kind.string_ && r["empty"].str_.length == 0);
    assert(r["nested"].table_["inner"].str_ == "from-env");
    assert(r["list"].kind == Val.Kind.array_); // untouched inside arrays

    // unset variable: hard error naming context and variable
    Val[string] missing;
    missing["x"] = tbl(table("env", Val("TACHY_UT_ENV_NOPE")));
    string msg;
    try
    {
        resolveEnvVars(missing, "ctx.toml");
        assert(false, "expected TachyError");
    }
    catch (TachyError err)
        msg = err.msg;
    assert(canFind(msg, "ctx.toml: vars.x"));
    assert(canFind(msg, "TACHY_UT_ENV_NOPE"));

    // default: used only when the variable is unset
    Val[string] dflt;
    {
        Val marker;
        marker.kind = Val.Kind.table_;
        marker.table_["env"] = Val("TACHY_UT_ENV");          // set
        marker.table_["default"] = Val("fallback");
        dflt["set"] = marker;
    }
    {
        Val marker;
        marker.kind = Val.Kind.table_;
        marker.table_["env"] = Val("TACHY_UT_ENV_NOPE");     // unset
        marker.table_["default"] = Val("fallback");
        dflt["unset"] = marker;
    }
    {
        Val marker;
        marker.kind = Val.Kind.table_;
        marker.table_["env"] = Val("TACHY_UT_ENV_EMPTY");    // set, empty
        marker.table_["default"] = Val("fallback");
        dflt["empty"] = marker;
    }
    auto rd = resolveEnvVars(dflt, "ctx.toml");
    assert(rd["set"].str_ == "from-env");       // value wins over default
    assert(rd["unset"].str_ == "fallback");     // default covers unset only
    assert(rd["empty"].str_.length == 0);       // empty value is a value

    // non-string default is a type error even when env is set
    {
        Val marker;
        marker.kind = Val.Kind.table_;
        marker.table_["env"] = Val("TACHY_UT_ENV");
        marker.table_["default"] = Val(7L);
        Val[string] bad;
        bad["x"] = marker;
        string dmsg;
        try
        {
            resolveEnvVars(bad, "ctx.toml");
            assert(false, "expected TachyError");
        }
        catch (TachyError err)
            dmsg = err.msg;
        assert(canFind(dmsg, "'default' must be a string"));
    }

    // a table with env plus unrelated keys is a plain nested table
    {
        Val plain;
        plain.kind = Val.Kind.table_;
        plain.table_["env"] = Val("prod");
        plain.table_["port"] = Val(80L);
        Val[string] mixed;
        mixed["app"] = plain;
        auto rm = resolveEnvVars(mixed, "ctx.toml");
        assert(rm["app"].kind == Val.Kind.table_);
        assert(rm["app"].table_["env"].str_ == "prod");
        assert(rm["app"].table_["port"].integer_ == 80);
    }

    // non-string env key type
    Val[string] badtype;
    badtype["x"] = tbl(table("env", Val(1L)));
    assertThrown!(TachyError)(resolveEnvVars(badtype, "ctx.toml"));
}

unittest // resolveEnvVars: { env, from } dotenv markers
{
    import std.algorithm.searching : canFind;
    import std.array : join;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.stdio : File;

    auto dir = buildPath(tempDir, "tachy_vars_dotenv_ut");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) if (exists(dir)) rmdirRecurse(dir);

    void writeFile(string name, string content)
    {
        auto f = File(buildPath(dir, name), "w");
        f.write(content);
        f.close();
    }

    writeFile(".env", [
        "# a comment line",
        "",
        "SECRET_VAR=s3cret",
        "export EXPORTED=yes",
        "QUOTED=\"hello world\"",
        "ESCAPED=\"line\\nbreak \\\"q\\\" \\\\ done\"",
        "LITERAL='a\\nb \"c\"'",
        "EMPTY=",
        "EMPTYQ=\"\"",
        "TRAILING =  spaced  # trailing comment",
        "HASH=a#b", // '#' not after whitespace stays part of the value
        "DUP=first",
        "DUP=second", // later keys win
    ].join("\n") ~ "\n");
    mkdirRecurse(buildPath(dir, "sub"));
    writeFile("sub/local.env", "LOCAL=from-sub\n");

    const string ctx = buildPath(dir, "main.toml");

    Val mk(string envName, string fromPath = null, string dflt = null)
    {
        Val m;
        m.kind = Val.Kind.table_;
        m.table_["env"] = Val(envName);
        if (fromPath !is null) m.table_["from"] = Val(fromPath);
        if (dflt !is null) m.table_["default"] = Val(dflt);
        return m;
    }

    Val[string] vars;
    vars["secret"] = mk("SECRET_VAR", ".env");
    vars["exported"] = mk("EXPORTED", ".env");
    vars["quoted"] = mk("QUOTED", ".env");
    vars["escaped"] = mk("ESCAPED", ".env");
    vars["literal"] = mk("LITERAL", ".env");
    vars["empty"] = mk("EMPTY", ".env");
    vars["emptyq"] = mk("EMPTYQ", ".env");
    vars["trailing"] = mk("TRAILING", ".env");
    vars["hash"] = mk("HASH", ".env");
    vars["dup"] = mk("DUP", ".env");
    vars["sub"] = mk("LOCAL", "sub/local.env"); // relative to ctx dir
    vars["absolute"] = mk("SECRET_VAR", buildPath(dir, ".env"));
    vars["file_value_wins"] = mk("SECRET_VAR", ".env", "fallback");
    vars["default_covers_missing"] = mk("NOT_IN_FILE", ".env", "fallback");
    vars["empty_is_a_value"] = mk("EMPTY", ".env", "fallback");
    vars["nested"] = tbl(table("inner", mk("SECRET_VAR", ".env")));

    auto r = resolveEnvVars(vars, ctx);
    assert(r["secret"].str_ == "s3cret");
    assert(r["exported"].str_ == "yes");
    assert(r["quoted"].str_ == "hello world");
    assert(r["escaped"].str_ == "line\nbreak \"q\" \\ done");
    assert(r["literal"].str_ == `a\nb "c"`); // single quotes are literal
    assert(r["empty"].kind == Val.Kind.string_ && r["empty"].str_.length == 0);
    assert(r["emptyq"].str_.length == 0);
    assert(r["trailing"].str_ == "spaced");
    assert(r["hash"].str_ == "a#b");
    assert(r["dup"].str_ == "second");
    assert(r["sub"].str_ == "from-sub");
    assert(r["absolute"].str_ == "s3cret");
    assert(r["file_value_wins"].str_ == "s3cret");
    assert(r["default_covers_missing"].str_ == "fallback");
    assert(r["empty_is_a_value"].str_.length == 0); // empty value, not default
    assert(r["nested"].table_["inner"].str_ == "s3cret");

    // the file is the source: the process environment is not consulted
    {
        import std.process : environment;
        environment["SECRET_VAR"] = "from-process-env";
        scope (exit) environment.remove("SECRET_VAR");
        Val[string] onlyFile;
        onlyFile["x"] = mk("SECRET_VAR", ".env");
        auto rf = resolveEnvVars(onlyFile, ctx);
        assert(rf["x"].str_ == "s3cret");
    }

    // missing dotenv file: hard error naming the declaring context
    {
        Val[string] bad;
        bad["x"] = mk("SECRET_VAR", "nope.env");
        string msg;
        try
        {
            resolveEnvVars(bad, ctx);
            assert(false, "expected TachyError");
        }
        catch (TachyError err)
            msg = err.msg;
        assert(canFind(msg, ctx ~ ": vars.x"));
        assert(canFind(msg, "cannot read dotenv file"));
        assert(canFind(msg, buildPath(dir, "nope.env")));
    }

    // key missing from the file without a default: names file and key
    {
        Val[string] bad;
        bad["x"] = mk("NOT_IN_FILE", ".env");
        string msg;
        try
        {
            resolveEnvVars(bad, ctx);
            assert(false, "expected TachyError");
        }
        catch (TachyError err)
            msg = err.msg;
        assert(canFind(msg, "NOT_IN_FILE"));
        assert(canFind(msg, buildPath(dir, ".env")));
    }

    // non-string 'from' is a type error
    {
        Val m;
        m.kind = Val.Kind.table_;
        m.table_["env"] = Val("X");
        m.table_["from"] = Val(1L);
        Val[string] bad;
        bad["x"] = m;
        string msg;
        try
        {
            resolveEnvVars(bad, ctx);
            assert(false, "expected TachyError");
        }
        catch (TachyError err)
            msg = err.msg;
        assert(canFind(msg, "'from' must be a string"));
    }

    // env + from + an unrelated key stays a plain nested table
    {
        Val plain;
        plain.kind = Val.Kind.table_;
        plain.table_["env"] = Val("SECRET_VAR");
        plain.table_["from"] = Val(".env");
        plain.table_["port"] = Val(80L);
        Val[string] mixed;
        mixed["app"] = plain;
        auto rm = resolveEnvVars(mixed, ctx);
        assert(rm["app"].kind == Val.Kind.table_);
        assert(rm["app"].table_["from"].str_ == ".env");
        assert(rm["app"].table_["port"].integer_ == 80);
    }
}

unittest // dotenv parsing errors name file and line
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.stdio : File;

    auto dir = buildPath(tempDir, "tachy_vars_dotenv_err_ut");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) if (exists(dir)) rmdirRecurse(dir);

    void expectError(string name, string content, string[] needles)
    {
        auto f = File(buildPath(dir, name), "w");
        f.write(content);
        f.close();

        Val m;
        m.kind = Val.Kind.table_;
        m.table_["env"] = Val("K");
        m.table_["from"] = Val(name);
        Val[string] vars;
        vars["x"] = m;
        try
        {
            resolveEnvVars(vars, buildPath(dir, "main.toml"));
            assert(false, "expected TachyError for " ~ name);
        }
        catch (TachyError err)
        {
            import std.algorithm.searching : canFind;
            foreach (n; needles)
                assert(canFind(err.msg, n), err.msg ~ " must contain '" ~ n ~ "'");
        }
    }
    expectError("line3.env", "# c\n\njusttext\n", [":3: expected"]);
    expectError("nokey.env", "justtext\n", [":1: expected KEY=VALUE"]);
    expectError("emptykey.env", "=v\n", [":1: expected KEY=VALUE"]);
    expectError("spacekey.env", "a b=v\n", [":1: invalid key"]);
    expectError("unterm.env", "K=\"abc\n", [":1: unterminated quoted value"]);
    expectError("untermsq.env", "K='abc\n", [":1: unterminated quoted value"]);
    expectError("badescape.env", `K="a\qb"` ~ "\n", [":1: unknown escape"]);
    expectError("afterquote.env", "K=\"a\" junk\n",
        [":1: unexpected content after quoted value"]);
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

unittest // { age = "..." } markers: resolution, stripping, combinations
{
    import std.algorithm.searching : canFind;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;

    auto dir = buildPath(tempDir, "tachy_vars_age_ut");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "secrets"));
    scope (exit) if (exists(dir)) rmdirRecurse(dir);
    write(buildPath(dir, "secrets", "db_password.age"), "ciphertext");
    write(buildPath(dir, "secrets", "binary.age"), "bytes");
    write(buildPath(dir, "id.txt"), "# identity\n");
    const string ctx = buildPath(dir, "inventory.toml");

    // fake decryptor: records what it was asked, returns canned content
    string lastAgePath, lastIdPath, lastMaterial;
    auto saved = ageDecrypt;
    scope (exit) ageDecrypt = saved;
    ageDecrypt = (string agePath, in AgeIdentity identity, string where)
    {
        lastAgePath = agePath;
        lastIdPath = identity.path;
        lastMaterial = identity.material;
        if (canFind(agePath, "no-key-matched"))
            throw new TachyError("cannot decrypt '" ~ agePath
                ~ "': no identity matched any of the recipients");
        if (canFind(agePath, "binary"))
            return "\xFF\xFE\x00not utf8";
        if (canFind(agePath, "crlf"))
            return "secret\r\n";
        return "s3cret\n";
    };

    Val mkAge(string path)
    {
        return tbl(table("age", Val(path)));
    }

    const string savedHome = environment.get("HOME");
    const string savedEnvId = environment.get("AGE_IDENTITY");
    scope (exit)
    {
        environment["HOME"] = savedHome;
        environment.remove("AGE_IDENTITY");
        if (savedEnvId !is null && savedEnvId.length)
            environment["AGE_IDENTITY"] = savedEnvId;
    }
    environment["HOME"] = dir; // no ~/.ssh/id_ed25519 there
    environment.remove("AGE_IDENTITY");

    // resolution with an explicit identity; one trailing newline stripped
    {
        Val[string] vars;
        vars["db_password"] = mkAge("secrets/db_password.age");
        vars["nested"] = tbl(table("inner", mkAge("secrets/db_password.age")));
        auto r = resolveEnvVars(vars, ctx, AgeConfig(true, buildPath(dir, "id.txt")));
        assert(r["db_password"].str_ == "s3cret");
        assert(r["nested"].table_["inner"].str_ == "s3cret");
        assert(lastAgePath == buildPath(dir, "secrets", "db_password.age"), lastAgePath);
        assert(lastIdPath == buildPath(dir, "id.txt"));
    }

    // CRLF also stripped
    {
        Val[string] vars;
        vars["x"] = mkAge("secrets/crlf.age");
        auto r = resolveEnvVars(vars, ctx, AgeConfig(true, buildPath(dir, "id.txt")));
        assert(r["x"].str_ == "secret");
    }

    // AGE_IDENTITY: an existing path is used as a path...
    {
        environment["AGE_IDENTITY"] = buildPath(dir, "id.txt");
        Val[string] vars;
        vars["x"] = mkAge("secrets/db_password.age");
        auto r = resolveEnvVars(vars, ctx, AgeConfig(true, null));
        assert(r["x"].str_ == "s3cret" && lastIdPath == buildPath(dir, "id.txt"));
    }
    // ...and non-path material is passed as material (never on disk)
    {
        environment["AGE_IDENTITY"] = "AGE-SECRET-KEY-1MATERIAL";
        Val[string] vars;
        vars["x"] = mkAge("secrets/db_password.age");
        auto r = resolveEnvVars(vars, ctx, AgeConfig(true, null));
        assert(r["x"].str_ == "s3cret");
        assert(lastMaterial == "AGE-SECRET-KEY-1MATERIAL" && lastIdPath.length == 0);
    }
    // an AGE_IDENTITY that is neither a path nor material is a clear error
    {
        environment["AGE_IDENTITY"] = "definitely-not-a-file.txt";
        Val[string] vars;
        vars["x"] = mkAge("secrets/db_password.age");
        string msg;
        try
        {
            resolveEnvVars(vars, ctx, AgeConfig(true, null));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "AGE_IDENTITY 'definitely-not-a-file.txt'"), msg);
        assert(canFind(msg, "neither an existing file"), msg);
    }
    // default: ~/.ssh/id_ed25519
    {
        environment.remove("AGE_IDENTITY");
        mkdirRecurse(buildPath(dir, ".ssh"));
        write(buildPath(dir, ".ssh", "id_ed25519"), "-----BEGIN OPENSSH PRIVATE KEY-----\n");
        Val[string] vars;
        vars["x"] = mkAge("secrets/db_password.age");
        auto r = resolveEnvVars(vars, ctx, AgeConfig(true, null));
        assert(r["x"].str_ == "s3cret");
        assert(lastIdPath == buildPath(dir, ".ssh", "id_ed25519"), lastIdPath);
    }
    // none available: error naming the three options
    {
        environment.remove("AGE_IDENTITY");
        environment["HOME"] = buildPath(dir, "empty-home");
        mkdirRecurse(buildPath(dir, "empty-home"));
        Val[string] vars;
        vars["x"] = mkAge("secrets/db_password.age");
        string msg;
        try
        {
            resolveEnvVars(vars, ctx, AgeConfig(true, null));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "no age identity available"), msg);
        assert(canFind(msg, "--identity"), msg);
    }

    // not allowed outside inventories (tasks files)
    {
        Val[string] vars;
        vars["x"] = mkAge("secrets/db_password.age");
        string msg;
        try
        {
            resolveEnvVars(vars, "tasks.toml");
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "only supported in inventory"), msg);
    }

    // decrypt failure relays age's message with context
    {
        Val[string] vars;
        vars["x"] = mkAge("secrets/no-key-matched.age");
        string msg;
        try
        {
            resolveEnvVars(vars, ctx, AgeConfig(true, buildPath(dir, "id.txt")));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "vars.x"), msg);
        assert(canFind(msg, "no-key-matched.age"), msg);
        assert(canFind(msg, "no identity matched"), msg);
    }

    // binary plaintext is rejected
    {
        Val[string] vars;
        vars["x"] = mkAge("secrets/binary.age");
        string msg;
        try
        {
            resolveEnvVars(vars, ctx, AgeConfig(true, buildPath(dir, "id.txt")));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "not valid UTF-8"), msg);
        assert(canFind(msg, "binary secrets"), msg);
    }

    // combinations are errors, and type checks
    {
        foreach (extraKey; ["env", "default", "from"])
        {
            Val m;
            m.kind = Val.Kind.table_;
            m.table_["age"] = Val("secrets/db_password.age");
            m.table_[extraKey] = Val("x");
            Val[string] vars;
            vars["x"] = m;
            string msg;
            try
            {
                resolveEnvVars(vars, ctx, AgeConfig(true, buildPath(dir, "id.txt")));
                assert(false, "expected TachyError");
            }
            catch (TachyError e)
                msg = e.msg;
            assert(canFind(msg, "'age' cannot be combined"), msg);
        }
        // non-string age is a type error
        Val[string] bad;
        bad["x"] = tbl(table("age", Val(1L)));
        string msg;
        try
        {
            resolveEnvVars(bad, ctx, AgeConfig(true, buildPath(dir, "id.txt")));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "'age' must be a string"), msg);
    }
}
