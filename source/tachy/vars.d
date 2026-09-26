module tachy.vars;

/**
 * Variable handling: deep merging of variable scopes and `{{ expr }}`
 * template rendering.
 *
 * Precedence (lowest to highest), mirroring the intuitive Ansible order:
 *   global vars  <  host vars
 *   <  apply-chain vars  <  file vars
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
struct AgeConfig {
    bool enabled;
    string identity; // explicit identity file, or null for auto-detection
}

/// An age identity: a file path (age key or ssh private key — age
/// accepts the latter natively), or raw key material (fed to age on
/// stdin, never written to disk).
struct AgeIdentity {
    string path;
    string material;

    static AgeIdentity fromPath(string p) {
        AgeIdentity id;
        id.path = p;
        return id;
    }

    static AgeIdentity fromMaterial(string m) {
        AgeIdentity id;
        id.material = m;
        return id;
    }
}

/// The first line of every age v1 ciphertext file (armor-less header).
package(tachy) enum string ageFileHeader = "age-encryption.org/v1\n";

/// True when `bytes` look like an age ciphertext.  `file` sources
/// marked `age = true` carry ciphertext on the controller and
/// plaintext inside a deployed bundle (the controller decrypts them
/// when building the bundle, exactly like it decrypts inventory vars
/// into the generated inventory); this check tells the two apart.
package(tachy) bool isAgeCiphertext(const char[] bytes) @safe pure nothrow {
    return bytes.length >= ageFileHeader.length
        && bytes[0 .. ageFileHeader.length] == ageFileHeader;
}

/// Decrypt the age file at `agePath` with the standard identity
/// resolution (`explicitIdentity` from `--identity`, then
/// `AGE_IDENTITY`, then `~/.ssh/id_ed25519`).  For `file` sources
/// marked `age = true`, running where the identity lives — the
/// controller.
package(tachy) string decryptAgeFile(string agePath, string explicitIdentity,
        string where) @trusted {
    const AgeIdentity identity = resolveAgeIdentity(explicitIdentity, where);
    try
        return ageDecrypt(agePath, identity, where);
    catch(TachyError e)
        throw new TachyError(where ~ ": " ~ e.msg);
}

/// Decryption hook — the default runs the age binary; unittests replace
string delegate(string agePath, in AgeIdentity identity, string where) ageDecrypt =
    (string agePath, in AgeIdentity identity, string where) =>
    defaultAgeDecrypt(agePath, identity, where);

/// Resolve `{ env = "NAME", default = "...", from = "..." }`,
/// `{ run = "command" }` and `{ age = "file.age" }` variable entries,
/// replacing them with their value.  Without `from` an env marker
/// reads the environment of the current process; with `from` it reads
/// that dotenv file instead; a run marker captures its command's
/// output (stdout, or stderr through `stream = "stderr"`); an age
/// marker decrypts the named file (paths relative to the file
/// declaring the vars).  Called when a vars table is consumed:
/// inventory tables resolve on the controller (age markers enabled),
/// tasks-file tables in the environment of the process that loads them
/// (the host, in bundled mode — age markers are rejected there).
/// Nested tables are walked; scalars and arrays pass through.  A marker
/// naming a variable that has no value and no default is a hard error;
/// a set-but-empty value, from the environment or from a dotenv file,
/// resolves to the empty string (the default only covers a missing
/// value).
Val[string] resolveEnvVars(in Val[string] vars, string context,
        in AgeConfig age = AgeConfig.init) @trusted {
    Val[string] r;
    string[string][string] dotenvCache; // resolved path -> parsed entries
    foreach(string k, const Val v; vars)
        r[k] = resolveEnvVal(v, context ~ ": vars." ~ k, context, dotenvCache, age);
    return r;
}

private Val resolveEnvVal(in Val v, string where, string context,
        ref string[string][string] dotenvCache, in AgeConfig age) @trusted {
    import std.process : environment;

    if(v.kind != Val.Kind.table_)
        return cast(Val) v;

    // An age marker is a table of exactly { age = "path" } — it cannot
    // combine with the env/default/from family or a run marker (it is
    // self-contained: a failed decryption is an error, not an absent
    // value).
    if(auto a = "age" in v.table_) {
        if(v.table_.length != 1)
            throw new TachyError(where
                    ~ ": 'age' cannot be combined with 'env', 'default', 'from'"
                    ~ " or 'run'");
        if((*a).kind != Val.Kind.string_)
            throw new TachyError(where ~ ": 'age' must be a string, not a "
                    ~ (*a).typeName());
        if(!age.enabled)
            throw new TachyError(
                    where ~ ": 'age' markers are only supported"
                    ~ " in inventory vars — they are decrypted on the controller"
                    ~ " (tasks-file vars resolve on the host in bundled runs)");
        const string agePath = resolveDotenvPath((*a).str_, context);
        const AgeIdentity identity = resolveAgeIdentity(age.identity, where);
        string value;
        try
            value = ageDecrypt(agePath, identity, where);
        catch(TachyError e)
            throw new TachyError(where ~ ": " ~ e.msg);
        try {
            import std.utf : validate;

            validate(value);
        } catch(Exception)
            throw new TachyError(where ~ ": decrypted content of '" ~ agePath
                    ~ "' is not valid UTF-8 (binary secrets do not fit variables"
                    ~ " — deploy them with a file src marked age = true)");
        // Secret files are usually created with one trailing newline;
        // strip it (and a CR before it) so templates see the secret.
        if(value.length && value[$ - 1] == '\n')
            value = value[0 .. $ - 1];
        if(value.length && value[$ - 1] == '\r')
            value = value[0 .. $ - 1];
        return Val(value);
    }
    // A run marker is a table of { run = "command" } plus an optional
    // stream = "stdout"/"stderr": the command's captured output becomes
    // the value.  Like 'age' it is self-contained — it cannot combine
    // with the env/default/from family, and a failed command is an
    // error, not an absent value.
    if(auto c = "run" in v.table_) {
        foreach(string k, const Val _; v.table_)
            if(k != "run" && k != "stream")
                throw new TachyError(where ~ ": 'run' cannot be combined with"
                        ~ " 'env', 'default' or 'from' (a run marker holds only"
                        ~ " 'run' and 'stream')");
        if((*c).kind != Val.Kind.string_)
            throw new TachyError(where ~ ": 'run' must be a string, not a "
                    ~ (*c).typeName());
        bool wantStderr;
        if(auto s = "stream" in v.table_) {
            if((*s).kind != Val.Kind.string_)
                throw new TachyError(where ~ ": 'stream' must be a string, not a "
                        ~ (*s).typeName());
            if((*s).str_ != "stdout" && (*s).str_ != "stderr")
                throw new TachyError(where ~ ": 'stream' must be \"stdout\" or"
                        ~ " \"stderr\", not \"" ~ (*s).str_ ~ "\"");
            wantStderr = (*s).str_ == "stderr";
        }
        return Val(runCapture((*c).str_, wantStderr, where, context));
    }

    // An env marker is a table whose keys are "env" plus any of
    // "default" and "from".  Tables with other keys are plain nested
    // tables.
    auto e = "env" in v.table_;
    bool marker = e !is null;
    foreach(string k, const Val _; v.table_)
        if(k != "env" && k != "default" && k != "from")
            marker = false;
    if(!marker) {
        Val r;
        r.kind = Val.Kind.table_;
        foreach(string k, const Val entry; v.table_)
            r.table_[k] = resolveEnvVal(entry, where ~ "." ~ k, context,
                    dotenvCache, age);
        return r;
    }

    auto d = "default" in v.table_;
    auto from = "from" in v.table_;
    if((*e).kind != Val.Kind.string_)
        throw new TachyError(where ~ ": 'env' must be a string, not a "
                ~ (*e).typeName());
    if(d !is null && (*d).kind != Val.Kind.string_)
        throw new TachyError(where ~ ": 'default' must be a string, not a "
                ~ (*d).typeName());
    if(from !is null && (*from).kind != Val.Kind.string_)
        throw new TachyError(where ~ ": 'from' must be a string, not a "
                ~ (*from).typeName());

    string value;
    bool have;
    string missing;
    if(from !is null) {
        const string path = resolveDotenvPath((*from).str_, context);
        have = dotenvLookup(path, (*e).str_, where, dotenvCache, value);
        missing = where ~ ": environment variable '" ~ (*e).str_
            ~ "' is not set in '" ~ path ~ "'";
    } else {
        value = environment.get((*e).str_);
        have = value !is null;
        missing = where ~ ": environment variable '" ~ (*e).str_ ~ "' is not set";
    }
    if(have)
        return Val(value);
    if(d !is null)
        return Val((*d).str_);
    throw new TachyError(missing);
}
/// Capture the output of a `{ run = "command" }` marker: run it with
/// /bin/sh -c and return the chosen stream.  The command runs in the
/// directory of the file declaring the vars (like `from` paths and
/// `ensure` jobs: relative paths resolve next to the declaring file)
/// and sees the environment of the process loading it — the controller
/// for inventory vars, the host for tasks-file vars in bundled runs
/// (the controller's validation load executes it once there too).
/// One trailing newline (and a CR before it) is stripped, so
/// `hostname -I` yields the bare value.  A failing command is an error
/// naming the variable, the command and the status (with the other
/// stream's output when it has any); so is output that is not valid
/// UTF-8 (binary does not fit variables).
private string runCapture(string command, bool wantStderr, string where,
        string context) @trusted {
    import core.thread : Thread;
    import std.array : appender;
    import std.conv : text;
    import std.path : dirName;
    import std.process : Config, ProcessPipes, Redirect, pipeProcess, wait;
    import std.string : strip;

    const string dir = dirName(context); // declaring file's directory
    ProcessPipes p;
    try
        p = pipeProcess(["/bin/sh", "-c", command],
                Redirect.stdin | Redirect.stdout | Redirect.stderr,
                null, Config.none, dir);
    catch(Exception e)
        throw new TachyError(where ~ ": cannot run '" ~ command ~ "': " ~ e.msg);
    p.stdin.close(); // commands see EOF on stdin, never the loader's

    // Drain the uncaptured stream on a thread so a command writing
    // more than a pipe buffer of it cannot deadlock the capture (the
    // transport's runStreaming drains the same way).
    auto other = wantStderr ? p.stdout : p.stderr;
    auto otherApp = appender!(ubyte[]);
    auto thr = new Thread({
        auto buf = new ubyte[65_536];
        for(;;) {
            auto n = other.rawRead(buf).length;
            if(n == 0)
                break;
            otherApp.put(buf[0 .. n]);
        }
    });
    thr.start();

    string value;
    {
        auto capture = wantStderr ? p.stderr : p.stdout;
        auto app = appender!(ubyte[]);
        auto buf = new ubyte[65_536];
        for(;;) {
            auto n = capture.rawRead(buf).length;
            if(n == 0)
                break;
            app.put(buf[0 .. n]);
        }
        value = cast(string) app.data;
    }
    thr.join();
    const int status = wait(p.pid);
    if(status != 0) {
        const string m = strip(cast(string) otherApp.data);
        throw new TachyError(where ~ ": command '" ~ command
                ~ "' failed with exit status " ~ text(status)
                ~ (m.length ? ": " ~ firstLine(m) : ""));
    }
    try {
        import std.utf : validate;

        validate(value);
    } catch(Exception)
        throw new TachyError(where ~ ": output of '" ~ command
                ~ "' is not valid UTF-8 (binary output does not fit variables)");
    if(value.length && value[$ - 1] == '\n')
        value = value[0 .. $ - 1];
    if(value.length && value[$ - 1] == '\r')
        value = value[0 .. $ - 1];
    return value;
}

/// The first line of `s`, capped for error messages.
private string firstLine(string s) @safe pure {
    import std.string : indexOf;

    const ptrdiff_t nl = indexOf(s, '\n');
    string line = nl >= 0 ? s[0 .. nl] : s;
    return line.length > 200 ? line[0 .. 200] ~ "…" : line;
}

/// Resolve a `from` path like any other tasks-file path: absolute
/// paths pass through, relative ones are relative to the directory of
/// the file declaring the vars table.
private string resolveDotenvPath(string from, string context) @trusted {
    import std.path : buildPath, dirName, isAbsolute;

    return isAbsolute(from) ? from : buildPath(dirName(context), from);
}

/// Look up `key` in the dotenv file at `path`; the file is parsed at
/// most once per resolveEnvVars call.  Returns false when the file
/// does not define the key; `value` receives the entry otherwise.
private bool dotenvLookup(string path, string key, string where,
        ref string[string][string] dotenvCache, out string value) @trusted {
    if(auto cached = path in dotenvCache) {
        if(auto hit = key in *cached) {
            value = *hit;
            return true;
        }
        return false;
    }
    import std.file : readText;

    string content;
    try
        content = readText(path);
    catch(Exception e)
        throw new TachyError(where ~ ": cannot read dotenv file '" ~ path
                ~ "': " ~ e.msg);
    string[string] entries = parseDotenv(content, where, path);
    dotenvCache[path] = entries;
    if(auto hit = key in entries) {
        value = *hit;
        return true;
    }
    return false;
}

/// Identity for `{ age = ... }` markers, in order: the explicit
/// identity (`--identity`, or the config file's `identity` entry
/// when the flag is absent), then the AGE_IDENTITY environment
/// variable (an existing file path, or raw key material), then the
/// controller's default ssh key — age accepts ed25519 ssh private
/// keys natively.  Anything else is an error naming the options.
private AgeIdentity resolveAgeIdentity(string explicitIdentity, string where) @trusted {
    import std.file : exists;
    import std.path : buildPath;
    import std.process : environment;

    if(explicitIdentity.length) {
        if(!exists(explicitIdentity))
            throw new TachyError(where ~ ": age identity '" ~ explicitIdentity
                    ~ "' does not exist");
        return AgeIdentity.fromPath(explicitIdentity);
    }
    const string envId = environment.get("AGE_IDENTITY");
    if(envId.length) {
        if(exists(envId))
            return AgeIdentity.fromPath(envId);
        if(isKeyMaterial(envId))
            return AgeIdentity.fromMaterial(envId);
        throw new TachyError(where ~ ": AGE_IDENTITY '" ~ envId
                ~ "' is neither an existing file (relative to the current"
                ~ " directory) nor age key material (AGE-SECRET-KEY-1... or"
                ~ " an ssh private key block)");
    }
    const string home = environment.get("HOME");
    if(home.length) {
        const string sshKey = buildPath(home, ".ssh", "id_ed25519");
        if(exists(sshKey))
            return AgeIdentity.fromPath(sshKey); // age accepts ssh keys natively
    }
    throw new TachyError(where ~ ": no age identity available: pass"
            ~ " --identity PATH, set an identity in config.pravic, set"
            ~ " AGE_IDENTITY to a path or key material, or provide"
            ~ " ~/.ssh/id_ed25519");
}

/// Recognize raw age key material: an `AGE-SECRET-KEY-1...` secret key
/// or an ssh private key block.  Anything else that is not an existing
/// path is a configuration error, not material to hand to age.
private bool isKeyMaterial(string s) @safe pure {
    import std.algorithm.searching : canFind, startsWith;

    return s.startsWith("AGE-SECRET-KEY-1") || canFind(s, "PRIVATE KEY");
}

/// Run `age --decrypt` on `agePath`.  Key material (AGE_IDENTITY) is
/// fed to `/dev/stdin` — it is never written to disk.  stderr is
/// drained after stdout (age's error output is one short line).
private string defaultAgeDecrypt(string agePath, in AgeIdentity identity,
        string where) @trusted {
    import std.array : appender;
    import std.conv : text;
    import std.process : Redirect, pipeProcess, wait;
    import std.string : strip;

    const string idArg = identity.path.length ? identity.path : "/dev/stdin";
    auto p = pipeProcess(["age", "--decrypt", "-i", idArg, agePath],
            Redirect.stdin | Redirect.stdout | Redirect.stderr);
    if(identity.material.length) {
        p.stdin.rawWrite(cast(const(ubyte)[]) identity.material);
        p.stdin.flush();
    }
    p.stdin.close(); // age sees EOF on the identity stream

    auto outApp = appender!(ubyte[]);
    auto buf = new ubyte[65_536];
    for(;;) {
        auto n = p.stdout.rawRead(buf).length;
        if(n == 0)
            break;
        outApp.put(buf[0 .. n]);
    }
    string errText;
    {
        auto ebuf = new ubyte[4096];
        for(;;) {
            auto n = p.stderr.rawRead(ebuf).length;
            if(n == 0)
                break;
            errText ~= cast(string) ebuf[0 .. n];
        }
    }
    const int status = wait(p.pid);
    if(status != 0) {
        auto m = errText.strip;
        if(!m.length)
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
@trusted {
    import std.conv : text;
    import std.string : indexOf, splitLines, strip;

    string[string] entries;
    foreach(size_t i, string raw; content.splitLines) {
        const string origin = where ~ ": " ~ path ~ ":" ~ text(i + 1) ~ ": ";
        string line = raw.strip();
        if(!line.length || line[0] == '#')
            continue;
        if(line.length > 7 && line[0 .. 7] == "export ")
            line = line[7 .. $].strip();
        const ptrdiff_t eq = indexOf(line, '=');
        if(eq <= 0)
            throw new TachyError(origin ~ "expected KEY=VALUE");
        const string key = line[0 .. eq].strip();
        if(!key.length || canFind(key, ' ') || canFind(key, '\t'))
            throw new TachyError(origin ~ "invalid key '" ~ key ~ "'");
        entries[key] = parseDotenvValue(line[eq + 1 .. $], origin);
    }
    return entries;
}

private string parseDotenvValue(string rest, string origin) @trusted {
    import std.string : strip, stripLeft;

    const string v = rest.stripLeft();

    // Single-line quoted values: double quotes process escapes, single
    // quotes are literal (backslash included).  After the closing
    // quote only whitespace or a comment may follow.
    if(v.length && (v[0] == '"' || v[0] == '\'')) {
        const char q = v[0];
        string r;
        for(size_t j = 1; j < v.length; ++j) {
            const char c = v[j];
            if(q == '"' && c == '\\' && j + 1 < v.length) {
                switch(v[j + 1]) {
                    case 'n':
                        r ~= '\n';
                        break;
                    case 't':
                        r ~= '\t';
                        break;
                    case 'r':
                        r ~= '\r';
                        break;
                    case 'f':
                        r ~= '\f';
                        break;
                    case 'b':
                        r ~= '\b';
                        break;
                    case '"':
                        r ~= '"';
                        break;
                    case '\'':
                        r ~= '\'';
                        break;
                    case '\\':
                        r ~= '\\';
                        break;
                    default:
                        throw new TachyError(origin ~ "unknown escape '\\"
                                ~ v[j + 1] ~ "' in quoted value");
                }
                ++j;
                continue;
            }
            if(c == q) {
                const string trailing = v[j + 1 .. $].strip();
                if(trailing.length && trailing[0] != '#')
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
    foreach(size_t j; 0 .. v.length)
        if(v[j] == '#' && (j == 0 || v[j - 1] == ' ' || v[j - 1] == '\t'))
            return v[0 .. j].strip();
    return v.strip();
}

/// Deep merge: `over` wins per leaf key; nested tables merge recursively.
/// Arrays and scalars replace.  Returns a fresh tree; inputs are untouched.
Val[string] deepMerge(in Val[string] base, in Val[string] over) @trusted pure {
    Val[string] r;
    foreach(string k, const Val v; base)
        r[k] = cast(Val) v;
    foreach(string k, const Val v; over) {
        auto cur = k in r;
        if(cur !is null && (*cur).kind == Val.Kind.table_ && v.kind == Val.Kind.table_)
            (*cur).table_ = deepMerge((*cur).table_, v.table_);
        else
            r[k] = cast(Val) v;
    }
    return r;
}
/// Look up a dotted path like `nginx.port` in nested variable tables.
const(Val)* lookupPath(in Val[string] vars, string dottedPath) @safe pure {
    import std.algorithm.iteration : splitter;

    const(Val)* cur;
    bool first = true;
    foreach(part; splitter(dottedPath, '.')) {
        if(first) {
            cur = part in vars;
            first = false;
        } else {
            if(cur is null || (*cur).kind != Val.Kind.table_)
                return null;
            cur = part in (*cur).table_;
        }
        if(cur is null)
            return null;
    }
    return cur;
}

/// Render `{{ expr }}` templates in `input` using `vars`.
string renderTemplate(string input, in Val[string] vars, string[] active = null) {
    if(!canFind(input, "{{"))
        return input;

    auto app = appender!string;
    size_t i = 0;
    while(i < input.length) {
        const ptrdiff_t rel = indexOf(input[i .. $], "{{");
        if(rel < 0) {
            app.put(input[i .. $]);
            break;
        }
        const size_t open = i + cast(size_t) rel;
        app.put(input[i .. open]);

        const ptrdiff_t relClose = indexOf(input[open + 2 .. $], "}}");
        if(relClose < 0)
            throw new TachyError("unterminated '{{' in template: " ~ input);
        const size_t close = open + 2 + cast(size_t) relClose;

        const string expr = strip(input[open + 2 .. close]);
        if(expr.empty)
            throw new TachyError("empty '{{}}' template in: " ~ input);
        if(canFind(expr, "{{"))
            throw new TachyError("malformed template (nested '{{') in: " ~ input);

        app.put(resolveExpr(expr, vars, active));
        i = close + 2;
    }
    return app.data;
}

private string resolveExpr(string expr, in Val[string] vars, string[] active) {
    import std.string : join;

    if(canFind(active, expr))
        throw new TachyError("variable cycle detected: " ~ active.join(" -> ") ~ " -> " ~ expr);

    auto v = lookupPath(vars, expr);
    if(v is null)
        throw new TachyError("undefined variable '" ~ expr ~ "'");

    final switch((*v).kind) {
        case Val.Kind.string_:
            return renderTemplate((*v).str_, vars, active ~ expr);
        case Val.Kind.integer_:
        case Val.Kind.float_:
        case Val.Kind.boolean_:
            return (*v).scalarToString();
        case Val.Kind.choose_: {
            auto chosen = evalChoose(*v, vars, active ~ expr);
            // a case value may itself be a choose
            while(chosen.kind == Val.Kind.choose_)
                chosen = evalChoose(chosen, vars, active ~ expr);
            final switch(chosen.kind) {
                case Val.Kind.string_:
                    return renderTemplate(chosen.str_, vars, active ~ expr);
                case Val.Kind.integer_:
                case Val.Kind.float_:
                case Val.Kind.boolean_:
                    return chosen.scalarToString();
                case Val.Kind.array_:
                case Val.Kind.table_:
                    throw new TachyError(
                            "variable '" ~ expr
                            ~ "' is an " ~ chosen.typeName()
                            ~ " and cannot be substituted into a string");
                case Val.Kind.choose_:
                    assert(0, "unreachable: chooses resolved above");
            }
        }
        case Val.Kind.array_:
        case Val.Kind.table_:
            throw new TachyError("variable '" ~ expr ~ "' is an " ~ (*v)
                    .typeName()
                    ~ " and cannot be substituted into a string");
    }
}

/// Evaluate a `choose` value: render its subject (a quoted string,
/// usually a `"{{ ... }}"` template) against `vars`, match it exactly
/// against the case patterns, and return the matching case's value — or
/// the `_` default, which the parser makes mandatory.  The chosen value
/// is returned as-is; the caller renders it in its own context.
private Val evalChoose(in Val v, in Val[string] vars, string[] active)
@trusted {
    const string subject = renderTemplate(v.str_, vars, active);
    size_t defaultIdx;
    foreach(size_t i; 0 .. v.choosePatterns_.length) {
        if(v.choosePatterns_[i] == "_")
            defaultIdx = i; // the mandatory fallback, never matched directly
        else if(v.choosePatterns_[i] == subject)
            return cast(Val) v.chooseValues_[i];
    }
    return cast(Val) v.chooseValues_[defaultIdx];
}

/// Deep-copy `params`, rendering every string against `vars`.
Val[string] renderParams(in Val[string] params, in Val[string] vars) @trusted {
    Val[string] r;
    foreach(string k, const Val v; params)
        r[k] = renderVal(v, vars);
    return r;
}

private Val renderVal(in Val v, in Val[string] vars) @trusted {
    final switch(v.kind) {
        case Val.Kind.string_:
            return Val(renderTemplate(v.str_, vars));
        case Val.Kind.integer_:
        case Val.Kind.float_:
        case Val.Kind.boolean_:
            return cast(Val) v;
        case Val.Kind.choose_:
            return renderVal(evalChoose(v, vars, null), vars);
        case Val.Kind.array_: {
            Val r;
            r.kind = Val.Kind.array_;
            foreach(const e; v.array_)
                r.array_ ~= renderVal(e, vars);
            return r;
        }
        case Val.Kind.table_: {
            Val r;
            r.kind = Val.Kind.table_;
            foreach(string k, const e; v.table_)
                r.table_[k] = renderVal(e, vars);
            return r;
        }
    }
}

// ---------------------------------------------------------------------------

/// Resolve an entry path (`template`, `src`) the way `file`/`service`
/// do: absolute paths pass through, relative ones resolve against the
/// defining tasks file's directory.
package(tachy) string resolveEntryPath(string path, string baseDir) @safe pure {
    import std.path : buildPath, isAbsolute;

    return isAbsolute(path) ? path : buildPath(baseDir, path);
}

/// Render the template file at `tplPath` for one entry: the run scope
/// `vars` merged with the entry's local `vars` param (local values
/// win) — exactly the scope `file`/`service` render `template` with at
/// run time.  `where` prefixes errors ("file: ", "service: ").
package(tachy) string renderTemplateFile(string tplPath, string baseDir,
        Val[string] vars, in Val[string] params, string where) @trusted {
    import std.file : readText;

    const string abs = resolveEntryPath(tplPath, baseDir);
    Val[string] tplScope = vars;
    if(auto v = "vars" in params)
        tplScope = deepMerge(vars, (*v).table_);
    try
        return renderTemplate(readText(abs), tplScope);
    catch(TachyError e)
        throw new TachyError(where ~ "cannot render '" ~ abs ~ "': " ~ e.msg);
    catch(Exception e)
        throw new TachyError(where ~ "cannot read template '" ~ abs ~ "': " ~ e.msg);
}
