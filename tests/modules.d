/// Tests for tachy.modules.package, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.modules;

import tachy.modules;
import tachy.tests.fake;

import std.algorithm.searching : canFind;
import tachy.tests.fake : FakeTransport;
import tachy.transport : CommandResult;
import tachy.errors : TachyError;
import tachy.value : Val;
import std.array : join;

@("runModule dispatches every name moduleNames() registers")
unittest
{
    auto t = new FakeTransport;
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");
    foreach (m; moduleNames())
    {
        Val[string] noParams;
        try
            runModule(m, noParams, ctx);
        catch (TachyError e)
            assert(!canFind(e.msg, "unknown module"),
                m ~ " is registered but runModule does not dispatch it: " ~ e.msg);
    }
}

@("\"package\" reaches its executor through runModule")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(1, "", ""), CommandResult(0, "", "")];
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");
    Val[string] p;
    p["name"] = Val("apt:vim");
    auto r = runModule("package", p, ctx);
    assert(r.changed, r.msg);
    assert(canFind(t.commands[1], "apt-get install -y 'vim'"), t.commands[1]);
}

@("mustRun captures both streams into the verbose details")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "to-out\n", "to-err\n")];
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");

    string[] details;
    mustRun(t, ctx, details, "echo hi", "echo hi");
    assert(canFind(details, "cmd: echo hi"), details.join("\n"));
    assert(canFind(details, "stdout: to-out"), details.join("\n"));
    assert(canFind(details, "stderr: to-err"), details.join("\n"));
}

@("mustRun: silent commands and check mode add no stream details")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "", "")];
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");

    string[] details;
    mustRun(t, ctx, details, "true", "true");
    assert(details == ["cmd: true"], details.join("\n"));

    // check mode: the command never runs, so nothing is captured
    auto t2 = new FakeTransport;
    TaskContext check = TaskContext(t2, true, "fakehost", "/tmp");
    string[] checkDetails;
    mustRun(t2, check, checkDetails, "echo hi", "echo hi");
    assert(checkDetails == ["cmd: echo hi"], checkDetails.join("\n"));
    assert(t2.commands.length == 0, "check mode must not run the command");
}

@("mustRunWithInput captures the streams of the fed command")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "acked\n", "warned\n")];
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");

    string[] details;
    mustRunWithInput(t, ctx, details, "cat > /tmp/x", "payload", "write /tmp/x");
    assert(canFind(details, "stdout: acked"), details.join("\n"));
    assert(canFind(details, "stderr: warned"), details.join("\n"));
    assert(t.lastInput == "payload");
}

@("mustRun failures still name the failing command and output")
unittest
{
    import std.exception : assertThrown;

    auto t = new FakeTransport;
    t.replies ~= [CommandResult(3, "", "boom\n")];
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");

    string[] details;
    string msg;
    try
        mustRun(t, ctx, details, "false", "run false");
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "boom"), msg);
    assert(canFind(details, "stderr: boom"), details.join("\n"));
}
