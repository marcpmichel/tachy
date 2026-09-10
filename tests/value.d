/// Tests for tachy.value, moved from the module's in-file unittest
/// blocks (tests/ is compiled only under `dub test`).  Two of the
/// parser suites (value kinds, multi-line strings) were rewritten
/// during the move; the rest moved verbatim.
module tachy.tests.value;

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
import tachy.errors : TachyError;
    return text(v);
}

unittest // values of every kind
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

unittest // multi-line strings: escapes, trims, line continuation, quote runs
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

unittest // group form expands to ordered statements; both forms merge
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
check "is debian" {
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
    assert(stmts[6].kind == "check" && stmts[6].key == "is debian"
        && stmts[6].value.table_["run"].str_ == "true");
    assert(stmts[7].kind == "import" && stmts[7].key == "../shared/tool");
    // statement order is source order
    assert(stmts[3].line < stmts[4].line && stmts[4].line < stmts[5].line);
}

unittest // an omitted block is the empty block: no attributes, no braces
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

unittest // inventory and settings shapes
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

unittest // strictness: the errors a typo produces
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
    fails("check { run = \"x\" }", "expected a key");
    fails("includes { a = 1 }", "unknown directive");
    fails("apply \"x.pravic\" { }", "unknown directive");
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

unittest // empty and comment-only files parse to nothing
{
    assert(parseStmts("").length == 0);
    assert(parseStmts("# nothing\n\n# more\n").length == 0);
    assert(parseStmts("group app { }").length == 1);
    assert(parseStmts("vars { }").length == 0);
    // keywords are plain data in key position
    auto t = varsTable("var check = 1\nvar vars = 2");
    assert(t["check"].integer_ == 1 && t["vars"].integer_ == 2);
}

unittest
{
    auto t = varsTable("var a = 1\nvar bad = 2");
    import std.exception : assertThrown, assertNotThrown;
    assertNotThrown(checkKeys(t, ["a", "bad"], "ctx"));
    assertThrown!(TachyError)(checkKeys(t, ["a"], "ctx"));
    assert(optString(t, "missing", "ctx", "dflt") == "dflt");
    assertThrown!(TachyError)(optString(t, "a", "ctx", "dflt")); // integer, not string
}
