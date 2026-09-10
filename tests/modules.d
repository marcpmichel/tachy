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

unittest // runModule dispatches every name moduleNames() registers
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

unittest // "package" reaches its executor through runModule
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
