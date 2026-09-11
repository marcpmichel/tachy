module tachy.generate;

/**
 * The `generate` command — scaffolding created on the controller:
 *
 *  - `tachy generate key <path>`: a new age key pair, produced by the
 *    `age-keygen` binary and written to <path> (mode 0600, never
 *    overwritten; the public key is printed). The identity file
 *    decrypts `{ age = ... }` inventory vars — pass it with
 *    `--identity <path>`, the settings `identity` entry or
 *    `AGE_IDENTITY`, and encrypt secrets with the printed public
 *    key (`age -r <pubkey> -o secret.age`).
 *  - `tachy generate task <path>`: a commented sample tasks file,
 *    loadable as-is (verified by unittest).
 *  - `tachy generate settings <path>`: a commented sample settings
 *    file, loadable as-is.
 */
import std.stdio : stdout;

import tachy.errors;

/// Dispatch `tachy generate <what> <path>`; returns the exit code.
int runGenerate(in string[] args)
{
    if (args.length != 2)
        throw new TachyError("generate: expected 'key <path>', 'task <path>'"
            ~ " or 'settings <path>' — examples: tachy generate key key.txt,"
            ~ " tachy generate task main.pravic, tachy generate settings"
            ~ " settings.pravic");
    switch (args[0])
    {
        case "key":
            return generateKey(args[1]);
        case "task":
            return generateTask(args[1]);
        case "settings":
            return generateSettings(args[1]);
        default:
            throw new TachyError("generate: unknown thing '" ~ args[0]
                ~ "' to generate (expected 'key', 'task' or 'settings')");
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
        ~ " vars via --identity %s, the settings identity entry or AGE_IDENTITY",
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

/// Sample settings file; refuses to overwrite (generate creates new
/// files).
private int generateSettings(string path)
{
    import std.file : exists, write;
    import std.stdio : writefln;

    if (!path.length)
        throw new TachyError("generate settings: expected an output path");
    if (exists(path))
        throw new TachyError("generate settings: '" ~ path
            ~ "' already exists (generate never overwrites)");
    try
        write(path, sampleSettings);
    catch (Exception e)
        throw new TachyError("cannot write '" ~ path ~ "': " ~ e.msg);
    writefln("wrote a sample settings file to %s — edit the imports"
        ~ " search paths, then use import \"name\" in tasks files", path);
    return 0;
}

// The sample texts live in assets/*.txt and are embedded at compile
// time with import(), like the help/man blocks in app.d.
private immutable string sampleTasks = import("assets/sampleTask.txt");
private immutable string sampleSettings = import("assets/sampleSettings.txt");
