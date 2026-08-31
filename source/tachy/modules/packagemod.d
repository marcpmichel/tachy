module tachy.modules.packagemod;

/**
 * `package` module — idempotent system package management.  Entries are
 * keyed by "<manager>:<name>"; only "apt" is supported for now:
 *
 *     package.name    = "apt:vim"           (the table key)
 *     package.version = "latest"            # default; an explicit version
 *                                           # pins the package exactly
 *     package.present = true                # default; false removes it
 *
 * State is probed read-only with dpkg-query; mutations go through
 * apt-get with DEBIAN_FRONTEND=noninteractive so installs never block
 * on configuration prompts:
 *
 *   - missing            -> apt-get install -y <pkg>
 *   - pinned version and the installed one differs
 *                        -> apt-get install -y --allow-downgrades <pkg>=<v>
 *   - present = false    -> apt-get remove -y <pkg>
 *
 * "latest" only ensures presence: checking for newer candidates would
 * need network access on every run, so version drift is not detected
 * unless an exact version is pinned (write it epoch-qualified, as
 * dpkg-query reports it, e.g. "2:8.1.0875-5").
 */
import std.array : join;
import std.conv : text;
import std.string : split, strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, optBool, optStr, requireStr;
import tachy.transport : Transport;
import tachy.value : Val;

/// Split and validate a "<manager>:<name>" package key.
private void parseKey(string key, out string manager, out string pkg, string context)
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

    if (!canFind(key, ":"))
        throw new TachyError(context ~ ": package keys must be \"<manager>:<name>\""
            ~ " like \"apt:vim\", not \"" ~ key ~ "\"");
    const size_t colon = indexOf(key, ':');
    manager = key[0 .. colon];
    pkg = key[colon + 1 .. $];
    if (manager != "apt")
        throw new TachyError(context ~ ": unsupported package manager '" ~ manager
            ~ "' (only \"apt\" is implemented)");
    if (!pkg.length)
        throw new TachyError(context ~ ": empty package name in \"" ~ key ~ "\"");
}

/// Validate a package key without running anything (load time).
void validatePackageKey(string key, string context)
{
    string manager, pkg;
    parseKey(key, manager, pkg, context);
}

TaskResult runPackageModule(Val[string] params, TaskContext ctx)
{
    auto t = ctx.transport;
    const string key = requireStr(params, "name", "package");
    const string ver = optStr(params, "version", "package", "latest");
    const bool present = optBool(params, "present", "package", true);

    string manager, pkg;
    parseKey(key, manager, pkg, "package '" ~ key ~ "'");

    string[] actions;
    string[] details;

    // Read-only probe: "install ok installed 2:1.0-1" when installed.
    auto probe = t.run("dpkg-query -W -f=" ~ q("${Status} ${Version}") ~ " " ~ q(pkg));
    string installedVersion;
    if (probe.ok)
    {
        const string[] tokens = split(probe.outText.strip);
        const string status = tokens.length > 1
            ? tokens[0 .. $ - 1].join(" ") : probe.outText.strip;
        if (status == "install ok installed")
            installedVersion = tokens[$ - 1];
    }

    if (present)
    {
        if (!installedVersion.length)
        {
            const string spec = ver == "latest" ? pkg : pkg ~ "=" ~ ver;
            mustRun(t, ctx, details,
                "DEBIAN_FRONTEND=noninteractive apt-get install -y " ~ q(spec),
                "install package '" ~ pkg ~ "'");
            actions ~= "installed";
        }
        else if (ver != "latest" && ver != installedVersion)
        {
            mustRun(t, ctx, details,
                "DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "
                    ~ q(pkg ~ "=" ~ ver),
                "pin package '" ~ pkg ~ "' to " ~ ver);
            actions ~= text("version ", installedVersion, " -> ", ver);
        }
    }
    else if (installedVersion.length)
    {
        mustRun(t, ctx, details,
            "DEBIAN_FRONTEND=noninteractive apt-get remove -y " ~ q(pkg),
            "remove package '" ~ pkg ~ "'");
        actions ~= "removed";
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length ? actions.join("; ")
        : present ? "installed (" ~ installedVersion ~ ")" : "already absent";
    res.details = details;
    return res;
}

private string q(string s) @safe pure
{
    import tachy.transport : shQuote;
    return shQuote(s);
}

// ---------------------------------------------------------------------------
// Tests with a scripted transport: command construction only.
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown;
    import tachy.modules.fake : FakeTransport;
    import tachy.transport : CommandResult;

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

    unittest // install when missing, idempotence when installed
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

    unittest // version pinning
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

    unittest // removal
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

    unittest // key and parameter errors
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
}
