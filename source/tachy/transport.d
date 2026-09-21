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

struct CommandResult {
    int status;
    string outText;
    string errText;

    bool ok() const @safe pure nothrow
    {
        return status == 0;
    }
}

abstract class Transport {
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
        foreach(line; r.outText.splitLines())
            sink(line, false);
        foreach(line; r.errText.splitLines())
            sink(line, true);
        return r;
    }

    string describe() const;
}

/// Single-quote a string for safe interpolation into a shell command.
string shQuote(string s) @safe pure
{
    string r = "'";
    foreach(char c; s) {
        if(c == '\'')
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
    if(input !is null) {
        pin = pipe();
        stdinFile = pin.readEnd;
    } else
        stdinFile = File("/dev/null", "r");

    pout = pipe();
    perr = pipe();

    auto pid = spawnProcess(argv, stdinFile, pout.writeEnd, perr.writeEnd);

    // A SIGINT/SIGTERM asks this child to terminate too, so the run
    // loop unblocks and can stop between jobs (tachy.signals).  The
    // numeric pid is captured before wait() invalidates it.
    import tachy.signals : trackChild, untrackChild;
    import core.sys.posix.sys.types : pid_t;

    const pid_t pidNum = pid.processID;
    trackChild(pidNum);
    scope(exit)
        untrackChild(pidNum);

    // Parent must drop its copies so EOF semantics work.
    pout.writeEnd.close();
    perr.writeEnd.close();
    if(input !is null) {
        pin.readEnd.close();
        try
            pin.writeEnd.rawWrite(cast(const(ubyte)[]) input);
        catch(Exception e) {
            // EPIPE: consumer exited early; result below still reflects it.
        }
        pin.writeEnd.close();
    }

    // Drain stderr on a thread so large stdout cannot deadlock.  With a
    // sink, stderr lines are delivered from this thread and stdout
    // lines from the calling thread; the sink must synchronize itself.
    auto errThread = new Thread({
        auto buf = new ubyte[4096];
        for(;;) {
            auto n = posixRead(perr.readEnd.fileno, buf);
            if(n <= 0)
                break;
            errApp.put(buf[0 .. n]);
            if(sink !is null)
                feedLines(errCarry, cast(string) buf[0 .. n], sink, true);
        }
        if(sink !is null && errCarry.length)
            sink(errCarry, true);
    });
    errThread.start();

    {
        auto buf = new ubyte[65536];
        for(;;) {
            auto n = posixRead(pout.readEnd.fileno, buf);
            if(n <= 0)
                break;
            outApp.put(buf[0 .. n]);
            if(sink !is null)
                feedLines(outCarry, cast(string) buf[0 .. n], sink, false);
        }
    }
    if(sink !is null && outCarry.length)
        sink(outCarry, false);

    errThread.join();
    const int status = wait(pid);

    return CommandResult(status, cast(string) outApp.data, cast(string) errApp.data);
}

/// One unbuffered read on a descriptor: returns the bytes available
/// now (0 at end of stream), unlike File.rawRead's fill-the-buffer
/// semantics which would batch a streamed run until EOF.  Interrupted
/// reads retry: -1/EINTR must not masquerade as end of stream, or a
/// signal arriving mid-command silently truncates the output.
private ptrdiff_t posixRead(int fd, ubyte[] buf) @system
{
    version(Posix) {
        import core.sys.posix.unistd : read;
        import core.stdc.errno : errno, EINTR;

        for(;;) {
            const auto n = read(fd, buf.ptr, buf.length);
            if(n >= 0)
                return n;
            if(errno != EINTR)
                return n;
        }
    } else
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
    while(canFind(carry, '\n')) {
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

final class LocalTransport : Transport {
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

    override string describe() const
    {
        return "local";
    }
}

final class SshTransport : Transport {
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
        if(user_.length)
            s ~= user_ ~ "@";
        s ~= address_;
        if(port_ != 22)
            s ~= text(":", port_);
        return s;
    }

    private string[] argvFor(string command)
    {
        string[] argv = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"];
        if(user_.length)
            argv ~= ["-l", user_];
        if(port_ != 22)
            argv ~= ["-p", text(port_)];
        if(keyPath_.length)
            argv ~= ["-i", keyPath_];
        argv ~= ["--", address_, command];
        return argv;
    }
}

Transport makeTransport(in HostConfig host)
{
    if(host.connection == "local")
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

enum StatKind {
    nonexistent,
    file,
    directory,
    link,
    other
}

struct StatInfo {
    StatKind kind;
    int mode; // full st_mode permission bits (0o7777 range from stat %a)
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
    if(!r.ok)
        throw new TachyError("stat '" ~ path ~ "' failed: " ~ (r.errText.strip.length ? r.errText.strip : text("exit status ", r
                .status)));
    auto line = r.outText.strip;
    if(line == "__TACHY_ABSENT__")
        return StatInfo(StatKind.nonexistent, 0, null, null);

    auto parts = splitFirstLines(line);
    if(parts.length != 4)
        throw new TachyError("unexpected stat output for '" ~ path ~ "': " ~ line);

    StatInfo st;
    switch(parts[0]) {
        case "directory":
            st.kind = StatKind.directory;
            break;
        case "symbolic link":
            st.kind = StatKind.link;
            break;
        case "regular file":
            st.kind = StatKind.file;
            break;
        default:
            st.kind = StatKind.other;
            break;
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
    if(!r.ok)
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
    foreach(char c; s) {
        if(c < '0' || c > '7')
            return 0;
        m = m * 8 + (c - '0');
    }
    return m;
}

// ---------------------------------------------------------------------------
