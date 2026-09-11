/// Tests for tachy.modules.accounts, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.accounts;

import tachy.modules.accounts;
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

@("group: create, idempotence, removal")
unittest
{
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(2, "", ""), CommandResult(0, "", "")]; // missing, add
        auto r = runGroupModule(P2("name", "deploy"), fakeCtx(t));
        assert(r.changed && canFind(t.commands[1], "groupadd -- 'deploy'"));
    }
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "deploy:x:1000:\n", "")];
        auto r = runGroupModule(P2("name", "deploy"), fakeCtx(t));
        assert(!r.changed && t.commands.length == 1);
    }
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "old:x:99:\n", ""), CommandResult(0, "", "")];
        auto r = runGroupModule(P2("name", "old", "state", "absent"), fakeCtx(t));
        assert(r.changed && canFind(t.commands[1], "groupdel -- 'old'"));
    }
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(2, "", "")];
        auto r = runGroupModule(P2("name", "old", "state", "absent"), fakeCtx(t));
        assert(!r.changed);
    }
    // invalid state
    auto t = new FakeTransport;
    assertThrown!(TachyError)(runGroupModule(P2("name", "x", "state", "maybe"), fakeCtx(t)));
}

@("user: creation with defaults and with attributes")
unittest
{
    // defaults: /bin/sh shell, home created, per-user group
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(2, "", ""),  // passwd: missing
            CommandResult(2, ""),                // group "deploy": missing
            CommandResult(0, "", "")];           // useradd
        auto r = runUserModule(P2("name", "deploy"), fakeCtx(t));
        assert(r.changed, r.msg);
        assert(canFind(t.commands[2], "useradd"), t.commands[2]);
        assert(canFind(t.commands[2], "-s '/bin/sh'"), t.commands[2]);
        assert(canFind(t.commands[2], " -m"), t.commands[2]);
        assert(!canFind(t.commands[2], "-g"), t.commands[2]);   // per-user group
        assert(!canFind(t.commands[2], "-G"), t.commands[2]);
        assert(!canFind(t.commands[2], "-c"), t.commands[2]);
    }
    // full attributes, explicit primary group exists
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(2, ""),                    // passwd: missing
            CommandResult(0, "docker:x:900:\n"),               // primary exists
            CommandResult(0, "wheel:x:10:\n"),                 // supplementary exists
            CommandResult(0, "", "")];                         // useradd
        Val[string] p;
        p["name"] = Val("deploy");
        p["group"] = Val("docker");
        p["groups"] = valList(["wheel"]);
        p["shell"] = Val("/bin/zsh");
        p["comment"] = Val("epices user");
        p["home"] = Val("/srv/deploy");
        auto r = runUserModule(p, fakeCtx(t));
        assert(r.changed);
        assert(canFind(t.commands[3], "-g 'docker'"), t.commands[3]);
        assert(canFind(t.commands[3], "-G 'wheel'"), t.commands[3]);
        assert(canFind(t.commands[3], "-s '/bin/zsh'"), t.commands[3]);
        assert(canFind(t.commands[3], "-c 'epices user'"), t.commands[3]);
        assert(canFind(t.commands[3], "-d '/srv/deploy'"), t.commands[3]);
    }

    // create_home = false -> -M; existing group named after the user -> -g
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(2, ""),
            CommandResult(0, "svc:x:901:\n"),
            CommandResult(0, "", "")];
        Val[string] p;
        p["name"] = Val("svc");
        p["create_home"] = Val(false);
        auto r = runUserModule(p, fakeCtx(t));
        assert(r.changed);
        assert(canFind(t.commands[2], " -M"), t.commands[2]);
        assert(canFind(t.commands[2], "-g 'svc'"), t.commands[2]);
    }
    // explicit primary group missing -> clear error
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(2, ""), CommandResult(2, "")];
        Val[string] p;
        p["name"] = Val("x");
        p["group"] = Val("nope");
        string msg;
        try
        {
            runUserModule(p, fakeCtx(t));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "primary group 'nope' does not exist"), msg);
    }
}

@("user: existing — drift repair and idempotence")
unittest
{
    const string passwd = "deploy:x:1000:1000:epices user:/home/deploy:/bin/bash\n";
    const string group1000 = "deploy:x:1000:\n";

    // no drift: shell/comment/home match, groups already member
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, passwd, ""),
            CommandResult(0, "deploy wheel docker\n", "")];
        Val[string] p;
        p["name"] = Val("deploy");
        p["shell"] = Val("/bin/bash");
        p["groups"] = valList(["docker"]);
        auto r = runUserModule(p, fakeCtx(t));
        assert(!r.changed, r.msg);
    }
    // shell + comment drift -> single usermod with -s and -c
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, passwd, ""),
            CommandResult(0, "", "")];
        Val[string] p;
        p["name"] = Val("deploy");
        p["shell"] = Val("/bin/zsh");
        p["comment"] = Val("new comment");
        auto r = runUserModule(p, fakeCtx(t));
        assert(r.changed, r.msg);
        assert(canFind(t.commands[1], "usermod -s '/bin/zsh' -c 'new comment'"), t.commands[1]);
    }
    // primary group and home drift -> -g and -m -d
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, passwd, ""),
            CommandResult(0, "oldgrp:x:1000:\n"),       // gid 1000 -> other name
            CommandResult(0, "", "")];                  // usermod
        Val[string] p;
        p["name"] = Val("deploy");
        p["group"] = Val("docker");
        p["home"] = Val("/srv/deploy");
        auto r = runUserModule(p, fakeCtx(t));
        assert(r.changed);
        assert(canFind(t.commands[2], "-g 'docker'"), t.commands[2]);
        assert(canFind(t.commands[2], "-m -d '/srv/deploy'"), t.commands[2]);
    }
    // missing supplementary membership -> additive usermod -aG
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, passwd, ""),
            CommandResult(0, "deploy\n", ""),
            CommandResult(0, "", "")];
        Val[string] p;
        p["name"] = Val("deploy");
        p["groups"] = valList(["docker", "wheel"]);
        auto r = runUserModule(p, fakeCtx(t));
        assert(r.changed);
        assert(canFind(t.commands[2], "usermod -aG 'docker,wheel' -- 'deploy'"), t.commands[2]);
    }
}

@("user: removal")
unittest
{
    // absent + existing
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "x:x:1:1:::\n", ""), CommandResult(0, "", "")];
        auto r = runUserModule(P2("name", "gone", "state", "absent"), fakeCtx(t));
        assert(r.changed && canFind(t.commands[1], "userdel -- 'gone'"));
    }
    // absent + remove_home -> -r
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(0, "x:x:1:1:::\n", ""), CommandResult(0, "", "")];
        Val[string] p;
        p["name"] = Val("gone");
        p["state"] = Val("absent");
        p["remove_home"] = Val(true);
        auto r = runUserModule(p, fakeCtx(t));
        assert(r.changed && canFind(t.commands[1], "userdel -r -- 'gone'"));
    }
    // absent + already gone
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(2, "", "")];
        auto r = runUserModule(P2("name", "gone", "state", "absent"), fakeCtx(t));
        assert(!r.changed);
    }
    // remove_home with state=present is a configuration error
    {
        auto t = new FakeTransport;
        Val[string] p;
        p["name"] = Val("x");
        p["remove_home"] = Val(true);
        assertThrown!(TachyError)(runUserModule(p, fakeCtx(t)));
    }
    // invalid state
    {
        auto t = new FakeTransport;
        assertThrown!(TachyError)(runUserModule(P2("name", "x", "state", "maybe"), fakeCtx(t)));
    }
}

private Val[string] P2(string k1, string v1, string k2 = null, string v2 = null,
    string k3 = null, string v3 = null)
{
    Val[string] p;
    p[k1] = Val(v1);
    if (k2.length)
        p[k2] = Val(v2);
    if (k3.length)
        p[k3] = Val(v3);
    return p;
}

private Val valList(string[] items)
{
    Val v;
    v.kind = Val.Kind.array_;
    foreach (item; items)
        v.array_ ~= Val(item);
    return v;
}
