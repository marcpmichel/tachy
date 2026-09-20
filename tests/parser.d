/// Tests for tachy.parser (moved from tests/value.d when the parser
/// left tachy.value; tests/ is compiled only under `dub test`).
module tachy.tests.parser;

import tachy.parser : parsePractic;
import tachy.value;
import tachy.errors : TachyError;

private PracticStmt[] parseStmts(string src)
{
    return parsePractic(src, "test.pravic").stmts;
}

private Val[string] varsTable(string src)
{
    Val[string] t;
    foreach (s; parseStmts(src))
        t[s.key] = s.value;
    return t;
}

private string toText(T)(T v)
{
    import std.conv : text;
    return text(v);
}

@("values of every kind")
unittest
{
    auto t = varsTable(`
var a = "x"
var b = 1
var c = 1.5
var d = true
var e = [1, 2]
var f = -0.25e2
var g = 0x1F
var h = 0o755
var i = 0b101
var j = 'C:\path'
var k = "tab\t\"q\" é"
`);
    assert(t["a"].kind == Val.Kind.string_ && t["a"].str_ == "x");
    assert(t["b"].kind == Val.Kind.integer_ && t["b"].integer_ == 1);
    assert(t["c"].kind == Val.Kind.float_);
    assert(t["d"].kind == Val.Kind.boolean_ && t["d"].boolean_);
    assert(t["e"].kind == Val.Kind.array_ && t["e"].array_.length == 2
        && t["e"].array_[1].integer_ == 2);
    assert(t["f"].kind == Val.Kind.float_ && t["f"].float_ == -25.0);
    assert(t["g"].integer_ == 31 && t["h"].integer_ == 493
        && t["i"].integer_ == 5);
    assert(t["j"].str_ == `C:\path`);
    assert(t["k"].str_ == "tab\t\"q\" é");
    assert(t["b"].scalarToString() == "1");
    assert(t["d"].scalarToString() == "true");
}

@("multi-line strings: escapes, trims, line continuation, quote runs")
unittest
{
    auto t = varsTable(`
var m = """
line one
line two
"""
var n = """
first
"""
var cont = """
start \
continued
"""
`);
    // a newline immediately after the opening quotes is trimmed
    assert(t["n"].str_ == "first\n", t["n"].str_);
    // a backslash at end of line trims whitespace to the next line
    assert(t["cont"].str_ == "start continued\n", t["cont"].str_);

    // up to two unescaped quotes belong to the content before """
    auto quotes = varsTable("var q2 = \"\"\"\nword \"\"\"\"\"");
    assert(quotes["q2"].str_ == "word \"\"", quotes["q2"].str_);
}

@("group form expands to ordered statements; both forms merge")
unittest
{
    auto stmts = parseStmts(`
vars {
    A = "one",
    B = 2
}
var C = true
files {
    /tmp/x { mode = "0644" }
    "/tmp/y" = { owner = "app" }
}
file /tmp/z { mode = "0600" }
ensure "is debian" {
    run = "true"
    exit_status = 0
}
import "../shared/tool" { }
`);
    assert(stmts.length == 8, toText(stmts.length));
    assert(stmts[0].kind == "vars" && stmts[0].key == "A"
        && stmts[0].value.str_ == "one");
    assert(stmts[1].key == "B" && stmts[1].value.integer_ == 2);
    assert(stmts[2].key == "C" && stmts[2].value.boolean_);
    assert(stmts[3].kind == "files" && stmts[3].key == "/tmp/x"
        && stmts[3].value.table_["mode"].str_ == "0644");
    assert(stmts[4].key == "/tmp/y" && stmts[4].value.table_["owner"].str_ == "app");
    assert(stmts[5].kind == "files" && stmts[5].key == "/tmp/z");
    assert(stmts[6].kind == "ensure" && stmts[6].key == "is debian"
        && stmts[6].value.table_["run"].str_ == "true");
    assert(stmts[7].kind == "import" && stmts[7].key == "../shared/tool");
    // statement order is source order
    assert(stmts[3].line < stmts[4].line && stmts[4].line < stmts[5].line);
}

@("an omitted block is the empty block: no attributes, no braces")
unittest
{
    auto stmts = parseStmts(`
directory /tmp/two
import "../task2"
file /tmp/three { mode = "0644" }
package apt:curl
`);
    assert(stmts.length == 4, toText(stmts.length));
    assert(stmts[0].kind == "directories" && stmts[0].key == "/tmp/two"
        && stmts[0].value.kind == Val.Kind.table_
        && stmts[0].value.table_.length == 0);
    assert(stmts[1].kind == "import" && stmts[1].key == "../task2"
        && stmts[1].value.table_.length == 0);
    assert(stmts[2].kind == "files"
        && stmts[2].value.table_["mode"].str_ == "0644");
    assert(stmts[3].kind == "packages"
        && stmts[3].value.table_.length == 0);

    // a comment may follow the key; EOF without a trailing newline is fine
    assert(parseStmts("directory /tmp/x  # fresh\n").length == 1);
    assert(parseStmts("directory /tmp/x").length == 1);

    // group-form entries are the same entries: braces optional there too
    auto g = parseStmts(`
hosts {
    web1
    web2 { address = "10.0.0.2" }
}
`);
    assert(g.length == 2, toText(g.length));
    assert(g[0].kind == "hosts" && g[0].key == "web1"
        && g[0].value.table_.length == 0);
    assert(g[1].key == "web2"
        && g[1].value.table_["address"].str_ == "10.0.0.2");
}

@("inventory and config shapes")
unittest
{
    auto stmts = parseStmts(`
host web1 {
    address = "10.0.0.1"
    tags = ["web", "front"]
    vars { http_port = 81 }
}
hosts {
    web2 {
        address = "10.0.0.2",
        vars { role = "secondary" },
    }
}
imports {
    paths = ["/opt/tachy/shared"],
}
webui {
    projects = ["/srv/site"],
}
`);
    assert(stmts.length == 4);
    assert(stmts[0].kind == "hosts" && stmts[0].key == "web1"
        && stmts[0].value.table_["vars"].table_["http_port"].integer_ == 81);
    assert(stmts[1].kind == "hosts" && stmts[1].key == "web2");
    assert(stmts[2].kind == "imports" && stmts[2].key == "paths"
        && stmts[2].value.array_.length == 1);
    assert(stmts[3].kind == "webui" && stmts[3].key == "projects");
}

@("strictness: the errors a typo produces")
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown;

    void fails(string src, string needle)
    {
        string msg;
        try
        {
            parseStmts(src);
            assert(false, "expected TachyError for: " ~ src);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, needle), msg ~ " does not contain: " ~ needle);
    }

    fails("varsite = 1", "unknown directive 'varsite'");
    fails("var x 1", "expected '{', '=' or end of line");
    fails("vars", "expected '{'");
    fails("vars = { a = 1 }", "opens a block");
    fails("ensure { run = \"x\" }", "expected a key");
    fails("includes { a = 1 }", "unknown directive");
    fails("hook \"x.pravic\" { }", "unknown directive");
    fails("before packages { }", "unknown directive");
    fails("var a = 1, b = 2", "expected end of line");
    fails("vars { a = 1 b = 2 }", "expected ',' or a newline");
    fails("vars { a = 1, a = 2 }", "duplicate key 'a'");
    fails("var a = 1\nvar a = 2", "duplicate vars \"a\"");
    fails("vars { a = ", "expected a value");
    fails("var a = [1 2]", "expected ',' or ']'");
    fails("var a = \"x", "unterminated string");
    fails("vars { a = 1", "unterminated block");
    fails("var a = .5", "expected a value");
    fails("var a = 1979-05-27", "invalid characters in number");
    fails("var a = 007", "leading zeros");
    fails("var a = \"bad \\z escape\"", "unknown escape");
    fails("var {{ x }} = 1", "expected a key");
    fails("[vars]\na = 1", "unknown directive");
    fails("directory /tmp/two mode = \"0755\"", "expected '{', '=' or end of line");
    fails("vars { a b }", "expected '{', '=' or a separator");
    // errors carry file and line
    try
    {
        parseStmts("var ok = 1\nvars {\n  bad entry\n}\n");
        assert(false);
    }
    catch (TachyError e)
        assert(canFind(e.msg, "test.pravic: line 3"), e.msg);
}

@("empty and comment-only files parse to nothing")
unittest
{
    assert(parseStmts("").length == 0);
    assert(parseStmts("# nothing\n\n# more\n").length == 0);
    assert(parseStmts("group app { }").length == 1);
    assert(parseStmts("vars { }").length == 0);
    // keywords are plain data in key position
    auto t = varsTable("var ensure = 1\nvar vars = 2");
    assert(t["ensure"].integer_ == 1 && t["vars"].integer_ == 2);
}

@("probe directive keyword: quoted and bare URL keys, guarded boundary")
unittest
{
    import std.algorithm.searching : canFind, startsWith;

    auto stmts = parseStmts("probe \"http://localhost/h\" { code = 200 }\n");
    assert(stmts.length == 1);
    assert(stmts[0].kind == "probe");
    assert(stmts[0].key == "http://localhost/h");
    assert(stmts[0].value.table_["code"].integer_ == 200);

    // ':' '/' '.' '.' are key characters: URLs need no quotes
    stmts = parseStmts("probe https://127.0.0.1:8080/healthz { }\n");
    assert(stmts[0].kind == "probe" && stmts[0].key == "https://127.0.0.1:8080/healthz");

    // the keyword guard: a bare scheme is one unknown directive, not
    // some keyword followed by a key
    string msg;
    try
    {
        parseStmts("https://localhost/x { }\n");
        assert(false);
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "unknown directive"), msg);
    assert(canFind(msg, "https"), msg);

    // braceless when there are no attributes at all
    stmts = parseStmts("probe http://localhost/ping\n");
    assert(stmts[0].kind == "probe" && stmts[0].key == "http://localhost/ping");
}

@("repo directive: both forms, canonical kind, keyword guard")
unittest
{
    auto stmts = parseStmts(`
repo /srv/app {
    url = "git@example.com/me/app.git",
    branch = "main"
}
repos {
    /srv/one { url = "u1" }
    /srv/two
}
repo /srv/bare
`);
    assert(stmts.length == 4, toText(stmts.length));
    assert(stmts[0].kind == "repos" && stmts[0].key == "/srv/app"
        && stmts[0].value.table_["url"].str_ == "git@example.com/me/app.git");
    assert(stmts[1].kind == "repos" && stmts[1].key == "/srv/one");
    assert(stmts[2].kind == "repos" && stmts[2].key == "/srv/two"
        && stmts[2].value.table_.length == 0);
    assert(stmts[3].kind == "repos" && stmts[3].key == "/srv/bare");

    // the keyword guard: `repofoo` is one unknown directive, not `repo`
    import std.algorithm.searching : canFind;
    string msg;
    try
    {
        parseStmts("repofoo = 1\n");
        assert(false);
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "unknown directive 'repofoo'"), msg);
}

@("choose: both spellings, wrapped and bare")
unittest
{
    auto t = varsTable(`
var env = "dev"
var name = {
  choose "{{env}}" {
    "dev" = "Development"
    "prod" = "Production"
    _ = "Unknown"
  }
}
`);
    auto c = t["name"];
    assert(c.kind == Val.Kind.choose_, c.typeName());
    assert(c.str_ == "{{env}}");
    assert(c.choosePatterns_ == ["dev", "prod", "_"]);
    assert(c.chooseValues_[0].str_ == "Development"
        && c.chooseValues_[1].str_ == "Production"
        && c.chooseValues_[2].str_ == "Unknown");

    // inline wrapped form, per the spec's spelling
    auto inline = varsTable(
        `var test = { choose "{{ country_code }}" { "FR" = "France", "IT" = "Italy", _ = "Other" } }`);
    assert(inline["test"].kind == Val.Kind.choose_);
    assert(inline["test"].choosePatterns_ == ["FR", "IT", "_"]);

    // bare form without the wrapper block
    auto bare = varsTable(`var x = choose "{{e}}" { "a" = "1", _ = "0" }`);
    assert(bare["x"].kind == Val.Kind.choose_ && bare["x"].str_ == "{{e}}");

    // a single-entry choose (default only) and nested chooses in cases
    auto nested = varsTable(`var x = { choose "{{e}}" { "a" = { choose "{{f}}" { "b" = "2", _ = "3" } }, _ = "0" } }`);
    assert(nested["x"].chooseValues_[0].kind == Val.Kind.choose_);
    assert(nested["x"].chooseValues_[0].choosePatterns_ == ["b", "_"]);

    // a wrapped choose among a var's other entries is not confused with
    // a key spelled "choose"
    auto mixed = varsTable(`var x = { port = 8080, mode = "run" }`);
    assert(mixed["x"].kind == Val.Kind.table_ && mixed["x"].table_.length == 2);
    auto keyed = varsTable(`var x = { choose = "plain key", _ = "not a choose" }`);
    assert(keyed["x"].kind == Val.Kind.table_);
}

@("choose: display and Pravic round-trip shape")
unittest
{
    import std.algorithm.searching : canFind;

    auto t = varsTable(`var x = { choose "{{e}}" { "a" = "1", _ = "z" } }`);
    assert(canFind(t["x"].display(), `choose "{{e}}" { a = "1", _ = "z" }`),
        t["x"].display());

    // re-parsing the display reproduces the same value
    auto back = varsTable("var y = " ~ t["x"].display());
    assert(back["y"].kind == Val.Kind.choose_);
    assert(back["y"].str_ == "{{e}}" && back["y"].choosePatterns_ == ["a", "_"]);
}

@("choose: placement is restricted to var assignations")
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown;

    void fails(string src, string needle)
    {
        string msg;
        try
        {
            parseStmts(src);
            assert(false, "expected TachyError for: " ~ src);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, needle), msg ~ " does not contain: " ~ needle);
    }

    // job parameters, apply bindings and host attributes reject it
    fails(`file "/tmp/x" { content = { choose "{{e}}" { "a" = "1", _ = "0" } } }`,
        "'choose' is only available inside a var assignation");
    fails(`apply "other.pravic" { where = { choose "{{e}}" { "a" = "1", _ = "0" } } }`,
        "'choose' is only available inside a var assignation");
    fails(`host web1 { address = { choose "{{e}}" { "a" = "1", _ = "0" } } }`,
        "'choose' is only available inside a var assignation");

    // vars statements (both forms) and inventory host vars accept it
    assert(parseStmts(`vars { x = { choose "{{e}}" { "a" = "1", _ = "0" } } }`).length == 1);
    assert(parseStmts(`var x = { choose "{{e}}" { "a" = "1", _ = "0" } }`).length == 1);
    assert(parseStmts(`host web1 { vars { x = { choose "{{e}}" { "a" = "1", _ = "0" } } } }`).length == 1);
}

@("choose: strictness errors")
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown;

    void fails(string src, string needle)
    {
        string msg;
        try
        {
            parseStmts(src);
            assert(false, "expected TachyError for: " ~ src);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, needle), msg ~ " does not contain: " ~ needle);
    }

    // the '_' default is mandatory
    fails(`var x = { choose "{{e}}" { "a" = "1" } }`,
        "a choose block needs a default '_' case");
    // the selector must be a quoted string (bare choose form)
    fails(`var x = choose env { "a" = "1", _ = "0" }`,
        "the choose selector must be a quoted string");
    // in the wrapped form an unquoted selector reads as a key first
    fails(`var x = { choose 3 { "a" = "1", _ = "0" } }`,
        "expected '{', '=' or a separator after key 'choose'");
    // a duplicate pattern stays a duplicate key
    fails(`var x = { choose "{{e}}" { "a" = "1", "a" = "2", _ = "0" } }`,
        "duplicate key 'a'");
    // an unterminated choose wrapper (the case block alone closed)
    fails(`var x = { choose "{{e}}" { "a" = "1", _ = "0" }`,
        "expected '}' to close the choose block");
    // an unterminated case block
    fails(`var x = { choose "{{e}}" { "a" = "1"`,
        "unterminated block");
}

@("assert directive: both forms, canonical kind, keyword guard")
unittest
{
    import std.algorithm.searching : canFind;

    void fails(string src, string needle)
    {
        string msg;
        try
        {
            parseStmts(src);
            assert(false, "expected TachyError for: " ~ src);
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, needle), msg ~ " does not contain: " ~ needle);
    }

    // single form; the canonical kind is the plural
    auto stmts = parseStmts(`assert "one" { value = "{{ v }}", equals = "x" }` ~ "\n");
    assert(stmts.length == 1);
    assert(stmts[0].kind == "asserts");
    assert(stmts[0].key == "one");
    assert(stmts[0].value.table_["equals"].str_ == "x");

    // group form: one statement per entry, in source order
    stmts = parseStmts("asserts {\n"
        ~ "    \"one\" = { value = \"a\", contains = \"a\" }\n"
        ~ "    \"two\" = { value = \"b\" }\n"
        ~ "}\n");
    assert(stmts.length == 2);
    assert(stmts[0].kind == "asserts" && stmts[0].key == "one");
    assert(stmts[1].kind == "asserts" && stmts[1].key == "two");

    // keyword guards: `assertx`/`assertment` are unknown directives,
    // never `assert` with a glued key
    fails("assertx { }", "unknown directive");
    fails("assertment \"x\" { }", "unknown directive");

    // the same assertion key through both spellings is a duplicate
    fails(`assert "x" { value = "a", equals = "a" }` ~ "\n"
        ~ `asserts { "x" = { value = "b", equals = "b" } }`, "duplicate");
}
