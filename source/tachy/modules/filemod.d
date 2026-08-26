module tachy.modules.filemod;

/**
 * `file` module — idempotent file and directory management.
 *
 *     file.path    = "/etc/app"             (required)
 *     file.state   = "directory"            # file (default) | directory | link | absent
 *     file.content = "exact content\n"      # state=file: enforce exact content
 *     file.src     = "app.conf"             # state=file: copy this local file
 *                                           # state=link: symlink target (required)
 *     file.mode    = "0755"                 # or TOML int 0o755
 *     file.owner   = "app"                  # chown
 *     file.group   = "app"                  # chgrp
 */
import std.conv : octal;
import std.format : format;
import std.path : buildPath, isAbsolute;
import std.string : join;

import std.file : readText;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, mustRunWithInput, optStr, requireStr;
import tachy.transport : StatKind, Transport, readLinkTarget, shQuote, statPath;
import tachy.value : Val;

TaskResult runFileModule(Val[string] params, TaskContext ctx)
{
    auto t = ctx.transport;
    const string path = requireStr(params, "path", "file");

    const string stateStr = optStr(params, "state", "file", "file");
    State state;
    switch (stateStr)
    {
        case "file": state = State.file; break;
        case "directory": state = State.directory; break;
        case "link": state = State.link; break;
        case "absent": state = State.absent; break;
        default:
            throw new TachyError("file: invalid state '" ~ stateStr
                ~ "' (expected file, directory, link or absent)");
    }

    string content;
    bool hasContent;
    if (auto p = "content" in params)
    {
        if ((*p).kind != Val.Kind.string_)
            throw new TachyError("file: 'content' must be a string, not a " ~ (*p).typeName());
        hasContent = true;
        content = (*p).str_;
    }

    string src = optStr(params, "src", "file");
    bool hasSrc = src.length > 0;
    const string owner = optStr(params, "owner", "file");
    const string group = optStr(params, "group", "file");
    int mode = -1;
    if (auto p = "mode" in params)
        mode = parseMode(*p);

    // Combination validation.
    if (hasContent && hasSrc)
        throw new TachyError("file: 'content' and 'src' are mutually exclusive");
    final switch (state)
    {
        case State.link:
            if (!hasSrc)
                throw new TachyError("file: 'src' (the link target) is required with state=link");
            if (hasContent)
                throw new TachyError("file: 'content' is not allowed with state=link");
            break;
        case State.directory:
        case State.absent:
            if (hasContent)
                throw new TachyError("file: 'content' is not allowed with state=" ~ stateStr);
            if (hasSrc)
                throw new TachyError("file: 'src' is not allowed with state=" ~ stateStr);
            break;
        case State.file:
            break;
    }

    string[] actions;
    string[] details;

    final switch (state)
    {
        case State.absent:
            if (statPath(t, path).kind != StatKind.nonexistent)
            {
                mustRun(t, ctx, details, "rm -rf -- " ~ shQuote(path), "remove '" ~ path ~ "'");
                actions ~= "removed";
            }
            break;

        case State.directory:
            auto st = statPath(t, path);
            if (st.kind != StatKind.nonexistent && st.kind != StatKind.directory)
                throw new TachyError("file: '" ~ path ~ "' exists and is not a directory");
            if (st.kind == StatKind.nonexistent)
            {
                mustRun(t, ctx, details, "mkdir -p -- " ~ shQuote(path), "create directory '" ~ path ~ "'");
                actions ~= "created directory";
            }
            applyAttrs(t, ctx, path, mode, owner, group, actions, details);
            break;

        case State.file:
        {
            auto st = statPath(t, path);
            if (st.kind == StatKind.directory)
                throw new TachyError("file: '" ~ path ~ "' exists and is a directory");
            if (hasSrc)
            {
                const string srcPath = isAbsolute(src) ? src : buildPath(ctx.tasksFileDir, src);
                try content = readText(srcPath);
                catch (Exception e)
                    throw new TachyError("file: cannot read src '" ~ srcPath ~ "': " ~ e.msg);
                hasContent = true;
            }
            if (hasContent)
            {
                string current;
                if (st.kind != StatKind.nonexistent)
                {
                    auto r = t.run("cat -- " ~ shQuote(path));
                    if (r.ok)
                        current = r.outText;
                }
                if (st.kind == StatKind.nonexistent || current != content)
                {
                    mustRunWithInput(t, ctx, details, "cat > " ~ shQuote(path), content,
                        "write '" ~ path ~ "'");
                    actions ~= st.kind == StatKind.nonexistent ? "created file" : "updated content";
                }
            }
            else if (st.kind == StatKind.nonexistent)
            {
                mustRun(t, ctx, details, "touch -- " ~ shQuote(path), "create '" ~ path ~ "'");
                actions ~= "created empty file";
            }
            applyAttrs(t, ctx, path, mode, owner, group, actions, details);
            break;
        }

        case State.link:
            auto st = statPath(t, path);
            if (st.kind == StatKind.link)
            {
                if (readLinkTarget(t, path) != src)
                {
                    mustRun(t, ctx, details, "ln -sfn -- " ~ shQuote(src) ~ " " ~ shQuote(path),
                        "relink '" ~ path ~ "'");
                    actions ~= "retargeted link";
                }
            }
            else if (st.kind == StatKind.directory)
                throw new TachyError("file: '" ~ path ~ "' is a directory; remove it before replacing it with a link");
            else if (st.kind != StatKind.nonexistent)
            {
                mustRun(t, ctx, details, "ln -sfn -- " ~ shQuote(src) ~ " " ~ shQuote(path),
                    "relink '" ~ path ~ "'");
                actions ~= "replaced existing path with link";
            }
            else
            {
                mustRun(t, ctx, details, "ln -s -- " ~ shQuote(src) ~ " " ~ shQuote(path),
                    "link '" ~ path ~ "'");
                actions ~= "created link";
            }
            // mode/owner/group are not applied to links (chmod/chown follow
            // the target); configuring the target itself is the right tool.
            break;
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length == 0 ? neutral(state, path) : actions.join("; ");
    res.details = details;
    return res;
}

private enum State { file, directory, link, absent }

private string neutral(State state, string path) @safe pure
{
    final switch (state)
    {
        case State.absent: return "already absent";
        case State.directory: return "directory present";
        case State.file: return "file present";
        case State.link: return "link present";
    }
}

/// Enforce mode/owner/group on an existing path (fresh stat).
private void applyAttrs(Transport t, TaskContext ctx, string path,
    int mode, string owner, string group, ref string[] actions, ref string[] details)
{
    if (mode < 0 && !owner.length && !group.length)
        return;
    auto st = statPath(t, path);
    if (st.kind == StatKind.nonexistent)
        throw new TachyError("file: '" ~ path ~ "' does not exist"); // caller bug

    if (mode >= 0 && (st.mode & octal!7777) != mode)
    {
        mustRun(t, ctx, details, format!"chmod %04o -- %s"(mode, shQuote(path)),
            "chmod '" ~ path ~ "'");
        actions ~= format!"mode %04o -> %04o"(st.mode & octal!7777, mode);
    }
    const bool chOwner = owner.length && st.owner != owner;
    const bool chGroup = group.length && st.group != group;
    if (chOwner || chGroup)
    {
        string spec = (chOwner ? owner : "") ~ (chGroup ? ":" ~ group : "");
        mustRun(t, ctx, details, "chown -- " ~ shQuote(spec) ~ " " ~ shQuote(path),
            "chown '" ~ path ~ "'");
        string what;
        if (chOwner)
            what ~= "owner " ~ st.owner ~ " -> " ~ owner;
        if (chGroup)
            what ~= (what.length ? ", " : "") ~ "group " ~ st.group ~ " -> " ~ group;
        actions ~= what;
    }
}

private int parseMode(in Val v)
{
    if (v.kind == Val.Kind.integer_)
    {
        if (v.integer_ < 0 || v.integer_ > octal!7777)
            throw new TachyError("file: 'mode' integer out of range (0..4095)");
        return cast(int) v.integer_;
    }
    if (v.kind == Val.Kind.string_)
    {
        const string s = v.str_;
        if (!s.length || s.length > 4)
            throw new TachyError("file: 'mode' must be 1..4 octal digits like \"0755\"");
        int m = 0;
        foreach (char c; s)
        {
            if (c < '0' || c > '7')
                throw new TachyError("file: 'mode' must be octal like \"0755\", got \"" ~ s ~ "\"");
            m = m * 8 + (c - '0');
        }
        return m;
    }
    throw new TachyError("file: 'mode' must be an octal string like \"0755\" or an integer like 0o755, not a "
        ~ v.typeName());
}

// ---------------------------------------------------------------------------
// Tests against the real local filesystem (LocalTransport).
// ---------------------------------------------------------------------------

version (unittest) private
{
    import std.file : exists, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import std.file : tempDir;
    import tachy.transport : LocalTransport;

    string freshDir()
    {
        auto dir = buildPath(tempDir, "tachy_filemod_ut");
        if (exists(dir)) rmdirRecurse(dir);
        mkdirRecurse(dir);
        return dir;
    }

    Val[string] P(string k, string v)
    {
        Val[string] p;
        p[k] = Val(v);
        return p;
    }

    TaskContext ctxLocal(string dir, bool check = false)
    {
        return TaskContext(new LocalTransport, check, "localhost", dir);
    }
}

unittest // directory lifecycle: create, idempotence, mode fix, idempotence
{
    import std.file : isDir;
    import tachy.transport : statPath;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    auto sub = buildPath(dir, "etc/app");
    Val[string] p;
    p["path"] = Val(sub);
    p["state"] = Val("directory");
    p["mode"] = Val("0750");

    auto r1 = runFileModule(p, ctx);
    assert(r1.changed && isDir(sub));
    auto r2 = runFileModule(p, ctx);
    assert(!r2.changed, r2.msg);
    assert(statPath(ctx.transport, sub).mode == octal!750);

    p["mode"] = Val("0700");
    auto r3 = runFileModule(p, ctx);
    assert(r3.changed && statPath(ctx.transport, sub).mode == octal!700);
    auto r4 = runFileModule(p, ctx);
    assert(!r4.changed);
}

unittest // file content lifecycle: create, idempotence, drift, repair
{
    import std.file : readText, write;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    auto f = buildPath(dir, "app.conf");
    Val[string] p;
    p["path"] = Val(f);
    p["content"] = Val("port = 8080\n");

    auto r1 = runFileModule(p, ctx);
    assert(r1.changed && readText(f) == "port = 8080\n");
    auto r2 = runFileModule(p, ctx);
    assert(!r2.changed, r2.msg);

    write(f, "port = 9090\n"); // drift
    auto r3 = runFileModule(p, ctx);
    assert(r3.changed && readText(f) == "port = 8080\n");

    // check mode: drift is detected but not repaired
    write(f, "tampered\n");
    auto r4 = runFileModule(p, ctxLocal(dir, true));
    assert(r4.changed && readText(f) == "tampered\n");
}

unittest // state=absent
{
    import std.file : exists, write;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    auto f = buildPath(dir, "junk");
    write(f, "x");

    Val[string] p;
    p["path"] = Val(f);
    p["state"] = Val("absent");

    assert(runFileModule(p, ctx).changed && !exists(f));
    assert(!runFileModule(p, ctx).changed);
}

unittest // symlink lifecycle
{
    import std.file : symlink, readLink;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    auto link = buildPath(dir, "current");
    Val[string] p;
    p["path"] = Val(link);
    p["state"] = Val("link");
    p["src"] = Val("/usr/bin/env");

    assert(runFileModule(p, ctx).changed);
    assert(readLink(link) == "/usr/bin/env");
    assert(!runFileModule(p, ctx).changed); // idempotent

    p["src"] = Val("/bin/sh");
    assert(runFileModule(p, ctx).changed && readLink(link) == "/bin/sh");
}

unittest // error cases
{
    import std.exception : assertThrown;
    import std.file : mkdirRecurse;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    auto d = buildPath(dir, "d");
    mkdirRecurse(d);

    // existing directory, state=file
    {
        Val[string] p;
        p["path"] = Val(d);
        p["content"] = Val("x");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // content + src conflict
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["content"] = Val("x");
        p["src"] = Val("y");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // link without src
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["state"] = Val("link");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // invalid state value
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["state"] = Val("bogus");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // bad mode
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["mode"] = Val("0999");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
}
