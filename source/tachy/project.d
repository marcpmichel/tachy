module tachy.project;

/**
 * Projects and bundles.
 *
 * The parent directory of a tasks file is its *project*.  Instead of
 * dribbling one shell command at a time from the controller, tachy
 * deploys the whole project to every selected host as a temporary
 * *bundle* and runs the composition on the host itself:
 *
 *     /tmp/tachy.XXXXXXXXXX/      created by mktemp -d on the host
 *     ├── tachy                   copy of the controller's tachy binary
 *     ├── inventory.pravic         generated: one local host with its vars
 *     ├── report                  written by the inner run: "ok changed failed"
 *     └── project/                copy of the tasks file's parent directory
 *
 * The copied binary is executed on the host (over ssh, or locally for
 * `connection = "local"` hosts) with `--direct`: it applies the copied
 * tasks file through a local connection, so applies and `file.src`
 * paths resolve inside the copied project — a project must be
 * self-contained.  Host variables travel in the generated inventory, so
 * the inner run sees the same scope (global < host) the controller
 * would have used.
 *
 * Only linux/amd64 is supported for now: the binary copy is the running
 * binary, so controller and hosts must share the platform.
 */
import std.algorithm.sorting : sort;
import std.array : Appender, appender, array;
import std.conv : text;
import std.format : format;
import std.path : buildPath, dirName, isAbsolute;
import std.process : Redirect, pipeProcess, wait;
import std.string : join, strip;

import std.file : read, thisExePath;

import tachy.errors;
import tachy.transport : CommandResult, Transport, shQuote;
import tachy.value : Val;

private alias Sink = Appender!string;

struct ProjectBundle
{
    string root;          // temporary directory on the host
    string projectDir;    // root ~ "/project": the copied project
    string tachyPath;     // root ~ "/tachy": the copied binary
    string inventoryPath; // root ~ "/inventory.pravic": generated inventory
}

/// One `import` statement's source: a file or directory (absolute path,
/// possibly outside the project) copied into the bundle as `dest` —
/// its base name — next to the project copy, so src/template/run
/// references resolve on the host.
/// One controller-decrypted secret: `src` file (relative to the project
/// root) with its plaintext.  Bundled mode decrypts `age = true` sources
/// on the controller — the identity never travels inside a bundle — and
/// writes the plaintext over the ciphertext copy, exactly like decrypted
/// inventory vars travel in the generated inventory.
struct DecryptedFile
{
    string relPath; // project-relative path of the source file
    string bytes;   // plaintext, byte-exact
}

struct ImportSpec
{
    string src;
    string dest;
}


/// Deploy a project bundle on the host reached through `t`: copy
/// `localProjectDir`, the running tachy binary and a generated
/// one-host inventory into a fresh temporary directory there, plus
/// every `imports` source (validated here: it must exist, and its
/// destination must not clash with project content or another import).
/// `decrypted` overwrites project files with controller-decrypted
/// plaintext (age-marked `src` secrets).
ProjectBundle deployProject(Transport t, string localProjectDir,
    string hostName, in Val[string] hostVars, in ImportSpec[] imports = [],
    in DecryptedFile[] decrypted = [])
{
    checkImports(localProjectDir, imports);

    auto mk = t.run("mktemp -d \"${TMPDIR:-/tmp}/tachy.XXXXXXXXXX\"");
    if (!mk.ok)
        throw new TachyError("cannot create a temporary bundle directory on "
            ~ hostName ~ ": " ~ failText(mk));

    ProjectBundle b;
    b.root = mk.outText.strip;
    if (!b.root.length || !isAbsolute(b.root))
        throw new TachyError("unexpected mktemp output on " ~ hostName ~ ": '" ~ b.root ~ "'");
    b.projectDir = buildPath(b.root, "project");
    b.tachyPath = buildPath(b.root, "tachy");
    b.inventoryPath = buildPath(b.root, "inventory.pravic");

    auto mkd = t.run("mkdir -- " ~ shQuote(b.projectDir));
    if (!mkd.ok)
        throw new TachyError("cannot create " ~ b.projectDir ~ " on " ~ hostName
            ~ ": " ~ failText(mkd));

    // Project copy (plus imports): one tar on the controller, untar on
    // the host (stdin).
    auto extract = t.runWithInput("tar -C " ~ shQuote(b.projectDir) ~ " -xf -",
        tarBundle(localProjectDir, imports));
    if (!extract.ok)
        throw new TachyError("cannot copy project '" ~ localProjectDir ~ "' to "
            ~ hostName ~ ": " ~ failText(extract));

    // Decrypted secrets overwrite their ciphertext copies (the tar above
    // brought the encrypted files in; relPath is validated project-relative
    // by the caller, so this stays inside the bundle's project copy).
    foreach (ref const DecryptedFile d; decrypted)
    {
        auto put = t.runWithInput("cat > " ~ shQuote(buildPath(b.projectDir, d.relPath)),
            d.bytes);
        if (!put.ok)
            throw new TachyError("cannot write decrypted secret '" ~ d.relPath
                ~ "' into the bundle on " ~ hostName ~ ": " ~ failText(put));
    }

    // The binary itself (linux/amd64: same platform as the controller).
    string selfBytes;
    try selfBytes = cast(string) read(thisExePath());
    catch (Exception e)
        throw new TachyError("cannot read the tachy binary '" ~ thisExePath() ~ "': " ~ e.msg);
    auto cp = t.runWithInput("cat > " ~ shQuote(b.tachyPath), selfBytes);
    if (!cp.ok)
        throw new TachyError("cannot copy the tachy binary to " ~ hostName ~ ": " ~ failText(cp));
    auto chm = t.run("chmod 0755 -- " ~ shQuote(b.tachyPath));
    if (!chm.ok)
        throw new TachyError("cannot make the tachy binary executable on "
            ~ hostName ~ ": " ~ failText(chm));

    auto inv = t.runWithInput("cat > " ~ shQuote(b.inventoryPath),
        hostInventoryPravic(hostName, hostVars));
    if (!inv.ok)
        throw new TachyError("cannot write the generated inventory on "
            ~ hostName ~ ": " ~ failText(inv));

    return b;
}

/// Best-effort bundle removal; never throws.
void removeBundle(Transport t, in ProjectBundle b)
{
    try t.run("rm -rf -- " ~ shQuote(b.root));
    catch (Exception)
    {
    }
}

/// The command line running the bundled binary on the host: it runs in
/// the copied project's directory (so error origins and relative paths
/// read like project paths, not bundle paths) and applies the tasks
/// file's basename in `--direct` mode against the generated inventory —
/// with the `check` command when the controller was in check mode —
/// forwarding verbosity and colors, and reporting its counters to
/// `reportPath`.
string innerTachyCommand(in ProjectBundle b, string hostName, string tasksBaseName,
    bool check, bool verbose, bool color, string reportPath)
{
    string cmd = "cd " ~ shQuote(b.projectDir) ~ " && " ~ shQuote(b.tachyPath)
        ~ (check ? " check" : " apply") ~ " --direct --events";
    if (verbose)
        cmd ~= " --verbose";
    if (color)
        cmd ~= " --color";
    cmd ~= " --direct-report " ~ shQuote(reportPath);
    cmd ~= " -i " ~ shQuote(b.inventoryPath);
    cmd ~= " " ~ shQuote(hostName) ~ " " ~ shQuote(tasksBaseName);
    return cmd;
}

/// Parse an inner run's report ("ok changed failed" on one line).
bool parseReport(string text, out ulong ok, out ulong changed, out ulong failed)
{
    import std.array : split;
    import std.conv : to;
    ok = changed = failed = 0;
    auto parts = split(text.strip);
    if (parts.length != 3)
        return false;
    try
    {
        ok = to!ulong(parts[0]);
        changed = to!ulong(parts[1]);
        failed = to!ulong(parts[2]);
    }
    catch (Exception)
        return false;
    return true;
}

// ---------------------------------------------------------------------------
// Generated inventory: host variables serialized back to Pravic.
// ---------------------------------------------------------------------------

/// A one-host, local-connection inventory carrying the host's effective
/// variables (the controller's global < host merge).
string hostInventoryPravic(string hostName, in Val[string] hostVars)
{
    auto app = appender!string;
    app.put("host " ~ pravicKey(hostName) ~ " {\n");
    app.put("    connection = \"local\",\n");
    app.put("    vars {\n");
    writeVarEntries(app, hostVars, 2);
    app.put("    },\n");
    app.put("}\n");
    return app.data;
}

/// Emit one vars level: scalar and array keys, then nested tables as
/// blocks.  Keys are sorted for deterministic output.
private void writeVarEntries(ref Sink app, in Val[string] t, int depth)
{
    auto keys = t.byKey.array;
    keys.sort();
    foreach (k; keys)
    {
        app.put(indentOf(depth));
        if (t[k].kind == Val.Kind.table_)
        {
            app.put(pravicKey(k) ~ " {\n");
            writeVarEntries(app, t[k].table_, depth + 1);
            app.put(indentOf(depth) ~ "},\n");
        }
        else
            app.put(pravicKey(k) ~ " = " ~ pravicValue(t[k]) ~ ",\n");
    }
}

private string indentOf(int depth) @safe pure
{
    import std.array : replicate;
    return "    ".replicate(depth);
}

package(tachy) string pravicValue(in Val v)
{
    final switch (v.kind)
    {
        case Val.Kind.string_: return pravicString(v.str_);
        case Val.Kind.integer_: return text(v.integer_);
        case Val.Kind.float_: return pravicFloat(v.float_);
        case Val.Kind.boolean_: return v.boolean_ ? "true" : "false";
        case Val.Kind.array_:
        {
            string[] parts;
            foreach (const e; v.array_)
                parts ~= pravicValue(e);
            return "[" ~ parts.join(", ") ~ "]";
        }
        case Val.Kind.table_:
        {
            auto keys = v.table_.byKey.array;
            keys.sort();
            string[] parts;
            foreach (k; keys)
                parts ~= pravicKey(k) ~ " = " ~ pravicValue(v.table_[k]);
            return "{ " ~ parts.join(", ") ~ " }";
        }
        case Val.Kind.choose_:
        {
            // The parser re-reads exactly this spelling, so a choose in
            // an inventory var round-trips into the generated per-host
            // inventory and is rendered on the host like any var.
            string[] parts;
            foreach (size_t i; 0 .. v.choosePatterns_.length)
                parts ~= pravicKey(v.choosePatterns_[i]) ~ " = "
                    ~ pravicValue(v.chooseValues_[i]);
            return "choose " ~ pravicString(v.str_)
                ~ " { " ~ parts.join(", ") ~ " }";
        }
    }
}

private string pravicKey(string k)
{
    return pravicString(k);
}

private string pravicString(string s)
{
    string r = "\"";
    foreach (char c; s)
    {
        switch (c)
        {
            case '"': r ~= "\\\""; break;
            case '\\': r ~= "\\\\"; break;
            case '\n': r ~= "\\n"; break;
            case '\r': r ~= "\\r"; break;
            case '\t': r ~= "\\t"; break;
            default:
                if (c < 0x20)
                    r ~= format!"\\u%04X"(c);
                else
                    r ~= c;
        }
    }
    return r ~ "\"";
}

/// Pravic floats need a fractional part or exponent to stay floats.
private string pravicFloat(double d)
{
    import std.algorithm.searching : canFind;
    import std.string : toLower;
    auto s = format!"%s"(d).toLower();
    if (!canFind(s, '.') && !canFind(s, 'e') && !canFind(s, 'n') && !canFind(s, 'i'))
        s ~= ".0";
    return s;
}

// ---------------------------------------------------------------------------
// Local helpers.
// ---------------------------------------------------------------------------

private string tarBundle(string dir, in ImportSpec[] imports)
{
    // One archive: the whole project, then each import from its own
    // parent directory under its destination name (multiple -C options
    // are positional in GNU tar).
    string[] args = ["tar", "-C", dir, "-cf", "-", "."];
    foreach (ref const ImportSpec imp; imports)
        args ~= ["-C", dirName(imp.src), imp.dest];
    auto p = pipeProcess(args, Redirect.stdout);
    auto app = appender!(ubyte[]);
    auto buf = new ubyte[65536];
    for (;;)
    {
        auto n = p.stdout.rawRead(buf).length;
        if (n == 0)
            break;
        app.put(buf[0 .. n]);
    }
    const int status = wait(p.pid); // tar warnings go to our stderr directly
    if (status != 0)
        throw new TachyError("cannot archive the project '" ~ dir
            ~ "' (tar exit status " ~ text(status) ~ ")");
    return cast(string) app.data;
}


/// Validate import sources (controller side): each must exist, and its
/// destination (the base name) must not collide with project content or
/// with another import's destination.
private void checkImports(string localProjectDir, in ImportSpec[] imports) @trusted
{
    import std.file : exists;

    bool[string] dests;
    foreach (ref const ImportSpec imp; imports)
    {
        if (!exists(imp.src))
            throw new TachyError("import '" ~ imp.src ~ "' does not exist");
        if (dests.get(imp.dest, false))
            throw new TachyError("import '" ~ imp.src ~ "': '" ~ imp.dest
                ~ "' is already the destination of another import");
        dests[imp.dest] = true;
        if (exists(buildPath(localProjectDir, imp.dest)))
            throw new TachyError("import '" ~ imp.src ~ "': '" ~ imp.dest
                ~ "' already exists in the project '" ~ localProjectDir
                ~ "' (imports may not overwrite project content)");
    }
}
private string failText(in CommandResult r)
{
    auto m = r.errText.strip;
    if (!m.length)
        m = r.outText.strip;
    if (!m.length)
        m = "exit status " ~ text(r.status);
    return m;
}

// ---------------------------------------------------------------------------
