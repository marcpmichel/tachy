module tachy.modules.filemod;

/**
 * `file` module — idempotent file and directory management.
 *
 *     file.path    = "/etc/app"             (required)
 *     file.state   = "directory"            # file (default) | directory | link | absent
 *     file.src     = "app.conf"             # state=file: copy this local file
 *                                           # state=link: symlink target (required)
 *     file.age     = true                   # state=file: src is age-encrypted —
 *                                           # decrypt it (controller-side) and
 *                                           # deploy the plaintext, byte-exact
 *     file.template = "app.tmpl"            # state=file: render this file's
 *                                           # {{ vars }} onto the target
 *     file.vars    = { user = "app" }       # local template context
 *                                           # (with template only; local
 *                                           # values win over the host scope)
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
 * `age = true` marks the `src` file as age-encrypted: the plaintext is
 * deployed byte-exact (no UTF-8 constraint, no newline stripping, no
 * templating — unlike `{ age = ... }` inventory vars).  Decryption
 * happens where an identity lives: the controller decrypts the file
 * into the bundle before the on-host run, so a src that already holds
 * plaintext (no age header) is used as-is.
 */
import std.algorithm.searching : canFind;
import std.conv : octal, text;
import std.format : format;
import std.string : join, split, splitLines, strip;

import std.file : read;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, mustRunWithInput, optBool, optStr, requireStr;
import tachy.transport : StatKind, Transport, readLinkTarget, shQuote, statPath;
import tachy.value : Val;
import tachy.vars : decryptAgeFile, isAgeCiphertext, renderTemplateFile,
    resolveEntryPath;

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
    const bool hasAge = optBool(params, "age", "file");
    const string templatePath = optStr(params, "template", "file");
    const bool hasTemplate = templatePath.length > 0;
    const string owner = optStr(params, "owner", "file");
    const string group = optStr(params, "group", "file");
    int mode = -1;
    if (auto p = "mode" in params)
        mode = parseMode(*p);

    // Combination validation.
    if (hasAge && !hasSrc)
        throw new TachyError("file: 'age' requires 'src' (it marks that"
            ~ " source file as age-encrypted)");
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
            if (hasAge)
                throw new TachyError("file: 'age' is not allowed with state=link ('src' is the link target)");
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
                // variable scope (the entry's local `vars` merged over
                // it, local values winning) and use the result as the
                // content.
                content = renderTemplateFile(templatePath,
                    ctx.tasksFileDir, ctx.vars, params, "file: ");
                hasContent = true;
            }
            else if (hasSrc)
            {
                // src = <path>: copy this file verbatim, as bytes — it may
                // be binary (e.g. a GPG keyring); only `template` needs
                // valid UTF-8.  With age = true the source is an
                // age-encrypted secret: decrypt it when it still carries
                // the ciphertext header (on the controller); inside a
                // deployed bundle the controller already replaced it with
                // the plaintext, which is used as-is.
                const string srcPath = resolveEntryPath(src, ctx.tasksFileDir);
                try content = cast(string) read(srcPath);
                catch (Exception e)
                    throw new TachyError("file: cannot read src '" ~ srcPath ~ "': " ~ e.msg);
                if (hasAge && isAgeCiphertext(content))
                    content = decryptAgeFile(srcPath, ctx.ageIdentity,
                        "file: '" ~ path ~ "'");
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
    {
        // In check mode creation was suppressed, so there is nothing
        // to probe: the attrs fold into the would-be creation.
        if (!ctx.checkMode)
            throw new TachyError("file: '" ~ path ~ "' does not exist"); // caller bug
        return;
    }

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
