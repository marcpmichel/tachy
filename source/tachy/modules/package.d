module tachy.modules;

/**
 * Task modules: the unit of work applied to a host.  A task is exactly one
 * module invocation; modules are idempotent — they inspect current state
 * first and only act (and report `changed`) when it differs from the desired
 * one.  With `TaskContext.checkMode` set they report would-be changes without
 * mutating anything.
 */
public import tachy.modules.accounts : runGroupModule, runUserModule;
public import tachy.modules.composemod : runComposeModule;
public import tachy.modules.ensuremod : runEnsureModule;
public import tachy.modules.filemod : runFileModule;
public import tachy.modules.httpmod : runHttpModule;
public import tachy.modules.packagemod : runPackageModule;
public import tachy.modules.servicemod : runServiceModule;

import tachy.modules.composemod : validateComposeParams;
import tachy.modules.ensuremod : parseExitStatus, parseOutput;
import tachy.modules.httpmod : validateHttpParams;
import tachy.modules.packagemod : validatePackageKey;

import tachy.errors;
import tachy.transport;
import tachy.value;

struct TaskContext
{
    Transport transport;
    bool checkMode;
    string hostName;
    string tasksFileDir;  // base dir for relative `file.src` paths
    Val[string] vars;     // rendered variable scope, for template rendering
    string ageIdentity;   // --identity or the settings identity entry
                          // (empty: AGE_IDENTITY, then ~/.ssh/id_ed25519)
}

struct TaskResult
{
    bool changed;
    string msg;        // one-line summary
    string[] details;  // commands executed + change details (shown with -v)
}

private immutable string[] allModules = ["file", "service", "ensure", "group", "user", "package", "compose", "http"];

/// Registered module names.
string[] moduleNames() @safe pure nothrow
{
    return allModules.dup;
}

/// Static key validation (values may still contain templates at parse time).
void validateModuleParams(string moduleName, in Val[string] params, string context)
{
    switch (moduleName)
    {
        case "file":
            checkKeys(params, ["path", "state", "src", "content", "line", "block",
                "template", "mode", "owner", "group", "age"],
                context ~ " (file)");
            if ("path" !in params)
                throw new TachyError(context ~ " (file): 'path' is required");
            if (auto p = "age" in params)
            {
                if ((*p).kind != Val.Kind.boolean_)
                    throw new TachyError(context ~ " (file): 'age' must be a"
                        ~ " boolean marking 'src' as age-encrypted, not a "
                        ~ (*p).typeName());
                if ((*p).boolean_ && "src" !in params)
                    throw new TachyError(context ~ " (file): 'age' requires"
                        ~ " 'src' (it marks that source file as age-encrypted)");
            }
            break;
        case "ensure":
        {
            checkKeys(params, ["name", "run", "exit_status", "output"],
                context ~ " (ensure)");
            if ("run" !in params)
                throw new TachyError(context ~ " (ensure): 'run' is required");
            if (auto p = "exit_status" in params)
                parseExitStatus(*p, context ~ " (ensure)");
            if (auto p = "output" in params)
                parseOutput(*p, context ~ " (ensure)");
            break;
        }
        case "http":
        {
            checkKeys(params, ["url", "type", "headers", "data", "code",
                "output", "timeout"], context ~ " (http)");
            if ("url" !in params)
                throw new TachyError(context ~ " (http): 'url' is required");
            validateHttpParams(params, context ~ " (http)");
            break;
        }
        case "group":
            checkKeys(params, ["name", "state"], context ~ " (group)");
            if ("name" !in params)
                throw new TachyError(context ~ " (group): 'name' is required");
            checkPresentAbsent(params, "state", context ~ " (group)");
            break;
        case "user":
            checkKeys(params, ["name", "group", "groups", "shell", "comment",
                "create_home", "home", "state", "remove_home"], context ~ " (user)");
            if ("name" !in params)
                throw new TachyError(context ~ " (user): 'name' is required");
            checkPresentAbsent(params, "state", context ~ " (user)");
            break;
        case "package":
        {
            import std.algorithm.searching : canFind;
            checkKeys(params, ["name", "version", "present"], context ~ " (package)");
            if ("name" !in params)
                throw new TachyError(context ~ " (package): 'name' is required");
            if (auto p = "name" in params)
                if ((*p).kind == Val.Kind.string_ && !canFind((*p).str_, "{{"))
                    validatePackageKey((*p).str_, context ~ " (package)");
            if (auto p = "version" in params)
                if ((*p).kind != Val.Kind.string_)
                    throw new TachyError(context ~ " (package): 'version' must be a string, not a "
                        ~ (*p).typeName());
            break;
        }
        case "compose":
        {
            checkKeys(params, ["dir", "file", "project", "services", "state", "pull",
                "build", "recreate", "wait", "wait_timeout", "timeout",
                "remove_orphans", "remove_volumes", "remove_images"],
                context ~ " (compose)");
            validateComposeParams(params, context ~ " (compose)");
            break;
        }
        case "service":
        {
            checkKeys(params, ["name", "state", "enabled", "src", "template", "vars"],
                context ~ " (service)");
            if ("name" !in params)
                throw new TachyError(context ~ " (service): 'name' is required");
            if (("src" in params) !is null && ("template" in params) !is null)
                throw new TachyError(context ~ " (service): 'src' and 'template' are mutually exclusive");
            foreach (k; ["src", "template"])
                if (auto p = k in params)
                    if ((*p).kind != Val.Kind.string_)
                        throw new TachyError(context ~ " (service): '" ~ k
                            ~ "' must be a string, not a " ~ (*p).typeName());
            if (auto p = "vars" in params)
            {
                if ((*p).kind != Val.Kind.table_)
                    throw new TachyError(context ~ " (service): 'vars' must be a table, not a "
                        ~ (*p).typeName());
                if ("template" !in params)
                    throw new TachyError(context ~ " (service): 'vars' is only meaningful with 'template'");
            }
            break;
        }
        default:
            throw new TachyError("unknown module '" ~ moduleName ~ "'");
    }
}

/// Literal (non-templated) `state` values must be "present" or "absent";
/// templated values are checked again at run time.
private void checkPresentAbsent(in Val[string] params, string key, string context)
{
    import std.algorithm.searching : canFind;
    auto p = key in params;
    if (p is null || (*p).kind != Val.Kind.string_)
        return;
    const string v = (*p).str_;
    if (canFind(v, "{{") || v == "present" || v == "absent")
        return;
    throw new TachyError(context ~ ": '" ~ key ~ "' must be \"present\" or \"absent\", not \"" ~ v ~ "\"");
}

/// Dispatch a rendered parameter set to its module.
TaskResult runModule(string moduleName, Val[string] params, TaskContext ctx)
{
    switch (moduleName)
    {
        case "file": return runFileModule(params, ctx);
        case "service": return runServiceModule(params, ctx);
        case "ensure": return runEnsureModule(params, ctx);
        case "group": return runGroupModule(params, ctx);
        case "user": return runUserModule(params, ctx);
        case "package": return runPackageModule(params, ctx);
        case "compose": return runComposeModule(params, ctx);
        case "http": return runHttpModule(params, ctx);
        default:
            throw new TachyError("unknown module '" ~ moduleName ~ "'");
    }
}

// ---------------------------------------------------------------------------
// Shared parameter accessors and command helpers for modules.
// ---------------------------------------------------------------------------

string requireStr(in Val[string] p, string key, string mod)
{
    auto pv = key in p;
    if (pv is null)
        throw new TachyError(mod ~ ": '" ~ key ~ "' is required");
    if ((*pv).kind != Val.Kind.string_)
        throw new TachyError(mod ~ ": '" ~ key ~ "' must be a string, not a " ~ (*pv).typeName());
    return (*pv).str_;
}

string optStr(in Val[string] p, string key, string mod, string def = null)
{
    auto pv = key in p;
    if (pv is null)
        return def;
    if ((*pv).kind != Val.Kind.string_)
        throw new TachyError(mod ~ ": '" ~ key ~ "' must be a string, not a " ~ (*pv).typeName());
    return (*pv).str_;
}

bool optBool(in Val[string] p, string key, string mod, bool def = false)
{
    auto pv = key in p;
    if (pv is null)
        return def;
    if ((*pv).kind != Val.Kind.boolean_)
        throw new TachyError(mod ~ ": '" ~ key ~ "' must be a boolean, not a " ~ (*pv).typeName());
    return (*pv).boolean_;
}

/// Execute `cmd`; records it and throws a descriptive error on failure.
/// In check mode the command is recorded but not executed.
void mustRun(Transport t, TaskContext ctx, ref string[] details, string cmd, string action)
{
    import std.string : strip;
    details ~= "cmd: " ~ cmd;
    if (ctx.checkMode)
        return;
    auto r = t.run(cmd);
    if (!r.ok)
    {
        auto m = r.errText.strip;
        if (!m.length)
            m = r.outText.strip;
        if (!m.length)
            m = "exit status " ~ intText(r.status);
        throw new TachyError(action ~ " failed on " ~ ctx.hostName ~ ": `" ~ cmd ~ "`: " ~ m);
    }
}

/// Like `mustRun` but feeds `input` to the command's stdin.
void mustRunWithInput(Transport t, TaskContext ctx, ref string[] details,
    string cmd, string input, string action)
{
    import std.string : strip;
    details ~= "cmd: " ~ cmd ~ " (stdin: " ~ intText(cast(int) input.length) ~ " bytes)";
    if (ctx.checkMode)
        return;
    auto r = t.runWithInput(cmd, input);
    if (!r.ok)
    {
        auto m = r.errText.strip;
        if (!m.length)
            m = r.outText.strip;
        if (!m.length)
            m = "exit status " ~ intText(r.status);
        throw new TachyError(action ~ " failed on " ~ ctx.hostName ~ ": `" ~ cmd ~ "`: " ~ m);
    }
}

private string intText(int v) @safe pure
{
    import std.conv : text;
    return text(v);
}

// ---------------------------------------------------------------------------
// Tests: dispatch must cover every registered module name.
// ---------------------------------------------------------------------------
