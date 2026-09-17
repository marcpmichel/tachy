module tachy.upgrade;

/**
 * The `upgrade` command: keep an installed tachy current with the
 * GitHub releases of this repository (the slug is hard-coded).
 *
 * One step, no sub-commands: `tachy upgrade` resolves the latest
 * release through GitHub's "releases/latest" redirect — one curl call,
 * no API, no rate limit, no JSON — and compares it with the running
 * build (versions are dates, YY.mm.dd).  Same version: it says so and
 * exits.  An update available: it asks "upgrade tachy now? [y/N]" on a
 * terminal (`--yes` skips the question; without a terminal, `--yes` is
 * required so scripts never hang on a prompt), downloads the release
 * asset `tachy-<version>-linux-amd64` next to the running binary,
 * verifies it answers `version` with the expected version and renames
 * it over the running binary — an atomic same-filesystem rename; the
 * running process keeps its old image until it exits.  Every step
 * before the rename can fail without touching the installed tachy.
 *
 * curl is required: GitHub is HTTPS-only and `tachy.http` is
 * deliberately plain HTTP (curl joins age, git and docker in the set
 * of external tools tachy shells out to).
 */
import std.algorithm.searching : canFind, startsWith;
import std.string : strip;

import tachy.errors;
import tachy.runner : RunOptions;
import tachy.transport : CommandResult, LocalTransport, shQuote;

/// The GitHub repository releases are fetched from.
private enum repoSlug = "marcpmichel/tachy";

/// Swappable hooks for tests.  Each stands in for one step of the
/// real flow; when null, the real implementation runs.
string delegate() latestReleaseHook = null;

/// Stands in for the download: receives the asset URL and the temp
/// path the bytes must land on.
void delegate(in string url, in string tmpPath) downloadReleaseHook = null;

/// Stands in for the y/N prompt (the real one asks on stdin).
bool delegate(in string question) confirmHook = null;

/// Stands in for the final rename of the downloaded binary over the
/// running one.
void delegate(in string tmpPath, in string exePath) replaceHook = null;

/// `tachy upgrade` — check, ask (unless --yes), download, replace.
int runUpgrade(const RunOptions opts, in string currentVersion, in string[] args)
    @trusted
{
    if (args.length)
        throw new TachyError("upgrade takes no sub-commands — just run"
            ~ " \"tachy upgrade\" (add --yes to skip the confirmation)");

    const latest = latestReleaseHook ? latestReleaseHook() : defaultLatestRelease();

    import std.stdio : stdout;
    const cmp = compareVersions(currentVersion, latest);
    if (cmp > 0)
    {
        stdout.writeln("the installed tachy ", currentVersion,
            " is newer than the latest release (", latest, ")");
        return 0;
    }
    if (cmp == 0)
    {
        stdout.writeln("tachy is up to date (", currentVersion, ")");
        return 0;
    }

    stdout.writeln("an update is available: tachy ", latest,
        " (installed: ", currentVersion, ")");

    if (!opts.yes)
    {
        const question = "upgrade tachy now? [y/N] ";
        const bool proceed = confirmHook !is null
            ? confirmHook(question)
            : askOnTty(question);
        if (!proceed)
        {
            stdout.writeln("upgrade cancelled");
            return 0;
        }
    }

    const exe = runningBinaryPath();
    import core.sys.posix.unistd : getpid;
    import std.conv : text;
    import std.path : buildPath, dirName;
    const tmp = buildPath(dirName(exe),
        ".tachy-upgrade-" ~ text(getpid()) ~ ".tmp");
    import std.file : remove;
    scope (failure)
        try
            remove(tmp);
        catch (Exception)
        {
        }

    const url = assetUrl(latest);
    stdout.writeln("downloading ", url, " ...");
    if (downloadReleaseHook !is null)
        downloadReleaseHook(url, tmp);
    else
        downloadRelease(url, tmp);
    verifyDownloaded(tmp, latest);

    if (replaceHook !is null)
        replaceHook(tmp, exe);
    else
        defaultReplace(tmp, exe);

    stdout.writeln("upgraded: tachy ", currentVersion, " -> ", latest,
        " (the new version takes effect on the next run)");
    return 0;
}

/// The y/N prompt for a real terminal: refused outright when stdin is
/// not one — an unattended run must not block on a question it cannot
/// see; `--yes` is the way through.
private bool askOnTty(in string question) @trusted
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;
        if (isatty(0) == 0)
            throw new TachyError("no terminal to confirm the upgrade —"
                ~ " re-run with --yes to upgrade unattended");
    }
    return promptYesNo(question);
}

/// Write the question and read one line: only "y"/"yes" (any case)
/// proceeds; EOF and anything else decline, the N of "y/N".
private bool promptYesNo(in string question) @trusted
{
    import std.stdio : stdin, stdout;
    import std.string : toLower;
    stdout.write(question);
    stdout.flush();
    const line = stdin.readln();
    if (line is null)
        return false;
    const answer = strip(line).toLower;
    return answer == "y" || answer == "yes";
}

/// The file the running process was started from: the kernel resolves
/// it, so a tachy on $PATH behind symlinks still lands on the real
/// binary.
private string runningBinaryPath() @trusted
{
    import std.file : thisExePath;
    try
        return thisExePath();
    catch (Exception e)
        throw new TachyError("upgrade: cannot locate the running binary: "
            ~ e.msg);
}

/// The release asset URL for a version, the name `mise run release`
/// uploads.
private string assetUrl(in string v) @safe pure
{
    return "https://github.com/" ~ repoSlug ~ "/releases/download/v"
        ~ v ~ "/tachy-" ~ v ~ "-linux-amd64";
}

/// Download the release asset with curl: silent, redirects followed,
/// HTTP errors fail (curl -f) — a "not found" page must not become the
/// new binary.
private void downloadRelease(in string url, in string tmpPath) @trusted
{
    auto r = (new LocalTransport).run("curl -fsSL -o " ~ shQuote(tmpPath)
        ~ " " ~ shQuote(url));
    if (!r.ok)
        throw new TachyError("upgrade: cannot download '" ~ url ~ "': "
            ~ failText(r));
}

/// Prove the downloaded file is the release we asked for before it
/// replaces anything: executable, and its `version` output matches.
private void verifyDownloaded(in string tmpPath, in string expected) @trusted
{
    auto t = new LocalTransport;
    auto ch = t.run("chmod 0755 -- " ~ shQuote(tmpPath));
    if (!ch.ok)
        throw new TachyError("upgrade: cannot make the downloaded binary"
            ~ " executable: " ~ failText(ch));
    auto r = t.run(shQuote(tmpPath) ~ " version");
    const got = r.outText.strip;
    if (!r.ok)
        throw new TachyError("upgrade: the downloaded file does not run as tachy "
            ~ expected
            ~ (got.length ? " (it answered '" ~ got ~ "')" : "")
            ~ ": " ~ failText(r) ~ "; keeping the installed tachy");
    if (got != "tachy " ~ expected)
        throw new TachyError("upgrade: the downloaded file is not tachy "
            ~ expected
            ~ (got.length ? " (it answered '" ~ got ~ "')" : " (no output)")
            ~ "; keeping the installed tachy");
}

/// The final swap: one rename inside the binary's own directory, so it
/// is atomic and the running process keeps its old image.  Renaming
/// over a running binary is fine; only its directory needs write
/// permission.
package(tachy) void defaultReplace(in string tmpPath, in string exePath)
    @trusted
{
    import std.file : rename;
    try
        rename(tmpPath, exePath);
    catch (Exception e)
        throw new TachyError("cannot replace '" ~ exePath ~ "': " ~ e.msg
            ~ (canFind(e.msg, "Permission denied")
                ? " (re-run with sudo to upgrade a system-wide install)"
                : ""));
}

private string failText(in CommandResult r) @safe pure
{
    const m = r.errText.strip;
    return m.length ? m : "exit status " ~ intText(r.status);
}

/// Resolve the latest release's version: the "releases/latest" URL
/// answers a HEAD request with a 302 whose Location points at the
/// newest release tag — one tiny curl call, no API.
private string defaultLatestRelease() @trusted
{
    auto r = (new LocalTransport).run(
        "curl -fsSI -o /dev/null -w '%{redirect_url}' https://github.com/"
        ~ repoSlug ~ "/releases/latest");
    if (!r.ok)
        throw new TachyError("upgrade: cannot reach the releases of " ~ repoSlug
            ~ ": " ~ failText(r) ~ " (is curl installed?)");
    return latestFromEffectiveUrl(r.outText.strip);
}

/// Extract the release version from the effective URL of the
/// "releases/latest" redirect: ".../releases/tag/v26.09.20" →
/// "26.09.20".
package(tachy) string latestFromEffectiveUrl(string url) @safe pure
{
    if (!canFind(url, "/tag/"))
        throw new TachyError("upgrade: cannot determine the latest release from '"
            ~ url ~ "' (no /tag/ in the redirect)");
    import std.string : split;
    string v = split(url, "/tag/")[$ - 1].strip;
    if (v.startsWith("v"))
        v = v[1 .. $];
    if (!v.length)
        throw new TachyError("upgrade: empty version in the redirect URL '" ~ url ~ "'");
    return v;
}

/// Compare two tachy versions (dates, "YY.mm.dd"): segment-wise
/// numeric, so "26.9.10" sorts before "26.10.1" regardless of padding.
package(tachy) int compareVersions(string a, string b) @safe pure
{
    const long[] x = segments(a);
    const long[] y = segments(b);
    foreach (i; 0 .. (x.length > y.length ? x.length : y.length))
    {
        const long l = i < x.length ? x[i] : 0;
        const long r = i < y.length ? y[i] : 0;
        if (l != r)
            return l < r ? -1 : 1;
    }
    return 0;
}

private long[] segments(string s) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.conv : ConvException, to;
    long[] r;
    foreach (part; s.splitter("."))
        try
            r ~= to!long(part);
        catch (ConvException e)
            throw new TachyError("upgrade: cannot compare version '" ~ s
                ~ "' (expected numbers separated by dots)");
    return r;
}

private string intText(int v) @safe pure
{
    import std.conv : text;
    return text(v);
}
