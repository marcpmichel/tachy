module tachy.modules.servicemod;

/**
 * `service` module — idempotent systemd service management.
 *
 *     service.name    = "nginx"                    (required)
 *     service.state   = "started"                  # started | stopped | restarted | reloaded
 *     service.enabled = true                       # enable/disable at boot
 *
 * `started`/`stopped`/`enabled` only act when the current state differs.
 * `restarted`/`reloaded` always act (that is their point) and always report
 * a change.  Non-systemd targets are rejected with a clear error.
 */
import std.string : indexOf, join, strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, optBool, optStr, requireStr;
import tachy.transport : Transport, shQuote;
import tachy.value : Val;

TaskResult runServiceModule(Val[string] params, TaskContext ctx)
{
    auto t = ctx.transport;
    const string name = requireStr(params, "name", "service");
    if (!name.length || name[0] == '-')
        throw new TachyError("service: invalid unit name '" ~ name ~ "'");

    const string state = optStr(params, "state", "service");
    if (state.length)
        switch (state)
        {
            case "started":
            case "stopped":
            case "restarted":
            case "reloaded":
                break;
            default:
                throw new TachyError("service: invalid state '" ~ state
                    ~ "' (expected started, stopped, restarted or reloaded)");
        }

    const bool hasEnabled = ("enabled" in params) !is null;
    const bool enabled = hasEnabled ? optBool(params, "enabled", "service") : false;
    if (!state.length && !hasEnabled)
        throw new TachyError("service: at least one of 'state' or 'enabled' is required");

    {
        auto r = t.run("command -v systemctl");
        if (!r.ok)
            throw new TachyError("service: systemctl is not available on " ~ ctx.hostName
                ~ "; only systemd targets are supported");
    }

    string[] actions;
    string[] details;

    if (hasEnabled)
    {
        const string word = systemctlWord(t, "is-enabled", name);
        if (word == "enabled")
        {
            if (!enabled)
            {
                mustRun(t, ctx, details, "systemctl disable " ~ shQuote(name), "disable " ~ name);
                actions ~= "disabled";
            }
        }
        else if (word == "disabled")
        {
            if (enabled)
            {
                mustRun(t, ctx, details, "systemctl enable " ~ shQuote(name), "enable " ~ name);
                actions ~= "enabled";
            }
        }
        else if (word == "masked")
        {
            if (enabled)
                throw new TachyError("service: unit '" ~ name ~ "' is masked; unmask it before enabling");
        }
        else if (enabled)
        {
            throw new TachyError("service: unit '" ~ name ~ "' is '" ~ word
                ~ "' and cannot be enabled");
        }
    }

    if (state.length)
    {
        const string word = systemctlWord(t, "is-active", name);
        switch (state)
        {
            case "started":
                if (word != "active")
                {
                    mustRun(t, ctx, details, "systemctl start " ~ shQuote(name), "start " ~ name);
                    actions ~= "started";
                }
                break;
            case "stopped":
                if (word == "active")
                {
                    mustRun(t, ctx, details, "systemctl stop " ~ shQuote(name), "stop " ~ name);
                    actions ~= "stopped";
                }
                break;
            case "restarted":
                mustRun(t, ctx, details, "systemctl restart " ~ shQuote(name), "restart " ~ name);
                actions ~= "restarted";
                break;
            case "reloaded":
                mustRun(t, ctx, details, "systemctl reload " ~ shQuote(name), "reload " ~ name);
                actions ~= "reloaded";
                break;
            default:
                assert(0, "unreachable: state validated above");
        }
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length == 0 ? "service '" ~ name ~ "' up to date" : actions.join(", ");
    res.details = details;
    return res;
}

/// Query `systemctl is-<sub> <name>` and return the first output word.
private string systemctlWord(Transport t, string sub, string name)
{
    auto r = t.run("systemctl " ~ sub ~ " " ~ shQuote(name));
    auto word = firstLine(r.outText);
    if (!word.length && !r.ok)
    {
        auto m = r.errText.strip;
        if (!m.length)
            m = "exit status " ~ importIntText(r.status);
        throw new TachyError("systemctl " ~ sub ~ " " ~ name ~ " failed: " ~ m);
    }
    return word;
}

private string firstLine(string s) @safe pure
{
    import std.string : lineSplitter;
    foreach (l; lineSplitter(s))
        return l.strip();
    return "";
}

private string importIntText(int v) @safe pure
{
    import std.conv : text;
    return text(v);
}

// ---------------------------------------------------------------------------
// Tests with a scripted transport: decision logic only, no real systemd.
// ---------------------------------------------------------------------------

version (unittest) private
{
    import tachy.modules.fake : FakeTransport;
    import tachy.transport : CommandResult;

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
}

unittest // started + already active -> unchanged
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "active\n", "")];
    auto r = runServiceModule(SP("nginx", "started"), fakeCtx(t));
    assert(!r.changed, r.msg);
    assert(t.commands.length == 2);
    assert(t.commands[1].indexOf("is-active") >= 0);
}

unittest // started + inactive -> start, changed
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(3, "inactive\n", ""), CommandResult(0, "", "")];
    auto r = runServiceModule(SP("nginx", "started"), fakeCtx(t));
    assert(r.changed);
    assert(t.commands.length == 3 && t.commands[2].indexOf("systemctl start") >= 0);
}

unittest // stopped + active -> stop, changed; stopped + inactive -> unchanged
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "active\n", ""), CommandResult(0, "", "")];
    assert(runServiceModule(SP("nginx", "stopped"), fakeCtx(t)).changed);

    auto t2 = new FakeTransport;
    t2.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(3, "inactive\n", "")];
    assert(!runServiceModule(SP("nginx", "stopped"), fakeCtx(t2)).changed);
}

unittest // restart always acts
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "active\n", ""), CommandResult(0, "", "")];
    auto r = runServiceModule(SP("nginx", "restarted"), fakeCtx(t));
    assert(r.changed && t.commands[2].indexOf("systemctl restart") >= 0);
}

unittest // enable when disabled
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(1, "disabled\n", ""), CommandResult(0, "", "")];
    Val[string] p;
    p["name"] = Val("nginx");
    p["enabled"] = Val(true);
    auto r = runServiceModule(p, fakeCtx(t));
    assert(r.changed && t.commands[2].indexOf("systemctl enable") >= 0);
}

unittest // already enabled -> unchanged
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(0, "/usr/bin/systemctl\n", ""), CommandResult(0, "enabled\n", "")];
    Val[string] p;
    p["name"] = Val("nginx");
    p["enabled"] = Val(true);
    assert(!runServiceModule(p, fakeCtx(t)).changed);
}

unittest // error paths
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
