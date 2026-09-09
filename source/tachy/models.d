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
 *     [files.PATH]        state (default "file"; also "link"/"absent"),
 *                          content, src, line, block, mode, owner, group
 *     [directories.PATH]  state (default "directory"; also "absent"),
 *                          mode, owner, group
 *     [services.UNIT]     state (started/stopped/restarted/reloaded), enabled
 *     [compose.DIR]       Docker Compose stacks: file, project, services,
 *                          state (running/stopped/absent), pull, build,
 *                          recreate, wait, wait_timeout, timeout,
 *                          remove_orphans, remove_volumes, remove_images
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
 * after.accounts, before.services, services, after.services, compose,
 * execute.  The `[before.G]`/`[after.G]` hooks (G: packages, accounts,
 * services) are execute-style checks wrapping their group.
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
import std.file : exists, isDir;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, isAbsolute;
import std.string : indexOf;

import tachy.errors;
import tachy.modules : validateModuleParams;
import tachy.settings;
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
    string[] imports;     // [import] sources, resolved absolute paths,
                          // deduplicated; bundled mode copies them into
                          // the bundle (direct runs parse and ignore)
    string[] deferred;    // composition entries under an [import]
                          // destination that do not exist locally:
                          // the on-host inner run composes them (the
                          // import only lands inside the bundle)
}

/// Load a tasks file, recursively resolving includes and applies.  The
/// entry path is used as spelled (error origins read like the command
/// line); composed files are recorded normalized in `sourceFiles`.
/// `settings` supplies the `[import]` search paths (settings.toml).
LoadedTasks loadTasksFile(string path, in Settings settings = Settings.init)
{
    LoadedTasks loaded;
    string[][string] seen; // (module \0 target) -> origins
    string[] active;       // include chain, for cycle detection
    string[] importLandings; // where each [import] lands in the project
    const string projectDir = dirName(buildNormalizedPath(absolutePath(path)));
    loadInto(path, null, projectDir, importLandings, settings, active, loaded, seen);
    return loaded;
}




/// Returns the file's exported scope: outer vars + own vars + everything
/// its includes and applies contributed.  The scope grows monotonically
/// through the composition chain, so a file's own jobs (which run after
/// its includes) can use variables defined by the files it includes.
private Val[string] loadInto(string path, Val[string] outerVars,
    string projectDir, ref string[] importLandings, in Settings settings,
    ref string[] active, ref LoadedTasks loaded, ref string[][string] seen)
{
    if (canFind(active, path))
        throw new TachyError("composition cycle: " ~ active.join(" -> ") ~ " -> " ~ path);
    loaded.sourceFiles ~= buildNormalizedPath(absolutePath(path));

    auto root = loadToml(path);
    auto t = root.table_;
    checkKeys(t, ["vars", "files", "directories", "packages", "groups", "users",
        "services", "compose", "execute", "before", "after", "includes", "apply", "import"], path);

    auto ownVars = resolveEnvVars(optTable(t, "vars", path), path);
    auto scopeVars = deepMerge(outerVars, ownVars);
    // Imports are collected for the bundler (see addImports); they do
    // not participate in the scope or the execution order.  Their
    // landing directories drive composition deferral below.
    addImports(loaded, path, projectDir, importLandings, settings, t);

    processDirective(t, "includes", path, projectDir, importLandings, settings,
        scopeVars, active, loaded, seen);

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
    // Compose stacks after systemd services: the containers they manage
    // are services too, and files (which may deploy the compose file
    // itself) have long since run.  Execute checks come last.
    addJobs(loaded, seen, path, "compose", "compose", t, scopeVars);
    addJobs(loaded, seen, path, "execute", "execute", t, scopeVars);

    // Applies respect the order of execution of the directives: they run
    // after this file's own jobs.
    processDirective(t, "apply", path, projectDir, importLandings, settings,
        scopeVars, active, loaded, seen);
    return scopeVars;
}

/// Resolve one `[import]` key: as-is when absolute; the defining file's
/// directory next; then the settings search paths in order (first
/// existing candidate wins).  Unresolved keys keep the defining-relative
/// path, so the deploy-time existence check names it.
private string resolveImportPath(string src, string definingFile,
    in Settings settings)
{
    import std.file : exists;

    if (isAbsolute(src))
        return src;
    auto here = buildNormalizedPath(
        absolutePath(buildPath(dirName(definingFile), src)));
    if (!settings.importPaths.length || exists(here))
        return here;
    foreach (root; settings.importPaths)
    {
        auto candidate = buildNormalizedPath(buildPath(root, src));
        if (exists(candidate))
            return candidate;
    }
    return here;
}

/// Walk one composition directive (`includes` or `apply`), sorted by path
/// for determinism.  Directive vars bind for the composed subtree; the
/// subtree's resulting scope flows on, so later directives (and the
/// includer, for includes) see everything it contributed.
private void processDirective(in Val[string] t, string directive, string path,
    string projectDir, ref string[] importLandings, in Settings settings,
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
            resolved = buildNormalizedPath(
                absolutePath(buildPath(dirName(path), resolved)));
        // A composition entry inside — or naming — a declared [import]
        // destination exists only inside the bundle (the import has not
        // landed here): defer it to the host — the on-host inner run
        // composes it there, with its binding.  When it is readable
        // locally after all, compose it normally.
        if (underImportLanding(resolved, importLandings) && !exists(resolved))
        {
            if (!canFind(loaded.deferred, resolved))
                loaded.deferred ~= resolved;
            continue;
        }
        // A composition entry that names an existing directory names
        // its entry point, exactly like a directory argument on the
        // command line.
        if (exists(resolved) && isDir(resolved))
            resolved = buildPath(resolved, "main.toml");
        active ~= path;
        auto childScope = loadInto(resolved, deepMerge(scopeVars, binding),
            projectDir, importLandings, settings, active, loaded, seen);
        active = active[0 .. $ - 1];
        scopeVars = deepMerge(scopeVars, childScope);
    }
}

/// Collect `[import]` entries: files or directories living outside the
/// project that bundled mode copies into the bundle next to the project
/// copy (destination: the path's base name — see tachy.project).  Only
/// bundled mode acts on them; direct runs (including the on-host inner
/// run, where the copies already sit inside the project) parse and
/// ignore them, so no existence check happens here.
private void addImports(ref LoadedTasks loaded, string path, string projectDir,
    ref string[] importLandings, in Settings settings, in Val[string] t)
{
    if ("import" !in t)
        return;
    auto dir = t["import"];
    if (dir.kind != Val.Kind.table_)
        throw new TachyError(path ~ ": 'import' must be a table");
    auto paths = dir.table_.byKey.array;
    paths.sort();
    foreach (src; paths)
    {
        auto entry = dir.table_[src];
        if (entry.kind != Val.Kind.table_)
            throw new TachyError(path ~ ": import.\"" ~ src
                ~ "\" must be a table");
        if (entry.table_.length)
            throw new TachyError(path ~ ": import.\"" ~ src
                ~ "\": 'import' entries take no parameters (the path is"
                ~ " copied into the bundle as its base name)");
        auto resolved = resolveImportPath(src, path, settings);
        if (!canFind(loaded.imports, resolved))
        {
            loaded.imports ~= resolved;
            // where bundled mode lands this import: the composition
            // deferral test above matches paths under it
            const string landing = buildPath(projectDir, baseName(resolved));
            if (!canFind(importLandings, landing))
                importLandings ~= landing;
        }
    }
}

/// True when `resolved` falls under a directory a declared [import]
/// will land in (project root / base name of the import source).
private bool underImportLanding(string resolved, in string[] importLandings)
{
    import std.algorithm.searching : startsWith;
    foreach (landing; importLandings)
        if (resolved == landing || startsWith(resolved, landing ~ "/"))
            return true;
    return false;
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
        // The table key injects the target: "path" for files, "dir" for
        // compose stacks, "name" for everything else.
        string key, noun;
        switch (moduleName)
        {
            case "file": key = "path"; noun = "path"; break;
            case "compose": key = "dir"; noun = "directory"; break;
            default: key = noun = "name"; break;
        }
        if (!target.length)
            throw new TachyError(ctx ~ ": empty " ~ noun);
        if (entry.kind != Val.Kind.table_)
            throw new TachyError(ctx ~ " must map to a table of parameters");

        auto params = dupTable(entry.table_);
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
            throw new TachyError(ctx ~ ": " ~ noun ~ " '"
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
        case "compose": return "compose";
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

unittest // tasks-file [vars] { age } is rejected: decryption is controller-side
{
    import std.algorithm.searching : canFind;
    string msg;
    try
    {
        loadTasksFile(writeTemp("age_in_tasks.toml",
            "[vars]\nx = { age = \"secret.age\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "only supported in inventory"), msg);
    assert(canFind(msg, "vars.x"), msg);
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

unittest // [services] with src / template / vars (unit file management)
{
    import std.algorithm.searching : canFind;
    auto loaded = loadTasksFile(writeTemp("svc_unit.toml", `
[services."my_service"]
state = "started"
template = "templates/my_service.service.tmpl"
vars = { service_user = "example" }

[services."second_service"]
state = "enabled"
src = "services/second.service"
`));
    assert(loaded.jobs.length == 2); // sorted by key: my_service, second_service
    assert(loaded.jobs[0].params["template"].str_ == "templates/my_service.service.tmpl");
    assert(loaded.jobs[0].params["vars"].table_["service_user"].str_ == "example");
    assert(loaded.jobs[1].params["src"].str_ == "services/second.service");
    assert(loaded.jobs[1].params["state"].str_ == "enabled");

    // load-time validation: src and template are exclusive, vars needs template
    string msg;
    try
    {
        loadTasksFile(writeTemp("svc_both.toml",
            "[services.x]\nsrc = \"a\"\ntemplate = \"b\"\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "mutually exclusive"));

    try
    {
        loadTasksFile(writeTemp("svc_vars_only.toml",
            "[services.x]\nstate = \"started\"\nvars = { a = \"b\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "only meaningful with 'template'"));

    try
    {
        loadTasksFile(writeTemp("svc_badvars.toml",
            "[services.x]\nstate = \"started\"\ntemplate = \"t\"\nvars = \"nope\"\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "'vars' must be a table"));
}

unittest // [import]: collection, spellings, errors, direct-mode tolerance
{
    import std.algorithm.searching : canFind;
    import std.path : baseName, isAbsolute;

    // header-style path key and the inline spelling are equivalent
    auto p = writeTemp("imp_main.toml", `
[import.tasks/imp_gogs]
[import]
"../imp_data" = {}
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.imports.length == 2);
    // resolved absolute, relative to the defining file's directory
    foreach (src; loaded.imports)
    {
        assert(isAbsolute(src));
        assert(baseName(src).length);
    }

    // duplicate identical paths deduplicate
    p = writeTemp("imp_dup.toml", `
[import]
"a_dir" = {}
[import."a_dir"]
`);
    loaded = loadTasksFile(p);
    assert(loaded.imports.length == 1);

    // no parameters accepted (strict)
    {
        string msg;
        try
        {
            loadTasksFile(writeTemp("imp_param.toml",
                "[import.\"a_dir\"]\ndest = \"x\"\n"));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "take no parameters"), msg);
    }
    // non-table entry and non-table directive
    assertThrown!TachyError(loadTasksFile(writeTemp("imp_scalar.toml",
        "[import]\nx = 1\n")));
    assertThrown!TachyError(loadTasksFile(writeTemp("imp_notable.toml",
        "import = 1\n")));
    // imports do not create jobs
    p = writeTemp("imp_jobs.toml", "[import.\"a_dir\"]\n");
    assert(loadTasksFile(p).jobs.length == 0);
}

unittest // composition into an [import] destination: deferral
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;

    // layout: base/proj/main.toml (the project), base/gogs_lib/ (the
    // import source, a sibling directory outside the project)
    auto base = buildPath(tempDir, "tachy_import_defer_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "proj"));
    mkdirRecurse(buildPath(base, "gogs_lib"));
    scope (exit) rmdirRecurse(base);
    write(buildPath(base, "gogs_lib", "setup.toml"), `
[files."/tmp/defer-owned"]
content = "from the imported file with {{ flavor }}"
`);
    write(buildPath(base, "proj", "main.toml"), `
[vars]
flavor = "vanilla"

[import."../gogs_lib"]

[files."/tmp/defer-entry"]
content = "entry"

[apply."gogs_lib/setup.toml"]
flavor = "chocolate"
`);

    // controller-side: gogs_lib/setup.toml does not exist in the
    // project, so the entry defers instead of failing to load
    auto loaded = loadTasksFile(buildPath(base, "proj", "main.toml"));
    assert(loaded.jobs.length == 1);            // only the entry's own job
    assert(loaded.jobs[0].target == "/tmp/defer-entry");
    assert(loaded.deferred.length == 1);
    assert(canFind(loaded.deferred[0], "gogs_lib")
        && canFind(loaded.deferred[0], "setup.toml"));
    assert(loaded.sourceFiles.length == 1);     // the deferred file is
                                                // not read here

    // with the file present under the landing, it composes normally
    // (that is what the on-host inner run sees)
    mkdirRecurse(buildPath(base, "proj", "gogs_lib"));
    write(buildPath(base, "proj", "gogs_lib", "setup.toml"), `
[files."/tmp/defer-owned"]
content = "x"
`);
    loaded = loadTasksFile(buildPath(base, "proj", "main.toml"));
    assert(loaded.deferred.length == 0);
    assert(loaded.jobs.length == 2);            // own job + applied job
    assert(loaded.jobs[1].target == "/tmp/defer-owned");
    assert(loaded.jobs[1].overlay["flavor"].str_ == "chocolate");
    rmdirRecurse(buildPath(base, "proj", "gogs_lib"));

    // missing and NOT under an import landing is still a load error
    assertThrown!TachyError(loadTasksFile(writeTemp("defer_missing.toml", `
[apply."nowhere_lib/x.toml"]
`)));
}

unittest // [import] search paths: settings.toml resolution order
{
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import tachy.settings : Settings;

    auto base = buildPath(tempDir, "tachy_import_search_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "proj", "local_lib"));
    mkdirRecurse(buildPath(base, "libs1", "found1"));
    mkdirRecurse(buildPath(base, "libs2", "found2"));
    scope (exit) rmdirRecurse(base);
    write(buildPath(base, "proj", "main.toml"), `
[import."local_lib"]
[import."found1"]
[import."found2"]
[import."nowhere"]
`);

    Settings settings;
    settings.importPaths ~= buildPath(base, "libs1");
    settings.importPaths ~= buildPath(base, "libs2");

    auto loaded = loadTasksFile(buildPath(base, "proj", "main.toml"),
        settings);
    assert(loaded.imports.length == 4);
    foreach (src; loaded.imports)
    {
        // defining-relative wins even with search paths configured
        if (canFind(src, "local_lib"))
            assert(canFind(src, buildPath(base, "proj", "local_lib")), src);
        else if (canFind(src, "found1"))
            assert(canFind(src, buildPath(base, "libs1", "found1")), src);
        else if (canFind(src, "found2"))
            assert(canFind(src, buildPath(base, "libs2", "found2")), src);
        else
            // unresolved: keeps the defining-relative guess
            assert(canFind(src, buildPath(base, "proj", "nowhere")), src);
    }
    // without settings, keys stay defining-relative
    loaded = loadTasksFile(buildPath(base, "proj", "main.toml"));
    foreach (src; loaded.imports)
        assert(canFind(src, buildPath(base, "proj")), src);
}

unittest // composition entry naming the import landing itself (a dir)
{
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    // base/proj/main.toml imports ../nvim (a directory of tasks);
    // [apply."nvim"] names the landing itself
    auto base = buildPath(tempDir, "tachy_import_dir_ut");
    if (exists(base)) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "proj"));
    mkdirRecurse(buildPath(base, "nvim"));
    scope (exit) rmdirRecurse(base);
    write(buildPath(base, "nvim", "main.toml"), `
[files."/tmp/direct-owned"]
content = "from the imported dir entry point"
`);
    write(buildPath(base, "proj", "main.toml"), `
[import."../nvim"]

[files."/tmp/direct-entry"]
content = "entry"

[apply."nvim"]
`);

    // controller: the landing itself defers (not only paths under it)
    auto loaded = loadTasksFile(buildPath(base, "proj", "main.toml"));
    assert(loaded.jobs.length == 1);
    assert(loaded.deferred.length == 1);
    assert(canFind(loaded.deferred[0], "nvim"));
    assert(canFind(loaded.deferred[0], buildPath(base, "proj")));

    // host view: the landed directory composes through its main.toml
    // (entry-point convention, like a directory CLI argument)
    mkdirRecurse(buildPath(base, "proj", "nvim"));
    write(buildPath(base, "proj", "nvim", "main.toml"), `
[files."/tmp/direct-owned"]
content = "x"
`);
    loaded = loadTasksFile(buildPath(base, "proj", "main.toml"));
    assert(loaded.deferred.length == 0);
    assert(loaded.jobs.length == 2);
    assert(loaded.jobs[1].target == "/tmp/direct-owned");

    // a plain (non-import) directory entry also uses its main.toml
    write(buildPath(base, "proj", "main.toml"), `
[includes."nvim"]
`);
    loaded = loadTasksFile(buildPath(base, "proj", "main.toml"));
    assert(loaded.jobs.length == 1);
    assert(loaded.jobs[0].target == "/tmp/direct-owned");
}

unittest // [compose]: wiring, order, injection and validation
{
    auto p = writeTemp("compose.toml", `
[services.app]
state = "started"

[compose."/srv/app"]
file = "compose.yml"
project = "myapp"
services = ["backend", "db"]
pull = "always"

[execute."probe"]
run = "true"
`);
    auto loaded = loadTasksFile(p);
    assert(loaded.jobs.length == 3);
    assert(loaded.jobs[0].kind == "service");                    // services first
    assert(loaded.jobs[1].kind == "compose" && loaded.jobs[1].moduleName == "compose");
    assert(loaded.jobs[1].target == "/srv/app");                 // dir injected
    assert(loaded.jobs[1].params["dir"].str_ == "/srv/app");
    assert(loaded.jobs[1].params["file"].str_ == "compose.yml");
    assert(loaded.jobs[1].params["project"].str_ == "myapp");
    assert(loaded.jobs[1].params["services"].array_.length == 2);
    assert(loaded.jobs[1].params["pull"].str_ == "always");
    assert("state" !in loaded.jobs[1].params);                   // module defaults it
    assert(loaded.jobs[2].kind == "execute");                    // execute last

    // both spellings are equivalent; duplicates are load-time errors
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_dup.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\n[compose]\n\"/srv/app\" = { file = \"b.yml\" }\n")));
    // the dir key is implied
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_key.toml",
        "[compose.\"/srv/app\"]\ndir = \"/elsewhere\"\nfile = \"a.yml\"\n")));
    // unknown attribute
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_unk.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nbogus = 1\n")));
    // file is required
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_nofile.toml",
        "[compose.\"/srv/app\"]\nproject = \"x\"\n")));
    // bad state
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_state.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nstate = \"paused\"\n")));
    // bad pull policy
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_pull.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\npull = \"sometimes\"\n")));
    // relative dir
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_rel.toml",
        "[compose.\"srv/app\"]\nfile = \"a.yml\"\n")));
    // invalid project name
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_proj.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nproject = \"MyApp\"\n")));
    // services must be an array of strings
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_svcs.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nservices = \"web\"\n")));
    // remove_volumes only with state = "absent"
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_rv.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nremove_volumes = true\n")));
    // remove_orphans only with state = "stopped"
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_ro.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nremove_orphans = true\n")));
    // wait only with state = "running"
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_wait.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nstate = \"stopped\"\nwait = false\n")));
    // wait_timeout only with wait = true
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_wt.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\nwait = false\nwait_timeout = 10\n")));
    // non-positive timeout
    assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_to.toml",
        "[compose.\"/srv/app\"]\nfile = \"a.yml\"\ntimeout = 0\n")));
}
