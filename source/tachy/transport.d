module tachy.transport;

/**
 * Execution transports.  Every state mutation is expressed as a POSIX shell
 * command string, so local and remote hosts share one implementation:
 *
 *   - local: `/bin/sh -c <command>`
 *   - ssh:   `ssh <options> -- <address> <command>` (stdin piped through)
 *
 * File upload is `cat > path` fed over stdin, which works identically for
 * both transports.
 */
import std.array : appender;
import core.thread : Thread;
import std.conv : text;
import std.process : Pipe, pipe, spawnProcess, wait;
import std.stdio : File;
import std.string : strip;

import tachy.errors;
import tachy.inventory : HostConfig;

struct CommandResult
{
    int status;
    string outText;
    string errText;

    bool ok() const @safe pure nothrow { return status == 0; }
}

abstract class Transport
{
    /// Run a shell command, /dev/null on stdin.
    CommandResult run(string command);

    /// Run a shell command with `input` fed to its stdin.
    CommandResult runWithInput(string command, string input);

    /// Run a shell command, delivering complete output lines to `sink`
    /// as they arrive (`line`, `isStderr`).  The default implementation
    /// runs to completion and splits the captured text; LocalTransport
    /// and SshTransport deliver incrementally while the command runs.
    /// The sink may be called from several threads (stdout on the
    /// calling thread, stderr on a drain thread) and must be internally
    /// synchronized; a final line without a trailing newline is flushed
    /// at end of stream.  The returned result still carries the full
    /// text.
    CommandResult runStreaming(string command, void delegate(string, bool) sink)
    {
        import std.algorithm.searching : endsWith;
        import std.string : splitLines;
        auto r = run(command);
        foreach (line; r.outText.splitLines())
            sink(line, false);
        foreach (line; r.errText.splitLines())
            sink(line, true);
        return r;
    }

    string describe() const;
}

/// Single-quote a string for safe interpolation into a shell command.
string shQuote(string s) @safe pure
{
    string r = "'";
    foreach (char c; s)
    {
        if (c == '\'')
            r ~= "'\\''";
        else
            r ~= c;
    }
    return r ~ "'";
}

private CommandResult runCommand(string[] argv, string input = null,
    void delegate(string, bool) sink = null)
{
    auto outApp = appender!(ubyte[]);
    auto errApp = appender!(ubyte[])();
    string outCarry, errCarry;

    Pipe pin, pout, perr;
    File stdinFile;
    if (input !is null)
    {
        pin = pipe();
        stdinFile = pin.readEnd;
    }
    else
        stdinFile = File("/dev/null", "r");

    pout = pipe();
    perr = pipe();

    auto pid = spawnProcess(argv, stdinFile, pout.writeEnd, perr.writeEnd);

    // Parent must drop its copies so EOF semantics work.
    pout.writeEnd.close();
    perr.writeEnd.close();
    if (input !is null)
    {
        pin.readEnd.close();
        try
            pin.writeEnd.rawWrite(cast(const(ubyte)[]) input);
        catch (Exception e)
        {
            // EPIPE: consumer exited early; result below still reflects it.
        }
        pin.writeEnd.close();
    }

    // Drain stderr on a thread so large stdout cannot deadlock.  With a
    // sink, stderr lines are delivered from this thread and stdout
    // lines from the calling thread; the sink must synchronize itself.
    auto errThread = new Thread({
        auto buf = new ubyte[4096];
        for (;;)
        {
            auto n = posixRead(perr.readEnd.fileno, buf);
            if (n <= 0) break;
            errApp.put(buf[0 .. n]);
            if (sink !is null)
                feedLines(errCarry, cast(string) buf[0 .. n], sink, true);
        }
        if (sink !is null && errCarry.length)
            sink(errCarry, true);
    });
    errThread.start();

    {
        auto buf = new ubyte[65536];
        for (;;)
        {
            auto n = posixRead(pout.readEnd.fileno, buf);
            if (n <= 0) break;
            outApp.put(buf[0 .. n]);
            if (sink !is null)
                feedLines(outCarry, cast(string) buf[0 .. n], sink, false);
        }
    }
    if (sink !is null && outCarry.length)
        sink(outCarry, false);

    errThread.join();
    const int status = wait(pid);

    return CommandResult(status, cast(string) outApp.data, cast(string) errApp.data);
}

/// One unbuffered read on a descriptor: returns the bytes available
/// now (0 at end of stream), unlike File.rawRead's fill-the-buffer
/// semantics which would batch a streamed run until EOF.
private ptrdiff_t posixRead(int fd, ubyte[] buf) @system
{
    version (Posix)
    {
        import core.sys.posix.unistd : read;
        return read(fd, buf.ptr, buf.length);
    }
    else
        static assert(false, "tachy requires a POSIX system");
}

/// Feed one chunk to a line sink, keeping the unterminated remainder in
/// `carry`.  Newlines are byte-level, so multibyte sequences split
/// across chunks are reassembled safely.
private void feedLines(ref string carry, string chunk,
    void delegate(string, bool) sink, bool isErr)
{
    import std.algorithm.searching : canFind;
    carry ~= chunk;
    while (canFind(carry, '\n'))
    {
        const size_t nl = cast(size_t) stdStringIndexOf(carry, '\n');
        sink(carry[0 .. nl], isErr);
        carry = carry[nl + 1 .. $];
    }
}

private ptrdiff_t stdStringIndexOf(string s, char c) @safe pure
{
    import std.string : indexOf;
    return indexOf(s, c);
}


final class LocalTransport : Transport
{
    override CommandResult run(string command)
    {
        return runCommand(["/bin/sh", "-c", command]);
    }

    override CommandResult runStreaming(string command, void delegate(string, bool) sink)
    {
        return runCommand(["/bin/sh", "-c", command], null, sink);
    }

    override CommandResult runWithInput(string command, string input)
    {
        return runCommand(["/bin/sh", "-c", command], input);
    }

    override string describe() const { return "local"; }
}

final class SshTransport : Transport
{
    private string address_;
    private string user_;
    private int port_;
    private string keyPath_;

    this(string address, string user, int port, string keyPath)
    {
        address_ = address;
        user_ = user;
        port_ = port;
        keyPath_ = keyPath;
    }

    override CommandResult run(string command)
    {
        return runCommand(argvFor(command));
    }

    override CommandResult runStreaming(string command, void delegate(string, bool) sink)
    {
        return runCommand(argvFor(command), null, sink);
    }


    override CommandResult runWithInput(string command, string input)
    {
        return runCommand(argvFor(command), input);
    }

    override string describe() const
    {
        auto s = "ssh://";
        if (user_.length) s ~= user_ ~ "@";
        s ~= address_;
        if (port_ != 22) s ~= text(":", port_);
        return s;
    }

    private string[] argvFor(string command)
    {
        string[] argv = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"];
        if (user_.length)
            argv ~= ["-l", user_];
        if (port_ != 22)
            argv ~= ["-p", text(port_)];
        if (keyPath_.length)
            argv ~= ["-i", keyPath_];
        argv ~= ["--", address_, command];
        return argv;
    }
}

Transport makeTransport(in HostConfig host)
{
    if (host.connection == "local")
        return new LocalTransport;
    return new SshTransport(
        host.address.length ? host.address : host.name,
        host.user,
        host.port,
        host.key);
}

// ---------------------------------------------------------------------------
// Remote filesystem primitives built on shell commands (transport agnostic).
// ---------------------------------------------------------------------------

enum StatKind { nonexistent, file, directory, link, other }

struct StatInfo
{
    StatKind kind;
    int mode;      // full st_mode permission bits (0o7777 range from stat %a)
    string owner;
    string group;
}

/// `stat` a path; works for broken symlinks too.  Assumes GNU coreutils.
StatInfo statPath(Transport t, string path)
{
    auto q = shQuote(path);
    auto cmd = "if [ -e " ~ q ~ " ] || [ -L " ~ q ~ " ]; then stat -c '%F|%a|%U|%G' -- "
        ~ q ~ "; else echo __TACHY_ABSENT__; fi";
    auto r = t.run(cmd);
    if (!r.ok)
        throw new TachyError("stat '" ~ path ~ "' failed: " ~ (r.errText.strip.length ? r.errText.strip : text("exit status ", r.status)));
    auto line = r.outText.strip;
    if (line == "__TACHY_ABSENT__")
        return StatInfo(StatKind.nonexistent, 0, null, null);

    auto parts = splitFirstLines(line);
    if (parts.length != 4)
        throw new TachyError("unexpected stat output for '" ~ path ~ "': " ~ line);

    StatInfo st;
    switch (parts[0])
    {
        case "directory": st.kind = StatKind.directory; break;
        case "symbolic link": st.kind = StatKind.link; break;
        case "regular file": st.kind = StatKind.file; break;
        default: st.kind = StatKind.other; break;
    }
    st.mode = parseOctal(parts[1]);
    st.owner = parts[2];
    st.group = parts[3];
    return st;
}

/// Read the target of a symlink.
string readLinkTarget(Transport t, string path)
{
    auto r = t.run("readlink -- " ~ shQuote(path));
    if (!r.ok)
        throw new TachyError("readlink '" ~ path ~ "' failed: " ~ r.errText.strip);
    return r.outText.strip;
}

private string[] splitFirstLines(string line) @safe pure
{
    import std.string : split;
    return split(line, "|");
}

private int parseOctal(string s) @safe pure
{
    int m = 0;
    foreach (char c; s)
    {
        if (c < '0' || c > '7')
            return 0;
        m = m * 8 + (c - '0');
    }
    return m;
}

// ---------------------------------------------------------------------------

version (unittest)
{
    unittest // local execution
    {
        auto t = new LocalTransport;
        auto r = t.run("echo hi");
        assert(r.ok);
        assert(r.outText == "hi\n");
        auto bad = t.run("exit 3");
        assert(!bad.ok && bad.status == 3);
    }

    unittest // runStreaming: lines arrive while the command runs
    {
        import std.conv : text;
        import std.datetime.stopwatch : StopWatch;

        auto t = new LocalTransport;
        string[] lines;
        bool[] errs;
        ulong[] stamps; // ticks at each line
        StopWatch clock;
        clock.start();

        auto r = t.runStreaming(
            "echo one; echo err-one >&2; sleep 0.4; echo two; printf no-newline",
            (string line, bool isErr)
            {
                synchronized (Object.classinfo)
                {
                    lines ~= line;
                    errs ~= isErr;
                    stamps ~= clock.peek.total!"usecs";
                }
            });

        assert(r.ok, r.errText);
        assert(lines.length == 4, text(lines));
        // only relative stdout order is guaranteed: the stderr drain
        // thread may deliver its line at any position
        import std.algorithm.searching : canFind;
        import std.algorithm.searching : countUntil;
        const size_t iOne = lines.countUntil("one");
        const size_t iTwo = lines.countUntil("two");
        const size_t iNone = lines.countUntil("no-newline");
        assert(iOne < iTwo && iTwo < iNone, text(lines));
        assert(canFind(lines, "err-one"), text(lines));
        assert(r.outText == "one\ntwo\nno-newline", r.outText);
        assert(r.errText == "err-one\n");
        // streaming, not batched: "two" arrived well after "one"
        assert(stamps[iTwo] > stamps[iOne] + 300_000, text(stamps)); // usecs
    }

    unittest // stdin round trip
    {
        auto t = new LocalTransport;
        auto r = t.runWithInput("cat > /tmp/.tachy_ut_pipe && cat /tmp/.tachy_ut_pipe", "payload-é\n");
        assert(r.ok);
        assert(r.outText == "payload-é\n");
        import std.file : remove;
        remove("/tmp/.tachy_ut_pipe");
    }

    unittest // shell quoting
    {
        assert(shQuote("plain") == "'plain'");
        assert(shQuote("it's") == "'it'\\''s'");
        assert(shQuote("") == "''");
        auto t = new LocalTransport;
        auto r = t.run("echo " ~ shQuote("a b'c d$e"));
        assert(r.outText == "a b'c d$e\n");
    }

    unittest // statPath via local transport
    {
        import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, write;
        import std.path : buildPath;
        import std.file : tempDir;
        auto dir = buildPath(tempDir, "tachy_transport_ut");
        if (exists(dir)) rmdirRecurse(dir);
        mkdirRecurse(dir);
        scope (exit) if (exists(dir)) rmdirRecurse(dir);

        auto t = new LocalTransport;
        auto missing = statPath(t, buildPath(dir, "nope"));
        assert(missing.kind == StatKind.nonexistent);

        auto f = buildPath(dir, "f");
        import std.stdio : File;
        { auto fh = File(f, "w"); fh.write("x"); } // scope: deterministic flush
        chmod0(f, 384);
        auto st = statPath(t, f);
        assert(st.kind == StatKind.file);
        assert(st.mode == 384);
        assert(st.owner.length && st.group.length);

        version (linux)
        {
            symlink("/nonexistent-target", buildPath(dir, "broken"));
            auto lnk = statPath(t, buildPath(dir, "broken"));
            assert(lnk.kind == StatKind.link);
            assert(readLinkTarget(t, buildPath(dir, "broken")) == "/nonexistent-target");
        }
    }

    private void chmod0(string path, int mode)
    {
        import std.conv : to;
        import std.process : execute;
        execute(["chmod", to!string(mode, 8), path]);
    }
}
