/// Serialization for tests that read or mutate shared process state —
/// the environment variables (HOME, AGE_IDENTITY, XDG_CONFIG_HOME,
/// TACHY_CONFIG), the working directory (chdir is process-global) and
/// pid-derived shared paths (the upgrade tests' temp file):
/// the silly runner is threaded, so every such span locks this mutex.
/// Tests using unique per-test names (TACHY_UT_*) need no lock.
module tachy.tests.envsync;

import core.sync.mutex : Mutex;

__gshared Mutex envM;

shared static this()
{
    envM = new Mutex;
}
