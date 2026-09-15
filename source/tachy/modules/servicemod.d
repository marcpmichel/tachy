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
import std.file : read;
import std.string : indexOf, join, strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, mustRunWithInput, optBool, optStr, requireStr;
import tachy.transport : StatKind, Transport, shQuote, statPath;
import tachy.value : Val;
import tachy.vars : renderTemplateFile, resolveEntryPath;

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
        content = renderTemplateFile((*tpl).str_, ctx.tasksFileDir,
            ctx.vars, params, "service: ");
    }
    else if (auto src = "src" in params)
    {
        if ((*src).kind != Val.Kind.string_)
            throw new TachyError("service: 'src' must be a string, not a "
                ~ (*src).typeName());
        const string srcPath = resolveEntryPath((*src).str_, ctx.tasksFileDir);
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
