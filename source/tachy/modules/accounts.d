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

TaskResult runGroupModule(Val[string] params, TaskContext ctx) {
    auto t = ctx.transport;
    const string name = requireStr(params, "name", "group");
    const string state = optStr(params, "state", "group", "present");
    if(state != "present" && state != "absent")
        throw new TachyError("group: 'state' must be \"present\" or \"absent\", not \"" ~ state ~ "\"");

    string[] actions;
    string[] details;
    const bool exists = groupExists(t, name);

    if(state == "present") {
        if(!exists) {
            mustRun(t, ctx, details, "groupadd -- " ~ q(name), "create group '" ~ name ~ "'");
            actions ~= "created group";
        }
    } else if(exists) {
        try
            mustRun(t, ctx, details, "groupdel -- " ~ q(name), "delete group '" ~ name ~ "'");
        catch(TachyError e) {
            if(indexOf(e.msg, "primary group") >= 0)
                throw new TachyError(e.msg ~ " (a user still has '" ~ name
                        ~ "' as primary group; remove the user first — e.g. a [users] "
                        ~ "removal in an earlier tasks file)");
            throw e;
        }
        actions ~= "removed group";
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length ? actions.join("; ") : state == "present" ? "group present" : "already absent";
    res.details = details;
    return res;
}

// ---------------------------------------------------------------------------
// user
// ---------------------------------------------------------------------------

TaskResult runUserModule(Val[string] params, TaskContext ctx) {
    auto t = ctx.transport;
    const string name = requireStr(params, "name", "user");
    const string state = optStr(params, "state", "user", "present");
    if(state != "present" && state != "absent")
        throw new TachyError("user: 'state' must be \"present\" or \"absent\", not \"" ~ state ~ "\"");

    const string group = optStr(params, "group", "user");
    const string[] groups = optStringArray(params, "groups", "user");
    const string shell = optStr(params, "shell", "user");
    const string comment = optStr(params, "comment", "user");
    const string home = optStr(params, "home", "user");
    const bool createHome = optBool(params, "create_home", "user", true);
    const bool removeHome = optBool(params, "remove_home", "user", false);
    if(removeHome && state == "present")
        throw new TachyError("user: 'remove_home' is only used with state = \"absent\"");

    string[] actions;
    string[] details;
    const string[] entry = passwdEntry(t, name); // null when the user is missing
    const bool exists = entry !is null;

    if(state == "absent") {
        if(exists) {
            string del = "userdel";
            if(removeHome)
                del ~= " -r";
            mustRun(t, ctx, details, del ~ " -- " ~ q(name), "delete user '" ~ name ~ "'");
            actions ~= removeHome ? "removed user (and home)" : "removed user";
        }
    } else if(!exists) {
        // Creation.  The primary group: an explicit `group` must already
        // exist ([groups] manages that); without one, reuse a group named
        // after the user when it exists, otherwise let useradd create it.
        string primary = group.length ? group : name;
        if(!groupExists(t, primary)) {
            if(group.length) {
                throw new TachyError("user: primary group '" ~ group
                        ~ "' does not exist; ensure it with [groups] first");
            }
            primary = null; // useradd creates the per-user group
        }

        foreach(g; groups) {
            if(!groupExists(t, g)) {
                throw new TachyError("user: supplementary group '" ~ g
                        ~ "' does not exist; ensure it with [groups] first");
            }
        }

        string cmd = "useradd";
        if(primary.length) cmd ~= " -g " ~ q(primary);
        if(groups.length) cmd ~= " -G " ~ q(groups.join(","));
        cmd ~= " -s " ~ q(shell.length ? shell : "/bin/sh");
        if(comment.length) cmd ~= " -c " ~ q(comment);
        if(home.length) cmd ~= " -d " ~ q(home);
        cmd ~= createHome ? " -m" : " -M";
        cmd ~= " -- " ~ q(name);
        mustRun(t, ctx, details, cmd, "create user '" ~ name ~ "'");
        actions ~= "created user";
    } else {
        // Existing user: enforce the attributes that were set (unset
        // attributes only shape creation and are left alone).
        const string[] fields = entry; // name x uid gid gecos home shell

        string flags;
        if(group.length) {
            const string current = groupNameForGid(t, fields[3]);
            if(current != group) {
                flags ~= " -g " ~ q(group);
                actions ~= text("primary group ", current, " -> ", group);
            }
        }
        if(shell.length && shell != fields[6]) {
            flags ~= " -s " ~ q(shell);
            actions ~= text("shell ", fields[6], " -> ", shell);
        }
        if(comment.length && comment != fields[4]) {
            flags ~= " -c " ~ q(comment);
            actions ~= text("comment ", fields[4].length ? fields[4] : "(none)",
                    " -> ", comment);
        }
        if(home.length && home != fields[5]) {
            flags ~= " -m -d " ~ q(home); // -m moves the existing home
            actions ~= text("home ", fields[5], " -> ", home);
        }

        if(groups.length) {
            // Additive only: memberships outside the list are kept.
            auto r = t.run("id -nG -- " ~ q(name));
            if(!r.ok)
                throw new TachyError("user: cannot list groups of '" ~ name ~ "': " ~ r.errText.strip);
            const string[] current = split(r.outText.strip);
            const string[] missing = groups.filter!(g => !canFindValue(current, g)).array;
            if(missing.length) {
                flags ~= " -aG " ~ q(missing.join(","));
                actions ~= "added to " ~ missing.join(", ");
            }
        }

        if(flags.length)
            mustRun(t, ctx, details, "usermod" ~ flags ~ " -- " ~ q(name),
                    "modify user '" ~ name ~ "'");
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length ? actions.join("; ") : state == "present" ? "user present" : "already absent";
    res.details = details;
    return res;
}

// ---------------------------------------------------------------------------
// Probes and helpers.
// ---------------------------------------------------------------------------

private string q(string s) @safe pure {
    import tachy.transport : shQuote;

    return shQuote(s);
}

private bool groupExists(Transport t, string name) {
    return t.run("getent group " ~ q(name)).ok;
}

/// The colon-separated fields of a passwd entry, or null when the user
/// does not exist.  A single getent doubles as the existence probe.
private string[] passwdEntry(Transport t, string name) {
    auto r = t.run("getent passwd " ~ q(name));
    if(!r.ok) return null;
    string[] fields = split(r.outText.strip, ":");
    if(fields.length != 7)
        throw new TachyError("user: unexpected passwd entry for '" ~ name ~ "': " ~ r.outText.strip);
    return fields;
}

/// The group name owning a gid.
private string groupNameForGid(Transport t, string gid) {
    auto r = t.run("getent group " ~ q(gid));
    if(!r.ok)
        throw new TachyError("user: cannot resolve primary group id " ~ gid);
    const string[] fields = split(r.outText.strip, ":");
    if(fields.length < 3 || fields[2] != gid)
        throw new TachyError("user: unexpected group entry for id " ~ gid ~ ": " ~ r.outText.strip);
    return fields[0];
}

private bool canFindValue(in string[] haystack, string needle) @safe pure {
    foreach(h; haystack)
        if(h == needle) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests with a scripted transport: command construction only, no real
// account is touched.
// ---------------------------------------------------------------------------
