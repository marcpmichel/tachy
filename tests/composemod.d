/// Tests for tachy.modules.composemod, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.composemod;

import tachy.modules.composemod;
import tachy.tests.fake;

import tachy.tests.fake : FakeTransport;
import tachy.value : Val;
import tachy.modules : TaskContext;
import tachy.errors : TachyError;
import std.algorithm.searching : canFind;
import std.array;
import tachy.transport : CommandResult;

TaskContext fakeCtx(ref FakeTransport t)
{
    return TaskContext(t, false, "fakehost", "/tmp");
}
/// Minimal compose params: dir + file.
Val[string] CP(string dir, string file)
{
    Val[string] p;
    p["dir"] = Val(dir);
    p["file"] = Val(file);
    return p;
}


/// Val has no array constructor; build one for `services`.
Val arrVal(Val[] elems)
{
    Val v;
    v.kind = Val.Kind.array_;
    v.array_ = elems;
    return v;
}

/// Run `dg`, expected to throw a TachyError; return its message.
string failMsg(scope void delegate() dg)
{
    try dg();
    catch (TachyError e)
        return e.msg;
    assert(false, "expected TachyError");
}

@("running and fully conformant -> unchanged")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "Docker Compose version v5.4.0\n", ""),
    CommandResult(0, "db\nweb\n", ""),
    CommandResult(0, "db 1f7ebb0f\n", ""),
    CommandResult(0, "web 33d2e0d5\n", ""),
    CommandResult(0, "db\tapp-db-1\trunning\t1f7ebb0f\nweb\tapp-web-1\trunning\t33d2e0d5\n", ""),
    CommandResult(0, "/app-db-1 running none\n/app-web-1 running healthy\n", ""),
];
auto r = runComposeModule(CP("/srv/app", "compose.yml"), fakeCtx(t));
assert(!r.changed, r.msg);
assert(canFind(r.msg, "2 service(s) up to date"), r.msg);
assert(t.commands.length == 6, t.commands.join(" | "));
assert(t.commands[1] == "docker compose -f '/srv/app/compose.yml' -p 'app' --project-directory '/srv/app' config --services",
    t.commands[1]);
assert(t.commands[5] == "docker inspect --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 'app-db-1' 'app-web-1'",
    t.commands[5]);
}

@("config hash drift -> up, then converging re-probe")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "web\n", ""),
    CommandResult(0, "web abc123\n", ""),
    CommandResult(0, "web\tapp-web-1\trunning\tzzzz9999\n", ""),
    CommandResult(0, "", ""),
    CommandResult(0, "web\tapp-web-1\trunning\tabc123\n", ""),
    CommandResult(0, "/app-web-1 running none\n", ""),
];
auto r = runComposeModule(CP("/srv/app", "compose.yml"), fakeCtx(t));
assert(r.changed, r.msg);
assert(canFind(r.msg, "recreated 'app-web-1'"), r.msg);
assert(canFind(r.details[0], "config hash differs"), r.details[0]);
assert(t.commands[4] == "docker compose -f '/srv/app/compose.yml' -p 'app' --project-directory '/srv/app' up --detach --wait",
    t.commands[4]);
assert(t.commands.length == 7, t.commands.join(" | "));
}

@("stopped container and policy flags -> exact up, no post-probe without wait")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "web\n", ""),
    CommandResult(0, "web h1\n", ""),
    CommandResult(0, "web\tapp-web-1\texited\th1\n", ""),
    CommandResult(0, "", ""),
];
Val[string] p = CP("/srv/app", "compose.yml");
p["pull"] = Val("always");
p["build"] = Val("never");
p["recreate"] = Val("always");
p["wait"] = Val(false);
p["timeout"] = Val(10L);
auto r = runComposeModule(p, fakeCtx(t));
assert(r.changed, r.msg);
assert(canFind(r.msg, "started 'app-web-1'"), r.msg);
assert(t.commands[4] == "docker compose -f '/srv/app/compose.yml' -p 'app' --project-directory '/srv/app' up --detach --pull always --no-build --force-recreate -t 10",
    t.commands[4]);
assert(t.commands.length == 5, t.commands.join(" | "));
}

@("unhealthy container -> up; wait flags; converging health")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "web\n", ""),
    CommandResult(0, "web h1\n", ""),
    CommandResult(0, "web\tapp-web-1\trunning\th1\n", ""),
    CommandResult(0, "/app-web-1 running starting\n", ""),
    CommandResult(0, "", ""),
    CommandResult(0, "web\tapp-web-1\trunning\th1\n", ""),
    CommandResult(0, "/app-web-1 running healthy\n", ""),
];
Val[string] p = CP("/srv/app", "/opt/stacks/my.yml");  // absolute file path
p["wait_timeout"] = Val(300L);
auto r = runComposeModule(p, fakeCtx(t));
assert(r.changed, r.msg);
assert(canFind(r.msg, "awaited 'app-web-1'"), r.msg);
assert(t.commands[5] == "docker compose -f '/opt/stacks/my.yml' -p 'app' --project-directory '/srv/app' up --detach --wait --wait-timeout 300",
    t.commands[5]);
}

@("services subset: unknown name is an error, subset reaches the command")
unittest
{
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "v\n", ""),
        CommandResult(0, "db\nweb\n", ""),
    ];
    Val[string] p = CP("/srv/app", "compose.yml");
    p["services"] = arrVal([Val("web"), Val("ghost")]);
    assert(canFind(failMsg({ runComposeModule(p, fakeCtx(t)); }),
        "service 'ghost' is not defined in /srv/app/compose.yml"));
}
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "v\n", ""),
        CommandResult(0, "db\nweb\n", ""),
        CommandResult(0, "web h1\n", ""),
        CommandResult(0, "", ""),   // no containers at all
        CommandResult(0, "", ""),   // up
    ];
    Val[string] p = CP("/srv/app", "compose.yml");
    p["services"] = arrVal([Val("web")]);
    p["wait"] = Val(false);
    auto r = runComposeModule(p, fakeCtx(t));
    assert(r.changed, r.msg);
    assert(t.commands[4] == "docker compose -f '/srv/app/compose.yml' -p 'app' --project-directory '/srv/app' up --detach 'web'",
        t.commands[4]);
    // only the selected service is hashed
    assert(!canFind(t.commands[2], "db"), t.commands[2]);
}
}

@("stopped: stop selected running services, remove orphans via the engine")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "db\nweb\n", ""),
    CommandResult(0, "legacy\tapp-old-1\texited\tzzz\nweb\tapp-web-1\trunning\th\n", ""),
    CommandResult(0, "", ""),   // compose stop
    CommandResult(0, "", ""),   // docker rm -f
];
Val[string] p = CP("/srv/app", "compose.yml");
p["state"] = Val("stopped");
p["remove_orphans"] = Val(true);
p["timeout"] = Val(20L);
auto r = runComposeModule(p, fakeCtx(t));
assert(r.changed, r.msg);
assert(canFind(r.msg, "stopped 'web'"), r.msg);
assert(canFind(r.msg, "removed 1 orphan container(s)"), r.msg);
assert(t.commands[3] == "docker compose -f '/srv/app/compose.yml' -p 'app' --project-directory '/srv/app' stop -t 20",
    t.commands[3]);
assert(t.commands[4] == "docker rm -f 'app-old-1'", t.commands[4]);
}

@("stopped and already stopped -> unchanged")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "web\n", ""),
    CommandResult(0, "web\tapp-web-1\texited\th\n", ""),
];
Val[string] p = CP("/srv/app", "compose.yml");
p["state"] = Val("stopped");
auto r = runComposeModule(p, fakeCtx(t));
assert(!r.changed, r.msg);
assert(r.msg == "already stopped", r.msg);
assert(t.commands.length == 3, t.commands.join(" | "));
}

@("absent: down with optional volume/image removal, then verified")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "abc12\n", ""),   // containers exist
    CommandResult(0, "", ""),          // down
    CommandResult(0, "", ""),          // re-probe containers
    CommandResult(0, "", ""),          // networks
    CommandResult(0, "", ""),          // volumes
];
Val[string] p = CP("/srv/app", "compose.yml");
p["state"] = Val("absent");
p["remove_volumes"] = Val(true);
p["remove_images"] = Val(true);
auto r = runComposeModule(p, fakeCtx(t));
assert(r.changed, r.msg);
assert(canFind(r.msg, "brought down"), r.msg);
assert(canFind(r.msg, "volumes removed"), r.msg);
assert(canFind(r.msg, "images removed"), r.msg);
assert(t.commands[2] == "docker compose -f '/srv/app/compose.yml' -p 'app' --project-directory '/srv/app' down --remove-orphans --volumes --rmi all",
    t.commands[2]);
}

@("absent and nothing left -> unchanged, no compose invocation")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "", ""),   // containers
    CommandResult(0, "", ""),   // networks
];
Val[string] p = CP("/srv/app", "compose.yml");
p["state"] = Val("absent");
auto r = runComposeModule(p, fakeCtx(t));
assert(!r.changed, r.msg);
assert(r.msg == "already absent", r.msg);
assert(t.commands.length == 3, t.commands.join(" | "));
}

@("failure and parameter errors")
unittest
{
{
    // docker compose unavailable
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(1, "", "exec format error\n")];
    assert(canFind(failMsg({ runComposeModule(CP("/srv/app", "compose.yml"), fakeCtx(t)); }),
        "docker compose is not available"));
}
{
    // compose file cannot be loaded
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "v\n", ""),
        CommandResult(1, "", "stat /srv/app/compose.yml: no such file or directory\n")];
    assert(canFind(failMsg({ runComposeModule(CP("/srv/app", "compose.yml"), fakeCtx(t)); }),
        "cannot load /srv/app/compose.yml"));
}
{
    // invalid rendered state
    auto t = new FakeTransport;
    Val[string] p = CP("/srv/app", "compose.yml");
    p["state"] = Val("paused");
    assert(canFind(failMsg({ runComposeModule(p, fakeCtx(t)); }),
        "must be one of running, stopped, absent"));
}
{
    // derived project name impossible
    auto t = new FakeTransport;
    assert(canFind(failMsg({ runComposeModule(CP("/srv/(())", "compose.yml"), fakeCtx(t)); }),
        "set 'project' explicitly"));
}
{
    // explicit project name rejected
    auto t = new FakeTransport;
    Val[string] p = CP("/srv/app", "compose.yml");
    p["project"] = Val("MyApp");
    assert(canFind(failMsg({ runComposeModule(p, fakeCtx(t)); }), "invalid"));
}
{
    // remove_volumes contradicts running
    auto t = new FakeTransport;
    Val[string] p = CP("/srv/app", "compose.yml");
    p["remove_volumes"] = Val(true);
    assert(canFind(failMsg({ runComposeModule(p, fakeCtx(t)); }),
        "only meaningful with state = \"absent\""));
}
{
    // wait_timeout without wait
    auto t = new FakeTransport;
    Val[string] p = CP("/srv/app", "compose.yml");
    p["wait"] = Val(false);
    p["wait_timeout"] = Val(5L);
    assert(canFind(failMsg({ runComposeModule(p, fakeCtx(t)); }),
        "only meaningful with 'wait = true'"));
}
{
    // non-positive timeout
    auto t = new FakeTransport;
    Val[string] p = CP("/srv/app", "compose.yml");
    p["timeout"] = Val(0L);
    assert(canFind(failMsg({ runComposeModule(p, fakeCtx(t)); }), "positive"));
}
{
    // relative dir
    auto t = new FakeTransport;
    assert(canFind(failMsg({ runComposeModule(CP("srv/app", "compose.yml"), fakeCtx(t)); }),
        "absolute"));
}
}

@("check mode: drift is reported, nothing runs")
unittest
{
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "v\n", ""),
    CommandResult(0, "web\n", ""),
    CommandResult(0, "web h1\n", ""),
    CommandResult(0, "", ""),   // no containers
];
TaskContext ctx = TaskContext(t, true, "fakehost", "/tmp");
auto r = runComposeModule(CP("/srv/app", "compose.yml"), ctx);
assert(r.changed, r.msg);
assert(t.commands.length == 4, t.commands.join(" | "));
foreach (c; t.commands)
    assert(!canFind(c, " up "), c);
}
