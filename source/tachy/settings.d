module tachy.settings;

/**
 * The optional settings file (`settings.toml`), read once at the start
 * of a run.  Discovery, first match wins:
 *
 *   1. `--settings PATH` — explicit, must exist
 *   2. the `TACHY_SETTINGS` environment variable — must exist
 *   3. `settings.toml` in the current directory
 *   4. `$XDG_CONFIG_HOME/tachy/settings.toml`
 *      (default `~/.config/tachy/settings.toml`)
 *
 * With none of these present, settings are simply empty.  Today the
 * file holds the `[import]` search paths and the `webui` project list
 * (the projects `tachy webui` offers in the browser); anything else in
 * it is a load-time error (strict, like inventories and tasks files):
 *
 *     [imports]
 *     paths = ["libs", "~/.config/tachy/imports"]
 *
 *     [webui]
 *     projects = ["~/Code/site"]
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
    string[] importPaths;    // absolute directories searched for [import]
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

    auto root = loadToml(path);
    checkKeys(root.table_, ["imports", "webui"], path);
    if (auto imp = "imports" in root.table_)
    {
        if ((*imp).kind != Val.Kind.table_)
            throw new TachyError(path ~ ": 'imports' must be a table");
        checkKeys((*imp).table_, ["paths"], path ~ ": imports");
        if (auto p = "paths" in (*imp).table_)
        {
            if ((*p).kind != Val.Kind.array_)
                throw new TachyError(path ~ ": imports.paths must be an"
                    ~ " array of strings, not a " ~ (*p).typeName());
            foreach (ref const e; (*p).array_)
            {
                if (e.kind != Val.Kind.string_)
                    throw new TachyError(path ~ ": imports.paths must"
                        ~ " contain strings, not a " ~ e.typeName());
                s.importPaths ~= resolveSearchPath(e.str_, path);
            }
        }
    }
    if (auto web = "webui" in root.table_)
    {
        if ((*web).kind != Val.Kind.table_)
            throw new TachyError(path ~ ": 'webui' must be a table");
        checkKeys((*web).table_, ["projects"], path ~ ": webui");
        if (auto p = "projects" in (*web).table_)
        {
            if ((*p).kind != Val.Kind.array_)
                throw new TachyError(path ~ ": webui.projects must be an"
                    ~ " array of strings, not a " ~ (*p).typeName());
            foreach (ref const e; (*p).array_)
            {
                if (e.kind != Val.Kind.string_)
                    throw new TachyError(path ~ ": webui.projects must"
                        ~ " contain strings, not a " ~ e.typeName());
                // a project entry may be a directory (its main.toml is
                // the entry point) or a tasks file; existence is not a
                // load-time concern — the webui reports it per project
                s.webuiProjects ~= resolveSearchPath(e.str_, path);
            }
        }
    }
    return s;
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
    if (exists("settings.toml"))
        return "settings.toml";
    const string xdg = environment.get("XDG_CONFIG_HOME");
    const string config = xdg.length ? xdg
        : buildPath(environment.get("HOME"), ".config");
    if (config.length)
    {
        auto p = buildPath(config, "tachy", "settings.toml");
        if (exists(p))
            return p;
    }
    return null;
}

version (unittest)
{
    import std.algorithm.searching : canFind;
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;

    unittest // discovery: explicit, env, cwd, xdg — and absence
    {
        auto base = buildPath(tempDir, "tachy_settings_ut");
        if (exists(base)) rmdirRecurse(base);
        mkdirRecurse(buildPath(base, "cfg", "tachy"));
        mkdirRecurse(buildPath(base, "home", ".config", "tachy"));
        scope (exit) rmdirRecurse(base);

        // nothing anywhere -> empty settings, no error
        auto s = withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
            ["", "", buildPath(base, "nowhere")],
            () => loadSettings(""));
        assert(s.file.length == 0 && s.importPaths.length == 0);

        // explicit wins and must exist
        {
            string msg;
            try
            {
                loadSettings(buildPath(base, "missing.toml"));
                assert(false, "expected TachyError");
            }
            catch (TachyError e)
                msg = e.msg;
            assert(canFind(msg, "does not exist"), msg);
        }
        write(buildPath(base, "explicit.toml"), "[imports]\npaths = [\"d\"]\n");
        mkdirRecurse(buildPath(base, "d"));
        s = loadSettings(buildPath(base, "explicit.toml"));
        assert(s.importPaths.length == 1
            && s.importPaths[0] == buildPath(base, "d"), s.importPaths[0]);


        // TACHY_SETTINGS (missing -> error; present -> used, relative
        // entries resolve against it)
        write(buildPath(base, "home", ".config", "tachy", "settings.toml"),
            "[imports]\npaths = [\"~/abs-ut\", \"rel\"]\n");
        s = withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
            ["", "", buildPath(base, "home")],
            () => loadSettings(""));
        assert(canFind(s.file, ".config/tachy/settings.toml"), s.file);
        assert(s.importPaths.length == 2);
        assert(s.importPaths[0] == buildPath(base, "home", "abs-ut"));
        assert(s.importPaths[1] == buildPath(base, "home", ".config",
            "tachy", "rel"));

        // TACHY_SETTINGS pointing nowhere is an error
        {
            string msg;
            try
            {
                withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
                    [buildPath(base, "nope.toml"), "", ""],
                    () => loadSettings(""));
                assert(false, "expected TachyError");
            }
            catch (TachyError e)
                msg = e.msg;
            assert(canFind(msg, "TACHY_SETTINGS"), msg);
        }

        write(buildPath(base, "cfg", "tachy", "settings.toml"), "");

        s = withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
            ["", buildPath(base, "cfg"), buildPath(base, "home")],
            () => loadSettings(""));
        assert(canFind(s.file, buildPath(base, "cfg")), s.file);

        // cwd settings.toml is found before xdg
        {
            import std.file : chdir, getcwd;
            auto keep = getcwd();
            scope (exit) chdir(keep);
            chdir(base);
            write("settings.toml", "");
            s = withEnv(["TACHY_SETTINGS", "XDG_CONFIG_HOME", "HOME"],
                ["", buildPath(base, "cfg"), buildPath(base, "home")],
                () => loadSettings(""));
            assert(s.file == "settings.toml", s.file);
        }
    }

    unittest // [webui] projects: resolution and shapes
    {
        auto base = buildPath(tempDir, "tachy_settings_webui_ut");
        if (exists(base)) rmdirRecurse(base);
        mkdirRecurse(buildPath(base, "cfg"));
        mkdirRecurse(buildPath(base, "site"));
        scope (exit) rmdirRecurse(base);

        write(buildPath(base, "cfg", "s.toml"),
            "[webui]\nprojects = [\"site\", \"~/home-site\", \"/abs/task.toml\"]\n");
        auto s = loadSettings(buildPath(base, "cfg", "s.toml"));
        assert(s.webuiProjects.length == 3);
        assert(s.webuiProjects[0] == buildPath(base, "cfg", "site"),
            s.webuiProjects[0]); // relative to the settings file
        assert(s.webuiProjects[1] == buildPath(environment.get("HOME"),
            "home-site"), s.webuiProjects[1]); // ~ expanded
        assert(s.webuiProjects[2] == "/abs/task.toml"); // absolute kept
        // alongside [imports], and missing entries are fine (the webui
        // reports existence per project)
        write(buildPath(base, "cfg", "both.toml"),
            "[imports]\npaths = [\"libs\"]\n[webui]\nprojects = [\"nope\"]\n");
        s = loadSettings(buildPath(base, "cfg", "both.toml"));
        assert(s.importPaths.length == 1 && s.webuiProjects.length == 1);

        // empty/absent section is fine

        write(buildPath(base, "cfg", "empty.toml"), "[webui]\n");
        s = loadSettings(buildPath(base, "cfg", "empty.toml"));
        assert(s.webuiProjects.length == 0);

        // wrong shapes are load-time errors with file context
        foreach (content; [
            "[webui]\nprojects = \"site\"\n",
            "[webui]\nprojects = [1]\n",
            "[webui]\nbogus = 1\n",
            "webui = 1\n",
        ])
        {
            string msg;
            try
            {
                write(buildPath(base, "cfg", "bad.toml"), content);
                loadSettings(buildPath(base, "cfg", "bad.toml"));
                assert(false, "expected TachyError for: " ~ content);
            }
            catch (TachyError e)
                msg = e.msg;
            assert(canFind(msg, "bad.toml"), msg);
            assert(canFind(msg, "webui"), msg);
        }
    }

    // run `dg()` with environment variables temporarily overridden
    private Settings withEnv(string[] names, string[] values,
        Settings delegate() dg) @trusted
    {
        string[] saved;
        foreach (i, n; names)
        {
            saved ~= environment.get(n);
            environment[n] = values[i];
        }
        scope (exit)
            foreach (i, n; names)
            {
                if (saved[i].length) environment[n] = saved[i];
                else environment.remove(n);
            }
        return dg();
    }

    unittest // parse errors: unknown keys, wrong shapes
    {
        auto base = buildPath(tempDir, "tachy_settings_err_ut");
        if (exists(base)) rmdirRecurse(base);
        mkdirRecurse(base);
        scope (exit) rmdirRecurse(base);

        foreach (content; [
            "bogus = 1\n",
            "[other]\nx = 1\n",
            "imports = 1\n",
            "[imports]\npaths = \"libs\"\n",
            "[imports]\npaths = [1]\n",
            "[imports]\nbogus = 1\n",
        ])
        {
            string msg;
            try
            {
                write(buildPath(base, "s.toml"), content);
                loadSettings(buildPath(base, "s.toml"));
                assert(false, "expected TachyError for: " ~ content);
            }
            catch (TachyError e)
                msg = e.msg;
            assert(canFind(msg, "s.toml"), msg);
        }

        // [imports] without paths is fine
        write(buildPath(base, "s.toml"), "[imports]\n");
        auto s = loadSettings(buildPath(base, "s.toml"));
        assert(s.importPaths.length == 0);
    }

    // run `dg()` with environment variables temporarily overridden
    private auto withEnv(string[] names, string[] values, alias dg)()
    {
        string[] saved;
        foreach (i, n; names)
        {
            saved ~= environment.get(n);
            environment.set(n, values[i]);
        }
        scope (exit)
            foreach (i, n; names)
            {
                if (saved[i].length) environment.set(n, saved[i]);
                else environment.remove(n);
            }
        return dg();
    }
}
