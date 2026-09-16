/// Tests for tachy.value's validated accessors (the parser's suites
/// live in tests/parser.d; tests/ is compiled only under `dub test`).
module tachy.tests.value;

import tachy.parser : parsePractic;
import tachy.value;
import tachy.errors : TachyError;

private Val[string] varsTable(string src)
{
    Val[string] t;
    foreach (s; parsePractic(src, "test.pravic").stmts)
        t[s.key] = s.value;
    return t;
}

@("validated accessors: checkKeys and optString")
unittest
{
    auto t = varsTable("var a = 1\nvar bad = 2");
    import std.exception : assertThrown, assertNotThrown;
    assertNotThrown(checkKeys(t, ["a", "bad"], "ctx"));
    assertThrown!(TachyError)(checkKeys(t, ["a"], "ctx"));
    assert(optString(t, "missing", "ctx", "dflt") == "dflt");
    assertThrown!(TachyError)(optString(t, "a", "ctx", "dflt")); // integer, not string
}
