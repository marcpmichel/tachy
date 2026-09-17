/// Tests for the `debug` directive: the module (pure display, never
/// changed), its load-time validation and its models wiring.
module tachy.tests.debugmod;

import tachy.modules;
import tachy.models : loadTasksFile;
import tachy.value : Val;
import tachy.errors : TachyError;

import std.exception : assertThrown;
import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : File;

private string writeTemp(string sub, string content)
{
    auto dir = tempDir ~ "/tachy_debug_ut";
    if (!exists(dir)) mkdirRecurse(dir);
    auto p = buildPath(dir, sub);
    auto f = File(p, "w");
    f.write(content);
    f.close();
    return p;
}

@("debug: pure display, ok and never changed, check mode identical")
unittest
{
    Val[string] params;
    params["name"] = Val("a message");

    foreach (checkMode; [false, true])
    {
        auto ctx = TaskContext(null, checkMode, "scratch", "/tmp", null, null);
        auto r = runModule("debug", params, ctx);
        assert(!r.changed, "debug must never report changed");
        assert(r.msg.length == 0, "the message travels as the label");
        assert(r.details.length == 0);
    }
}

@("debug: load-time validation rejects any parameter beyond the message")
unittest
{
    Val[string] params;
    params["name"] = Val("msg");
    params["extra"] = Val(1L);
    assertThrown!TachyError(validateModuleParams("debug", params, "ctx"));

    params.remove("extra");
    validateModuleParams("debug", params, "ctx"); // must pass
}

@("debug: wiring — injection, kind, templated message, duplicates")
unittest
{
    auto p = writeTemp("debug-main.pravic", `
var who = "world"
debug "hello {{ who }}"
debug "step two" { }
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 2);
    assert(loaded.jobs[0].moduleName == "debug");
    assert(loaded.jobs[0].kind == "debug");
    assert(loaded.jobs[0].target == "hello {{ who }}");
    assert(loaded.jobs[0].params["name"].str_ == "hello {{ who }}");
    assert(loaded.jobs[1].target == "step two");

    // a parameter key clash is rejected like every other directive
    auto bad = writeTemp("debug-bad.pravic", `
debug "x" { name = "y" }
`);
    assertThrown!TachyError(loadTasksFile(bad));

    // the statement key is the message: duplicates are errors — the
    // parser rejects two identical debug statements in one file
    auto dup = writeTemp("debug-dup.pravic", `
debug "same"
debug "same"
`);
    string msg;
    try
        loadTasksFile(dup);
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, `duplicate debug "same"`), msg);

    // and the loader rejects the same message from two applied files
    auto once = writeTemp("debug-shared.pravic", `debug "same"`);
    writeTemp("debug-wrap1.pravic", `apply "debug-shared.pravic"`);
    writeTemp("debug-wrap2.pravic", `apply "debug-shared.pravic"`);
    auto both = writeTemp("debug-both.pravic", `
apply "debug-wrap1.pravic"
apply "debug-wrap2.pravic"
`);
    msg = "";
    try
        loadTasksFile(both);
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, `message 'same' is already managed`), msg);
}
