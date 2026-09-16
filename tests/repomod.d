/// Tests for tachy.modules.repomod: every flow against the scripted
/// fake transport (command construction and decision logic only).
module tachy.tests.repomod;

import tachy.modules.repomod;
import tachy.tests.fake;

import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import tachy.transport : CommandResult;
import tachy.modules : TaskContext;
import tachy.errors : TachyError;
import tachy.value : Val;

private TaskContext fakeCtx(ref FakeTransport t, bool check = false)
{
    return TaskContext(t, check, "fakehost", "/tmp");
}

private Val[string] RP(string path, string url,
    string branch = null, string tag = null, string type = null)
{
    Val[string] p;
    p["path"] = Val(path);
    p["url"] = Val(url);
    if (branch.length)
        p["branch"] = Val(branch);
    if (tag.length)
        p["tag"] = Val(tag);
    if (type.length)
        p["type"] = Val(type);
    return p;
}

private enum url = "git@example.com/me/app.git";

@("clone when the path is not a repository")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [CommandResult(1, "", ""), CommandResult(0, "", "")];
    auto r = runRepoModule(RP("/srv/app", url), fakeCtx(t));
    assert(r.changed, r.msg);
    assert(t.commands[0] == "git -C '/srv/app' rev-parse --git-dir", t.commands[0]);
    assert(t.commands[1] == "git clone 'git@example.com/me/app.git' '/srv/app'",
        t.commands[1]);
    assert(r.msg == "cloned repository from " ~ url, r.msg);
}

@("clone with branch or tag: --branch on the clone command")
unittest
{
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(1, "", ""), CommandResult(0, "", "")];
        runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t));
        assert(t.commands[1] == "git clone --branch 'main' '" ~ url ~ "' '/srv/app'",
            t.commands[1]);
    }
    {
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(1, "", ""), CommandResult(0, "", "")];
        auto r = runRepoModule(RP("/srv/app", url, null, "v0.12"), fakeCtx(t));
        assert(t.commands[1] == "git clone --branch 'v0.12' '" ~ url ~ "' '/srv/app'",
            t.commands[1]);
        assert(canFind(r.msg, "(tag v0.12)"), r.msg);
    }
}

@("up to date branch: probes only, unchanged")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/srv/app/.git\n", ""),   // rev-parse --git-dir
        CommandResult(0, url ~ "\n", ""),          // remote get-url origin
        CommandResult(0, "", ""),                  // fetch --prune origin
        CommandResult(0, "main\n", ""),            // rev-parse --abbrev-ref HEAD
        CommandResult(0, "S2\n", ""),              // refs/remotes/origin/main
        CommandResult(0, "S2\n", ""),              // rev-parse HEAD
    ];
    auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t));
    assert(!r.changed, r.msg);
    assert(r.msg == "up to date with origin/main", r.msg);
    assert(t.commands.length == 6);
}

@("behind origin: fast-forward --ff-only")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/srv/app/.git\n", ""),
        CommandResult(0, url ~ "\n", ""),
        CommandResult(0, "", ""),
        CommandResult(0, "main\n", ""),
        CommandResult(0, "S2\n", ""),
        CommandResult(0, "S1\n", ""),              // HEAD behind origin
        CommandResult(0, "", ""),                  // merge-base --is-ancestor
        CommandResult(0, "", ""),                  // merge --ff-only
    ];
    auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t));
    assert(r.changed, r.msg);
    assert(r.msg == "fast-forwarded main to origin/main", r.msg);
    assert(t.commands[7] == "git -C '/srv/app' merge --ff-only 'origin/main'",
        t.commands[7]);
}

@("diverged branch is an error, never rewritten")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/srv/app/.git\n", ""),
        CommandResult(0, url ~ "\n", ""),
        CommandResult(0, "", ""),
        CommandResult(0, "main\n", ""),
        CommandResult(0, "S2\n", ""),
        CommandResult(0, "S1\n", ""),
        CommandResult(1, "", ""),                  // HEAD not an ancestor
    ];
    string msg;
    try
    {
        runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "have diverged"), msg);
    assert(t.commands.length == 7);                // no merge attempted
}

@("switching branches: track origin when no local branch exists")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/srv/app/.git\n", ""),
        CommandResult(0, url ~ "\n", ""),
        CommandResult(0, "", ""),
        CommandResult(0, "dev\n", ""),             // currently on dev
        CommandResult(0, "S2\n", ""),              // origin/main exists
        CommandResult(1, "", ""),                  // no local main
        CommandResult(0, "", ""),                  // checkout -b
        CommandResult(0, "S2\n", ""),              // HEAD after checkout
    ];
    auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t));
    assert(r.changed, r.msg);
    assert(r.msg == "switched to branch main", r.msg);
    assert(t.commands[6] == "git -C '/srv/app' checkout -b 'main' 'origin/main'",
        t.commands[6]);
}

@("switching to an existing local branch also fast-forwards")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/srv/app/.git\n", ""),
        CommandResult(0, url ~ "\n", ""),
        CommandResult(0, "", ""),
        CommandResult(0, "dev\n", ""),
        CommandResult(0, "S2\n", ""),
        CommandResult(0, "S0\n", ""),              // local main exists
        CommandResult(0, "", ""),                  // checkout main
        CommandResult(0, "S1\n", ""),              // HEAD behind origin
        CommandResult(0, "", ""),                  // merge-base
        CommandResult(0, "", ""),                  // merge --ff-only
    ];
    auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t));
    assert(r.changed, r.msg);
    assert(r.msg == "switched to branch main; fast-forwarded main to origin/main",
        r.msg);
}

@("branch missing on origin is an error")
unittest
{
    auto t = new FakeTransport;
    t.replies ~= [
        CommandResult(0, "/srv/app/.git\n", ""),
        CommandResult(0, url ~ "\n", ""),
        CommandResult(0, "", ""),
        CommandResult(0, "dev\n", ""),
        CommandResult(1, "", ""),                  // no origin/newbranch
    ];
    string msg;
    try
    {
        runRepoModule(RP("/srv/app", url, "newbranch"), fakeCtx(t));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "branch 'newbranch' not found on origin"), msg);
}

@("tag: detached checkout on drift, idempotent on match")
unittest
{
    {
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, url ~ "\n", ""),
            CommandResult(0, "", ""),
            CommandResult(0, "S1\n", ""),          // HEAD
            CommandResult(0, "S2\n", ""),          // v0.12^{commit}
            CommandResult(0, "", ""),              // checkout --detach
        ];
        auto r = runRepoModule(RP("/srv/app", url, null, "v0.12"), fakeCtx(t));
        assert(r.changed, r.msg);
        assert(r.msg == "checked out tag v0.12", r.msg);
        assert(t.commands[5] == "git -C '/srv/app' checkout --detach 'v0.12'",
            t.commands[5]);
    }
    {
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, url ~ "\n", ""),
            CommandResult(0, "", ""),
            CommandResult(0, "S2\n", ""),
            CommandResult(0, "S2\n", ""),
        ];
        auto r = runRepoModule(RP("/srv/app", url, null, "v0.12"), fakeCtx(t));
        assert(!r.changed && r.msg == "at tag v0.12", r.msg);
    }
    // tag missing after fetch
    {
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, url ~ "\n", ""),
            CommandResult(0, "", ""),
            CommandResult(0, "S1\n", ""),
            CommandResult(1, "", ""),
        ];
        string msg;
        try
        {
            runRepoModule(RP("/srv/app", url, null, "nope"), fakeCtx(t));
            assert(false, "expected TachyError");
        }
        catch (TachyError e)
            msg = e.msg;
        assert(canFind(msg, "tag 'nope' not found"), msg);
    }
}

@("origin is enforced: added when missing, retargeted when different")
unittest
{
    {
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(1, "", ""),              // no origin remote
            CommandResult(0, "", ""),              // remote add
            CommandResult(0, "", ""),              // fetch
        ];
        auto r = runRepoModule(RP("/srv/app", url), fakeCtx(t));
        assert(r.changed, r.msg);
        assert(r.msg == "origin added (" ~ url ~ ")", r.msg);
        assert(t.commands[2] == "git -C '/srv/app' remote add origin '" ~ url ~ "'",
            t.commands[2]);
    }
    {
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, "git@old.example.com/me/app.git\n", ""),
            CommandResult(0, "", ""),              // remote set-url
            CommandResult(0, "", ""),              // fetch
        ];
        auto r = runRepoModule(RP("/srv/app", url), fakeCtx(t));
        assert(r.changed, r.msg);
        assert(r.msg == "origin retargeted to " ~ url, r.msg);
        assert(t.commands[2] == "git -C '/srv/app' remote set-url origin '" ~ url ~ "'",
            t.commands[2]);
    }
}

@("check mode: fetch probes, mutations are recorded not run")
unittest
{
    {
        // up to date: every probe runs, fetch included
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, url ~ "\n", ""),
            CommandResult(0, "", ""),
            CommandResult(0, "main\n", ""),
            CommandResult(0, "S2\n", ""),
            CommandResult(0, "S2\n", ""),
        ];
        auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t, true));
        assert(!r.changed, r.msg);
        assert(t.commands.length == 6);            // fetch ran in check mode
    }
    {
        // missing repository: would clone, nothing after it runs
        auto t = new FakeTransport;
        t.replies ~= [CommandResult(1, "", "")];
        auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t, true));
        assert(r.changed, r.msg);
        assert(r.msg == "would clone from " ~ url ~ " (branch main)", r.msg);
        assert(t.commands.length == 1);
        assert(canFind(r.details[0], "git clone --branch 'main'"), r.details[0]);
    }
    {
        // on the wrong branch: the local-branch probe runs (read-only),
        // the checkout itself is recorded not run
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, url ~ "\n", ""),
            CommandResult(0, "", ""),
            CommandResult(0, "dev\n", ""),
            CommandResult(0, "S2\n", ""),
            CommandResult(1, "", ""),              // no local main either
        ];
        auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t, true));
        assert(r.changed, r.msg);
        assert(r.msg == "would checkout branch main", r.msg);
        assert(t.commands.length == 6);
        assert(canFind(r.details[1], "checkout -b 'main' 'origin/main'"), r.details[1]);
    }
    {
        // behind origin: would fast-forward, no merge command
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, url ~ "\n", ""),
            CommandResult(0, "", ""),
            CommandResult(0, "main\n", ""),
            CommandResult(0, "S2\n", ""),
            CommandResult(0, "S1\n", ""),
            CommandResult(0, "", ""),
        ];
        auto r = runRepoModule(RP("/srv/app", url, "main"), fakeCtx(t, true));
        assert(r.changed, r.msg);
        assert(r.msg == "would fast-forward main to origin/main", r.msg);
        assert(t.commands.length == 7);
    }
    {
        // tag drift: would checkout tag
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, url ~ "\n", ""),
            CommandResult(0, "", ""),
            CommandResult(0, "S1\n", ""),
            CommandResult(0, "S2\n", ""),
        ];
        auto r = runRepoModule(RP("/srv/app", url, null, "v0.12"), fakeCtx(t, true));
        assert(r.changed, r.msg);
        assert(r.msg == "would checkout tag v0.12", r.msg);
        assert(t.commands.length == 5);
    }
    {
        // origin points elsewhere: would retarget, then stop
        auto t = new FakeTransport;
        t.replies ~= [
            CommandResult(0, "/srv/app/.git\n", ""),
            CommandResult(0, "git@old.example.com/me/app.git\n", ""),
        ];
        auto r = runRepoModule(RP("/srv/app", url), fakeCtx(t, true));
        assert(r.changed, r.msg);
        assert(r.msg == "origin retargeted to " ~ url, r.msg);
        assert(t.commands.length == 2);            // no set-url, no fetch
    }
}

@("only git is implemented, also after rendering")
unittest
{
    auto t = new FakeTransport;
    string msg;
    try
    {
        runRepoModule(RP("/srv/app", url, null, null, "hg"), fakeCtx(t));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "unsupported repository type 'hg'"), msg);
    assert(t.commands.length == 0);

    // a templated type passes load-time validation and fails at run time
    Val[string] p = RP("/srv/app", url);
    p["type"] = Val("{{ repo_type }}");
    assertThrown!(TachyError)(runRepoModule(p, fakeCtx(t)));
}
