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
 *     ├── inventory.toml          generated: one local host with its vars
 *     ├── report                  written by the inner run: "ok changed failed"
 *     └── project/                copy of the tasks file's parent directory
 *
 * The copied binary is executed on the host (over ssh, or locally for
 * `connection = "local"` hosts) with `--direct`: it applies the copied
 * tasks file through a local connection, so includes and `file.src`
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
import std.path : buildPath, isAbsolute;
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
    string inventoryPath; // root ~ "/inventory.toml": generated inventory
}

/// Deploy a project bundle on the host reached through `t`: copy
/// `localProjectDir`, the running tachy binary and a generated
/// one-host inventory into a fresh temporary directory there.
ProjectBundle deployProject(Transport t, string localProjectDir,
    string hostName, in Val[string] hostVars)
{
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
    b.inventoryPath = buildPath(b.root, "inventory.toml");

    auto mkd = t.run("mkdir -- " ~ shQuote(b.projectDir));
    if (!mkd.ok)
        throw new TachyError("cannot create " ~ b.projectDir ~ " on " ~ hostName
            ~ ": " ~ failText(mkd));

    // Project copy: tar on the controller, untar on the host (stdin).
    auto extract = t.runWithInput("tar -C " ~ shQuote(b.projectDir) ~ " -xf -",
        tarDirectory(localProjectDir));
    if (!extract.ok)
        throw new TachyError("cannot copy project '" ~ localProjectDir ~ "' to "
            ~ hostName ~ ": " ~ failText(extract));

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
        hostInventoryToml(hostName, hostVars));
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
/// file's basename in `--direct` mode against the generated inventory,
/// forwarding check mode, verbosity and colors, and reporting its
/// counters to `reportPath`.
string innerTachyCommand(in ProjectBundle b, string hostName, string tasksBaseName,
    bool check, bool verbose, bool color, string reportPath)
{
    string cmd = "cd " ~ shQuote(b.projectDir) ~ " && " ~ shQuote(b.tachyPath) ~ " --direct";
    if (check)
        cmd ~= " --check";
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
// Generated inventory: host variables serialized back to TOML.
// ---------------------------------------------------------------------------

/// A one-host, local-connection inventory carrying the host's effective
/// variables (the controller's global < host merge).
string hostInventoryToml(string hostName, in Val[string] hostVars)
{
    auto app = appender!string;
    const string hostKey = tomlKey(hostName);
    app.put("[hosts." ~ hostKey ~ "]\nconnection = \"local\"\n");
    app.put("\n[hosts." ~ hostKey ~ ".vars]\n");
    writeSections(app, hostVars, "hosts." ~ hostKey ~ ".vars");
    return app.data;
}

/// Emit a table body: scalar and array keys first, then one section per
/// nested table (scalars must precede any sub-table header).
private void writeSections(ref Sink app, in Val[string] t, string prefix)
{
    auto keys = t.byKey.array;
    keys.sort();
    string[] tableKeys;
    foreach (k; keys)
    {
        if (t[k].kind == Val.Kind.table_)
        {
            tableKeys ~= k;
            continue;
        }
        app.put(tomlKey(k) ~ " = " ~ tomlValue(t[k]) ~ "\n");
    }
    foreach (k; tableKeys)
    {
        app.put("\n[" ~ prefix ~ "." ~ tomlKey(k) ~ "]\n");
        writeSections(app, t[k].table_, prefix ~ "." ~ tomlKey(k));
    }
}

private string tomlValue(in Val v)
{
    final switch (v.kind)
    {
        case Val.Kind.string_: return tomlString(v.str_);
        case Val.Kind.integer_: return text(v.integer_);
        case Val.Kind.float_: return tomlFloat(v.float_);
        case Val.Kind.boolean_: return v.boolean_ ? "true" : "false";
        case Val.Kind.array_:
        {
            string[] parts;
            foreach (const e; v.array_)
                parts ~= tomlValue(e);
            return "[" ~ parts.join(", ") ~ "]";
        }
        case Val.Kind.table_:
        {
            auto keys = v.table_.byKey.array;
            keys.sort();
            string[] parts;
            foreach (k; keys)
                parts ~= tomlKey(k) ~ " = " ~ tomlValue(v.table_[k]);
            return "{ " ~ parts.join(", ") ~ " }";
        }
    }
}

private string tomlKey(string k)
{
    return tomlString(k);
}

private string tomlString(string s)
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

/// TOML floats need a fractional part or exponent to stay floats.
private string tomlFloat(double d)
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

private string tarDirectory(string dir)
{
    auto p = pipeProcess(["tar", "-C", dir, "-cf", "-", "."], Redirect.stdout);
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

version (unittest)
{
    import std.algorithm.searching : canFind;
    import std.file : exists, mkdirRecurse, readText, tempDir;
    import std.path : buildPath;
    import std.stdio : File;
    import tachy.transport : LocalTransport;
    import tachy.value : toVal;
    import toml : parseTOML;

    unittest // hostInventoryToml round-trips through the TOML parser
    {
        Val[string] vars;
        vars["str"] = Val("it's \"quoted\"\n");
        vars["int"] = Val(42L);
        vars["float"] = Val(1.5);
        vars["whole-float"] = Val(2.0);
        vars["bool"] = Val(true);
        Val nested;
        nested.kind = Val.Kind.table_;
        nested.table_["x"] = Val(1L);
        vars["nested"] = nested;
        Val deep;
        deep.kind = Val.Kind.table_;
        deep.table_["in"] = Val("side");
        nested.table_["deep"] = deep;
        Val arr;
        arr.kind = Val.Kind.array_;
        arr.array_ ~= Val("one");
        arr.array_ ~= Val("two");
        vars["list"] = arr;


        auto text = hostInventoryToml("web 1", vars);
        auto doc = parseTOML(text);
        auto host = toVal(doc.table["hosts"]).table_["web 1"].table_;
        assert(host["connection"].str_ == "local");
        auto got = host["vars"].table_;
        assert(got["str"].str_ == "it's \"quoted\"\n");
        assert(got["int"].integer_ == 42);
        assert(got["float"].float_ == 1.5);
        assert(got["whole-float"].kind == Val.Kind.float_);
        assert(got["bool"].boolean_);
        assert(got["nested"].table_["x"].integer_ == 1);
        assert(got["list"].array_[0].str_ == "one");
        assert(got["list"].array_.length == 2);
        assert(got["list"].array_[1].str_ == "two");
    }

    unittest // empty vars still produce a valid inventory
    {
        auto text = hostInventoryToml("plain", null);
        auto doc = parseTOML(text);
        auto host = toVal(doc.table["hosts"]).table_["plain"].table_;
        assert(host["connection"].str_ == "local");
        assert("vars" in host);
    }

    unittest // parseReport
    {
        ulong ok, changed, failed;
        assert(parseReport("3 2 1\n", ok, changed, failed));
        assert(ok == 3 && changed == 2 && failed == 1);
        assert(!parseReport("", ok, changed, failed));
        assert(!parseReport("1 2", ok, changed, failed));
        assert(!parseReport("1 2 x", ok, changed, failed));
        assert(!parseReport("1 2 3 4", ok, changed, failed));
    }

    unittest // deployProject + removeBundle over the local transport
    {
        auto dir = buildPath(tempDir, "tachy_project_ut", "proj");
        if (!exists(dir)) mkdirRecurse(dir);
        {
            auto f = File(buildPath(dir, "main.toml"), "w");
            f.write("[files.\"/tmp/x\"]\n");
            f.close();
        }
        if (!exists(buildPath(dir, "sub"))) mkdirRecurse(buildPath(dir, "sub"));
        {
            auto f = File(buildPath(dir, "sub", "data.txt"), "w");
            f.write("payload");
            f.close();
        }

        auto t = new LocalTransport;
        Val[string] vars;
        vars["k"] = Val("v");
        auto b = deployProject(t, dir, "h1", vars);
        scope (exit) removeBundle(t, b);

        assert(isAbsolute(b.root));
        assert(exists(buildPath(b.projectDir, "main.toml")));
        assert(readText(buildPath(b.projectDir, "sub", "data.txt")) == "payload");
        assert(exists(b.tachyPath));
        auto inv = readText(b.inventoryPath);
        assert(canFind(inv, `connection = "local"`));
        assert(canFind(inv, `"k" = "v"`));
        assert(canFind(inv, `[hosts."h1"`));

        removeBundle(t, b);
        assert(!exists(b.root));

        auto cmd = innerTachyCommand(b, "h1", "main.toml", true, false, true,
            buildPath(b.root, "report"));
        assert(canFind(cmd, "cd "));
        assert(canFind(cmd, "--direct --check --color"));
        assert(canFind(cmd, "--direct-report"));
        assert(canFind(cmd, "h1"));
        assert(canFind(cmd, "'main.toml'"));
    }
}
