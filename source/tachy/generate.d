module tachy.generate;

/**
 * The `generate` command — scaffolding created on the controller:
 *
 *  - `tachy generate key <path>`: a new age key pair, produced by the
 *    `age-keygen` binary and written to <path> (mode 0600, never
 *    overwritten; the public key is printed). The identity file
 *    decrypts `{ age = ... }` inventory vars — pass it with
 *    `--identity <path>`, the config `identity` entry or
 *    `AGE_IDENTITY`, and encrypt secrets with the printed public
 *    key (`age -r <pubkey> -o secret.age`).
 *  - `tachy generate task <path>`: a commented sample tasks file,
 *    loadable as-is (verified by unittest).
 *  - `tachy generate config <path>`: a commented sample config
 *    file, loadable as-is.
 *  - `tachy generate project <path>`: a sample project folder —
 *    inventory.pravic (one fictitious `example` host tagged `@demo`),
 *    main.pravic and config.pravic (the two samples above).  The
 *    folder is created when missing ('.' fills the current
 *    directory); existing files are never overwritten.
 *  - `tachy generate completions <shell>`: the shell completion script
 *    for bash, zsh or fish, printed on stdout (installation paths
 *    differ per shell and distro, so the user redirects it — the
 *    script's header carries the exact commands).  The scripts are
 *    static assets, drift-guarded against the command surface by the
 *    unittest in tests/generate.d; host and @tag selections complete
 *    dynamically through `tachy hosts list --completion`.
 */
import std.stdio : stdout;

import tachy.errors;

/// Dispatch `tachy generate <what> <path>`; returns the exit code.
int runGenerate(in string[] args)
{
    if (args.length != 2)
        throw new TachyError("generate: expected 'key <path>', 'task <path>',"
            ~ " 'config <path>', 'project <path>' or 'completions <shell>'"
            ~ " — examples: tachy generate key key.txt, tachy generate"
            ~ " task main.pravic, tachy generate config config.pravic,"
            ~ " tachy generate project demo, tachy generate completions bash");
    switch (args[0])
    {
        case "key":
            return generateKey(args[1]);
        case "task":
            return generateTask(args[1]);
        case "config":
            return generateConfig(args[1]);
        case "project":
            return generateProject(args[1]);
        case "completions":
            import std.stdio : stdout;
            stdout.write(completionsText(args[1]));
            return 0;
        default:
            throw new TachyError("generate: unknown thing '" ~ args[0]
                ~ "' to generate (expected 'key', 'task', 'config',"
                ~ " 'project' or 'completions')");
    }
}

/// The completion script for a shell: the embedded asset, validated
/// shell name first.  Static text, so the dispatch test can compare
/// the output against the asset directly.
package(tachy) string completionsText(string shell)
{
    switch (shell)
    {
        case "bash":
            return completionBash;
        case "zsh":
            return completionZsh;
        case "fish":
            return completionFish;
        default:
            throw new TachyError(shell.length
                ? "generate completions: unknown shell '" ~ shell
                    ~ "' (expected bash, zsh or fish)"
                : "generate completions: expected a shell"
                    ~ " (bash, zsh or fish)");
    }
}

/// New age key pair: `age-keygen -o <path>` writes the identity (0600,
/// refusing to overwrite) and prints the public key; both are relayed.
private int generateKey(string path) @trusted
{
    import std.conv : text;
    import std.string : strip;

    if (!path.length)
        throw new TachyError("generate key: expected an output path");
    auto r = executeSafe(["age-keygen", "-o", path]);
    if (r.status != 0)
        throw new TachyError("generate key '" ~ path ~ "': "
            ~ (r.output.strip.length ? r.output.strip
                : "age-keygen exit status " ~ text(r.status)));
    if (r.output.length)
        stdout.write(r.output); // the public key
    stdout.writefln("identity written to %s — decrypts { age = ... } inventory"
        ~ " vars via --identity %s, the config identity entry or AGE_IDENTITY",
        path, path);
    return 0;
}

/// `execute` with a clear error when the binary is not installed.
private auto executeSafe(string[] cmd) @trusted
{
    import std.process : execute;
    try
        return execute(cmd);
    catch (Exception e)
        throw new TachyError("cannot run age-keygen: " ~ e.msg
            ~ " — 'generate key' needs the age toolchain on the controller");
}

/// Sample tasks file; refuses to overwrite (generate creates new files).
package(tachy) int generateTask(string path)
{
    import std.file : exists, write;
    import std.stdio : writefln;

    if (!path.length)
        throw new TachyError("generate task: expected an output path");
    if (exists(path))
        throw new TachyError("generate task: '" ~ path
            ~ "' already exists (generate never overwrites)");
    try
        write(path, sampleTasks);
    catch (Exception e)
        throw new TachyError("cannot write '" ~ path ~ "': " ~ e.msg);
    writefln("wrote a sample tasks file to %s — edit it, then try:"
        ~ " tachy check <selection> %s", path, path);
    return 0;
}

/// Sample config file; refuses to overwrite (generate creates new
/// files).
private int generateConfig(string path)
{
    import std.file : exists, write;
    import std.stdio : writefln;

    if (!path.length)
        throw new TachyError("generate config: expected an output path");
    if (exists(path))
        throw new TachyError("generate config: '" ~ path
            ~ "' already exists (generate never overwrites)");
    try
        write(path, sampleConfig);
    catch (Exception e)
        throw new TachyError("cannot write '" ~ path ~ "': " ~ e.msg);
    writefln("wrote a sample config file to %s — edit the imports"
        ~ " search paths, then use import \"name\" in tasks files", path);
    return 0;
}

/// Sample project folder: the three files a fresh project starts
/// from — an inventory with one fictitious host (tagged `@demo`), the
/// sample tasks file and the sample config file.  `<name>` is created
/// when missing ('.' fills the current directory); an existing
/// non-directory aborts, and any already-present sample aborts the
/// whole scaffold before anything is written (all three or nothing).
package(tachy) int generateProject(string name)
{
    import std.file : exists, isDir, mkdirRecurse, write;
    import std.path : buildPath;
    import std.stdio : writefln;

    if (!name.length)
        throw new TachyError("generate project: expected a project path");
    if (exists(name) && !isDir(name))
        throw new TachyError("generate project: '" ~ name
            ~ "' exists and is not a directory");
    if (!exists(name))
        mkdirRecurse(name);

    static immutable string[3] names = ["inventory.pravic", "main.pravic",
        "config.pravic"];
    static immutable string[3] texts = [sampleInventory, sampleTasks,
        sampleConfig];
    foreach (f; names)
    {
        const string path = buildPath(name, f);
        if (exists(path))
            throw new TachyError("generate project: '" ~ path
                ~ "' already exists (generate never overwrites)");
    }
    foreach (i, f; names)
    {
        try
            write(buildPath(name, f), texts[i]);
        catch (Exception e)
            throw new TachyError("cannot write '" ~ buildPath(name, f)
                ~ "': " ~ e.msg);
    }
    writefln("wrote a sample project to %s (inventory.pravic, main.pravic,"
        ~ " config.pravic) — edit the example host in the inventory, then"
        ~ " try: tachy hosts list", name);
    return 0;
}

// The sample texts live in assets/*.txt and are embedded at compile
// time with import(), like the help/man blocks in app.d.  The
// completion scripts are hand-maintained assets too — the drift-guard
// unittest in tests/generate.d keeps them in sync with the command
// surface.
private immutable string sampleTasks = import("assets/sampleTask.txt");
private immutable string sampleConfig = import("assets/sampleConfig.txt");
private immutable string sampleInventory = import("assets/sampleInventory.txt");

package(tachy) immutable string completionBash = import("assets/completionBash.txt");
package(tachy) immutable string completionZsh = import("assets/completionZsh.txt");
package(tachy) immutable string completionFish = import("assets/completionFish.txt");
