/// Serialization for tests that read or mutate the shared environment
/// variables (HOME, AGE_IDENTITY, XDG_CONFIG_HOME, TACHY_SETTINGS): the
/// silly runner is threaded and the process environment is global, so
/// every env-touching span locks this mutex. Tests using unique
/// per-test names (TACHY_UT_*) need no lock.
module tachy.tests.envsync;

import core.sync.mutex : Mutex;

__gshared Mutex envM;

shared static this()
{
    envM = new Mutex;
}
