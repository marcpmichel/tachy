module tachy.runner;

/**
 * Orchestrates a run: the CLI selection resolves to inventory hosts, then
 * each tasks file is applied to every host — its includes first, then its
 * own jobs, all rendered against the host's variable scope.  A failing host
 * is dropped from the rest of its tasks file; other hosts continue.  Exit
 * code is 1 when anything failed.
 */
import std.array : join;
import std.conv : text;
import std.format : format;
import std.path : dirName;
import std.stdio : stdout, write, writefln, writeln;

import tachy.errors;
import tachy.inventory;
import tachy.models;
import tachy.modules;
import tachy.transport;
import tachy.value;
import tachy.vars;

struct RunOptions
{
    string inventoryPath = "inventory.toml";
    string selection;      // host names / #tags / all, comma separated
    bool checkMode;
    bool verbose;
    bool listHosts;
    string[] tasksFiles;
}

int runTachy(const RunOptions opts)
{
    if (!opts.selection.length)
        throw new TachyError("missing hosts selection (comma-separated host names or #tags, or \"all\")");

    auto inventory = Inventory.load(opts.inventoryPath);
    auto hosts = inventory.select(opts.selection);
    if (hosts.length == 0)
        throw new TachyError(text("selection '", opts.selection, "' matched no hosts"));

    const bool tty = isStdoutTty();
    int totalFailed;

    foreach (tasksFile; opts.tasksFiles)
    {
        auto loaded = loadTasksFile(tasksFile);

        writefln("== %s | hosts: %s", tasksFile, hosts.mapHosts().join(", "));

        if (opts.listHosts)
        {
            foreach (ref h; hosts)
                writefln("  %s (%s)", h.name, describeHost(h));
            continue;
        }

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
                    TaskContext ctx = TaskContext(t, opts.checkMode, host.name, job.tasksFileDir);
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

        writefln("-- %s: ok=%d changed=%d failed=%d%s", tasksFile, ok, changed, failed,
            opts.checkMode ? " (check mode, nothing applied)" : "");
        totalFailed += cast(int) failed;
    }

    return totalFailed > 0 ? 1 : 0;
}

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
    auto pv = (kind == "service" ? "name" : "path") in params;
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
