module tachy.modules.repomod;

/**
 * `repo` module — idempotent git checkouts behind the `repo` directive:
 *
 *     repo.path   = "/srv/app"            (the table key: the local checkout)
 *     repo.url    = "git@host/me/app.git" # required: where to clone/fetch from
 *     repo.type   = "git"                 # default; only git is implemented
 *     repo.branch = "main"                # optional: checkout + fast-forward
 *     repo.tag    = "v0.12"               # optional: detached checkout
 *
 * Ensures the repository exists at the path (cloned from `url` when the
 * path is not a git repository) and is synchronized:
 *
 *   - `url` is enforced on the `origin` remote (added or retargeted)
 *   - `git fetch --prune origin` refreshes the remote-tracking refs; it
 *     only moves refs under refs/remotes — never HEAD, the worktree or
 *     local branches — so it runs in check mode too
 *   - `tag` checks the tag's commit out detached
 *   - `branch` checks the branch out (tracking origin/<branch> when it
 *     does not exist locally) and fast-forwards it to origin/<branch>;
 *     a diverged branch is an error, not something tachy rewrites
 *   - neither `branch` nor `tag`: existence, origin and fetch is the
 *     whole contract
 *
 * Local work on the host is never discarded: the fast-forward runs only
 * when HEAD is an ancestor of origin/<branch>; anything else fails
 * naming the repository and the branch.
 */
import std.array : join;
import std.conv : text;
import std.string : strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, optStr, requireStr;
import tachy.transport : CommandResult, shQuote;
import tachy.value : Val;

TaskResult runRepoModule(Val[string] params, TaskContext ctx)
{
    auto t = ctx.transport;
    const string path = requireStr(params, "path", "repo");
    const string url = requireStr(params, "url", "repo");
    const string type = optStr(params, "type", "repo", "git");
    const string branch = optStr(params, "branch", "repo");
    const string tag = optStr(params, "tag", "repo");
    if(type != "git")
        throw new TachyError("repo '" ~ path ~ "': unsupported repository type '"
                ~ type ~ "' (only \"git\" is implemented)");

    const string q = shQuote(path);
    string[] actions;
    string[] details;

    TaskResult finish()
    {
        TaskResult res;
        res.changed = actions.length != 0;
        res.msg = actions.length ? actions.join("; ") : tag.length ? "at tag " ~ tag : branch.length ? "up to date with origin/" ~ branch : "up to date with origin";
        res.details = details;
        return res;
    }

    /// Run a read-only probe; empty output when it fails.
    string probe(string cmd)
    {
        auto r = t.run(cmd);
        return r.ok ? r.outText.strip : null;
    }

    /// Run a mutation (suppressed in check mode) or throw naming the action.
    void act(string cmd, string action)
    {
        mustRun(t, ctx, details, cmd, action ~ " of repository '" ~ path ~ "'");
    }

    // Not a git repository yet: clone it (with the declared branch/tag).
    // A failing probe on an existing-but-broken path surfaces as a
    // clone failure naming git's own error.
    if(!probe("git -C " ~ q ~ " rev-parse --git-dir")) {
        string clone = "git clone";
        if(branch.length)
            clone ~= " --branch " ~ shQuote(branch);
        else if(tag.length)
            clone ~= " --branch " ~ shQuote(tag);
        clone ~= " " ~ shQuote(url) ~ " " ~ q;
        act(clone, "clone");
        actions ~= (ctx.checkMode ? "would clone from " : "cloned repository from ")
            ~ url ~ (branch.length ? " (branch " ~ branch ~ ")" : tag.length ? " (tag " ~ tag ~ ")" : "");
        return finish();
    }

    // Enforce `url` on the origin remote; a retarget invalidates the
    // fetch below, so check mode stops here.
    auto origin = t.run("git -C " ~ q ~ " remote get-url origin");
    if(!origin.ok) {
        act("git -C " ~ q ~ " remote add origin " ~ shQuote(url), "add origin to");
        actions ~= "origin added (" ~ url ~ ")";
        if(ctx.checkMode)
            return finish();
    } else if(origin.outText.strip != url) {
        act("git -C " ~ q ~ " remote set-url origin " ~ shQuote(url), "retarget origin");
        actions ~= "origin retargeted to " ~ url;
        if(ctx.checkMode)
            return finish();
    }

    // Refresh the remote-tracking refs (read-only on the managed state,
    // so check mode fetches too); a failure names the repository.
    details ~= "cmd: git -C " ~ q ~ " fetch --prune origin";
    auto fetch = t.run("git -C " ~ q ~ " fetch --prune origin");
    if(!fetch.ok)
        throw new TachyError(
                "fetch of repository '" ~ path ~ "' failed on "
                ~ ctx.hostName ~ ": `git -C " ~ q ~ " fetch --prune origin`: "
                ~ errMsg(fetch));

    if(tag.length) {
        const string head = probe("git -C " ~ q ~ " rev-parse HEAD");
        const string commit = probe("git -C " ~ q ~ " rev-parse "
                ~ shQuote(tag ~ "^{commit}"));
        if(!commit.length)
            throw new TachyError("repo '" ~ path ~ "': tag '" ~ tag
                    ~ "' not found (fetched from origin '" ~ url ~ "')");
        if(head != commit) {
            act("git -C " ~ q ~ " checkout --detach " ~ shQuote(tag), "checkout tag");
            actions ~= (ctx.checkMode ? "would checkout tag " : "checked out tag ")
                ~ tag;
        }
        return finish();
    }

    if(branch.length) {
        const string cur = probe("git -C " ~ q ~ " rev-parse --abbrev-ref HEAD");
        const string originRef = "origin/" ~ branch;
        const string originSha = probe("git -C " ~ q ~ " rev-parse --verify --quiet "
                ~ shQuote("refs/remotes/" ~ originRef));
        if(!originSha.length)
            throw new TachyError("repo '" ~ path ~ "': branch '" ~ branch
                    ~ "' not found on origin '" ~ url ~ "'");
        if(cur != branch) {
            const string local = probe("git -C " ~ q ~ " rev-parse --verify --quiet "
                    ~ shQuote("refs/heads/" ~ branch));
            act(local.length
                    ? "git -C " ~ q ~ " checkout " ~ shQuote(branch) : "git -C " ~ q ~ " checkout -b " ~ shQuote(
                        branch) ~ " "
                    ~ shQuote(originRef),
                    "checkout branch");
            actions ~= (ctx.checkMode ? "would checkout branch " : "switched to branch ")
                ~ branch;
            if(ctx.checkMode)
                return finish();
        }
        const string head = probe("git -C " ~ q ~ " rev-parse HEAD");
        if(head != originSha) {
            auto ancestor = t.run("git -C " ~ q ~ " merge-base --is-ancestor HEAD "
                    ~ shQuote(originRef));
            if(!ancestor.ok)
                throw new TachyError("repo '" ~ path ~ "': branch '" ~ branch
                        ~ "' and '" ~ originRef ~ "' have diverged (local commits"
                        ~ " or a history rewrite); reconcile manually");
            act("git -C " ~ q ~ " merge --ff-only " ~ shQuote(originRef),
                    "fast-forward branch");
            actions ~= (ctx.checkMode ? "would fast-forward " : "fast-forwarded ")
                ~ branch ~ " to " ~ originRef;
        }
        return finish();
    }

    return finish();
}

private string errMsg(in CommandResult r) @safe
{
    auto m = r.errText.strip;
    if(!m.length)
        m = r.outText.strip;
    if(!m.length)
        m = "exit status " ~ text(r.status);
    return m;
}

// ---------------------------------------------------------------------------
// Tests with a scripted transport: command construction only.
// ---------------------------------------------------------------------------
