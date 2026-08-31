module tachy.runner;

/**
 * Orchestration.  Two execution modes:
 *
 *  - bundled (the default): for every selected host, the tasks file's
 *    parent directory — its *project* — is deployed to the host as a
 *    temporary bundle (project copy, tachy binary copy, generated
 *    one-host inventory; see tachy.project), and the copied binary
 *    executes there in --direct mode.  The inner run prints the usual
 *    per-job lines (relayed verbatim) and reports its counters through
 *    a report file, which the controller aggregates.  A failing host is
 *    dropped from the rest of its tasks file; other hosts continue.
 *    Exit code is 1 when anything failed.
 *
 *  - direct (--direct): no bundling — this process applies every job
 *    itself through each host's transport.  Used by the inner binary
 *    after bundling, and available for manual local execution.  With
 *    --direct-report, headers/footers are suppressed and counters are
 *    written to the report file instead (machine mode).
 */
import std.algorithm.comparison : among;
import std.algorithm.searching : endsWith, startsWith;
import std.array : join;
import std.conv : text;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName;
import std.stdio : File, stderr, stdout, write, writefln, writeln;

import tachy.errors;
import tachy.inventory;
import tachy.models;
import tachy.modules;
import tachy.project;
import tachy.transport;
import tachy.value;
import tachy.vars;

struct RunOptions
{
    string inventoryPath = "inventory.toml";
    string selection;      // host names / @tags / all, comma separated
    bool checkMode;
    bool verbose;
    bool listHosts;
    bool forceColor;       // color statuses even when stdout is not a tty
    bool keepBundle;      // keep the deployed bundle on each host (debugging)
    bool direct;           // apply jobs in this process, no project bundling
    string directReport;   // with --direct: write "ok changed failed" here
    string[] tasksFiles;
}

/// Interpret the positional tasks-file arguments: a directory names a
/// project whose entry file is "main.toml"; anything else is used as
/// the tasks file itself.  With no argument, "main.toml" in the
/// current directory is the entry point.
string[] resolveTasksFiles(in string[] args)
{
    import std.file : exists, isDir;
    if (!args.length)
        return ["main.toml"];
    auto resolved = args.dup;
    foreach (ref f; resolved)
        if (f.length && exists(f) && isDir(f))
            f = buildPath(f, "main.toml");
    return resolved;
}

int runTachy(const RunOptions opts)
{
    if (!opts.selection.length)
        throw new TachyError("missing hosts selection (comma-separated host names or @tags, or \"all\")");
    if (opts.direct && opts.listHosts)
        throw new TachyError("--list-hosts cannot be combined with --direct");

    auto inventory = Inventory.load(opts.inventoryPath);
    auto hosts = inventory.select(opts.selection);
    if (hosts.length == 0)
        throw new TachyError(text("selection '", opts.selection, "' matched no hosts"));

    if (opts.listHosts)
    {
        writefln("== %s | hosts: %s", opts.selection, hosts.mapHosts().join(", "));
        foreach (ref h; hosts)
            writefln("  %s (%s)", h.name, describeHost(h));
        return 0;
    }

    if (opts.direct)
        return runDirect(opts, inventory, hosts);
    return runBundled(opts, inventory, hosts);
}

// ---------------------------------------------------------------------------
// Direct mode: this process runs every job (the classic execution path).
// ---------------------------------------------------------------------------

private int runDirect(const RunOptions opts, Inventory inventory, HostConfig[] hosts)
{
    const bool tty = isStdoutTty() || opts.forceColor;
    const bool machine = opts.directReport.length > 0;
    int totalFailed;

    foreach (tasksFile; opts.tasksFiles)
    {
        auto loaded = loadTasksFile(tasksFile);

        if (!machine)
            writefln("== %s | hosts: %s", tasksFile, hosts.mapHosts().join(", "));

        size_t nameWidth = 0;
        foreach (ref h; hosts)
            nameWidth = h.name.length > nameWidth ? h.name.length : nameWidth;

        ulong ok, changed, failed;
        foreach (ref const host; hosts)
        {
            Transport t;
            try
                t = makeTransport(host);
            catch (Exception e)
            {
                failed++;
                printTask(tty, nameWidth, host.name, host.name, "failed", e.msg);
                continue;
            }

            auto hostVars = inventory.varsFor(host.name);

            foreach (ref const job; loaded.jobs)
            {
                try
                {
                    auto vars = deepMerge(hostVars, job.overlay);
                    auto params = renderParams(job.params, vars);
                    TaskContext ctx = TaskContext(t, opts.checkMode, host.name, job.tasksFileDir, vars);
                    auto r = runModule(job.moduleName, params, ctx);
                    if (r.changed)
                        changed++;
                    else
                        ok++;
                    string status = r.changed ? "changed" : "ok";
                    if (r.changed && opts.checkMode)
                        status = "changed (check)";
                    printTask(tty, nameWidth, host.name, defaultLabel(job.kind, params), status, r.msg);
                    if (opts.verbose)
                        foreach (d; r.details)
                            writeln("    ", d);
                }
                catch (Exception e)
                {
                    failed++;
                    printTask(tty, nameWidth, host.name, job.origin, "failed", e.msg);
                    break; // host is done for this tasks file
                }
            }
        }

        if (machine)
            writeDirectReport(opts.directReport, ok, changed, failed);
        else
            writefln("-- %s: ok=%d changed=%d failed=%d%s", tasksFile, ok, changed, failed,
                opts.checkMode ? " (check mode, nothing applied)" : "");
        totalFailed += cast(int) failed;
    }

    return totalFailed > 0 ? 1 : 0;
}

private void writeDirectReport(string path, ulong ok, ulong changed, ulong failed)
{
    try
    {
        auto f = File(path, "w");
        f.writefln("%s %s %s", ok, changed, failed);
        f.close();
    }
    catch (Exception e)
        throw new TachyError("cannot write the direct report '" ~ path ~ "': " ~ e.msg);
}

// ---------------------------------------------------------------------------

private struct DeployedBundle
{
    string host;
    Transport transport;
    ProjectBundle bundle;
}

private int runBundled(const RunOptions opts, Inventory inventory, HostConfig[] hosts)
{
    const bool tty = isStdoutTty();
    int totalFailed;
    DeployedBundle[string] deployed; // host \0 project dir -> bundle (reused)

    try
    {
        foreach (tasksFile; opts.tasksFiles)
        {
            auto loaded = loadTasksFile(tasksFile); // validate on the controller

            const string absTasks = buildNormalizedPath(absolutePath(tasksFile));
            const string projectDir = dirName(absTasks);
            checkProjectContained(loaded, projectDir);

            writefln("== %s | hosts: %s", tasksFile, hosts.mapHosts().join(", "));

            size_t nameWidth = 0;
            foreach (ref h; hosts)
                nameWidth = h.name.length > nameWidth ? h.name.length : nameWidth;

            ulong ok, changed, failed;
            foreach (ref const host; hosts)
            {
                Transport t;
                try
                    t = makeTransport(host);
                catch (Exception e)
                {
                    failed++;
                    printTask(tty, nameWidth, host.name, host.name, "failed", e.msg);
                    continue;
                }

                try
                {
                    const string key = host.name ~ "\0" ~ projectDir;
                    ProjectBundle b;
                    if (auto d = key in deployed)
                        b = (*d).bundle;
                    else
                    {
                        b = deployProject(t, projectDir, host.name, inventory.varsFor(host.name));
                        deployed[key] = DeployedBundle(host.name, t, b);
                    }

                    const string reportPath = buildPath(b.root, "report");
                    const string cmd = innerTachyCommand(b, host.name, baseName(absTasks),
                        opts.checkMode, opts.verbose, tty, reportPath);

                    auto r = t.run(cmd);
                    relayOutput(r.outText, r.errText);

                    ulong hOk, hChanged, hFailed;
                    if (readReport(t, reportPath, hOk, hChanged, hFailed))
                    {
                        ok += hOk;
                        changed += hChanged;
                        failed += hFailed;
                        if (!r.ok && hFailed == 0)
                            failed++; // killed or crashed after reporting
                    }
                    else
                        failed++; // inner run died before writing its report
                }
                catch (Exception e)
                {
                    failed++;
                    printTask(tty, nameWidth, host.name, "project", "failed", e.msg);
                }
            }

            writefln("-- %s: ok=%d changed=%d failed=%d%s", tasksFile, ok, changed, failed,
                opts.checkMode ? " (check mode, nothing applied)" : "");
            totalFailed += cast(int) failed;
        }
    }
    finally
    {
        foreach (ref d; deployed.byValue())
        {
            if (opts.keepBundle)
                writefln("-- bundle kept on %s at %s (remove it manually)",
                    d.host, d.bundle.root);
            else
                removeBundle(d.transport, d.bundle);
        }
    }

    return totalFailed > 0 ? 1 : 0;
}

/// A project must be self-contained: every file of the composition has
/// to live inside the tasks file's parent directory, since only that
/// directory is copied to the host.
private void checkProjectContained(in LoadedTasks loaded, string projectDir)
{
    const string prefix = projectDir ~ "/";
    foreach (f; loaded.sourceFiles)
        if (!startsWith(f, prefix))
            throw new TachyError("composition includes '" ~ f
                ~ "', which is outside the project directory '" ~ projectDir
                ~ "'; a project (the tasks file's parent directory) must be"
                ~ " self-contained");
}

private bool readReport(Transport t, string path, out ulong ok, out ulong changed, out ulong failed)
{
    ok = changed = failed = 0;
    auto r = t.run("cat -- " ~ shQuote(path));
    if (!r.ok)
        return false;
    return parseReport(r.outText, ok, changed, failed);
}

private void relayOutput(string outText, string errText)
{
    if (outText.length)
    {
        stdout.write(outText);
        if (!endsWith(outText, "\n"))
            writeln();
    }
    if (errText.length)
    {
        stderr.write(errText);
        if (!endsWith(errText, "\n"))
            stderr.writeln();
    }
}

// ---------------------------------------------------------------------------

private string[] mapHosts()(HostConfig[] hosts)
{
    import std.array : array;
    import std.algorithm.iteration : map;
    return hosts.map!(h => h.name).array;
}

private string describeHost(in HostConfig h) @safe pure
{
    if (h.connection == "local")
        return "local";
    auto s = "ssh ";
    if (h.user.length)
        s ~= h.user ~ "@";
    s ~= h.address.length ? h.address : h.name;
    if (h.port != 22)
        s ~= text(":", h.port);
    return s;
}

private string defaultLabel(string kind, in Val[string] params) @safe pure
{
    // files and directories key their params by "path", everything else
    // by the injected "name".
    const string key = kind.among!("file", "directory") ? "path" : "name";
    auto pv = key in params;
    if (pv !is null && (*pv).kind == Val.Kind.string_)
        return kind ~ " " ~ (*pv).str_;
    return kind;
}

private void printTask(bool tty, size_t nameWidth, string host, string label,
    string status, string msg)
{
    string color;
    if (tty)
    {
        if (status == "failed")
            color = "\033[31m";
        else if (status.startsWithChanged())
            color = "\033[33m";
        else if (status == "ok")
            color = "\033[32m";
    }
    const string reset = tty ? "\033[0m" : "";
    write(format("%-*s | ", nameWidth, host));
    if (color.length)
        write(color);
    write(format("%-16s", status));
    if (color.length)
        write(reset);
    writeln("| ", label, ": ", msg);
}

private bool startsWithChanged(string status) @safe pure
{
    return status.length >= 7 && status[0 .. 7] == "changed";
}

private bool isStdoutTty() @trusted
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;
        return isatty(1) != 0;
    }
    else
        return false;
}

// ---------------------------------------------------------------------------

version (unittest)
{
    import std.algorithm.searching : canFind;
    import std.file : exists, mkdirRecurse, tempDir;
    import std.path : buildPath;
    import std.stdio : File;

    unittest // resolveTasksFiles: directories map to main.toml
    {
        auto dir = buildPath(tempDir, "tachy_runner_ut", "proj");
        if (!exists(dir)) mkdirRecurse(dir);
        {
            auto f = File(buildPath(dir, "main.toml"), "w");
            f.write("[files.\"/tmp/x\"]\n");
            f.close();
        }

        // directory argument -> main.toml inside it
        auto r = resolveTasksFiles([dir]);
        assert(r.length == 1 && r[0] == buildPath(dir, "main.toml"));

        // trailing slash on the directory behaves the same
        r = resolveTasksFiles([dir ~ "/"]);
        assert(r.length == 1 && canFind(r[0], "main.toml"));

        // plain file and missing paths pass through untouched
        r = resolveTasksFiles(["site/other.toml", "missing.toml"]);
        assert(r == ["site/other.toml", "missing.toml"]);

        // no argument: main.toml in the current directory
        r = resolveTasksFiles([]);
        assert(r == ["main.toml"]);
    }
}
