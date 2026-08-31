module tachy.modules.filemod;

/**
 * `file` module — idempotent file and directory management.
 *
 *     file.path    = "/etc/app"             (required)
 *     file.state   = "directory"            # file (default) | directory | link | absent
 *     file.src     = "app.conf"             # state=file: copy this local file
 *                                           # state=link: symlink target (required)
 *     file.template = "app.tmpl"            # state=file: render this file's
 *                                           # {{ vars }} onto the target
 *     file.line    = "umask 022"            # state=file: ensure this line is present
 *     file.block   = "header\n...\n"        # state=file: ensure these lines are
 *                                           # present (contiguously, in order)
 *     file.mode    = "0755"                 # or TOML int 0o755
 *     file.owner   = "app"                  # chown
 *     file.group   = "app"                  # chgrp
 *
 * `line` and `block` are mutually exclusive, and exclusive with `content`
 * and `src`.  Presence is checked line by line (whole-line matches); a
 * missing line/block is appended, terminated with a newline.
 *
 * `src` copies a file verbatim; `template` (state=file) renders the
 * named file with the host's variable scope and writes the result —
 * the two are distinct, mutually exclusive sources, like `content`.
 */
import std.algorithm.searching : canFind;
import std.conv : octal, text;
import std.format : format;
import std.path : buildPath, isAbsolute;
import std.string : join, split, splitLines, strip;

import std.file : read, readText;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, mustRunWithInput, optBool, optStr, requireStr;
import tachy.transport : StatKind, Transport, readLinkTarget, shQuote, statPath;
import tachy.value : Val;
import tachy.vars : renderTemplate;

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

    const string line = optStr(params, "line", "file");
    const bool hasLine = line.length > 0;
    if (hasLine && canFind(line, "\n"))
        throw new TachyError("file: 'line' must be a single line (no newline characters)");

    const string block = optStr(params, "block", "file");
    const bool hasBlock = block.length > 0;
    if (hasBlock && splitLines(block).length == 0)
        throw new TachyError("file: 'block' must not be empty");

    string src = optStr(params, "src", "file");
    bool hasSrc = src.length > 0;
    const string templatePath = optStr(params, "template", "file");
    const bool hasTemplate = templatePath.length > 0;
    const string owner = optStr(params, "owner", "file");
    const string group = optStr(params, "group", "file");
    int mode = -1;
    if (auto p = "mode" in params)
        mode = parseMode(*p);

    // Combination validation.
    if (hasTemplate && hasSrc)
        throw new TachyError("file: 'src' (copy) and 'template' (render) are mutually exclusive");
    if (hasTemplate && hasContent)
        throw new TachyError("file: 'template' and 'content' are mutually exclusive");
    if (hasTemplate && (hasLine || hasBlock))
        throw new TachyError("file: 'template' and 'line'/'block' are mutually exclusive");

    if (hasContent && hasSrc)
        throw new TachyError("file: 'content' and 'src' are mutually exclusive");
    if (hasLine && hasBlock)
        throw new TachyError("file: 'line' and 'block' are mutually exclusive");
    foreach (const string what; ["line", "block"])
    {
        const bool has = what == "line" ? hasLine : hasBlock;
        if (!has)
            continue;
        if (hasContent)
            throw new TachyError("file: '" ~ what ~ "' and 'content' are mutually exclusive");
        if (hasSrc)
            throw new TachyError("file: '" ~ what ~ "' and 'src' are mutually exclusive");
    }
    final switch (state)
    {
        case State.link:
            if (!hasSrc)
                throw new TachyError("file: 'src' (the link target) is required with state=link");
            if (hasContent)
                throw new TachyError("file: 'content' is not allowed with state=link");
            if (hasTemplate)
                throw new TachyError("file: 'template' is not allowed with state=link");
            if (hasLine)
                throw new TachyError("file: 'line' is not allowed with state=link");
            if (hasBlock)
                throw new TachyError("file: 'block' is not allowed with state=link");
            break;
        case State.directory:
        case State.absent:
            if (hasContent)
                throw new TachyError("file: 'content' is not allowed with state=" ~ stateStr);
            if (hasSrc)
                throw new TachyError("file: 'src' is not allowed with state=" ~ stateStr);
            if (hasTemplate)
                throw new TachyError("file: 'template' is not allowed with state=" ~ stateStr);
            if (hasLine)
                throw new TachyError("file: 'line' is not allowed with state=" ~ stateStr);
            if (hasBlock)
                throw new TachyError("file: 'block' is not allowed with state=" ~ stateStr);
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
            if (hasTemplate)
            {
                // template = <path>: render that file with the host's
                // variable scope and use the result as the content.
                const string tplPath = isAbsolute(templatePath)
                    ? templatePath : buildPath(ctx.tasksFileDir, templatePath);
                try
                    content = renderTemplate(readText(tplPath), ctx.vars);
                catch (TachyError e)
                    throw new TachyError("file: cannot render '" ~ tplPath ~ "': " ~ e.msg);
                catch (Exception e)
                    throw new TachyError("file: cannot read template '" ~ tplPath ~ "': " ~ e.msg);
                hasContent = true;
            }
            else if (hasSrc)
            {
                // src = <path>: copy this file verbatim, as bytes — it may
                // be binary (e.g. a GPG keyring); only `template` needs
                // valid UTF-8.
                const string srcPath = isAbsolute(src) ? src : buildPath(ctx.tasksFileDir, src);
                try content = cast(string) read(srcPath);
                catch (Exception e)
                    throw new TachyError("file: cannot read src '" ~ srcPath ~ "': " ~ e.msg);
                hasContent = true;
            }
            if (hasContent)
            {
                // Compare by checksum: only the hash crosses the
                // transport, and arbitrary bytes never need decoding.
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
                        "write '" ~ path ~ "'");
                    actions ~= st.kind == StatKind.nonexistent ? "created file" : "updated content";
                }
            }
            else if (hasLine || hasBlock)
            {
                const string[] wanted = hasLine ? [line] : splitLines(block);
                string current;
                if (st.kind != StatKind.nonexistent)
                {
                    auto r = t.run("cat -- " ~ shQuote(path));
                    if (!r.ok)
                        throw new TachyError("file: cannot read '" ~ path ~ "': "
                            ~ (r.errText.strip.length ? r.errText.strip : text("exit status ", r.status)));
                    current = r.outText;
                }
                if (!containsLines(current, wanted))
                {
                    const string addition = wanted.join("\n") ~ "\n";
                    string newContent = !current.length ? addition
                        : current[$ - 1] == '\n' ? current ~ addition
                        : current ~ "\n" ~ addition;
                    mustRunWithInput(t, ctx, details, "cat > " ~ shQuote(path), newContent,
                        "update '" ~ path ~ "'");
                    actions ~= st.kind == StatKind.nonexistent ? "created file"
                        : hasLine ? "appended line" : "appended block";
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

/// Lowercase sha256 hex of `bytes` (compared against sha256sum output).
private string sha256Hex(string bytes) @safe pure
{
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : toLower;
    return toHexString(sha256Of(cast(const(ubyte)[]) bytes)).toLower();
}

/// Whole-line containment: does `text` contain `wanted` as a contiguous run
/// of complete lines (in order)?  A trailing newline on the last line is
/// not required, so "abc" contains the line "abc".
private bool containsLines(string text, in string[] wanted) @safe pure
{
    if (!wanted.length)
        return true;
    const auto lines = splitLines(text);
    if (lines.length < wanted.length)
        return false;
    outer:
    for (size_t i = 0; i + wanted.length <= lines.length; i++)
    {
        for (size_t j = 0; j < wanted.length; j++)
            if (lines[i + j] != wanted[j])
                continue outer;
        return true;
    }
    return false;
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

    TaskContext ctxLocal(string dir, bool check = false, Val[string] vars = null)
    {
        TaskContext ctx = TaskContext(new LocalTransport, check, "localhost", dir);
        ctx.vars = vars;
        return ctx;
    }

    Val[string] P(string k, string v)
    {
        Val[string] p;
        p[k] = Val(v);
        return p;
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

unittest // src = binary file: byte-exact copy, checksum compare, idempotent
{
    import std.file : read, write;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    // Invalid UTF-8 on purpose (OpenPGP keyring-like bytes).
    const ubyte[] key = cast(ubyte[]) "\x89PNG\r\n\x1a\n\xff\x00\x80\xfe binary \x93key\x94 bytes";
    auto srcPath = buildPath(dir, "docker.gpg");
    write(srcPath, key);

    auto f = buildPath(dir, "keyring.gpg");
    Val[string] p;
    p["path"] = Val(f);
    p["src"] = Val("docker.gpg");

    auto r1 = runFileModule(p, ctx);
    assert(r1.changed, r1.msg);
    assert(read(f) == key, "byte-exact copy");
    auto r2 = runFileModule(p, ctx);
    assert(!r2.changed, r2.msg); // checksum compare, no decode

    write(f, cast(ubyte[])[0x00, 0x01, 0x02]);
    auto r3 = runFileModule(p, ctx);
    assert(r3.changed && read(f) == key, "binary drift repaired");
}

unittest // template = <path>: render that file with the host scope
{
    import std.exception : assertThrown;
    import std.file : readText, write;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);

    Val[string] vars;
    vars["name"] = Val("web1");
    vars["port"] = Val(8080L);
    vars["nested"] = Val(1.5); // floats render through scalarToString
    Val t;
    t.kind = Val.Kind.table_;
    t.table_["env"] = Val("prod");
    vars["opts"] = t;
    auto ctx = ctxLocal(dir, false, vars);

    write(buildPath(dir, "app.tmpl"),
        "server {{ name }} : {{ port }} (env={{ opts.env }}, f={{ nested }})\n");
    auto f = buildPath(dir, "app.conf");
    Val[string] p;
    p["path"] = Val(f);
    p["template"] = Val("app.tmpl");

    auto r1 = runFileModule(p, ctx);
    assert(r1.changed);
    assert(readText(f) == "server web1 : 8080 (env=prod, f=1.5)\n", readText(f));
    assert(!runFileModule(p, ctx).changed); // idempotent against rendered form

    // variable drift: same template, different scope -> rewritten
    vars["name"] = Val("web2");
    auto r3 = runFileModule(p, ctxLocal(dir, false, vars));
    assert(r3.changed && readText(f) == "server web2 : 8080 (env=prod, f=1.5)\n");

    // verbatim copy: src alone never processes {{ }}
    write(buildPath(dir, "raw.src"), "literal {{ name }}\n");
    Val[string] praw;
    praw["path"] = Val(buildPath(dir, "raw.conf"));
    praw["src"] = Val("raw.src");
    runFileModule(praw, ctx);
    assert(readText(buildPath(dir, "raw.conf")) == "literal {{ name }}\n");

    // undefined variable in the template is a hard error naming the template
    write(buildPath(dir, "bad.tmpl"), "{{ missing }}\n");
    Val[string] pbad;
    pbad["path"] = Val(buildPath(dir, "bad.conf"));
    pbad["template"] = Val("bad.tmpl");
    assertThrown!(TachyError)(runFileModule(pbad, ctx));

    // missing template file is an error naming the path
    Val[string] pmiss;
    pmiss["path"] = Val(buildPath(dir, "miss.conf"));
    pmiss["template"] = Val("nope.tmpl");
    assertThrown!(TachyError)(runFileModule(pmiss, ctx));

    // check mode renders and compares but does not write
    write(f, "drifted\n");
    auto rc = runFileModule(p, ctxLocal(dir, true, vars));
    assert(rc.changed && readText(f) == "drifted\n");
}

unittest // template = <path>: combination errors
{
    import std.exception : assertThrown;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    // template with src (copy and render are distinct sources)
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["src"] = Val("a");
        p["template"] = Val("b");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // template with content
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["content"] = Val("a");
        p["template"] = Val("b");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // template with line
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["template"] = Val("b");
        p["line"] = Val("a");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // template with a non-file state
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["state"] = Val("directory");
        p["template"] = Val("b");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // template with state=link
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["state"] = Val("link");
        p["src"] = Val("a");
        p["template"] = Val("b");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
}
unittest // line lifecycle: create, idempotence, append, mid-line non-match
{
    import std.file : readText, write;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    auto f = buildPath(dir, "sysctl.conf");
    Val[string] p;
    p["path"] = Val(f);
    p["line"] = Val("vm.swappiness = 10");

    auto r1 = runFileModule(p, ctx);
    assert(r1.changed && readText(f) == "vm.swappiness = 10\n");
    assert(!runFileModule(p, ctx).changed); // idempotent

    write(f, "kernel.panic = 10\n");        // line missing again
    auto r3 = runFileModule(p, ctx);
    assert(r3.changed && readText(f) == "kernel.panic = 10\nvm.swappiness = 10\n");
    assert(!runFileModule(p, ctx).changed);

    write(f, "vm.swappiness = 100\n");      // partial line is not the line
    auto r4 = runFileModule(p, ctx);
    assert(r4.changed && readText(f) == "vm.swappiness = 100\nvm.swappiness = 10\n");

    write(f, "a");                          // no trailing newline on last line
    auto r5 = runFileModule(p, ctx);
    assert(r5.changed && readText(f) == "a\nvm.swappiness = 10\n");

    // whole-line match without trailing newline needs no change
    write(f, "vm.swappiness = 10");
    assert(!runFileModule(p, ctx).changed);

    // check mode: missing line is reported but not written
    write(f, "other\n");
    auto r7 = runFileModule(p, ctxLocal(dir, true));
    assert(r7.changed && readText(f) == "other\n");
}

unittest // block lifecycle: append contiguous lines, idempotence, mid-file match
{
    import std.file : readText, write;
    auto dir = freshDir;
    scope (exit) rmdirRecurse(dir);
    auto ctx = ctxLocal(dir);

    auto f = buildPath(dir, "fstab");
    Val[string] p;
    p["path"] = Val(f);
    p["block"] = Val("# tachy: managed\n/tmp none none\n");

    auto r1 = runFileModule(p, ctx);
    assert(r1.changed && readText(f) == "# tachy: managed\n/tmp none none\n");
    assert(!runFileModule(p, ctx).changed); // idempotent

    write(f, "/dev/sda1 / ext4 defaults 0 1\n");
    auto r3 = runFileModule(p, ctx);
    assert(r3.changed
        && readText(f) == "/dev/sda1 / ext4 defaults 0 1\n# tachy: managed\n/tmp none none\n");
    assert(!runFileModule(p, ctx).changed);

    // block present mid-file, different context around it: no change
    write(f, "before\n# tachy: managed\n/tmp none none\nafter\n");
    assert(!runFileModule(p, ctx).changed);

    // block without trailing newline in the param matches the same lines
    write(f, "x\n# tachy: managed\n/tmp none none\n");
    Val[string] p2;
    p2["path"] = Val(f);
    p2["block"] = Val("# tachy: managed\n/tmp none none");
    assert(!runFileModule(p2, ctx).changed);

    // out-of-order lines are not the block
    write(f, "/tmp none none\n# tachy: managed\n");
    assert(runFileModule(p2, ctx).changed);
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
    // line + block conflict
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["line"] = Val("a");
        p["block"] = Val("b");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // line + content conflict
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["line"] = Val("a");
        p["content"] = Val("b");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // block + src conflict
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["block"] = Val("a\nb");
        p["src"] = Val("y");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // multi-line line
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["line"] = Val("a\nb");
        assertThrown!(TachyError)(runFileModule(p, ctx));
    }
    // line with state=directory
    {
        Val[string] p;
        p["path"] = Val(buildPath(dir, "x"));
        p["state"] = Val("directory");
        p["line"] = Val("a");
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
