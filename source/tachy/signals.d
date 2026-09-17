module tachy.signals;

/**
 * Ctrl-C (SIGINT) and SIGTERM: cooperative shutdown instead of an
 * instant death.
 *
 * The run loops check `received()` between jobs and stop dispatching;
 * the event stream still reports what completed and the process exits
 * with the conventional `128 + signal`.  A first signal also asks the
 * in-flight child processes (ssh, /bin/sh, inner runs — registered by
 * the transport when it spawns them) to terminate, so the blocked
 * command returns and the loop reaches its next check.  A second
 * signal is the user insisting: children are killed hard and the
 * process leaves immediately, without further cleanup.
 *
 * The web commands use the same flag to leave their accept loop.
 *
 * Handler rules: the handler itself only flips an integer and calls
 * kill(2)/_exit(2) — async-signal-safe, no allocation.  The child
 * registry is a fixed array written by normal code under a mutex; the
 * handler reads it without the mutex, which is the usual benign race
 * for signal handlers (entries are plain ints).
 */
import core.sync.mutex : Mutex;
import core.sys.posix.signal : SIGINT, SIGKILL, SIGTERM, kill, sigaction,
    sigaction_t, sigemptyset;
import core.sys.posix.unistd : _exit;
import core.atomic : atomicLoad, atomicStore;
import core.sys.posix.sys.types : pid_t;

private enum maxTracked = 64;

private __gshared int gotsig; // 0 = not interrupted, else the signal number
private __gshared pid_t[maxTracked] trackedPids;
private __gshared int trackedCount;

private __gshared Mutex trackMutex; // guards the registry in normal code

shared static this()
{
    trackMutex = new Mutex;
}

/// Install the SIGINT/SIGTERM handler.  Idempotent; every entry point
/// that runs jobs or serves the web calls this once.
void installSignalHandlers() @trusted
{
    sigaction_t sa;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0; // no SA_RESTART: blocking calls return so loops re-check
    sa.sa_handler = &signalHandler;
    sigaction(SIGINT, &sa, null);
    sigaction(SIGTERM, &sa, null);
}

/// Signal number received so far, 0 when the run was not interrupted.
int signalReceived() @trusted nothrow
{
    return cast(int) atomicLoad(gotsig);
}

/// Exit code for an interrupted run: the conventional 128 + signal.
int signalExitCode() @safe nothrow
{
    const int sig = signalReceived();
    return sig ? 128 + sig : 0;
}

/// "SIGINT"/"SIGTERM" (or "SIG<n>" for anything else), for reports.
string signalName(int sig) @safe pure nothrow
{
    switch (sig)
    {
        case SIGINT: return "SIGINT";
        case SIGTERM: return "SIGTERM";
        default: return "SIG" ~ (sig ? unsignedText(sig) : "0");
    }
}

private string unsignedText(int v) @safe pure nothrow
{
    import std.conv : text;
    return text(v);
}

/// Remember a child process so a signal can reach it.  The registry is
/// bounded; beyond 64 concurrent children new ones simply stay
/// untracked (they still die with the process group on Ctrl-C).
package(tachy) void trackChild(pid_t pid) @trusted
{
    synchronized (trackMutex)
    {
        if (trackedCount < maxTracked)
            trackedPids[trackedCount++] = pid;
    }
}

/// Forget a child (called when it has been reaped).
package(tachy) void untrackChild(pid_t pid) @trusted
{
    synchronized (trackMutex)
    {
        foreach (i; 0 .. trackedCount)
            if (trackedPids[i] == pid)
            {
                trackedPids[i] = trackedPids[--trackedCount];
                return;
            }
    }
}

private extern(C) void signalHandler(int sig) nothrow @nogc @system
{
    if (gotsig != 0)
    {
        // Second signal: the user insists.  Kill the children hard and
        // leave now — the old die-immediately behavior.
        foreach (i; 0 .. trackedCount)
            kill(trackedPids[i], SIGKILL);
        _exit(128 + sig);
    }
    atomicStore(gotsig, sig);
    // Ask the in-flight commands to terminate so the run loop unblocks
    // and reaches its next interrupted check.
    foreach (i; 0 .. trackedCount)
        kill(trackedPids[i], SIGTERM);
}
