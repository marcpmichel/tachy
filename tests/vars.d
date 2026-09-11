/// Tests for tachy.vars, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.vars;

import tachy.vars;
import tachy.value : Val;
import tachy.errors : TachyError;
import std.algorithm.searching : canFind;

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

unittest // resolveEnvVars: { env = "NAME" } markers
{
import std.exception : assertThrown;
import tachy.errors : TachyError;
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

unittest // isAgeCiphertext: the age v1 header decides ciphertext vs plaintext
{
import tachy.vars : isAgeCiphertext;

assert(isAgeCiphertext("age-encryption.org/v1\n-> X25519 body\n"));
assert(isAgeCiphertext("age-encryption.org/v1\n"));
assert(!isAgeCiphertext("age-encryption.org/v1")); // no newline: not the header
assert(!isAgeCiphertext(""));
assert(!isAgeCiphertext("plain secret\n"));
assert(!isAgeCiphertext("\x00\x01age-encryption.org/v1\n"));
}
