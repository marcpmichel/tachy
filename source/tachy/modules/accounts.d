module tachy.modules.accounts;

/**
 * `group` and `user` modules — idempotent account management through
 * the standard shadow-utils commands (groupadd/groupmod/groupdel,
 * useradd/usermod/userdel).
 *
 *     group.name  = "deploy"                  (the table key)
 *     group.state = "present"                 # default; "absent" removes
 *
 *     user.name        = "deploy"             (the table key)
 *     user.group       = "deploy"             # primary group, default: a
 *                                             # group named after the user
 *     user.groups      = ["docker"]           # supplementary groups; only
 *                                             # ADDS missing memberships
 *     user.shell       = "/bin/bash"          # default at creation: /bin/sh
 *     user.comment     = "epices user"        # GECOS, default: none
 *     user.create_home = true                 # creation only: -m / -M
 *     user.home        = "/home/epices"       # default at creation: /home/<name>
 *     user.state       = "present"            # default; "absent" removes
 *     user.remove_home = false                # with state=absent: userdel -r
 *
 * Semantics follow the other ensure modules: present users/groups are
 * created when missing; attributes that were set explicitly are enforced
 * on existing accounts (drift is repaired with usermod), while unset
 * attributes only shape creation and are left alone afterwards.
 * `groups` is purely additive — memberships outside the list are never
 * removed.  Existence is probed with `getent` (glibc), so the target
 * must be a mainstream Linux besides the usual coreutils assumption.
 */
import std.algorithm.iteration : filter;
import std.array : array, join;
import std.conv : text;
import std.string : indexOf, split, strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, optBool, optStr, requireStr;
import tachy.transport : Transport;
import tachy.value : Val, optStringArray;

// ---------------------------------------------------------------------------
// group
// ---------------------------------------------------------------------------

TaskResult runGroupModule(Val[string] params, TaskContext ctx)
{
    auto t = ctx.transport;
    const string name = requireStr(params, "name", "group");
    const string state = optStr(params, "state", "group", "present");
    if (state != "present" && state != "absent")
        throw new TachyError("group: 'state' must be \"present\" or \"absent\", not \"" ~ state ~ "\"");

    string[] actions;
    string[] details;
    const bool exists = groupExists(t, name);

    if (state == "present")
    {
        if (!exists)
        {
            mustRun(t, ctx, details, "groupadd -- " ~ q(name), "create group '" ~ name ~ "'");
            actions ~= "created group";
        }
    }
    else if (exists)
    {
        try
            mustRun(t, ctx, details, "groupdel -- " ~ q(name), "delete group '" ~ name ~ "'");
        catch (TachyError e)
        {
            if (indexOf(e.msg, "primary group") >= 0)
                throw new TachyError(e.msg ~ " (a user still has '" ~ name
                    ~ "' as primary group; remove the user first — e.g. a [users] "
                    ~ "removal in an earlier tasks file)");
            throw e;
        }
        actions ~= "removed group";
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length ? actions.join("; ")
        : state == "present" ? "group present" : "already absent";
    res.details = details;
    return res;
}

// ---------------------------------------------------------------------------
// user
// ---------------------------------------------------------------------------

TaskResult runUserModule(Val[string] params, TaskContext ctx)
{
    auto t = ctx.transport;
    const string name = requireStr(params, "name", "user");
    const string state = optStr(params, "state", "user", "present");
    if (state != "present" && state != "absent")
        throw new TachyError("user: 'state' must be \"present\" or \"absent\", not \"" ~ state ~ "\"");

    const string group = optStr(params, "group", "user");
    const string[] groups = optStringArray(params, "groups", "user");
    const string shell = optStr(params, "shell", "user");
    const string comment = optStr(params, "comment", "user");
    const string home = optStr(params, "home", "user");
    const bool createHome = optBool(params, "create_home", "user", true);
    const bool removeHome = optBool(params, "remove_home", "user", false);
    if (removeHome && state == "present")
        throw new TachyError("user: 'remove_home' is only used with state = \"absent\"");

    string[] actions;
    string[] details;
    const string[] entry = passwdEntry(t, name); // null when the user is missing
    const bool exists = entry !is null;

    if (state == "absent")
    {
        if (exists)
        {
            string del = "userdel";
            if (removeHome)
                del ~= " -r";
            mustRun(t, ctx, details, del ~ " -- " ~ q(name), "delete user '" ~ name ~ "'");
            actions ~= removeHome ? "removed user (and home)" : "removed user";
        }
    }
    else if (!exists)
    {
        // Creation.  The primary group: an explicit `group` must already
        // exist ([groups] manages that); without one, reuse a group named
        // after the user when it exists, otherwise let useradd create it.
        string primary = group.length ? group : name;
        if (!groupExists(t, primary))
        {
            if (group.length)
                throw new TachyError("user: primary group '" ~ group
                    ~ "' does not exist; ensure it with [groups] first");
            primary = null; // useradd creates the per-user group
        }

        foreach (g; groups)
            if (!groupExists(t, g))
                throw new TachyError("user: supplementary group '" ~ g
                    ~ "' does not exist; ensure it with [groups] first");

        string cmd = "useradd";
        if (primary.length)
            cmd ~= " -g " ~ q(primary);
        if (groups.length)
            cmd ~= " -G " ~ q(groups.join(","));
        cmd ~= " -s " ~ q(shell.length ? shell : "/bin/sh");
        if (comment.length)
            cmd ~= " -c " ~ q(comment);
        if (home.length)
            cmd ~= " -d " ~ q(home);
        cmd ~= createHome ? " -m" : " -M";
        cmd ~= " -- " ~ q(name);
        mustRun(t, ctx, details, cmd, "create user '" ~ name ~ "'");
        actions ~= "created user";
    }
    else
    {
        // Existing user: enforce the attributes that were set (unset
        // attributes only shape creation and are left alone).
        const string[] fields = entry; // name x uid gid gecos home shell

        string flags;
        if (group.length)
        {
            const string current = groupNameForGid(t, fields[3]);
            if (current != group)
            {
                flags ~= " -g " ~ q(group);
                actions ~= text("primary group ", current, " -> ", group);
            }
        }
        if (shell.length && shell != fields[6])
        {
            flags ~= " -s " ~ q(shell);
            actions ~= text("shell ", fields[6], " -> ", shell);
        }
        if (comment.length && comment != fields[4])
        {
            flags ~= " -c " ~ q(comment);
            actions ~= text("comment ", fields[4].length ? fields[4] : "(none)",
                " -> ", comment);
        }
        if (home.length && home != fields[5])
        {
            flags ~= " -m -d " ~ q(home); // -m moves the existing home
            actions ~= text("home ", fields[5], " -> ", home);
        }

        if (groups.length)
        {
            // Additive only: memberships outside the list are kept.
            auto r = t.run("id -nG -- " ~ q(name));
            if (!r.ok)
                throw new TachyError("user: cannot list groups of '" ~ name ~ "': " ~ r.errText.strip);
            const string[] current = split(r.outText.strip);
            const string[] missing = groups.filter!(g => !canFindValue(current, g)).array;
            if (missing.length)
            {
                flags ~= " -aG " ~ q(missing.join(","));
                actions ~= "added to " ~ missing.join(", ");
            }
        }

        if (flags.length)
            mustRun(t, ctx, details, "usermod" ~ flags ~ " -- " ~ q(name),
                "modify user '" ~ name ~ "'");
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length ? actions.join("; ")
        : state == "present" ? "user present" : "already absent";
    res.details = details;
    return res;
}

// ---------------------------------------------------------------------------
// Probes and helpers.
// ---------------------------------------------------------------------------

private string q(string s) @safe pure
{
    import tachy.transport : shQuote;
    return shQuote(s);
}

private bool groupExists(Transport t, string name)
{
    return t.run("getent group " ~ q(name)).ok;
}

/// The colon-separated fields of a passwd entry, or null when the user
/// does not exist.  A single getent doubles as the existence probe.
private string[] passwdEntry(Transport t, string name)
{
    auto r = t.run("getent passwd " ~ q(name));
    if (!r.ok)
        return null;
    string[] fields = split(r.outText.strip, ":");
    if (fields.length != 7)
        throw new TachyError("user: unexpected passwd entry for '" ~ name ~ "': " ~ r.outText.strip);
    return fields;
}

/// The group name owning a gid.
private string groupNameForGid(Transport t, string gid)
{
    auto r = t.run("getent group " ~ q(gid));
    if (!r.ok)
        throw new TachyError("user: cannot resolve primary group id " ~ gid);
    const string[] fields = split(r.outText.strip, ":");
    if (fields.length < 3 || fields[2] != gid)
        throw new TachyError("user: unexpected group entry for id " ~ gid ~ ": " ~ r.outText.strip);
    return fields[0];
}

private bool canFindValue(in string[] haystack, string needle) @safe pure
{
    foreach (h; haystack)
        if (h == needle)
            return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests with a scripted transport: command construction only, no real
// account is touched.
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

    unittest // group: create, idempotence, removal
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

    unittest // user: creation with defaults and with attributes
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

    unittest // user: existing — drift repair and idempotence
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

    unittest // user: removal
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
}
