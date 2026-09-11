/// Tests for tachy.runner, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.runner;

import tachy.runner;

import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : File;

@("resolveTasksFiles: directories map to main.pravic")
unittest
{
    auto dir = buildPath(tempDir, "tachy_runner_ut", "proj");
    if (!exists(dir)) mkdirRecurse(dir);
    {
        auto f = File(buildPath(dir, "main.pravic"), "w");
        f.write("[files.\"/tmp/x\"]\n");
        f.close();
    }

    // directory argument -> main.pravic inside it
    auto r = resolveTasksFiles([dir]);
    assert(r.length == 1 && r[0] == buildPath(dir, "main.pravic"));

    // trailing slash on the directory behaves the same
    r = resolveTasksFiles([dir ~ "/"]);
    assert(r.length == 1 && canFind(r[0], "main.pravic"));

    // plain file and missing paths pass through untouched
    r = resolveTasksFiles(["site/other.pravic", "missing.pravic"]);
    assert(r == ["site/other.pravic", "missing.pravic"]);

    // no argument: main.pravic in the current directory
    r = resolveTasksFiles([]);
    assert(r == ["main.pravic"]);
}

@("collectDecryptedFiles: controller-side decryption of age-marked src")
unittest
{
import tachy.errors : TachyError;
import std.conv : text;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath, dirName;
import tachy.models : loadTasksFile;
import tachy.project : DecryptedFile;
import tachy.value : Val;
import tachy.vars : AgeIdentity, ageDecrypt;

auto dir = buildPath(tempDir, "tachy_runner_age_ut");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(buildPath(dir, "secrets"));
scope (exit) rmdirRecurse(dir);

auto mainFile = buildPath(dir, "main.pravic");
{
    import std.stdio : File;
    auto f = File(mainFile, "w");
    f.write(`
file /etc/a.key { src = "secrets/shared.age", age = true }
file /etc/b.key { src = "secrets/shared.age", age = true }
file /etc/c.key { src = "secrets/c.age", age = true }
file /etc/d.key { src = "secrets/{{ host }}.age", age = true }
`);
    f.close();
}
write(buildPath(dir, "secrets", "shared.age"), "age-encryption.org/v1\nshared\n");
write(buildPath(dir, "secrets", "c.age"), "age-encryption.org/v1\nc\n");
write(buildPath(dir, "secrets", "web1.age"), "age-encryption.org/v1\nweb1\n");
write(buildPath(dir, "id.txt"), "# identity\n");

int calls;
auto saved = ageDecrypt;
scope (exit) ageDecrypt = saved;
ageDecrypt = (string agePath, in AgeIdentity identity, string where)
{
    calls++;
    return "PLAIN:" ~ agePath;
};

auto loaded = loadTasksFile(mainFile);
Val[string] hostVars;
hostVars["host"] = Val("web1");

string[string] cache;
auto files = collectDecryptedFiles(loaded, hostVars, dir,
    buildPath(dir, "id.txt"), cache);

// three unique sources: shared (deduped across two jobs), c, and the
// host-templated web1 — each decrypted exactly once
assert(files.length == 3, text(files.length));
assert(calls == 3, text(calls));
foreach (ref const f; files)
{
    if (f.relPath == "secrets/shared.age")
        assert(f.bytes == "PLAIN:" ~ buildPath(dir, "secrets", "shared.age"));
    else if (f.relPath == "secrets/c.age")
        assert(f.bytes == "PLAIN:" ~ buildPath(dir, "secrets", "c.age"));
    else if (f.relPath == "secrets/web1.age")
        assert(f.bytes == "PLAIN:" ~ buildPath(dir, "secrets", "web1.age"));
    else
        assert(false, f.relPath);
}

// the cache serves a second host without re-decrypting
auto more = collectDecryptedFiles(loaded, hostVars, dir,
    buildPath(dir, "id.txt"), cache);
assert(more.length == 3 && calls == 3);

// a source outside the project is refused: it could not be shipped
{
    import std.file : mkdirRecurse;
    mkdirRecurse(buildPath(tempDir, "tachy_runner_age_ut_out"));
    scope (exit) rmdirRecurse(buildPath(tempDir, "tachy_runner_age_ut_out"));
    write(buildPath(tempDir, "tachy_runner_age_ut_out", "x.age"), "x");
    {
        import std.stdio : File;
        auto f = File(mainFile, "w");
        f.write(`
file /tmp/x { src = "../../tachy_runner_age_ut_out/x.age", age = true }
`);
        f.close();
    }
    auto l2 = loadTasksFile(mainFile);
    string[string] cache2;
    string msg;
    try
    {
        collectDecryptedFiles(l2, null, dir, buildPath(dir, "id.txt"), cache2);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "must live inside the project directory"), msg);
    assert(canFind(msg, "main.pravic"), msg);
}
}

@("deferred includes: the staging mirror collects their secrets")
unittest
{
import std.algorithm.searching : canFind;
import std.conv : text;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : File;
import tachy.errors : TachyError;
import tachy.models : loadTasksFile;
import tachy.project : DecryptedFile, ImportSpec;
import tachy.settings : Settings;
import tachy.value : Val;
import tachy.vars : AgeIdentity, ageDecrypt;

auto root = buildPath(tempDir, "tachy_runner_defer_ut");
if (exists(root)) rmdirRecurse(root);
mkdirRecurse(buildPath(root, "proj"));
mkdirRecurse(buildPath(root, "src", "land"));
scope (exit) rmdirRecurse(root);

// the import source, outside the project: a tasks file under the
// landing that only exists inside the bundle, plus its secrets
write(buildPath(root, "src", "land", "x.pravic"), `
include "y.pravic"
file /tmp/deferred.key { src = "s.age", age = true }
`);
write(buildPath(root, "src", "land", "y.pravic"), `
file /tmp/nested.key { src = "t.age", age = true }
`);
write(buildPath(root, "src", "land", "s.age"), "age-encryption.org/v1\ns\n");
write(buildPath(root, "src", "land", "t.age"), "age-encryption.org/v1\nt\n");
write(buildPath(root, "id.txt"), "# identity\n");
{
    auto f = File(buildPath(root, "proj", "main.pravic"), "w");
    f.write(`
import "land"
include "land/x.pravic"
`);
    f.close();
}

Settings settings;
settings.importPaths = [buildPath(root, "src")];

auto loaded = loadTasksFile(buildPath(root, "proj", "main.pravic"), settings);
assert(loaded.deferred.length == 1, text(loaded.deferred.length));
assert(canFind(loaded.deferred[0], "land/x.pravic"), loaded.deferred[0]);
assert(loaded.jobs.length == 0); // everything deferred, nothing seen

// without the mirror the controller sees no secrets (the old limit)
string[string] cache;
assert(collectDecryptedFiles(loaded, null, buildPath(root, "proj"),
    buildPath(root, "id.txt"), cache).length == 0);

// swappable decryptor (no age binary in the suite)
auto saved = ageDecrypt;
scope (exit) ageDecrypt = saved;
ageDecrypt = (string agePath, in AgeIdentity identity, string where)
    => "PLAIN:" ~ agePath;

// the staging mirror: project entries + the landed import as symlinks
ImportSpec[] imports = [ImportSpec(buildPath(root, "src", "land"), "land")];
const string staging = makeStaging(buildPath(root, "proj"), imports);
assert(exists(buildPath(staging, "main.pravic")));
assert(exists(buildPath(staging, "land", "x.pravic")));

// the shadow composition sees the deferred subtree, nested include
// included, exactly like the on-host inner run will
auto shadow = loadTasksFile(buildPath(staging, "main.pravic"), settings);
assert(shadow.deferred.length == 0, "landing exists in the mirror");
assert(shadow.jobs.length == 2, text(shadow.jobs.length));

string[string] cache2;
auto files = collectDecryptedFiles(shadow, null, staging,
    buildPath(root, "id.txt"), cache2);
assert(files.length == 2, text(files.length));
foreach (ref const f; files)
{
    assert(canFind(f.relPath, "land/"), f.relPath);
    assert(f.bytes == "PLAIN:" ~ buildPath(staging, f.relPath), f.relPath);
}

// removal unlinks the mirror without touching the real files
removeStaging(staging);
assert(!exists(staging));
assert(exists(buildPath(root, "src", "land", "s.age")));
assert(exists(buildPath(root, "src", "land", "x.pravic")));
assert(exists(buildPath(root, "proj", "main.pravic")));
}
@("hosts list and info text from an inventory")
unittest
{
import std.file : rmdirRecurse;
import tachy.inventory : HostConfig, Inventory;

auto dir = buildPath(tempDir, "tachy_runner_hosts_ut");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) rmdirRecurse(dir);

const string invPath = buildPath(dir, "inventory.pravic");
{
    auto f = File(invPath, "w");
    f.write(`
var admin = "root"

host web1 {
    address = "10.0.0.1"
    user = "deploy"
    port = 2222
    key = "~/.ssh/id_web1"
    tags = ["web", "front"]
    vars { http_port = 81 }
}

host buildbox {
    connection = "local"
}
`);
    f.close();
}

auto inv = Inventory.load(invPath);

// list: selection header, one line per host, sorted by name, with the
// connection target (the former --list-hosts output)
const string listAll = hostsListText("all", inv.select("all"));
assert(listAll == "== all | hosts: buildbox, web1\n"
    ~ "  buildbox (local)\n"
    ~ "  web1 (ssh deploy@10.0.0.1:2222)\n", listAll);

// info: header, set attributes plus connection/port defaults, then
// effective vars (global < host, sorted, no inventory_hostname)
auto vars = inv.varsFor("web1");
vars.remove("inventory_hostname");
const string info = hostInfoText(inv.select("web1")[0], vars);
assert(info == "== web1 (ssh deploy@10.0.0.1:2222)\n"
    ~ "  connection  ssh\n"
    ~ "  address     10.0.0.1\n"
    ~ "  user        deploy\n"
    ~ "  port        2222\n"
    ~ "  key         ~/.ssh/id_web1\n"
    ~ "  tags        web, front\n"
    ~ "  vars:\n"
    ~ "    admin = \"root\"\n"
    ~ "    http_port = 81\n", info);

// info on a bare local host: defaults and the global var only
auto bvars = inv.varsFor("buildbox");
bvars.remove("inventory_hostname");
const string bare = hostInfoText(inv.select("buildbox")[0], bvars);
assert(bare == "== buildbox (local)\n"
    ~ "  connection  local\n"
    ~ "  port        22\n"
    ~ "  vars:\n"
    ~ "    admin = \"root\"\n", bare);

// a bare host with no vars at all gets no vars section
const string none = hostInfoText(HostConfig("x"), null);
assert(none == "== x (ssh x)\n"
    ~ "  connection  ssh\n"
    ~ "  port        22\n", none);
}

@("hosts command: sub-command validation and unknown hosts")
unittest
{
import std.file : rmdirRecurse;
import tachy.errors : TachyError;
import tachy.inventory : Inventory;

// argument shapes are rejected before the inventory is even read
foreach (args; [cast(string[])[], ["ls"], ["list"], ["list", "a", "b"],
    ["info"], ["info", "a", "b"], ["nonsense", "x"]])
{
    string msg;
    try
    {
        runHosts(args, RunOptions("no-such-inventory.pravic"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "hosts"), msg);
}

// info resolves through the inventory: unknown names list the known
auto dir = buildPath(tempDir, "tachy_runner_hostscmd_ut");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) rmdirRecurse(dir);
const string invPath = buildPath(dir, "inventory.pravic");
{
    auto f = File(invPath, "w");
    f.write("host web1 { address = \"10.0.0.1\" }\n");
    f.close();
}

assert(runHosts(["info", "web1"], RunOptions(invPath)) == 0);

string msg;
try
{
    runHosts(["info", "nope"], RunOptions(invPath));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "unknown host 'nope'"), msg);
assert(canFind(msg, "known: web1"), msg);

// list rejects an empty selection the same way apply does
try
{
    runHosts(["list", ""], RunOptions(invPath));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "matched no hosts"), msg);
}
