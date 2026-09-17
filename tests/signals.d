/// Tests for tachy.signals: the pure/naming surface and the child
/// registry bookkeeping.  The handler's end-to-end behavior (a signal
/// stops the run with a summary and exit 128+signal) is covered by
/// scripted runs of the binary, not in-process — installing handlers
/// inside the threaded test runner would leak into unrelated tests.
module tachy.tests.signals;

import tachy.signals;

import core.sys.posix.signal : SIGINT, SIGTERM;
import core.sys.posix.sys.types : pid_t;
import core.sys.posix.unistd : getpid;

@("signalName names the two handled signals, numbers otherwise")
unittest
{
    assert(signalName(SIGINT) == "SIGINT");
    assert(signalName(SIGTERM) == "SIGTERM");
    assert(signalName(9) == "SIG9");
}

@("signalExitCode is 0 while no signal was received")
unittest
{
    // The test runner receives no signals; a received one would break
    // every other assertion here anyway.
    assert(signalReceived() == 0);
    assert(signalExitCode() == 0);
}

@("trackChild/untrackChild round-trips a live pid")
unittest
{
    import core.sys.posix.signal : kill;
    import std.process : spawnProcess, Pid, ProcessException;
    import std.stdio : File;

    // A real child so the pid is alive while tracked; killing it
    // directly is what the signal handler would do through the
    // registry (the handler itself cannot run under test).
    auto devNull = File("/dev/null", "w");
    auto p = spawnProcess(["sleep", "30"], devNull, devNull, devNull);
    const pid_t num = p.processID;
    trackChild(num);
    untrackChild(num); // the transport's scope-exit bookkeeping
    untrackChild(num); // unknown pid: a harmless no-op
    assert(kill(num, 0) == 0); // still alive and reaped only below

    import std.process : wait;
    kill(num, SIGTERM);
    wait(p);
}
