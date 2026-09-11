/// Tests for tachy.modules.servicemod, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.servicemod;

import tachy.modules.servicemod;
import tachy.tests.fake;

import tachy.tests.fake : FakeTransport;
import tachy.transport : CommandResult;
import tachy.value : Val;
import tachy.modules : TaskContext;
import tachy.errors : TachyError;
import std.array : join;
import std.string : indexOf;

TaskContext fakeCtx(ref FakeTransport t)
{
    return TaskContext(t, false, "fakehost", "/tmp");
}

Val[string] SP(string name, string state)
{
    Val[string] p;
    p["name"] = Val(name);
    if (state.length)
        p["state"] = Val(state);
    return p;
}

@("started + already active -> unchanged")
unittest
{
auto t = new FakeTransport;
t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "active\n", "")];
auto r = runServiceModule(SP("nginx", "started"), fakeCtx(t));
assert(!r.changed, r.msg);
assert(t.commands.length == 2);
assert(t.commands[1].indexOf("is-active") >= 0);
}

@("started + inactive -> start, changed")
unittest
{
auto t = new FakeTransport;
t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(3, "inactive\n", ""), CommandResult(0, "", "")];
auto r = runServiceModule(SP("nginx", "started"), fakeCtx(t));
assert(r.changed);
assert(t.commands.length == 3 && t.commands[2].indexOf("systemctl start") >= 0);
}

@("stopped + active -> stop, changed; stopped + inactive -> unchanged")
unittest
{
auto t = new FakeTransport;
t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "active\n", ""), CommandResult(0, "", "")];
assert(runServiceModule(SP("nginx", "stopped"), fakeCtx(t)).changed);

auto t2 = new FakeTransport;
t2.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(3, "inactive\n", "")];
assert(!runServiceModule(SP("nginx", "stopped"), fakeCtx(t2)).changed);
}

@("restart always acts")
unittest
{
auto t = new FakeTransport;
t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "active\n", ""), CommandResult(0, "", "")];
auto r = runServiceModule(SP("nginx", "restarted"), fakeCtx(t));
assert(r.changed && t.commands[2].indexOf("systemctl restart") >= 0);
}

@("enable when disabled")
unittest
{
auto t = new FakeTransport;
t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(1, "disabled\n", ""), CommandResult(0, "", "")];
Val[string] p;
p["name"] = Val("nginx");
p["enabled"] = Val(true);
auto r = runServiceModule(p, fakeCtx(t));
assert(r.changed && t.commands[2].indexOf("systemctl enable") >= 0);
}

@("already enabled -> unchanged")
unittest
{
auto t = new FakeTransport;
t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "enabled\n", "")];
Val[string] p;
p["name"] = Val("nginx");
p["enabled"] = Val(true);
assert(!runServiceModule(p, fakeCtx(t)).changed);
}

@("error paths")
unittest
{
import std.exception : assertThrown;
// no systemctl on target
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(1, "", "not found")];
    assertThrown!(TachyError)(runServiceModule(SP("x", "started"), fakeCtx(t)));
}
// neither state nor enabled
{
    auto t = new FakeTransport;
    assertThrown!(TachyError)(runServiceModule(SP("x", ""), fakeCtx(t)));
}
// invalid state
{
    auto t = new FakeTransport;
    assertThrown!(TachyError)(runServiceModule(SP("x", "running"), fakeCtx(t)));
}
// static unit cannot be enabled
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(1, "static\n", "")];
    Val[string] p;
    p["name"] = Val("app");
    p["enabled"] = Val(true);
    assertThrown!(TachyError)(runServiceModule(p, fakeCtx(t)));
}
// masked unit cannot be enabled
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(1, "masked\n", "")];
    Val[string] p;
    p["name"] = Val("app");
    p["enabled"] = Val(true);
    assertThrown!(TachyError)(runServiceModule(p, fakeCtx(t)));
}
// unit name that would look like an option
{
    auto t = new FakeTransport;
    assertThrown!(TachyError)(runServiceModule(SP("-evil", "started"), fakeCtx(t)));
}
}

// ---------------------------------------------------------------------------
// Unit file management (src / template / vars).
// ---------------------------------------------------------------------------

import std.algorithm.searching : canFind;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.string : toLower;

string utDigestHex(string s)
{
    return toHexString(sha256Of(cast(const(ubyte)[]) s)).toLower();
}

Val utTbl(Val[string] t)
{
    Val v;
    v.kind = Val.Kind.table_;
    v.table_ = t;
    return v;
}

@("template: local vars win over the host scope; create + daemon-reload")
unittest
{
auto dir = buildPath(tempDir, "tachy_svcmod_ut");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(buildPath(dir, "units"));
scope (exit) if (exists(dir)) rmdirRecurse(dir);
write(buildPath(dir, "units", "app.service.tmpl"),
    "[Service]\nExecStart=/bin/sleep {{ ttl }}\nUser={{ service_user }}\n");

auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "/usr/bin/systemctl\n", ""), // command -v systemctl
    CommandResult(0, "__TACHY_ABSENT__\n", ""),    // stat unit file
    CommandResult(0, "", ""),                      // cat > unit file
    CommandResult(0, "", ""),                      // daemon-reload
    CommandResult(3, "inactive\n", ""),            // is-active
    CommandResult(0, "", ""),                      // start
];
Val[string] hostVars;
hostVars["service_user"] = Val("www-data");
hostVars["ttl"] = Val("9999"); // local vars must win
Val[string] local;
local["ttl"] = Val("3600");
Val[string] p;
p["name"] = Val("app");
p["state"] = Val("started");
p["template"] = Val("units/app.service.tmpl");
p["vars"] = utTbl(local);

auto ctx = TaskContext(t, false, "fakehost", dir, hostVars);
auto r = runServiceModule(p, ctx);
assert(r.changed, r.msg);
assert(canFind(t.lastInput, "/bin/sleep 3600"), t.lastInput);
assert(canFind(t.lastInput, "User=www-data"), t.lastInput);
assert(canFind(r.msg, "created unit file") && canFind(r.msg, "started"), r.msg);
assert(canFind(t.commands[2], "/etc/systemd/system/app.service"));
assert(canFind(t.commands[3], "daemon-reload"));
}

@("template: checksum match + active -> fully idempotent")
unittest
{
auto dir = buildPath(tempDir, "tachy_svcmod_ut2");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) if (exists(dir)) rmdirRecurse(dir);
write(buildPath(dir, "app.service.tmpl"), "[Service]\nExecStart=/bin/true\n");

const string rendered = "[Service]\nExecStart=/bin/true\n";
auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "/usr/bin/systemctl\n", ""),
    CommandResult(0, "regular file|644|root|root\n", ""),
    CommandResult(0, utDigestHex(rendered) ~ "  /etc/systemd/system/app.service\n", ""),
    CommandResult(0, "active\n", ""),
];
Val[string] p;
p["name"] = Val("app.service");
p["state"] = Val("started");
p["template"] = Val("app.service.tmpl");
auto r = runServiceModule(p, TaskContext(t, false, "fakehost", dir));
assert(!r.changed, r.msg);
assert(t.commands.length == 4, t.commands.join(" | "));
}

@("template drift: updated unit file, daemon-reload, no restart")
unittest
{
auto dir = buildPath(tempDir, "tachy_svcmod_ut3");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) if (exists(dir)) rmdirRecurse(dir);
write(buildPath(dir, "app.service.tmpl"), "[Service]\nExecStart=/bin/sleep 1\n");

auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "/usr/bin/systemctl\n", ""),
    CommandResult(0, "regular file|644|root|root\n", ""),
    CommandResult(0, "0000000000000000000000000000000000000000000000000000000000000000  x\n", ""),
    CommandResult(0, "", ""),           // cat >
    CommandResult(0, "", ""),           // daemon-reload
    CommandResult(0, "active\n", ""),   // is-active: running stays running
];
Val[string] p;
p["name"] = Val("app.service");
p["state"] = Val("started");
p["template"] = Val("app.service.tmpl");
auto r = runServiceModule(p, TaskContext(t, false, "fakehost", dir));
assert(r.changed && canFind(r.msg, "updated unit file"), r.msg);
foreach (c; t.commands)
    assert(!canFind(c, "systemctl restart"), c); // restart is explicit
}

@("src: verbatim copy + unit-file-only management (no state)")
unittest
{
auto dir = buildPath(tempDir, "tachy_svcmod_ut4");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) if (exists(dir)) rmdirRecurse(dir);
write(buildPath(dir, "plain.service"), "[Service]\nExecStart=/bin/true\n");

auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "/usr/bin/systemctl\n", ""),
    CommandResult(0, "__TACHY_ABSENT__\n", ""),
    CommandResult(0, "", ""),
    CommandResult(0, "", ""),
];
Val[string] p;
p["name"] = Val("plain.service");
p["src"] = Val("plain.service");
auto r = runServiceModule(p, TaskContext(t, false, "fakehost", dir));
assert(r.changed && canFind(r.msg, "created unit file"), r.msg);
assert(t.commands.length == 4, t.commands.join(" | "));
assert(t.lastInput == "[Service]\nExecStart=/bin/true\n");
}

@("state = \"enabled\": enable without touching the running state")
unittest
{
// disabled -> enable
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/usr/bin/systemctl\n", ""),
        CommandResult(1, "disabled\n", ""),
        CommandResult(0, "", ""),
    ];
    auto r = runServiceModule(SP("app", "enabled"), fakeCtx(t));
    assert(r.changed && canFind(r.msg, "enabled"), r.msg);
    assert(t.commands.length == 3 && canFind(t.commands[2], "systemctl enable"));
}
// already enabled -> unchanged, is-active never queried
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/usr/bin/systemctl\n", ""),
        CommandResult(0, "enabled\n", ""),
    ];
    auto r = runServiceModule(SP("app", "enabled"), fakeCtx(t));
    assert(!r.changed, r.msg);
    foreach (c; t.commands)
        assert(!canFind(c, "is-active"), c);
}
// contradicts enabled = false
{
    import std.exception : assertThrown;
    auto t = new FakeTransport;
    Val[string] p;
    p["name"] = Val("app");
    p["state"] = Val("enabled");
    p["enabled"] = Val(false);
    assertThrown!(TachyError)(runServiceModule(p, fakeCtx(t)));
}
}

@("check mode: unit file write and daemon-reload recorded, not run")
unittest
{
auto dir = buildPath(tempDir, "tachy_svcmod_ut5");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) if (exists(dir)) rmdirRecurse(dir);
write(buildPath(dir, "app.service.tmpl"), "[Service]\nExecStart=/bin/true\n");

auto t = new FakeTransport;
t.replies ~= [
    CommandResult(0, "/usr/bin/systemctl\n", ""),
    CommandResult(0, "__TACHY_ABSENT__\n", ""),
];
Val[string] p;
p["name"] = Val("app");
p["template"] = Val("app.service.tmpl");
auto ctx = TaskContext(t, true, "fakehost", dir);
auto r = runServiceModule(p, ctx);
assert(r.changed && canFind(r.msg, "created unit file"), r.msg);
assert(t.commands.length == 2, t.commands.join(" | ")); // nothing executed
}

@("missing template / src files are errors naming the path")
unittest
{
import std.exception : assertThrown;
auto dir = buildPath(tempDir, "tachy_svcmod_ut6");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) if (exists(dir)) rmdirRecurse(dir);

Val[string] p;
p["name"] = Val("app");
p["state"] = Val("started");
p["template"] = Val("nope.tmpl");
auto t = new FakeTransport;
t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", "")];
string msg;
try
{
    runServiceModule(p, TaskContext(t, false, "fakehost", dir));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "nope.tmpl"), msg);
}
