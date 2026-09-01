module tachy.modules.servicemod;

/**
 * `service` module — idempotent systemd service management.
 *
 *     service.name     = "nginx"                    (required)
 *     service.state    = "started"                  # started | stopped | restarted | reloaded | enabled
 *     service.enabled  = true                       # enable/disable at boot
 *     service.src      = "units/nginx.service"      # manage the unit file (verbatim copy)
 *     service.template = "units/nginx.service.tmpl" # manage the unit file (rendered)
 *     service.vars     = { user = "www" }           # local template context (with template only)
 *
 * `started`/`stopped`/`enabled` only act when the current state differs.
 * `restarted`/`reloaded` always act (that is their point) and always report
 * a change.  `state = "enabled"` ensures boot enablement without touching
 * the running state.  With `src` or `template` the unit file itself is
 * managed first (checksum-compared, then written and `daemon-reload`d);
 * a changed unit file does not restart a running service — use
 * `state = "restarted"` to apply it.  Non-systemd targets are rejected
 * with a clear error.
 */
import std.algorithm.searching : canFind;
import std.array : split;
import std.file : read, readText;
import std.path : buildPath, isAbsolute;
import std.string : indexOf, join, strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, mustRunWithInput, optBool, optStr, requireStr;
import tachy.transport : StatKind, Transport, shQuote, statPath;
import tachy.value : Val;
import tachy.vars : deepMerge, renderTemplate;

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
            case "enabled":
                break;
            default:
                throw new TachyError("service: invalid state '" ~ state
                    ~ "' (expected started, stopped, restarted, reloaded or enabled)");
        }
    const bool hasEnabled = ("enabled" in params) !is null;
    const bool enabled = hasEnabled ? optBool(params, "enabled", "service") : false;
    if (state == "enabled" && hasEnabled && !enabled)
        throw new TachyError("service: 'state = \"enabled\"' contradicts 'enabled = false'");

    const bool hasSrc = ("src" in params) !is null;
    const bool hasTemplate = ("template" in params) !is null;
    if (!state.length && !hasEnabled && !hasSrc && !hasTemplate)
        throw new TachyError("service: at least one of 'state', 'enabled', 'src' or 'template' is required");

    {
        auto r = t.run("command -v systemctl");
        if (!r.ok)
            throw new TachyError("service: systemctl is not available on " ~ ctx.hostName
                ~ "; only systemd targets are supported");
    }

    string[] actions;
    string[] details;

    // The unit file first, so a subsequent start uses the new definition.
    if (hasSrc || hasTemplate)
        ensureUnitFile(t, ctx, params, name, actions, details);

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
    // state = "enabled": ensure boot enablement without touching the
    // running state (the 'enabled' param above may have done it already).
    if (state == "enabled" && !(hasEnabled && enabled))
    {
        const string word = systemctlWord(t, "is-enabled", name);
        if (word == "masked")
            throw new TachyError("service: unit '" ~ name ~ "' is masked; unmask it before enabling");
        if (word != "enabled")
        {
            mustRun(t, ctx, details, "systemctl enable " ~ shQuote(name), "enable " ~ name);
            actions ~= "enabled";
        }
    }

    if (state.length && state != "enabled")
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

/// Manage the unit file of a service: `template` renders the given file
/// against the host scope merged with the entry's local `vars` (local
/// wins); `src` copies bytes verbatim.  Paths resolve like `file.src`,
/// against the defining tasks file's directory.  The result is
/// checksum-compared against `/etc/systemd/system/<unit>` and, on drift,
/// written and followed by `systemctl daemon-reload` — a running service
/// is not restarted (use `state = "restarted"` to apply the new unit).
private void ensureUnitFile(Transport t, TaskContext ctx, in Val[string] params,
    string name, ref string[] actions, ref string[] details)
{
    const string unit = canFind(name, ".") ? name : name ~ ".service";
    const string path = "/etc/systemd/system/" ~ unit;

    string content;
    if (auto tpl = "template" in params)
    {
        if ((*tpl).kind != Val.Kind.string_)
            throw new TachyError("service: 'template' must be a string, not a "
                ~ (*tpl).typeName());
        const string tplPath = isAbsolute((*tpl).str_)
            ? (*tpl).str_ : buildPath(ctx.tasksFileDir, (*tpl).str_);
        Val[string] tplScope = ctx.vars;
        if (auto v = "vars" in params)
            tplScope = deepMerge(ctx.vars, (*v).table_);
        try
            content = renderTemplate(readText(tplPath), tplScope);
        catch (TachyError e)
            throw new TachyError("service: cannot render '" ~ tplPath ~ "': " ~ e.msg);
        catch (Exception e)
            throw new TachyError("service: cannot read template '" ~ tplPath ~ "': " ~ e.msg);
    }
    else if (auto src = "src" in params)
    {
        if ((*src).kind != Val.Kind.string_)
            throw new TachyError("service: 'src' must be a string, not a "
                ~ (*src).typeName());
        const string srcPath = isAbsolute((*src).str_)
            ? (*src).str_ : buildPath(ctx.tasksFileDir, (*src).str_);
        try
            content = cast(string) read(srcPath);
        catch (Exception e)
            throw new TachyError("service: cannot read src '" ~ srcPath ~ "': " ~ e.msg);
    }
    else
        assert(false, "ensureUnitFile called without src or template");

    const auto st = statPath(t, path);
    if (st.kind == StatKind.directory)
        throw new TachyError("service: unit path '" ~ path ~ "' exists and is a directory");

    // Compare by checksum: only the hash crosses the transport.
    bool same;
    if (st.kind == StatKind.file)
    {
        auto r = t.run("sha256sum -- " ~ shQuote(path));
        if (r.ok)
            same = split(r.outText.strip)[0] == sha256Hex(content);
    }
    if (!same)
    {
        mustRunWithInput(t, ctx, details, "cat > " ~ shQuote(path), content,
            "write unit '" ~ path ~ "'");
        mustRun(t, ctx, details, "systemctl daemon-reload",
            "daemon-reload after writing " ~ path);
        actions ~= st.kind == StatKind.nonexistent ? "created unit file" : "updated unit file";
    }
}

/// Lowercase sha256 hex of `bytes` (compared against sha256sum output).
private string sha256Hex(string bytes) @safe pure
{
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : toLower;
    return toHexString(sha256Of(cast(const(ubyte)[]) bytes)).toLower();
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

// ---------------------------------------------------------------------------
// Unit file management (src / template / vars).
// ---------------------------------------------------------------------------

version (unittest) private
{
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
}

unittest // template: local vars win over the host scope; create + daemon-reload
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

unittest // template: checksum match + active -> fully idempotent
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

unittest // template drift: updated unit file, daemon-reload, no restart
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

unittest // src: verbatim copy + unit-file-only management (no state)
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

unittest // state = "enabled": enable without touching the running state
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

unittest // check mode: unit file write and daemon-reload recorded, not run
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

unittest // missing template / src files are errors naming the path
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
