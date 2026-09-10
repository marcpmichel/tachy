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
import std.datetime.stopwatch : StopWatch;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName;
import std.stdio : File, stderr, stdout, write, writefln, writeln;

import tachy.errors;
import tachy.events;
import tachy.inventory;
import tachy.models;
import tachy.modules;
import tachy.project;
import tachy.settings;
import tachy.transport;
import tachy.value;
import tachy.vars;

struct RunOptions
{
    string inventoryPath = "inventory.pravic";
    string selection;      // host names / @tags / all, comma separated
    bool checkMode;
    bool verbose;
    bool listHosts;
    bool forceColor;       // color statuses even when stdout is not a tty
    bool keepBundle;      // keep the deployed bundle on each host (debugging)
    bool direct;           // apply jobs in this process, no project bundling
    string directReport;   // with --direct: write "ok changed failed" here
    bool events;           // with --direct: print one JSON event per line
    string identity;       // age identity for { age = ... } inventory vars
    string settings;       // optional settings file (default: discovered)
    string webAddress = "127.0.0.1"; // webui/webdoc: bind address
    int webPort = 8080;    // webui/webdoc: listen port
    string[] tasksFiles;
}


/// Interpret the positional tasks-file arguments: a directory names a
/// project whose entry file is "main.pravic"; anything else is used as
/// the tasks file itself.  With no argument, "main.pravic" in the
/// current directory is the entry point.
string[] resolveTasksFiles(in string[] args)
{
    import std.file : exists, isDir;
    if (!args.length)
        return ["main.pravic"];
    auto resolved = args.dup;
    foreach (ref f; resolved)
        if (f.length && exists(f) && isDir(f))
            f = buildPath(f, "main.pravic");
    return resolved;
}

int runTachy(const RunOptions opts)
{
    if (!opts.selection.length)
        throw new TachyError("missing hosts selection (comma-separated host names or @tags, or \"all\")");
    if (opts.direct && opts.listHosts)
        throw new TachyError("--list-hosts cannot be combined with --direct");

    auto inventory = Inventory.load(opts.inventoryPath, opts.identity);
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

    // One consumer for every event the job loop produces: the text
    // renderer (headers/footers suppressed in machine mode), or the
    // event serializer for machine consumption over a stream.  Machine
    // mode (--direct-report, how the bundled inner run executes) emits
    // job events only: the controller owns the header/footer events,
    // so the raw --events stream is not doubled.
    TextRenderer renderer = TextRenderer((string l) => terminalSink(l), tty, opts.verbose);
    void consume(JobEvent ev)
    {
        if (machine && ev.kind != JobEvent.Kind.job)
            return; // machine mode: job events only, no headers/footers
        if (opts.events)
        {
            stdout.writeln(eventLine(ev));
            stdout.flush();
            return;
        }
        renderer.handle(ev);
    }

    int totalFailed;

    const Settings settings = loadSettings(opts.settings);
    foreach (tasksFile; opts.tasksFiles)
    {
        auto loaded = loadTasksFile(tasksFile, settings);

        // Include entries under an import destination that do
        // not exist locally: without a bundle there is nothing to
        // compose them from, so --direct skips them (bundled mode
        // composes them on the host, where the import has landed).
        // stderr keeps stdout machine-clean in --events mode.
        foreach (d; loaded.deferred)
            stderr.writeln("-- skipped (under an import destination,"
                ~ " no bundle with --direct): ", d);

        consume(evFileStart(tasksFile, hosts.mapHosts()));

        ulong ok, changed, failed;
        foreach (ref const host; hosts)
        {
            Transport t;
            try
                t = makeTransport(host);
            catch (Exception e)
            {
                auto ev = evJob(host.name, tasksFile, host.name, "failed", e.msg);
                foldCounters(ev, ok, changed, failed);
                consume(ev);
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
                    StopWatch sw;
                    sw.start();
                    auto r = runModule(job.moduleName, params, ctx);
                    const ulong ms = sw.peek.total!"msecs";
                    string status = r.changed ? "changed" : "ok";
                    if (r.changed && opts.checkMode)
                        status = "changed (check)";
                    auto ev = evJob(host.name, tasksFile, defaultLabel(job.kind, params),
                        status, r.msg, r.details, ms);
                    foldCounters(ev, ok, changed, failed);
                    consume(ev);
                }
                catch (Exception e)
                {
                    auto ev = evJob(host.name, tasksFile, job.origin, "failed", e.msg);
                    foldCounters(ev, ok, changed, failed);
                    consume(ev);
                    break; // host is done for this tasks file
                }
            }
        }

        if (machine)
            writeDirectReport(opts.directReport, ok, changed, failed);
        consume(evFileDone(tasksFile, ok, changed, failed, opts.checkMode));
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
    const bool rawEvents = opts.events; // display the raw event stream
    TextRenderer renderer = TextRenderer((string l) => terminalSink(l), tty, opts.verbose);
    int totalFailed;
    DeployedBundle[string] deployed; // host \0 project dir -> bundle (reused)

    void display(JobEvent ev)
    {
        if (rawEvents)
            emitRawEvent(ev);
        else
            renderer.handle(ev);
    }

    try
    {
        const Settings settings = loadSettings(opts.settings);
        foreach (tasksFile; opts.tasksFiles)
        {
            auto loaded = loadTasksFile(tasksFile, settings); // validate on the controller

            const string absTasks = buildNormalizedPath(absolutePath(tasksFile));
            const string projectDir = dirName(absTasks);
            checkProjectContained(loaded, projectDir);

            // import sources land in the bundle next to the project
            // copy, under their base name (bundled mode only).
            ImportSpec[] imports;
            foreach (src; loaded.imports)
                imports ~= ImportSpec(src, baseName(src));


            // display() routes through the raw-event serializer in
            // --events mode, so the machine stream is self-describing:
            // fileStart and fileDone wrap the job events of each file
            // (the webui consumes exactly this).
            display(evFileStart(tasksFile, hosts.mapHosts()));


            ulong ok, changed, failed;
            foreach (ref const host; hosts)
            {
                Transport t;
                try
                    t = makeTransport(host);
                catch (Exception e)
                {
                    failed++;
                    display(evJob(host.name, tasksFile, host.name, "failed", e.msg));
                    continue;
                }

                try
                {
                    // The cache key covers the import set: two entry
                    // files sharing a project but importing differently
                    // must not reuse one bundle.
                    const string key = host.name ~ "\0" ~ projectDir
                        ~ "\0" ~ importsSignature(imports);
                    ProjectBundle b;
                    if (auto d = key in deployed)
                        b = (*d).bundle;
                    else
                    {
                        b = deployProject(t, projectDir, host.name,
                            inventory.varsFor(host.name), imports);
                        deployed[key] = DeployedBundle(host.name, t, b);
                    }

                    const string reportPath = buildPath(b.root, "report");
                    const string cmd = innerTachyCommand(b, host.name, baseName(absTasks),
                        opts.checkMode, opts.verbose, tty, reportPath);

                    // Stream the inner run's events live: each stdout
                    // line is one JSON event, rendered as it arrives.
                    // The sink runs on two threads (stdout here, stderr
                    // on the transport's drain thread); one lock
                    // serializes it.
                    Object sinkLock = new Object;
                    auto r = t.runStreaming(cmd, (string line, bool isErr)
                    {
                        synchronized (sinkLock)
                        {
                            if (isErr)
                            {
                                stderr.writeln(line);
                                return;
                            }
                            if (rawEvents)
                            {
                                stdout.writeln(line); // raw passthrough
                                stdout.flush();
                                return;
                            }
                            JobEvent ev;
                            try
                            {
                                if (parseEventLine(line, ev))
                                {
                                    // the controller prints its own
                                    // header/footer and owns the counters
                                    if (ev.kind == JobEvent.Kind.job)
                                        renderer.handle(ev);
                                    return;
                                }
                            }
                            catch (TachyError e)
                            {
                                stderr.writeln("bad event line from ",
                                    host.name, ": ", e.msg);
                                return;
                            }
                            stdout.writeln(line); // remote noise passes through
                        }
                    });

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
                    display(evJob(host.name, tasksFile, "project", "failed", e.msg));
                }
            }

            display(evFileDone(tasksFile, ok, changed, failed, opts.checkMode));
            totalFailed += cast(int) failed;
        }
    }
    finally
    {
        foreach (ref d; deployed.byValue())
        {
            if (opts.keepBundle)
            {
                // keep the raw event stream machine-clean
                if (rawEvents)
                    stderr.writefln("-- bundle kept on %s at %s (remove it manually)",
                        d.host, d.bundle.root);
                else
                    writefln("-- bundle kept on %s at %s (remove it manually)",
                        d.host, d.bundle.root);
            }
            else
                removeBundle(d.transport, d.bundle); // best-effort
        }
    }

    return totalFailed > 0 ? 1 : 0;
}


/// Cache-key signature of a bundle's import set (sources are resolved
/// absolute and collected in deterministic order).
private string importsSignature(in ImportSpec[] imports) @safe pure
{
    string s;
    foreach (ref const i; imports)
        s ~= i.src ~ "\0" ~ i.dest ~ "\n";
    return s;
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
    // files and directories key their params by "path", compose by the
    // injected "dir", everything else by the injected "name".
    const string key = kind.among!("file", "directory") ? "path"
        : kind == "compose" ? "dir" : "name";
    auto pv = key in params;
    if (pv !is null && (*pv).kind == Val.Kind.string_)
        return kind ~ " " ~ (*pv).str_;
    return kind;
}

/// Terminal event sink: writes each rendered line and flushes, so lines
/// from a streamed run appear as they happen.
private void terminalSink(string line)
{
    stdout.write(line);
    stdout.flush();
}

/// Machine mode: one JSON event per line on stdout, flushed as emitted.
private void emitRawEvent(JobEvent ev)
{
    stdout.writeln(eventLine(ev));
    stdout.flush();
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
