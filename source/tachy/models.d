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
 *                          content, src, line, block, mode, owner, group
 *     [directories.PATH]  state (default "directory"; also "absent"),
 *                          mode, owner, group
 *     [services.UNIT]     state (started/stopped/restarted/reloaded), enabled
 *
 * Files compose through includes and applies; each carries its own
 * variables.  Scopes chain: outer vars < directive vars < included file's
 * own `[vars]`; the resulting scope flows forward through the composition.
 * The two directives differ only in when the composed jobs run:
 *
 *   - `[includes]` runs first, before the file's own jobs (prerequisites:
 *     the includer's jobs can use variables defined by the files it
 *     includes);
 *   - `[apply]` runs after the file's own jobs, respecting the order of
 *     execution of the directives.
 *
 * The per-file execution order is: directories, files, before.packages,
 * packages, after.packages, before.accounts, groups, users,
 * after.accounts, before.services, services, after.services, execute.
 * The `[before.G]`/`[after.G]` hooks (G: packages, accounts, services)
 * are execute-style checks wrapping their group.
 *
 * Within one file both directives are processed sorted by path, and their
 * scopes keep flowing forward: a later directive sees the variables every
 * earlier one contributed.
 *
 *     [vars]
 *     domain = "example.org"
 *
 *     [includes."tasks/one.toml"]
 *     var1 = "value1"
 *
 *     [apply]
 *     "tasks/two.toml" = { later = true }
 *
 */
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, isAbsolute;
import std.string : indexOf;

import tachy.errors;
import tachy.modules : validateModuleParams;
import tachy.value;
import tachy.vars : deepMerge, resolveEnvVars;

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
    Job[] jobs;           // deterministic order; see module docs
    string[] sourceFiles; // every tasks file of the composition, resolved
                          // absolute paths (the entry file first)
}

/// Load a tasks file, recursively resolving includes and applies.  The
/// entry path is used as spelled (error origins read like the command
/// line); composed files are recorded normalized in `sourceFiles`.
LoadedTasks loadTasksFile(string path)
{
    LoadedTasks loaded;
    string[][string] seen; // (module \0 target) -> origins
    string[] active;       // include chain, for cycle detection
    loadInto(path, null, active, loaded, seen);
    return loaded;
}



/// Returns the file's exported scope: outer vars + own vars + everything
/// its includes and applies contributed.  The scope grows monotonically
/// through the composition chain, so a file's own jobs (which run after
/// its includes) can use variables defined by the files it includes.
private Val[string] loadInto(string path, Val[string] outerVars, ref string[] active,
    ref LoadedTasks loaded, ref string[][string] seen)
{
    if (canFind(active, path))
        throw new TachyError("composition cycle: " ~ active.join(" -> ") ~ " -> " ~ path);
    loaded.sourceFiles ~= buildNormalizedPath(absolutePath(path));

    auto root = loadToml(path);
    auto t = root.table_;
    checkKeys(t, ["vars", "files", "directories", "packages", "groups", "users",
        "services", "execute", "before", "after", "includes", "apply"], path);

    auto ownVars = resolveEnvVars(optTable(t, "vars", path), path);
    auto scopeVars = deepMerge(outerVars, ownVars);

    // Includes are prerequisites: they run before this file's own jobs.
    processDirective(t, "includes", path, scopeVars, active, loaded, seen);

    // Directories before files: a file may live inside a directory this
    // same file manages.  [before.<group>]/[after.<group>] hooks wrap
    // their group with execute-style checks (accounts = groups+users);
    // they run at the group's position whether or not it has entries.
    addJobs(loaded, seen, path, "directories", "file", t, scopeVars);
    addJobs(loaded, seen, path, "files", "file", t, scopeVars);
    addHooks(loaded, seen, path, t, "before", "packages", scopeVars);
    addJobs(loaded, seen, path, "packages", "package", t, scopeVars);
    addHooks(loaded, seen, path, t, "after", "packages", scopeVars);
    addHooks(loaded, seen, path, t, "before", "accounts", scopeVars);
    addJobs(loaded, seen, path, "groups", "group", t, scopeVars);
    addJobs(loaded, seen, path, "users", "user", t, scopeVars);
    addHooks(loaded, seen, path, t, "after", "accounts", scopeVars);
    addHooks(loaded, seen, path, t, "before", "services", scopeVars);
    addJobs(loaded, seen, path, "services", "service", t, scopeVars);
    addHooks(loaded, seen, path, t, "after", "services", scopeVars);
    addJobs(loaded, seen, path, "execute", "execute", t, scopeVars);

    // Applies respect the order of execution of the directives: they run
    // after this file's own jobs.
    processDirective(t, "apply", path, scopeVars, active, loaded, seen);
    return scopeVars;
}

/// Walk one composition directive (`includes` or `apply`), sorted by path
/// for determinism.  Directive vars bind for the composed subtree; the
/// subtree's resulting scope flows on, so later directives (and the
/// includer, for includes) see everything it contributed.
private void processDirective(in Val[string] t, string directive, string path,
    ref Val[string] scopeVars, ref string[] active, ref LoadedTasks loaded,
    ref string[][string] seen)
{
    if (directive !in t)
        return;
    auto dir = t[directive];
    if (dir.kind != Val.Kind.table_)
        throw new TachyError(path ~ ": '" ~ directive ~ "' must be a table");
    auto paths = dir.table_.byKey.array;
    paths.sort();
    foreach (dirPath; paths)
    {
        auto entry = dir.table_[dirPath];
        auto ctx = path ~ ": " ~ directive ~ "." ~ dirPath;
        if (entry.kind != Val.Kind.table_)
            throw new TachyError(ctx ~ " must be a table of variables");

        // The entry's keys are the variable binding; a `vars = { ... }`
        // sub-table is an equivalent, grouped spelling:
        //     [apply."files.toml"]
        //     vars = { three = "three" }
        auto binding = dupTable(entry.table_);
        if (auto v = "vars" in binding)
        {
            if ((*v).kind != Val.Kind.table_)
                throw new TachyError(ctx ~ ": 'vars' must be a table of variables, not a "
                    ~ (*v).typeName());
            auto nested = dupTable((*v).table_);
            binding.remove("vars");
            foreach (string k, const Val unused; nested)
                if (k in binding)
                    throw new TachyError(ctx ~ ": variable '" ~ k
                        ~ "' is bound both directly and under 'vars'");
            binding = deepMerge(binding, nested);
        }

        auto resolved = dirPath;
        if (!isAbsolute(resolved))
            resolved = buildNormalizedPath(buildPath(dirName(path), resolved));
        active ~= path;
        auto childScope = loadInto(resolved, deepMerge(scopeVars, binding),
            active, loaded, seen);
        active = active[0 .. $ - 1];
        scopeVars = deepMerge(scopeVars, childScope);
    }
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
            throw new TachyError(ctx ~ ": empty " ~ (moduleName == "file" ? "path" : "name"));
        if (entry.kind != Val.Kind.table_)
            throw new TachyError(ctx ~ " must map to a table of parameters");

        auto params = dupTable(entry.table_);
        const string key = moduleName == "file" ? "path" : "name";
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
            throw new TachyError(ctx ~ ": " ~ (moduleName == "file" ? "path" : "name") ~ " '"
                ~ target ~ "' is already managed at " ~ (*prev)[0]);
        seen[dedup] = [ctx];

        Job job;
        job.kind = kindFor(section);
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

/// Hook points: `[before.<group>]` and `[after.<group>]` wrap one job
/// group with execute-style checks (`run`, `exit_status`, `output`).
/// Groups: packages, accounts (groups + users), services.  Hooks run
/// at the group's position in this file's order whether or not the
/// group has entries, so a composition entry file can health-check
/// what its includes managed.
private void addHooks(ref LoadedTasks loaded, ref string[][string] seen,
    string path, in Val[string] t, string phase, string group, Val[string] overlay)
{
    auto pv = phase in t;
    if (pv is null)
        return;
    if ((*pv).kind != Val.Kind.table_)
        throw new TachyError(path ~ ": '" ~ phase ~ "' must be a table");
    checkKeys((*pv).table_, ["packages", "accounts", "services"],
        path ~ ": " ~ phase);

    auto gv = group in (*pv).table_;
    if (gv is null)
        return;

    // Reuse the [execute] machinery under a synthetic section name so
    // every check, message and duplicate rule matches exactly.
    Val[string] wrapper;
    wrapper[phase ~ "." ~ group] = cast(Val) *gv;
    addJobs(loaded, seen, path, phase ~ "." ~ group, "execute", wrapper, overlay);
}

/// Display kind for a tasks-file section.
private string kindFor(string section) @safe pure nothrow
{
    switch (section)
    {
        case "files": return "file";
        case "directories": return "directory";
        case "packages": return "package";
        case "groups": return "group";
        case "users": return "user";
        case "services": return "service";
        case "execute": return "execute";
        case "before.packages": case "after.packages":
        case "before.accounts": case "after.accounts":
        case "before.services": case "after.services":
            return "execute";
        default: assert(0, "unknown section " ~ section);
    }
}

version (unittest)
{
    import std.exception : assertThrown;
    import std.algorithm.searching : endsWith;
    import std.file : exists, mkdirRecurse, tempDir;
    import std.path : buildPath, isAbsolute;
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

unittest // [execute]: both spellings, order after services, name injection
{
    import std.exception : assertThrown;
    auto p = writeTemp("exec.toml", `
[files."/tmp/x"]
mode = "0400"

[execute]
"check os" = { run = "echo debian", exit_status = 0, output = "debian" }

[execute."probe thing"]
run = "true"
exit_status = { not = 1 }
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 3);
    assert(loaded.jobs[0].kind == "file");                       // files first
    assert(loaded.jobs[1].kind == "execute" && loaded.jobs[1].target == "check os");
    assert(loaded.jobs[1].moduleName == "execute");
    assert(loaded.jobs[1].params["name"].str_ == "check os");    // injected
    assert(loaded.jobs[2].target == "probe thing");              // sorted
    assert("exit_status" in loaded.jobs[2].params);

    // duplicate execute names are a load-time error
    assertThrown!(TachyError)(loadTasksFile(writeTemp("exec_dup.toml",
        "[execute.\"same\"]\nrun = \"true\"\n[execute]\n\"same\" = { run = \"false\" }\n")));
    // missing run
    assertThrown!(TachyError)(loadTasksFile(writeTemp("exec_norun.toml",
        "[execute.\"x\"]\noutput = \"y\"\n")));
    // unknown attribute
    assertThrown!(TachyError)(loadTasksFile(writeTemp("exec_unk.toml",
        "[execute.\"x\"]\nrun = \"true\"\nbogus = 1\n")));
    // bad exit_status shape
    assertThrown!(TachyError)(loadTasksFile(writeTemp("exec_bad.toml",
        "[execute.\"x\"]\nrun = \"true\"\nexit_status = \"0\"\n")));
}

unittest // a file inside a directory this file manages: directory job first
{
    auto p = writeTemp("dirfirst.toml", `
[directories."/srv/tree"]
mode = "0755"

[files."/srv/tree/leaf.conf"]
content = "x"
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 2);
    assert(loaded.jobs[0].kind == "directory" && loaded.jobs[0].target == "/srv/tree");
    assert(loaded.jobs[1].kind == "file" && loaded.jobs[1].target == "/srv/tree/leaf.conf");
}

unittest // [groups] and [users]: sections, order, validation
{
    import std.exception : assertThrown;
    auto p = writeTemp("accounts.toml", `
[directories."/srv/app"]
mode = "0755"

[groups]
"epices" = {}
"legacy" = { state = "absent" }

[users."deploy"]
group = "epices"
groups = ["epices"]
shell = "/bin/bash"
comment = "epices user"
home = "/home/epices"

[services.app]
state = "started"
`);
    auto loaded = loadTasksFile(p);
    // order: directories, groups (sorted), users, services
    assert(loaded.jobs.length == 5);
    assert(loaded.jobs[0].kind == "directory");
    assert(loaded.jobs[1].kind == "group" && loaded.jobs[1].target == "epices");
    assert(loaded.jobs[2].kind == "group" && loaded.jobs[2].target == "legacy");
    assert(loaded.jobs[3].kind == "user" && loaded.jobs[3].target == "deploy");
    assert(loaded.jobs[3].params["group"].str_ == "epices");
    assert(loaded.jobs[3].params["groups"].array_.length == 1);
    assert(loaded.jobs[4].kind == "service");

    // duplicate user names are a load-time error
    assertThrown!(TachyError)(loadTasksFile(writeTemp("acc_dup.toml",
        "[users.x]\n[users]\n\"x\" = {}\n")));
    // unknown attribute
    assertThrown!(TachyError)(loadTasksFile(writeTemp("acc_unk.toml",
        "[users.x]\nbogus = 1\n")));
    // bad literal state
    assertThrown!(TachyError)(loadTasksFile(writeTemp("acc_state.toml",
        "[groups.x]\nstate = \"maybe\"\n")));
}

unittest // [apply]/[includes]: vars = { ... } sub-table binding
{
    import std.exception : assertThrown;
    writeTemp("ap_files.toml", `
[files."/tmp/ap-file"]
content = "{{ three }} {{ direct }} {{ nested.tbl.x }}"
`);
    auto p = writeTemp("ap_main.toml", `
[apply."ap_files.toml"]
vars = { three = "three", nested = { tbl = { x = "deep" } } }
direct = "bound"
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 1);
    auto ov = loaded.jobs[0].overlay;
    assert(ov["three"].str_ == "three");
    assert(ov["direct"].str_ == "bound");                 // direct binding merges
    assert(ov["nested"].table_["tbl"].table_["x"].str_ == "deep");
    assert("vars" !in ov);                                // the sub-table is unwrapped

    // same spelling on includes
    auto q = writeTemp("inc_main.toml", `
[includes."ap_files.toml"]
vars = { three = "3" }
`);
    auto loaded2 = loadTasksFile(q);
    assert(loaded2.jobs[0].overlay["three"].str_ == "3");

    // variable bound both directly and under vars: ambiguous -> error
    assertThrown!(TachyError)(loadTasksFile(writeTemp("ap_dup.toml", `
[apply."ap_files.toml"]
vars = { three = "a" }
three = "b"
`)));
    // non-table vars
    assertThrown!(TachyError)(loadTasksFile(writeTemp("ap_bad.toml", `
[apply."ap_files.toml"]
vars = "nope"
`)));
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
    // every composed file is recorded, entry first, resolved absolute
    assert(loaded.sourceFiles.length == 3);
    assert(loaded.sourceFiles[0].endsWith("compose.toml"));
    assert(loaded.sourceFiles[1].endsWith("one.toml"));
    assert(loaded.sourceFiles[2].endsWith("two.toml"));
    assert(isAbsolute(loaded.sourceFiles[0]));
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

unittest // apply: same as include, but runs after the file's own jobs
{
    writeTemp("pre.toml", `
[files."/tmp/pre"]
mode = "0400"
`);
    writeTemp("post.toml", `
[vars]
from_post = "p"
[files."/tmp/post"]
mode = "0400"
`);
    writeTemp("post2.toml", `
[files."/tmp/post2"]
mode = "0400"
`);
    auto p = writeTemp("ordered.toml", `
[vars]
top = "yes"

[includes."pre.toml"]
pre_var = "pv"

[files."/tmp/own"]
mode = "0400"

[apply."post.toml"]
post_var = "pt"

[apply]
"post2.toml" = { sees_flow = "yes" }
`);
    auto loaded = loadTasksFile(p);
    // includes first, own jobs, then applies (sorted)
    assert(loaded.jobs.length == 4);
    assert(loaded.jobs[0].target == "/tmp/pre");
    assert(loaded.jobs[1].target == "/tmp/own");
    assert(loaded.jobs[2].target == "/tmp/post");
    assert(loaded.jobs[3].target == "/tmp/post2");

    // apply keeps include var semantics for the applied subtree
    assert(loaded.jobs[2].overlay["top"].str_ == "yes");
    assert(loaded.jobs[2].overlay["post_var"].str_ == "pt");
    assert(loaded.jobs[2].overlay["from_post"].str_ == "p");

    // scopes keep flowing forward through applies
    assert(loaded.jobs[3].overlay["from_post"].str_ == "p");  // flowed from post.toml

    // the own jobs do NOT see apply-contributed vars (they run earlier)
    assert("from_post" !in loaded.jobs[1].overlay);

    // apply participates in duplicate-target and cycle detection
    writeTemp("dup_apply_inc.toml", "[files.\"/tmp/x\"]\nmode = \"0600\"\n");
    assertThrown!(TachyError)(loadTasksFile(writeTemp("dup_apply.toml",
        "[files.\"/tmp/x\"]\nmode = \"0644\"\n[apply.\"dup_apply_inc.toml\"]\n")));
    writeTemp("cyc_c.toml", "[apply.\"cyc_d.toml\"]\n");
    writeTemp("cyc_d.toml", "[includes.\"cyc_c.toml\"]\n");
    assertThrown!(TachyError)(loadTasksFile(buildPath(
        dirName(writeTemp("cyc_c.toml", "[apply.\"cyc_d.toml\"]\n")), "cyc_c.toml")));
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

unittest // tasks-file [vars] entries may read the environment
{
    import std.algorithm.searching : canFind;
    import std.process : environment;
    environment["TACHY_UT_MODEL"] = "model-value";

    auto p = writeTemp("envvars.toml", `
[vars]
something = { env = "TACHY_UT_MODEL" }

[files."{{ something }}-target"]
mode = "0400"
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 1);
    assert(loaded.jobs[0].overlay["something"].str_ == "model-value");
    assert(loaded.jobs[0].target == "{{ something }}-target"); // rendered at run time

    // unset variable: load-time error naming the file and the variable
    string msg;
    try
    {
        loadTasksFile(writeTemp("envvars_missing.toml",
            "[vars]\nx = { env = \"TACHY_UT_MODEL_NOPE\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "vars.x"));
    assert(canFind(msg, "TACHY_UT_MODEL_NOPE"));
}

unittest // tasks-file [vars] { env, from } reads a dotenv file next to the file
{
    import std.algorithm.searching : canFind;

    writeTemp("proj.env", "TACHY_UT_DOTENV=from-dotenv-file\n");
    const string p = writeTemp("envfrom.toml", `
[vars]
secret_var = { env = "TACHY_UT_DOTENV", from = "proj.env" }

[files."/tmp/target"]
content = "{{ secret_var }}"
mode = "0600"
`);

    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 1);
    assert(loaded.jobs[0].overlay["secret_var"].str_ == "from-dotenv-file");

    // a missing dotenv file is a load-time error naming file and entry
    string msg;
    try
    {
        loadTasksFile(writeTemp("envfrom_missing.toml",
            "[vars]\nx = { env = \"K\", from = \"nope.env\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "vars.x"));
    assert(canFind(msg, "cannot read dotenv file"));
    assert(canFind(msg, "nope.env"));
}

unittest // [before.<group>] / [after.<group>] hooks: ordering
{
    auto loaded = loadTasksFile(writeTemp("hooks.toml", `
[files."/tmp/f1"]
mode = "0644"

[packages."apt:bc"]
[groups.epices]
[users.deploy]
[services.ssh]
state = "started"

[execute."final"]
run = "true"

[before.packages."pre-pkg"]
run = "test -x /usr/bin/dpkg"

[after.packages."post-pkg"]
run = "dpkg -s coreutils"

[before.accounts."pre-acc"]
run = "getent passwd root"

[after.accounts]
"post-acc" = { run = "getent group root" }

[before.services."pre-svc"]
run = "command -v systemctl"

[after.services."post-svc"]
run = "systemctl is-active ssh"
`));

    string[] order;
    foreach (j; loaded.jobs)
        order ~= j.kind ~ " " ~ j.target;
    assert(order == [
        "file /tmp/f1",
        "execute pre-pkg",
        "package apt:bc",
        "execute post-pkg",
        "execute pre-acc",
        "group epices",
        "user deploy",
        "execute post-acc",
        "execute pre-svc",
        "service ssh",
        "execute post-svc",
        "execute final",
    ], order.join(", "));

    // Hooks are execute jobs: name injected, moduleName execute.
    assert(loaded.jobs[1].moduleName == "execute");
    assert(loaded.jobs[1].params["name"].str_ == "pre-pkg");
    assert(loaded.jobs[1].params["run"].str_ == "test -x /usr/bin/dpkg");
    assert(canFind(loaded.jobs[1].origin, "before.packages \"pre-pkg\""));
}

unittest // hooks run at their position even when the group is empty
{
    auto loaded = loadTasksFile(writeTemp("hooks_empty.toml", `
[after.services."health"]
run = "true"

[before.accounts."pre-acc"]
run = "true"
`));
    assert(loaded.jobs.length == 2);
    assert(loaded.jobs[0].kind == "execute" && loaded.jobs[0].target == "pre-acc");
    assert(loaded.jobs[1].kind == "execute" && loaded.jobs[1].target == "health");

    // An include's hooks stay inside the include's position.
    writeTemp("hooks_inner.toml", `
[after.services."inner-hook"]
run = "true"
`);
    auto comp = loadTasksFile(writeTemp("hooks_main.toml", `
[includes."hooks_inner.toml"]

[files."/tmp/x"]
mode = "0644"
`));
    assert(comp.jobs.length == 2);
    assert(comp.jobs[0].kind == "execute" && comp.jobs[0].target == "inner-hook");
    assert(comp.jobs[1].kind == "file");
}

unittest // hook errors: unknown group, duplicate names, missing run
{
    import std.algorithm.searching : canFind;

    string msg;
    try
    {
        loadTasksFile(writeTemp("hooks_badgroup.toml",
            "[before.files.\"x\"]\nrun = \"true\"\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "before"));
    assert(canFind(msg, "unknown key 'files'"));

    try
    {
        loadTasksFile(writeTemp("hooks_dup.toml", `
[execute."dup"]
run = "true"

[after.services."dup"]
run = "true"
`));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "already managed"));

    try
    {
        loadTasksFile(writeTemp("hooks_norun.toml",
            "[after.packages.\"x\"]\nexit_status = 0\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "'run' is required"));

    try
    {
        loadTasksFile(writeTemp("hooks_nontable.toml", "before = 1\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "'before' must be a table"));
}
