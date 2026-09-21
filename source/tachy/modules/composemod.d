module tachy.modules.composemod;

/**
 * `compose` module — idempotent Docker Compose stack management.
 *
 *     compose.dir            = "/srv/app"        (required; the table key)
 *     compose.file           = "compose.yml"     (required; relative to dir)
 *     compose.project        = "myapp"           # default: sanitized basename
 *                                               # of dir, as compose derives it
 *     compose.services       = ["web", "db"]     # default: every service the
 *                                               # selected file enables
 *     compose.state          = "running"         # running (default) | stopped | absent
 *     compose.pull           = "missing"         # missing (default) | always | never
 *     compose.build          = "auto"            # auto (default) | always | never
 *     compose.recreate       = "auto"            # auto (default) | always | never
 *     compose.wait           = true              # wait for running/healthy after up
 *     compose.wait_timeout   = 300               # cap for that wait, in seconds
 *     compose.timeout        = 30                # stop/shutdown timeout, seconds
 *     compose.remove_orphans = true              # stopped: drop containers whose
 *                                               # service left the compose model
 *     compose.remove_volumes = true              # absent: also remove named volumes
 *     compose.remove_images  = true              # absent: also remove service images
 *
 * `running` probes every selected service read-only — a container that is
 * running, healthy (when its service defines a healthcheck) and whose
 * `com.docker.compose.config-hash` label equals the canonical hash
 * (`docker compose config --hash`) — and runs `up --detach` only on drift,
 * with the pull/build/recreate/wait policy flags.  `stopped` runs
 * `compose stop` (containers, networks and volumes are preserved);
 * remove_orphans removes leftover containers through the container engine.
 * `absent` runs `down --remove-orphans` (plus `--volumes` / `--rmi all` on
 * request) and is a no-op when no container, network or (with
 * remove_volumes) volume of the project exists — the compose file is only
 * consulted when something actually has to run.
 */
import std.algorithm.iteration : map;
import std.algorithm.searching : canFind;
import std.array : join, split;
import std.conv : text;
import std.path : baseName, buildPath, isAbsolute;
import std.string : lineSplitter, strip;

import tachy.errors;
import tachy.modules : TaskContext, TaskResult, mustRun, optBool, optStr, requireStr;
import tachy.transport : CommandResult, Transport, shQuote;
import tachy.value : Val;

/// Static validation (values may still contain templates at parse time).
/// Called from the module registry; `context` reads like
/// `"<file>: compose \"<dir>\" (compose)"`.
void validateComposeParams(in Val[string] params, string context) {
    if("file" !in params)
        throw new TachyError(context ~ ": 'file' is required");
    foreach(k; ["file", "project"])
        if(auto p = k in params)
            if((*p).kind != Val.Kind.string_)
                throw new TachyError(context ~ ": '" ~ k ~ "' must be a string, not a "
                        ~ (*p).typeName());
    if(auto p = "dir" in params)
        if((*p).kind == Val.Kind.string_ && !canFind((*p).str_, "{{")
                && !isAbsolute((*p).str_))
            throw new TachyError(context ~ ": 'dir' must be an absolute path, not \""
                    ~ (*p).str_ ~ "\"");
    if(auto p = "project" in params)
        if((*p).kind == Val.Kind.string_ && !canFind((*p).str_, "{{"))
            checkProjectName((*p).str_, context);
    if(auto p = "services" in params) {
        if((*p).kind != Val.Kind.array_)
            throw new TachyError(context ~ ": 'services' must be an array of strings, not a "
                    ~ (*p).typeName());
        foreach(const e; (*p).array_)
            if(e.kind != Val.Kind.string_)
                throw new TachyError(context ~ ": 'services' must contain only strings (got "
                        ~ e.display() ~ ")");
            else if(!e.str_.length)
                throw new TachyError(context ~ ": 'services' must not contain an empty service name");
    }
    if(auto p = "state" in params)
        checkLiteralChoice("state", *p, ["running", "stopped", "absent"], context);
    if(auto p = "pull" in params)
        checkLiteralChoice("pull", *p, ["missing", "always", "never"], context);
    foreach(k; ["build", "recreate"])
        if(auto p = k in params)
            checkLiteralChoice(k, *p, ["auto", "always", "never"], context);
    foreach(k; ["wait", "remove_orphans", "remove_volumes", "remove_images"])
        if(auto p = k in params)
            if((*p).kind != Val.Kind.boolean_)
                throw new TachyError(context ~ ": '" ~ k ~ "' must be a boolean, not a "
                        ~ (*p).typeName());
    foreach(k; ["wait_timeout", "timeout"])
        if(auto p = k in params) {
            if((*p).kind != Val.Kind.integer_)
                throw new TachyError(context ~ ": '" ~ k ~ "' must be an integer, not a "
                        ~ (*p).typeName());
            if((*p).integer_ <= 0)
                throw new TachyError(context ~ ": '" ~ k ~ "' must be a positive number of seconds");
        }

    // A literal state (a missing one means "running", the default) pins
    // the combinations early; a templated state is re-checked against the
    // rendered value at run time.
    bool templatedState;
    if(auto p = "state" in params)
        templatedState = canFind((*p).str_, "{{");
    if(!templatedState) {
        string state = "running";
        if(auto p = "state" in params)
            state = (*p).str_;
        if(state != "running")
            foreach(k; ["wait", "wait_timeout"])
                if(k in params)
                    throw new TachyError(context ~ ": '" ~ k
                            ~ "' is only meaningful with state = \"running\"");
        if(state != "stopped" && "remove_orphans" in params)
            throw new TachyError(context ~ ": 'remove_orphans' is only meaningful with state = \"stopped\"");
        if(state != "absent")
            foreach(k; ["remove_volumes", "remove_images"])
                if(k in params)
                    throw new TachyError(context ~ ": '" ~ k
                            ~ "' is only meaningful with state = \"absent\"");
    }
    if("wait_timeout" in params && "wait" in params
            && params["wait"].kind == Val.Kind.boolean_ && !params["wait"].boolean_)
        throw new TachyError(context ~ ": 'wait_timeout' is only meaningful with 'wait = true'");
}

TaskResult runComposeModule(Val[string] params, TaskContext ctx) {
    auto t = ctx.transport;

    const string dir = requireStr(params, "dir", "compose");
    if(!isAbsolute(dir))
        throw new TachyError("compose: 'dir' must be an absolute path, not \"" ~ dir ~ "\"");
    const string fileAttr = requireStr(params, "file", "compose");
    const string file = isAbsolute(fileAttr) ? fileAttr : buildPath(dir, fileAttr);

    const string state = optStr(params, "state", "compose", "running");
    checkChoice("state", state, ["running", "stopped", "absent"]);
    const string pull = optStr(params, "pull", "compose", "missing");
    const string build = optStr(params, "build", "compose", "auto");
    const string recreate = optStr(params, "recreate", "compose", "auto");
    checkChoice("pull", pull, ["missing", "always", "never"]);
    checkChoice("build", build, ["auto", "always", "never"]);
    checkChoice("recreate", recreate, ["auto", "always", "never"]);

    // Run-time re-checks of the combinations a templated state can produce
    // (literal contradictions were rejected at load time).
    if(state != "running")
        foreach(k; ["wait", "wait_timeout"])
            if(k in params)
                throw new TachyError("compose: '" ~ k
                        ~ "' is only meaningful with state = \"running\"");
    if(state != "stopped" && "remove_orphans" in params)
        throw new TachyError("compose: 'remove_orphans' is only meaningful with state = \"stopped\"");
    if(state != "absent")
        foreach(k; ["remove_volumes", "remove_images"])
            if(k in params)
                throw new TachyError("compose: '" ~ k
                        ~ "' is only meaningful with state = \"absent\"");

    const bool wait = optBool(params, "wait", "compose", true);
    const long waitTimeout = optIntParam(params, "wait_timeout", "compose");
    const long timeout = optIntParam(params, "timeout", "compose");
    if("wait_timeout" in params && !wait)
        throw new TachyError("compose: 'wait_timeout' is only meaningful with 'wait = true'");

    const string projectAttr = optStr(params, "project", "compose");
    const string project = projectAttr.length ? projectAttr : defaultProjectName(dir);
    checkProjectName(project, "compose");
    const string[] services = servicesParam(params);

    {
        auto r = t.run("docker compose version");
        if(!r.ok)
            throw new TachyError(
                    "compose: docker compose is not available on " ~ ctx.hostName
                    ~ "; the docker CLI with the compose plugin is required");
    }

    // One stable invocation prefix: the file, the project name and the
    // project directory are always pinned so probes and mutations cannot
    // drift apart on compose's defaults.
    const string base = "docker compose -f " ~ shQuote(file) ~ " -p " ~ shQuote(project)
        ~ " --project-directory " ~ shQuote(dir);

    string[] actions;
    string[] details;
    string okMsg = "up to date";

    switch(state) {
        case "running": {
            auto model = modelServices(t, base, file);
            const string[] selected = resolveSelected(services, model, file);
            string[string] want;
            foreach(s; selected)
                want[s] = configHash(t, base, s, file);

            auto drift = runningDrift(t, project, selected, want);
            details ~= drift.reasons;
            okMsg = text(selected.length) ~ " service(s) up to date";
            if(drift.reasons.length) {
                string cmd = base ~ " up --detach";
                if(pull != "missing") cmd ~= " --pull " ~ pull;
                if(build == "always") cmd ~= " --build";
                else if(build == "never") cmd ~= " --no-build";
                if(recreate == "always") cmd ~= " --force-recreate";
                else if(recreate == "never") cmd ~= " --no-recreate";
                if(wait) {
                    cmd ~= " --wait";
                    if(waitTimeout > 0)
                        cmd ~= " --wait-timeout " ~ text(waitTimeout);
                }
                if(timeout > 0)
                    cmd ~= " -t " ~ text(timeout);
                if(services.length)
                    cmd ~= " " ~ selected.map!shQuote.join(" ");
                mustRun(t, ctx, details, cmd, "compose up '" ~ project ~ "'");
                actions = drift.actions;
                // up --wait only returns once every selected service runs
                // (and passes its healthcheck); confirm the probe agrees.
                if(!ctx.checkMode && wait) {
                    auto still = runningDrift(t, project, selected, want);
                    if(still.reasons.length)
                        throw new TachyError("compose '" ~ dir ~ "': still not conformant after up: "
                                ~ still.reasons.join("; "));
                }
            }
            break;
        }
        case "stopped": {
            auto model = modelServices(t, base, file);
            const string[] selected = resolveSelected(services, model, file);
            auto containers = projectContainers(t, project);
            okMsg = "already stopped";

            string[] toStop;
            foreach(s; selected)
                foreach(c; containers)
                    if(c.service == s && c.state == "running") {
                        if(!canFind(toStop, s))
                            toStop ~= s;
                        break;
                    }
            if(toStop.length) {
                string cmd = base ~ " stop";
                if(timeout > 0)
                    cmd ~= " -t " ~ text(timeout);
                if(services.length)
                    cmd ~= " " ~ selected.map!shQuote.join(" ");
                mustRun(t, ctx, details, cmd, "compose stop '" ~ project ~ "'");
                actions ~= "stopped " ~ toStop.map!(s => "'" ~ s ~ "'").join(", ");
            }
            if(optBool(params, "remove_orphans", "compose")) {
                string[] orphans;
                foreach(c; containers)
                    if(!canFind(model, c.service))
                        orphans ~= c.name;
                if(orphans.length) {
                    mustRun(t, ctx, details,
                            "docker rm -f " ~ orphans.map!shQuote.join(" "),
                            "remove orphan containers of '" ~ project ~ "'");
                    actions ~= "removed " ~ text(orphans.length) ~ " orphan container(s)";
                }
            }
            break;
        }
        case "absent": {
            const bool removeVolumes = optBool(params, "remove_volumes", "compose");
            const bool removeImages = optBool(params, "remove_images", "compose");
            okMsg = "already absent";
            if(projectExists(t, project, removeVolumes)) {
                string cmd = base ~ " down --remove-orphans";
                if(timeout > 0)
                    cmd ~= " -t " ~ text(timeout);
                if(removeVolumes)
                    cmd ~= " --volumes";
                if(removeImages)
                    cmd ~= " --rmi all";
                mustRun(t, ctx, details, cmd, "compose down '" ~ project ~ "'");
                actions ~= "brought down";
                if(removeVolumes)
                    actions ~= "volumes removed";
                if(removeImages)
                    actions ~= "images removed";
                if(!ctx.checkMode && projectExists(t, project, removeVolumes))
                    throw new TachyError(
                            "compose '" ~ dir
                            ~ "': compose down left containers, networks or volumes of project '"
                            ~ project ~ "' behind");
            }
            break;
        }
        default:
            assert(0, "unreachable: state validated above");
    }

    TaskResult res;
    res.changed = actions.length != 0;
    res.msg = actions.length ? actions.join(", ") : okMsg;
    res.details = details;
    return res;
}

// ---------------------------------------------------------------------------
// Probes (all read-only) and name resolution.
// ---------------------------------------------------------------------------

/// Compose's own default project name: the lowercased basename of the
/// project directory with everything outside [a-z0-9_-] removed.
private string defaultProjectName(string dir) {
    import std.string : toLower;

    string r;
    foreach(char c; baseName(dir).toLower)
        if((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')
            r ~= c;
    if(!r.length)
        throw new TachyError("compose: cannot derive a project name from '" ~ dir
                ~ "'; set 'project' explicitly");
    return r;
}

/// Docker's project-name rule: `[a-z0-9][a-z0-9_-]*`.
private void checkProjectName(string p, string context) {
    bool ok = p.length && p[0] != '-' && p[0] != '_';
    foreach(char c; p)
        if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
            ok = false;
    if(!ok)
        throw new TachyError(context ~ ": project name \"" ~ p
                ~ "\" is invalid (docker wants [a-z0-9][a-z0-9_-]*)");
}

private void checkChoice(string key, string v, string[] allowed) {
    if(!canFind(allowed, v))
        throw new TachyError("compose: '" ~ key ~ "' must be one of " ~ allowed.join(", ")
                ~ ", not \"" ~ v ~ "\"");
}

/// Like checkChoice, but tolerant of templates (checked again at run time).
private void checkLiteralChoice(string key, in Val v, string[] allowed, string context) {
    if(v.kind != Val.Kind.string_)
        throw new TachyError(context ~ ": '" ~ key ~ "' must be a string, not a " ~ v.typeName());
    if(canFind(v.str_, "{{") || canFind(allowed, v.str_))
        return;
    throw new TachyError(context ~ ": '" ~ key ~ "' must be one of " ~ allowed.join(", ")
            ~ ", not \"" ~ v.str_ ~ "\"");
}

/// The literal value of `key`, or null when absent, non-string or templated.
private string literalStr(in Val[string] params, string key) {
    auto p = key in params;
    if(p is null || (*p).kind != Val.Kind.string_ || canFind((*p).str_, "{{"))
        return null;
    return (*p).str_;
}

private string[] servicesParam(in Val[string] params) {
    auto pv = "services" in params;
    if(pv is null)
        return null;
    if((*pv).kind != Val.Kind.array_)
        throw new TachyError("compose: 'services' must be an array of strings, not a "
                ~ (*pv).typeName());
    string[] r;
    foreach(const e; (*pv).array_) {
        if(e.kind != Val.Kind.string_)
            throw new TachyError("compose: 'services' must contain only strings (got "
                    ~ e.display() ~ ")");
        if(!e.str_.length)
            throw new TachyError("compose: 'services' must not contain an empty service name");
        r ~= e.str_;
    }
    return r;
}

private long optIntParam(in Val[string] p, string key, string mod) {
    auto pv = key in p;
    if(pv is null)
        return 0;
    if((*pv).kind != Val.Kind.integer_)
        throw new TachyError(mod ~ ": '" ~ key ~ "' must be an integer, not a "
                ~ (*pv).typeName());
    if((*pv).integer_ <= 0)
        throw new TachyError(mod ~ ": '" ~ key ~ "' must be a positive number of seconds");
    return (*pv).integer_;
}

/// Map the `services` subset onto the model; empty means every service the
/// selected file enables (profile-gated services are excluded by compose).
private string[] resolveSelected(in string[] services, in string[] model, string file) {
    if(!services.length)
        return model.dup;
    foreach(s; services)
        if(!canFind(model, s))
            throw new TachyError("compose: service '" ~ s ~ "' is not defined in " ~ file);
    return services.dup;
}

/// `docker compose config --services`: the model the file selects.  Also
/// the availability check for the compose file itself.
private string[] modelServices(Transport t, string base, string file) {
    auto r = t.run(base ~ " config --services");
    if(!r.ok)
        throw new TachyError("compose: cannot load " ~ file ~ ": " ~ firstMeaningful(r));
    string[] list;
    foreach(line; lineSplitter(r.outText)) {
        auto l = line.strip;
        if(l.length)
            list ~= l;
    }
    return list;
}

/// `docker compose config --hash <service>` prints "<service> <sha256>" —
/// the canonical config hash compose stamps into each container's
/// com.docker.compose.config-hash label.
private string configHash(Transport t, string base, string service, string file) {
    auto r = t.run(base ~ " config --hash " ~ shQuote(service));
    if(!r.ok)
        throw new TachyError("compose: cannot hash service '" ~ service ~ "' in " ~ file
                ~ ": " ~ firstMeaningful(r));
    auto parts = split(r.outText.strip);
    if(parts.length != 2 || parts[0] != service)
        throw new TachyError("compose: unexpected `config --hash` output for '" ~ service
                ~ "': \"" ~ r.outText.strip ~ "\"");
    return parts[1];
}

private struct ContainerInfo {
    string service;
    string name;
    string state; // as `docker ps` reports: running, exited, ...
    string hash; // com.docker.compose.config-hash label
}

/// Every container carrying the project's label (running or not).
private ContainerInfo[] projectContainers(Transport t, string project) {
    auto r = t.run("docker ps -a --filter label=com.docker.compose.project="
            ~ shQuote(project) ~ " --format " ~ shQuote(psFormat));
    if(!r.ok)
        throw new TachyError("compose: cannot list containers of project '" ~ project
                ~ "': " ~ firstMeaningful(r));
    ContainerInfo[] list;
    foreach(line; lineSplitter(r.outText)) {
        auto l = line.strip;
        if(!l.length)
            continue;
        auto f = split(l, "\t");
        // A container without the config-hash label (removed from the
        // compose model, or created outside compose) prints no trailing
        // field: docker drops the separator for an empty last value.
        if(f.length != 4 && f.length != 3)
            throw new TachyError("compose: unexpected `docker ps` output for project '"
                    ~ project ~ "': \"" ~ l ~ "\"");
        list ~= ContainerInfo(f[0], f[1], f[2], f.length == 4 ? f[3] : "");
    }
    return list;
}

private immutable string psFormat = "{{.Label \"com.docker.compose.service\"}}\\t{{.Names}}\\t{{.State}}\\t{{.Label \"com.docker.compose.config-hash\"}}";

private struct HealthInfo {
    string name;
    string status;
    string health; // healthy | unhealthy | starting | none
}

/// Runtime state and health of given containers; "none" when the container
/// has no healthcheck (running is then all that can hold).
private HealthInfo[] containerHealth(Transport t, string[] names, string project) {
    auto r = t.run("docker inspect --format " ~ shQuote(inspectFormat) ~ " "
            ~ names.map!shQuote.join(" "));
    if(!r.ok)
        throw new TachyError("compose: cannot inspect containers of project '" ~ project
                ~ "': " ~ firstMeaningful(r));
    HealthInfo[] list;
    foreach(line; lineSplitter(r.outText)) {
        auto l = line.strip;
        if(!l.length)
            continue;
        auto f = split(l);
        if(f.length != 3)
            throw new TachyError("compose: unexpected `docker inspect` output for project '"
                    ~ project ~ "': \"" ~ l ~ "\"");
        auto name = f[0].length && f[0][0] == '/' ? f[0][1 .. $] : f[0];
        list ~= HealthInfo(name, f[1], f[2]);
    }
    return list;
}

private immutable string inspectFormat =
    "{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}";

private struct Drift {
    string[] reasons; // what differs (details, shown with -v)
    string[] actions; // what up will do (the changed message)
}

/// Compare every selected service's containers against the canonical
/// hashes; when those hold, check runtime state and health.
private Drift runningDrift(Transport t, string project, in string[] selected,
        in string[string] want) {
    Drift d;
    auto containers = projectContainers(t, project);
    foreach(s; selected) {
        size_t count;
        foreach(c; containers)
            if(c.service == s) {
                count++;
                if(c.state != "running") {
                    d.reasons ~= "container '" ~ c.name ~ "' is " ~ c.state;
                    put(d.actions, "started '" ~ c.name ~ "'");
                } else if(c.hash != want[s]) {
                    d.reasons ~= "container '" ~ c.name
                        ~ "' predates the current compose file (config hash differs)";
                    put(d.actions, "recreated '" ~ c.name ~ "'");
                }
            }
        if(!count) {
            d.reasons ~= "service '" ~ s ~ "' has no container";
            put(d.actions, "started '" ~ s ~ "'");
        }
    }
    if(!d.reasons.length) {
        string[] names;
        foreach(c; containers)
            if(canFind(selected, c.service))
                names ~= c.name;
        if(names.length)
            foreach(h; containerHealth(t, names, project))
                if(h.status != "running" || (h.health != "none" && h.health != "healthy")) {
                    d.reasons ~= "container '" ~ h.name ~ "' is " ~ h.status
                        ~ (h.health != "none" ? " (health " ~ h.health ~ ")" : "");
                    put(d.actions, "awaited '" ~ h.name ~ "'");
                }
    }
    return d;
}

private void put(ref string[] a, string v) {
    if(!canFind(a, v))
        a ~= v;
}

/// True when any container, network or (only when asked) named volume of
/// the project still exists.  Label-based, so it works without the compose
/// file — absent needs nothing until something has to go.
private bool projectExists(Transport t, string project, bool volumesToo) {
    auto r = t.run("docker ps -a --filter label=com.docker.compose.project="
            ~ shQuote(project) ~ " -q");
    if(!r.ok)
        throw new TachyError("compose: cannot list containers of project '" ~ project
                ~ "': " ~ firstMeaningful(r));
    if(r.outText.strip.length)
        return true;
    r = t.run("docker network ls --filter label=com.docker.compose.project="
            ~ shQuote(project) ~ " -q");
    if(!r.ok)
        throw new TachyError("compose: cannot list networks of project '" ~ project
                ~ "': " ~ firstMeaningful(r));
    if(r.outText.strip.length)
        return true;
    if(volumesToo) {
        r = t.run("docker volume ls --filter label=com.docker.compose.project="
                ~ shQuote(project) ~ " -q");
        if(!r.ok)
            throw new TachyError("compose: cannot list volumes of project '" ~ project
                    ~ "': " ~ firstMeaningful(r));
        if(r.outText.strip.length)
            return true;
    }
    return false;
}

/// First line of stderr, else stdout, else the exit status.
private string firstMeaningful(in CommandResult r) {
    auto m = r.errText.strip;
    if(!m.length)
        m = r.outText.strip;
    if(!m.length)
        return "exit status " ~ text(r.status);
    foreach(l; lineSplitter(m))
        return l;
    return m; // no newline: the whole (stripped) text
}

// ---------------------------------------------------------------------------
// Tests with a scripted transport: decision logic only, no real docker.
// ---------------------------------------------------------------------------
