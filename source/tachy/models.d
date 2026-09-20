module tachy.models;

/**
 * Tasks files: lists of idempotent atomic "ensure" jobs, in Pravic
 * (see LANGUAGE.md).  Every directive is an independent statement and
 * **jobs run in source order** — there is no fixed directive order and
 * no sorting; what the old order used to guarantee is the author's to
 * express (a `directory` statement above the files that live in it, a
 * user's primary `group` above the `user`).
 *
 *     vars { domain = "example.org" }         # group form
 *     var owner = "app"                       # single form (they merge)
 *
 *     directory /srv/app { mode = "0755" }
 *     file /srv/app/conf { content = "x", mode = "0644" }
 *     package apt:nginx { state = "present" }
 *     ensure "answers on port 80" { run = "curl -fsS http://localhost/" }
 *
 * Kinds and their parameters:
 *     file PATH          state (default "file"; also "link"/"absent"),
 *                        content, src, line, block, template, mode,
 *                        owner, group
 *     directory PATH     state (default "directory"; also "absent"),
 *                        mode, owner, group
 *     service UNIT       state (started/stopped/restarted/reloaded), enabled
 *     compose DIR        Docker Compose stacks: file, project, services,
 *                        state (running/stopped/absent), pull, build,
 *                        recreate, wait, wait_timeout, timeout,
 *     ensure NAME        run (required), exit_status, output
 *     assert NAME        value (required); the expectation keys are
 *                        ensure's output shapes — equals, contains,
 *                        matches, composed with not/any/all/none —
 *                        tested against the rendered value (variables
 *                        only, no host contact)
 *     probe URL           type (default "GET"), headers, data, code
 *                        (default 200), output, timeout
 *     repo PATH          url (required), type (only "git"), branch, tag
 *                        (checkout + fast-forward; branch/tag mutually
 *                        exclusive)
 *
 * `apply "path" { bindings }` composes another tasks file **at the
 * statement's position**, carrying its own variables; a `vars`
 * sub-table in the binding is the grouped spelling of the entry keys.
 * Scopes chain (outer vars < binding < composed file's own vars) and
 * flow forward: statements after an apply see everything it
 * contributed.  `vars`/`var` and `import` statements are not jobs —
 * they take effect file-wide regardless of position.  Duplicate
 * targets anywhere in a composition are load-time errors.
 */
import std.algorithm.searching : canFind;
import std.array : join;
import std.file : exists, isDir;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, isAbsolute;
import std.string : indexOf;

import tachy.errors;
import tachy.modules : validateModuleParams;
import tachy.config;
import tachy.parser : loadPractic;
import tachy.value;
import tachy.vars : deepMerge, resolveEnvVars;

struct Job
{
    string kind;           // "file", "directory", "service", "ensure", ... (display)
    string moduleName;     // "file", "service", "ensure", ... (dispatch)
    string target;         // path, unit name or task name (the statement key)
    string origin;         // "file: kind \"target\"" for error messages
    string tasksFileDir;   // dir of the defining file, for relative file.src
    Val[string] params;    // module params (path/name injected); rendered per host
    Val[string] overlay;   // apply-chain + own vars, merged over host vars at run time
}

struct LoadedTasks
{
    Job[] jobs;           // source order through the composition
    string[] sourceFiles; // every tasks file of the composition, resolved
                          // absolute paths (the entry file first)
    string[] imports;     // import sources, resolved absolute paths,
                          // deduplicated; bundled mode copies them into
                          // the bundle (direct runs parse and ignore)
    string[] deferred;    // apply entries under an import destination
                          // that do not exist locally: the on-host inner
                          // run composes them (the import only lands
                          // inside the bundle)
}

/// Load a tasks file, recursively resolving applies.  The entry path is
/// used as spelled (error origins read like the command line); composed
/// files are recorded normalized in `sourceFiles`.  `config` supplies
/// the import search paths (config.pravic).
LoadedTasks loadTasksFile(string path, in Config config = Config.init)
{
    LoadedTasks loaded;
    string[][string] seen; // (module \0 target) -> origins
    string[] active;       // apply chain, for cycle detection
    string[] importLandings; // where each import lands in the project
    const string projectDir = dirName(buildNormalizedPath(absolutePath(path)));
    loadInto(path, null, projectDir, importLandings, config, active, loaded, seen);
    return loaded;
}

/// Returns the file's exported scope: outer vars + own vars + everything
/// its applies contributed, in statement order.  The scope grows
/// monotonically through the composition, so statements after an apply
/// can use variables defined by the files it composes.
private Val[string] loadInto(string path, Val[string] outerVars,
    string projectDir, ref string[] importLandings, in Config config,
    ref string[] active, ref LoadedTasks loaded, ref string[][string] seen)
{
    if (canFind(active, path))
        throw new TachyError("composition cycle: " ~ active.join(" -> ") ~ " -> " ~ path);
    loaded.sourceFiles ~= buildNormalizedPath(absolutePath(path));

    auto doc = loadPractic(path);

    // Pre-passes over statements that take effect file-wide: vars (the
    // whole file's scope, resolved before any job) and imports (their
    // landing directories drive composition deferral below, whatever the
    // statement order).  Only job and apply statements consume order.
    Val[string] ownVars;
    foreach (const ref s; doc.stmts)
    {
        if (s.kind == "vars")
            ownVars[s.key] = cast(Val) s.value;
        else if (s.kind == "import")
            addImport(loaded, path, projectDir, importLandings, config, s);
        else if (s.kind != "files" && s.kind != "directories" && s.kind != "packages"
                && s.kind != "groups" && s.kind != "users" && s.kind != "services"
                && s.kind != "repos" && s.kind != "compose" && s.kind != "ensure"
                && s.kind != "asserts" && s.kind != "apply" && s.kind != "probe"
                && s.kind != "debug")
            throw new TachyError(path ~ ": line " ~ text(s.line) ~ ": '"
                ~ s.kind ~ "' is not valid in a tasks file");
    }

    auto scopeVars = deepMerge(outerVars, resolveEnvVars(ownVars, path));

    // Walk in source order: applies compose at their position, every
    // other statement appends one job.
    foreach (ref s; doc.stmts)
    {
        if (s.kind == "apply")
        {
            processApply(s, path, projectDir, importLandings, config,
                scopeVars, active, loaded, seen);
        }
        else if (s.kind != "vars" && s.kind != "import")
            addJob(loaded, seen, path, s, scopeVars);
    }
    return scopeVars;
}

/// Resolve one import statement key: as-is when absolute; the defining
/// file's directory next; then the config search paths in order (first
/// existing candidate wins).  Unresolved keys keep the defining-relative
/// path, so the deploy-time existence check names it.
private string resolveImportPath(string src, string definingFile,
    in Config config)
{
    import std.file : exists;

    if (isAbsolute(src))
        return src;
    auto here = buildNormalizedPath(
        absolutePath(buildPath(dirName(definingFile), src)));
    if (!config.importPaths.length || exists(here))
        return here;
    foreach (root; config.importPaths)
    {
        auto candidate = buildNormalizedPath(buildPath(root, src));
        if (exists(candidate))
            return candidate;
    }
    return here;
}

/// Collect one `import` statement: a file or directory living outside
/// the project that bundled mode copies into the bundle next to the
/// project copy (destination: the path's base name — see tachy.project).
/// Only bundled mode acts on imports; direct runs (including the on-host
/// inner run, where the copies already sit inside the project) parse and
/// ignore them, so no existence check happens here.
private void addImport(ref LoadedTasks loaded, string path, string projectDir,
    ref string[] importLandings, in Config config, in PracticStmt s)
{
    const string ctx = path ~ ": line " ~ text(s.line) ~ ": import \""
        ~ s.key ~ "\"";
    if (s.value.kind != Val.Kind.table_)
        throw new TachyError(ctx ~ " must map to an empty block (no parameters)");
    if (s.value.table_.length)
        throw new TachyError(ctx ~ ": 'import' entries take no parameters (the"
            ~ " path is copied into the bundle as its base name)");
    auto resolved = resolveImportPath(s.key, path, config);
    if (!canFind(loaded.imports, resolved))
    {
        loaded.imports ~= resolved;
        // where bundled mode lands this import: the composition
        // deferral test matches paths under it
        const string landing = buildPath(projectDir, baseName(resolved));
        if (!canFind(importLandings, landing))
            importLandings ~= landing;
    }
}

/// True when `resolved` falls under a directory a declared import will
/// land in (project root / base name of the import source).
private bool underImportLanding(string resolved, in string[] importLandings)
{
    import std.algorithm.searching : startsWith;
    foreach (landing; importLandings)
        if (resolved == landing || startsWith(resolved, landing ~ "/"))
            return true;
    return false;
}

/// One `apply` statement: bind variables for the composed file and
/// recurse at the statement's position.  The subtree's resulting scope
/// flows on, so later statements (and the applier, when the apply
/// comes first) see everything it contributed.
private void processApply(in PracticStmt s, string path,
    string projectDir, ref string[] importLandings, in Config config,
    ref Val[string] scopeVars, ref string[] active, ref LoadedTasks loaded,
    ref string[][string] seen)
{
    const string ctx = path ~ ": line " ~ text(s.line) ~ ": apply \""
        ~ s.key ~ "\"";
    if (s.value.kind != Val.Kind.table_)
        throw new TachyError(ctx ~ " must map to a block of variables, not a "
            ~ s.value.typeName());

    // The entry's keys are the variable binding; a `vars = { ... }`
    // sub-table is an equivalent, grouped spelling.
    auto binding = dupTable(s.value.table_);
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

    // The binding resolves its markers like every other var of the
    // defining file: at load, in the process loading it, paths relative
    // to it — after the structural checks above (unwrapping, the
    // both-ways ambiguity), so a failed { run } command or an unset
    // { env } without a default fails the load before the child file
    // is even read.  { age } is rejected: tasks-file vars hold no
    // identity.  Deferred applies re-resolve on the host, where the
    // inner run re-parses this file.
    binding = resolveEnvVars(binding, path);

    string resolved = s.key.dup;
    if (!isAbsolute(resolved))
        resolved = buildNormalizedPath(
            absolutePath(buildPath(dirName(path), resolved)));
    // An apply inside — or naming — a declared import destination
    // exists only inside the bundle (the import has not landed here):
    // defer it to the host — the on-host inner run composes it there,
    // with its binding, at the statement's position.  When it is
    // readable locally after all, compose it normally.
    if (underImportLanding(resolved, importLandings) && !exists(resolved))
    {
        if (!canFind(loaded.deferred, resolved))
            loaded.deferred ~= resolved;
        return;
    }
    // An apply naming an existing directory names its entry point,
    // exactly like a directory argument on the command line.
    if (exists(resolved) && isDir(resolved))
        resolved = buildPath(resolved, "main.pravic");
    active ~= path;
    auto childScope = loadInto(resolved, deepMerge(scopeVars, binding),
        projectDir, importLandings, config, active, loaded, seen);
    active = active[0 .. $ - 1];
    scopeVars = deepMerge(scopeVars, childScope);
}

/// Turn one job statement into a Job: the statement key injects the
/// target, the module validates its parameters, duplicates anywhere in
/// the composition are load-time errors.
private void addJob(ref LoadedTasks loaded, ref string[][string] seen,
    string path, in PracticStmt s, Val[string] overlay)
{
    const string ctx = path ~ ": line " ~ text(s.line) ~ ": " ~ s.kind
        ~ " \"" ~ s.key ~ "\"";
    const string target = s.key;

    string moduleName;
    switch (s.kind)
    {
        case "files": moduleName = "file"; break;
        case "directories": moduleName = "file"; break;
        case "packages": moduleName = "package"; break;
        case "groups": moduleName = "group"; break;
        case "users": moduleName = "user"; break;
        case "services": moduleName = "service"; break;
        case "repos": moduleName = "repo"; break;
        case "compose": moduleName = "compose"; break;
        case "ensure": moduleName = "ensure"; break;
        case "asserts": moduleName = "assert"; break;
        case "probe": moduleName = "probe"; break;
        case "debug": moduleName = "debug"; break;
        default: assert(0, "not a job statement: " ~ s.kind);
    }

    // The statement key injects the target: "path" for files, "dir" for
    // compose stacks, "url" for probe checks, "name" for everything else.
    string key, noun;
    switch (moduleName)
    {
        case "file": key = "path"; noun = "path"; break;
        case "repo": key = "path"; noun = "repository"; break;
        case "compose": key = "dir"; noun = "directory"; break;
        case "probe": key = "url"; noun = "url"; break;
        case "debug": key = "name"; noun = "message"; break;
        case "assert": key = "name"; noun = "assertion"; break;
        default: key = noun = "name"; break;
    }
    if (!target.length)
        throw new TachyError(ctx ~ ": empty " ~ noun);
    if (s.value.kind != Val.Kind.table_)
        throw new TachyError(ctx ~ " must map to a block of parameters, not a "
            ~ s.value.typeName());

    auto params = dupTable(s.value.table_);
    if (key in params)
        throw new TachyError(ctx ~ ": '" ~ key ~ "' is implied by the statement key and must not be set");
    params[key] = Val(target);

    if (moduleName == "file" && "state" !in params)
        params["state"] = Val(s.kind == "files" ? "file" : "directory");

    validateModuleParams(moduleName, params, ctx);

    // An entry's local `vars` (the template context of `file` and
    // `service`) resolves its markers exactly like every other var of
    // the file: at load, in the process loading it — `{ env }` reads
    // that environment, `{ run }` captures that command's output, and
    // `{ age }` is rejected (tasks-file vars hold no identity).  After
    // validation, so structural errors surface before any command runs.
    if (auto v = "vars" in params)
    {
        Val resolved;
        resolved.kind = Val.Kind.table_;
        resolved.table_ = resolveEnvVars((*v).table_, path);
        params["vars"] = resolved;
    }
    if (s.kind == "directories")
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
    job.kind = kindFor(s.kind);
    job.moduleName = moduleName;
    job.target = target;
    job.origin = path ~ ": " ~ s.kind ~ " \"" ~ target ~ "\"";
    job.tasksFileDir = dirName(path);

    job.params = params;
    job.overlay = overlay;
    loaded.jobs ~= job;
}

/// Display kind for a job statement.
private string kindFor(string kind) @safe pure nothrow
{
    switch (kind)
    {
        case "files": return "file";
        case "directories": return "directory";
        case "packages": return "package";
        case "groups": return "group";
        case "users": return "user";
        case "services": return "service";
        case "repos": return "repo";
        case "compose": return "compose";
        case "ensure": return "ensure";
        case "asserts": return "assert";
        case "probe": return "probe";
        case "debug": return "debug";
        default: assert(0, "unknown kind " ~ kind);
    }
}

private string text(T)(T v) @safe pure
{
    import std.conv : text;
    return text(v);
}
