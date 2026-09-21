module tachy.config;

/**
 * The optional config file (`config.pravic`), read once at the start
 * of a run.  Discovery, first match wins:
 *
 *   1. `--config PATH` — explicit, must exist
 *   2. the `TACHY_CONFIG` environment variable — must exist
 *   3. `config.pravic` in the current directory
 *   4. `$XDG_CONFIG_HOME/tachy/config.pravic`
 *      (default `~/.config/tachy/config.pravic`)
 *
 * With none of these present, settings are simply empty.  Today the
 * file holds the age `identity`, the `import` search paths, the
 * `webui` project list (the projects `tachy webui` offers in the
 * browser) and the `output` section (the event output shape of
 * `apply`/`check`: `flat` lines or jobs grouped under a host line in a
 * `tree`); anything else in it is a load-time error (strict, like
 * inventories and tasks files):
 *
 *     identity "key.txt"                     # or: identity { path = "key.txt" }
 *
 *     imports {
 *         paths = ["libs", "~/.config/tachy/imports"]
 *     }
 *
 *     webui {
 *         projects = ["~/Code/site"]
 *     }
 *
 *     output {
 *         format = "tree"                    # "flat" (the default) or "tree"
 *     }
 *
 * The identity decrypts `{ age = ... }` inventory vars and `age = true`
 * file sources; `--identity` supersedes it (see `effectiveIdentity`).
 * Entries of all three resolve like search paths: `~`-expanded and,
 * when relative, against the config file's own directory (never the
 * cwd), so a config file works from anywhere.
 */
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName,
    expandTilde, isAbsolute;

import tachy.errors;
import tachy.parser : loadPractic;
import tachy.value;

struct Config {
    string identity; // age identity file, absolute ("" when unset)
    string[] importPaths; // absolute directories searched for import sources
    string[] webuiProjects; // absolute project paths offered by `tachy webui`
    string outputFormat = "flat"; // apply/check event output: "flat" or "tree"
    string file; // where these came from ("" when none found)
}

/// The run's age identity: the `--identity` flag supersedes the
/// config file's `identity` entry.  An empty result falls back to
/// AGE_IDENTITY, then ~/.ssh/id_ed25519 (resolved at use time).
string effectiveIdentity(string flagIdentity, in Config config) @safe pure nothrow
{
    return flagIdentity.length ? flagIdentity : config.identity;
}

/// Discover and load the config file; never throws for a file that is
/// simply absent, only for one that exists but is wrong.
Config loadConfig(string explicitPath) @trusted
{
    Config s;
    const string path = discoverConfig(explicitPath);
    if(!path.length) return s;
    s.file = path;

    auto doc = loadPractic(path);
    foreach(const ref stmt; doc.stmts) {
      switch(stmt.kind) {
        case "identity": checkCmdIdentity(stmt, s, path); break;
        case "imports": checkCmdImports(stmt, s, path); break;
        case "webui": checkCmdWebui(stmt, s, path); break;
        case "output": checkCmdOutput(stmt, s, path); break;
        default:
            throw new TachyError(path ~ ": line "
                    ~ importConv(stmt.line) ~ ": '" ~ stmt.kind
                    ~ "' is not valid in a config file");
      }
    }
    return s;
}

private void checkCmdIdentity(const PracticStmt stmt, ref Config c, const string path) {
  if(c.identity.length)
    throw new TachyError(path ~ ": line " ~ importConv(stmt.line) ~ ": duplicate 'identity' entry");

  if(stmt.key == "path" && stmt.value.kind == Val.Kind.string_)
    c.identity = resolveSearchPath(stmt.value.str_, path);
  else if(stmt.value.kind == Val.Kind.table_
      && stmt.value.table_.length == 0)
    c.identity = resolveSearchPath(stmt.key, path);
  else
    throw new TachyError(path ~ ": line " ~ importConv(stmt.line)
        ~ ": identity takes a path — 'identity \"key.txt\"' or"
        ~ " 'identity { path = \"key.txt\" }', not attributes");
}

private void checkCmdWebui(const PracticStmt stmt, ref Config c, const string path) {
  if(stmt.key != "projects")
    throw new TachyError(path ~ ": webui holds only 'projects', not '"
        ~ stmt.key ~ "'");
  if(stmt.value.kind != Val.Kind.array_)
    throw new TachyError(path ~ ": webui.projects must be an"
        ~ " array of strings, not a " ~ stmt.value.typeName());
  foreach(ref const e; stmt.value.array_) {
    if(e.kind != Val.Kind.string_)
      throw new TachyError(path ~ ": webui.projects must"
          ~ " contain strings, not a " ~ e.typeName());
    // a project entry may be a directory (its main.pravic is
    // the entry point) or a tasks file; existence is not a
    // load-time concern — the webui reports it per project
    c.webuiProjects ~= resolveSearchPath(e.str_, path);
  }
}

private void checkCmdOutput(const PracticStmt stmt, ref Config c, const string path) {
  if(stmt.key != "format")
    throw new TachyError(path ~ ": output holds only 'format', not '" ~ stmt.key ~ "'");
  
  if(stmt.value.kind != Val.Kind.string_)
    throw new TachyError(path ~ ": output.format must be a string," ~ " not a " ~ stmt.value.typeName());

  if(stmt.value.str_ != "flat" && stmt.value.str_ != "tree")
    throw new TachyError(path ~ ": output.format must be \"flat\"" ~ " or \"tree\", not \"" ~ stmt.value.str_ ~ "\"");
  
  c.outputFormat = stmt.value.str_;
}

private void checkCmdImports(const PracticStmt stmt, ref Config c, const string path) {
  if(stmt.key != "paths")
    throw new TachyError(path ~ ": imports holds only 'paths', not '"
        ~ stmt.key ~ "'");
  if(stmt.value.kind != Val.Kind.array_)
    throw new TachyError(path ~ ": imports.paths must be an"
        ~ " array of strings, not a " ~ stmt.value.typeName());
  foreach(ref const e; stmt.value.array_) {
    if(e.kind != Val.Kind.string_)
      throw new TachyError(path ~ ": imports.paths must"
          ~ " contain strings, not a " ~ e.typeName());
    c.importPaths ~= resolveSearchPath(e.str_, path);
  }
}


private string importConv(T)(T v) {
    import std.conv : text;

    return text(v);
}

/// One search-path entry: ~-expanded, then relative to the config
/// file's directory, always absolute.
private string resolveSearchPath(string entry, string configPath) @trusted {
    import std.file : exists;

    auto dir = expandTilde(entry);
    if(isAbsolute(dir)) return buildNormalizedPath(dir);
    return buildNormalizedPath(
            buildPath(dirName(absolutePath(configPath)), dir));
}

private string discoverConfig(string explicitPath) @trusted {
    import std.file : exists;
    import std.process : environment;

    if(explicitPath.length) {
        auto p = expandTilde(explicitPath);
        if(!exists(p))
            throw new TachyError("config file '" ~ explicitPath
                    ~ "' does not exist");
        return p;
    }
    const string env = environment.get("TACHY_CONFIG");
    if(env.length) {
        auto p = expandTilde(env);
        if(!exists(p))
            throw new TachyError("TACHY_CONFIG '" ~ env ~ "' does not exist");
        return p;
    }

    if(exists("config.pravic")) return "config.pravic";
    
    const string xdg = environment.get("XDG_CONFIG_HOME");
    const string xdgRoot = xdg.length ? xdg : buildPath(environment.get("HOME"), ".config");
    if(xdgRoot.length) {
        auto p = buildPath(xdgRoot, "tachy", "config.pravic");
        if(exists(p))
            return p;
    }
    return null;
}
