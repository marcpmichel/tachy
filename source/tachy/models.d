module tachy.models;

/**
 * Tasks files: lists of idempotent atomic "ensure" jobs, keyed by target.
 *
 * A tasks file manages three kinds of resources, each addressed by its path
 * (or unit name) as the table key.  Both TOML spellings are equivalent:
 *
 *     [files."/tmp/myfile"]            # sub-table style
 *     owner = "root"
 *     mode = "0600"
 *
 *     [files]                          # inline-table style
 *     "/tmp/myfile" = { owner = "root", mode = "0600" }
 *
 * Kinds and their parameters:
 *
 *     [files.PATH]        state (default "file"; also "link"/"absent"),
 *                          content, src, mode, owner, group
 *     [directories.PATH]  state (default "directory"; also "absent"),
 *                          mode, owner, group
 *     [services.UNIT]     state (started/stopped/restarted/reloaded), enabled
 *
 * Files compose through includes; each include carries its own variables.
 * Scopes chain: outer vars < include vars < included file's own `[vars]`;
 * the resulting scope flows forward, so the includer's own jobs (which run
 * after its includes) can use variables defined by the files it includes:
 *
 *     [vars]
 *     domain = "example.org"
 *
 *     [includes."tasks/one.toml"]
 *     var1 = "value1"
 *     var2 = "value2"
 *
 *     [includes]
 *     "tasks/two.toml" = { var1 = "override" }
 *
 */
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.path : buildNormalizedPath, buildPath, dirName, isAbsolute;
import std.string : indexOf;

import tachy.errors;
import tachy.modules : validateModuleParams;
import tachy.value;
import tachy.vars : deepMerge;

struct Job
{
    string kind;           // "file", "directory" or "service" (display)
    string moduleName;     // "file" or "service" (dispatch)
    string target;         // path or unit name (the table key)
    string origin;         // "file: kind \"target\"" for error messages
    string tasksFileDir;   // dir of the defining file, for relative file.src
    Val[string] params;    // module params (path/name injected); rendered per host
    Val[string] overlay;   // include-chain + own vars, merged over host vars at run time
}

struct LoadedTasks
{
    Job[] jobs; // deterministic order; see module docs
}

/// Load a tasks file, recursively resolving includes.
LoadedTasks loadTasksFile(string path)
{
    LoadedTasks loaded;
    string[][string] seen; // (module \0 target) -> origins
    string[] active;       // include chain, for cycle detection
    loadInto(path, null, active, loaded, seen);
    return loaded;
}

/// Returns the file's exported scope: outer vars + own vars + everything
/// its includes contributed.  The scope grows monotonically through the
/// include chain, so a file's own jobs (which run after its includes) can
/// use variables defined by the files it includes.
private Val[string] loadInto(string path, Val[string] outerVars, ref string[] active,
    ref LoadedTasks loaded, ref string[][string] seen)
{
    if (canFind(active, path))
        throw new TachyError("include cycle: " ~ active.join(" -> ") ~ " -> " ~ path);

    auto root = loadToml(path);
    auto t = root.table_;
    checkKeys(t, ["vars", "files", "directories", "services", "includes"], path);

    auto ownVars = optTable(t, "vars", path);
    auto scopeVars = deepMerge(outerVars, ownVars);

    // Includes first, sorted by path for determinism.  Include vars bind
    // for the included subtree; the subtree's resulting scope flows on.
    if ("includes" in t)
    {
        auto inc = t["includes"];
        if (inc.kind != Val.Kind.table_)
            throw new TachyError(path ~ ": 'includes' must be a table");
        auto paths = inc.table_.byKey.array;
        paths.sort();
        foreach (incPath; paths)
        {
            auto entry = inc.table_[incPath];
            auto ctx = path ~ ": includes." ~ incPath;
            if (entry.kind != Val.Kind.table_)
                throw new TachyError(ctx ~ " must be a table of variables");
            auto resolved = incPath;
            if (!isAbsolute(resolved))
                resolved = buildNormalizedPath(buildPath(dirName(path), resolved));
            active ~= path;
            auto childScope = loadInto(resolved, deepMerge(scopeVars, dupTable(entry.table_)),
                active, loaded, seen);
            active = active[0 .. $ - 1];
            scopeVars = deepMerge(scopeVars, childScope);
        }
    }

    addJobs(loaded, seen, path, "files", "file", t, scopeVars);
    addJobs(loaded, seen, path, "directories", "file", t, scopeVars);
    addJobs(loaded, seen, path, "services", "service", t, scopeVars);
    return scopeVars;
}

private void addJobs(ref LoadedTasks loaded, ref string[][string] seen,
    string path, string section, string moduleName, in Val[string] t, Val[string] overlay)
{
    if (section !in t)
        return;
    auto secVal = t[section];
    if (secVal.kind != Val.Kind.table_)
        throw new TachyError(path ~ ": '" ~ section ~ "' must be a table");

    const size_t before = loaded.jobs.length;

    foreach (string target, const Val entry; secVal.table_)
    {
        auto ctx = path ~ ": " ~ section ~ " \"" ~ target ~ "\"";
        if (!target.length)
            throw new TachyError(ctx ~ ": empty " ~ (moduleName == "service" ? "unit name" : "path"));
        if (entry.kind != Val.Kind.table_)
            throw new TachyError(ctx ~ " must map to a table of parameters");

        auto params = dupTable(entry.table_);
        const string key = moduleName == "service" ? "name" : "path";
        if (key in params)
            throw new TachyError(ctx ~ ": '" ~ key ~ "' is implied by the table key and must not be set");
        params[key] = Val(target);

        if (moduleName == "file" && "state" !in params)
            params["state"] = Val(section == "files" ? "file" : "directory");

        validateModuleParams(moduleName, params, ctx);
        if (section == "directories")
        {
            auto st = optString(params, "state", ctx);
            if (st != "directory" && st != "absent")
                throw new TachyError(ctx ~ ": 'state' must be \"directory\" or \"absent\", not \"" ~ st ~ "\"");
        }

        auto dedup = moduleName ~ "\0" ~ target;
        if (auto prev = dedup in seen)
            throw new TachyError(ctx ~ ": " ~ (moduleName == "service" ? "unit" : "path") ~ " '"
                ~ target ~ "' is already managed at " ~ (*prev)[0]);
        seen[dedup] = [ctx];

        Job job;
        job.kind = section == "files" ? "file"
            : section == "directories" ? "directory"
            : "service";
        job.moduleName = moduleName;
        job.target = target;
        job.origin = ctx;
        job.tasksFileDir = dirName(path);
        job.params = params;
        job.overlay = overlay;
        loaded.jobs ~= job;
    }

    // AA iteration order is unspecified: sort this section's jobs by target.
    loaded.jobs[before .. $].sort!((a, b) => a.target < b.target);
}

// ---------------------------------------------------------------------------

version (unittest)
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse;
    import std.path : buildPath;
    import std.file : tempDir;
    import std.stdio : File;

    private string writeTemp(string sub, string content)
    {
        auto dir = tempDir ~ "/tachy_models_ut";
        if (!exists(dir)) mkdirRecurse(dir);
        auto p = buildPath(dir, sub);
        auto f = File(p, "w");
        f.write(content);
        f.close();
        return p;
    }
}

unittest // both table spellings, param injection, defaults
{
    writeTemp("inner.toml", `
[directories."/srv/app"]
mode = "0755"
`);
    auto p = writeTemp("main.toml", `
[vars]
owner = "app"

[files."/tmp/myfile"]
owner = "root"
mode = "0600"

[files]
"/tmp/other" = { mode = "0644" }

[services.nginx]
state = "started"
enabled = true
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 3);

    assert(loaded.jobs[0].kind == "file" && loaded.jobs[0].target == "/tmp/myfile");
    assert(loaded.jobs[0].params["path"].str_ == "/tmp/myfile");
    assert(loaded.jobs[0].params["state"].str_ == "file");
    assert(loaded.jobs[0].params["mode"].str_ == "0600");
    assert(loaded.jobs[0].tasksFileDir.indexOf("tachy_models_ut") >= 0);

    assert(loaded.jobs[1].kind == "file" && loaded.jobs[1].target == "/tmp/other"); // sorted

    assert(loaded.jobs[2].kind == "service" && loaded.jobs[2].moduleName == "service");
    assert(loaded.jobs[2].params["name"].str_ == "nginx");
    assert(loaded.jobs[2].params["enabled"].boolean_);
}

unittest // includes: order, var layering, path resolution
{
    writeTemp("one.toml", `
[vars]
from_one = "1"
[files."/tmp/one"]
mode = "0400"
`);
    writeTemp("two.toml", `
[files."/tmp/two"]
mode = "0400"
`);
    auto p = writeTemp("compose.toml", `
[vars]
top = "yes"
override_me = "top"

[includes."one.toml"]
override_me = "one"

[includes]
"two.toml" = { extra = "e" }

[files."/tmp/top"]
mode = "0400"
`);
    auto loaded = loadTasksFile(p);
    // includes first (sorted), then own jobs
    assert(loaded.jobs.length == 3);
    assert(loaded.jobs[0].target == "/tmp/one");
    assert(loaded.jobs[1].target == "/tmp/two");
    assert(loaded.jobs[2].target == "/tmp/top");

    // overlay: outer vars < include vars < included file's own vars
    assert(loaded.jobs[0].overlay["top"].str_ == "yes");          // outer visible
    assert(loaded.jobs[0].overlay["override_me"].str_ == "one");  // include var wins
    assert(loaded.jobs[0].overlay["from_one"].str_ == "1");       // own vars of one.toml
    assert(loaded.jobs[1].overlay["extra"].str_ == "e");

    // flow-through: the includer's own jobs run after its includes and see
    // everything the includes contributed (child [vars] and bindings).
    assert(loaded.jobs[2].overlay["top"].str_ == "yes");
    assert(loaded.jobs[2].overlay["from_one"].str_ == "1");       // flowed from one.toml
    assert(loaded.jobs[2].overlay["extra"].str_ == "e");          // flowed from include vars
    assert(loaded.jobs[2].overlay["override_me"].str_ == "one");  // last include wins
}

unittest // errors
{
    import std.exception : assertThrown;
    // duplicate target across files
    writeTemp("dup_inc.toml", "[files.\"/tmp/x\"]\nmode = \"0600\"\n");
    assertThrown!(TachyError)(loadTasksFile(writeTemp("dup.toml",
        "[includes.\"dup_inc.toml\"]\n[files.\"/tmp/x\"]\nmode = \"0644\"\n")));
    // duplicate between files and directories
    assertThrown!(TachyError)(loadTasksFile(writeTemp("dup2.toml",
        "[files.\"/tmp/x\"]\nmode = \"0600\"\n[directories.\"/tmp/x\"]\nmode = \"0700\"\n")));
    // include cycle
    writeTemp("cyc_a.toml", "[includes.\"cyc_b.toml\"]\n");
    writeTemp("cyc_b.toml", "[includes.\"cyc_a.toml\"]\n");
    assertThrown!(TachyError)(loadTasksFile(buildPath(dirName(writeTemp("cyc_a.toml", "[includes.\"cyc_b.toml\"]\n")), "cyc_a.toml")));
    // explicit path/name key forbidden (implied by table key)
    assertThrown!(TachyError)(loadTasksFile(writeTemp("key.toml",
        "[files.\"/tmp/x\"]\npath = \"/elsewhere\"\n")));
    assertThrown!(TachyError)(loadTasksFile(writeTemp("key2.toml",
        "[services.app]\nname = \"other\"\n")));
    // bad directories state
    assertThrown!(TachyError)(loadTasksFile(writeTemp("st.toml",
        "[directories.\"/tmp/x\"]\nstate = \"file\"\n")));
    // unknown top-level key
    assertThrown!(TachyError)(loadTasksFile(writeTemp("unk.toml", "bogus = 1\n")));
    // unknown param key inside an entry
    assertThrown!(TachyError)(loadTasksFile(writeTemp("unk2.toml",
        "[files.\"/tmp/x\"]\nbogus = 1\n")));
}
