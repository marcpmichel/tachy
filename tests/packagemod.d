/// Tests for tachy.modules.packagemod, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.packagemod;

import tachy.modules.packagemod;
import tachy.tests.fake;

import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import tachy.tests.fake : FakeTransport;
import tachy.transport : CommandResult;
import tachy.value : Val;
import tachy.modules : TaskContext;
import tachy.errors : TachyError;

TaskContext fakeCtx(ref FakeTransport t)
{
    TaskContext ctx = TaskContext(t, false, "fakehost", "/tmp");
    return ctx;
}

private Val[string] PK(string key, string ver = null)
{
    Val[string] p;
    p["name"] = Val(key);
    if (ver.length)
        p["version"] = Val(ver);
    return p;
}

@("install when missing, idempotence when installed")
unittest
{
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(1, "", ""), CommandResult(0, "", "")];
        auto r = runPackageModule(PK("apt:vim"), fakeCtx(t));
        assert(r.changed, r.msg);
        assert(canFind(t.commands[1], "DEBIAN_FRONTEND=noninteractive apt-get install -y 'vim'"),
            t.commands[1]);
    }
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "install ok installed 2:8.1-1\n", "")];
        auto r = runPackageModule(PK("apt:vim"), fakeCtx(t));
        assert(!r.changed && canFind(r.msg, "2:8.1-1"), r.msg);
    }
    // deinstalled (config-files only) counts as missing
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "deinstall ok config-files 2:8.1-1\n", ""),
            CommandResult(0, "", "")];
        auto r = runPackageModule(PK("apt:vim"), fakeCtx(t));
        assert(r.changed);
    }
}

@("version pinning")
unittest
{
    // differing version -> install pkg=version with downgrade allowed
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "install ok installed 2:8.1-1\n", ""),
            CommandResult(0, "", "")];
        auto r = runPackageModule(PK("apt:vim", "2:7.4-1"), fakeCtx(t));
        assert(r.changed, r.msg);
        assert(canFind(t.commands[1], "--allow-downgrades 'vim=2:7.4-1'"), t.commands[1]);
    }
    // matching version -> nothing to do
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "install ok installed 2:8.1-1\n", "")];
        auto r = runPackageModule(PK("apt:vim", "2:8.1-1"), fakeCtx(t));
        assert(!r.changed);
    }
    // missing + pinned -> install pkg=version
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(1, "", ""), CommandResult(0, "", "")];
        auto r = runPackageModule(PK("apt:vim", "2:7.4-1"), fakeCtx(t));
        assert(r.changed);
        assert(canFind(t.commands[1], "apt-get install -y 'vim=2:7.4-1'"), t.commands[1]);
        assert(!canFind(t.commands[1], "--allow-downgrades"), t.commands[1]);
    }
}

@("removal")
unittest
{
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "install ok installed 2:8.1-1\n", ""),
            CommandResult(0, "", "")];
        Val[string] p = PK("apt:vim");
        p["present"] = Val(false);
        auto r = runPackageModule(p, fakeCtx(t));
        assert(r.changed);
        assert(canFind(t.commands[1], "DEBIAN_FRONTEND=noninteractive apt-get remove -y 'vim'"),
            t.commands[1]);
    }
    // already absent
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(1, "", "")];
        Val[string] p = PK("apt:vim");
        p["present"] = Val(false);
        auto r = runPackageModule(p, fakeCtx(t));
        assert(!r.changed);
    }
}

@("key and parameter errors")
unittest
{
    auto t = new FakeTransport;
    string msg;
    try
    {
        runPackageModule(PK("vim"), fakeCtx(t)); // no manager prefix
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "must be \"<manager>:<name>\""), msg);

    try
    {
        runPackageModule(PK("dnf:vim"), fakeCtx(t)); // unknown manager
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "unsupported package manager 'dnf'"), msg);

    try
    {
        runPackageModule(PK("apt:"), fakeCtx(t)); // empty package name
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "empty package name"), msg);

    // non-string version is a type error
    Val[string] p;
    p["name"] = Val("apt:vim");
    p["version"] = Val(7L);
    assertThrown!(TachyError)(runPackageModule(p, fakeCtx(t)));
}
