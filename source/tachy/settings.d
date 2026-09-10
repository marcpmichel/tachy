module tachy.settings;

/**
 * The optional settings file (`settings.pravic`), read once at the start
 * of a run.  Discovery, first match wins:
 *
 *   1. `--settings PATH` — explicit, must exist
 *   2. the `TACHY_SETTINGS` environment variable — must exist
 *   3. `settings.pravic` in the current directory
 *   4. `$XDG_CONFIG_HOME/tachy/settings.pravic`
 *      (default `~/.config/tachy/settings.pravic`)
 *
 * With none of these present, settings are simply empty.  Today the
 * file holds the `import` search paths and the `webui` project list
 * (the projects `tachy webui` offers in the browser); anything else in
 * it is a load-time error (strict, like inventories and tasks files):
 *
 *     imports {
 *         paths = ["libs", "~/.config/tachy/imports"]
 *     }
 *
 *     webui {
 *         projects = ["~/Code/site"]
 *     }
 *
 * Entries of both lists are `~`-expanded and, when relative, resolve
 * against the settings file's own directory (never the cwd), so a
 * settings file works from anywhere.
 */
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName,
    expandTilde, isAbsolute;

import tachy.errors;
import tachy.value;

struct Settings
{
    string[] importPaths;    // absolute directories searched for import sources
    string[] webuiProjects;  // absolute project paths offered by `tachy webui`
    string file;             // where these came from ("" when none found)
}

/// Discover and load the settings file; never throws for a file that is
/// simply absent, only for one that exists but is wrong.
Settings loadSettings(string explicitPath) @trusted
{
    Settings s;
    const string path = discoverSettings(explicitPath);
    if (!path.length)
        return s;
    s.file = path;

    auto doc = loadPractic(path);
    foreach (const ref stmt; doc.stmts)
    {
        if (stmt.kind == "imports")
        {
            if (stmt.key != "paths")
                throw new TachyError(path ~ ": imports holds only 'paths', not '"
                    ~ stmt.key ~ "'");
            if (stmt.value.kind != Val.Kind.array_)
                throw new TachyError(path ~ ": imports.paths must be an"
                    ~ " array of strings, not a " ~ stmt.value.typeName());
            foreach (ref const e; stmt.value.array_)
            {
                if (e.kind != Val.Kind.string_)
                    throw new TachyError(path ~ ": imports.paths must"
                        ~ " contain strings, not a " ~ e.typeName());
                s.importPaths ~= resolveSearchPath(e.str_, path);
            }
        }
        else if (stmt.kind == "webui")
        {
            if (stmt.key != "projects")
                throw new TachyError(path ~ ": webui holds only 'projects', not '"
                    ~ stmt.key ~ "'");
            if (stmt.value.kind != Val.Kind.array_)
                throw new TachyError(path ~ ": webui.projects must be an"
                    ~ " array of strings, not a " ~ stmt.value.typeName());
            foreach (ref const e; stmt.value.array_)
            {
                if (e.kind != Val.Kind.string_)
                    throw new TachyError(path ~ ": webui.projects must"
                        ~ " contain strings, not a " ~ e.typeName());
                // a project entry may be a directory (its main.pravic is
                // the entry point) or a tasks file; existence is not a
                // load-time concern — the webui reports it per project
                s.webuiProjects ~= resolveSearchPath(e.str_, path);
            }
        }
        else
            throw new TachyError(path ~ ": line "
                ~ importConv(stmt.line) ~ ": '" ~ stmt.kind
                ~ "' is not valid in a settings file");
    }
    return s;
}

private string importConv(T)(T v)
{
    import std.conv : text;
    return text(v);
}

/// One search-path entry: ~-expanded, then relative to the settings
/// file's directory, always absolute.
private string resolveSearchPath(string entry, string settingsPath) @trusted
{
    import std.file : exists;

    auto dir = expandTilde(entry);
    if (isAbsolute(dir))
        return buildNormalizedPath(dir);
    return buildNormalizedPath(
        buildPath(dirName(absolutePath(settingsPath)), dir));
}

private string discoverSettings(string explicitPath) @trusted
{
    import std.file : exists;
    import std.process : environment;

    if (explicitPath.length)
    {
        auto p = expandTilde(explicitPath);
        if (!exists(p))
            throw new TachyError("settings file '" ~ explicitPath
                ~ "' does not exist");
        return p;
    }
    const string env = environment.get("TACHY_SETTINGS");
    if (env.length)
    {
        auto p = expandTilde(env);
        if (!exists(p))
            throw new TachyError("TACHY_SETTINGS '" ~ env ~ "' does not exist");
        return p;
    }
    if (exists("settings.pravic"))
        return "settings.pravic";
    const string xdg = environment.get("XDG_CONFIG_HOME");
    const string config = xdg.length ? xdg
        : buildPath(environment.get("HOME"), ".config");
    if (config.length)
    {
        auto p = buildPath(config, "tachy", "settings.pravic");
        if (exists(p))
            return p;
    }
    return null;
}
