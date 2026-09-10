/// Tests for tachy.models, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.models;

import tachy.models;

import std.exception : assertThrown;
import std.algorithm.searching : endsWith;
import std.file : exists, mkdirRecurse, tempDir;
import std.path : buildPath, isAbsolute;
import std.stdio : File;
import tachy.errors : TachyError;
import std.array : join;
import std.path : dirName;
import std.string : indexOf;

private string writeTemp(string sub, string content)
{
    auto dir = tempDir ~ "/tachy_models_ut";
    if (!exists(dir)) mkdirRecurse(dir);
    auto p = buildPath(dir, sub);
    auto f = File(p, "w");
    f.write(content);
    f.close();
    return p;
}

unittest // both statement forms, param injection, defaults
{
writeTemp("inner.pravic", `
directory /srv/app { mode = "0755" }
`);
auto p = writeTemp("main.pravic", `
var owner = "app"

file /tmp/myfile {
    owner = "root"
    mode = "0600"
}

files {
    /tmp/other { mode = "0644" }
}

service nginx { state = "started", enabled = true }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 3);

assert(loaded.jobs[0].kind == "file" && loaded.jobs[0].target == "/tmp/myfile");
assert(loaded.jobs[0].params["path"].str_ == "/tmp/myfile");
assert(loaded.jobs[0].params["state"].str_ == "file");
assert(loaded.jobs[0].params["mode"].str_ == "0600");
assert(loaded.jobs[0].tasksFileDir.indexOf("tachy_models_ut") >= 0);

assert(loaded.jobs[1].kind == "file" && loaded.jobs[1].target == "/tmp/other");

assert(loaded.jobs[2].kind == "service" && loaded.jobs[2].moduleName == "service");
assert(loaded.jobs[2].params["name"].str_ == "nginx");
assert(loaded.jobs[2].params["enabled"].boolean_);
}

unittest // check: name injection, source order, validation
{
import std.exception : assertThrown;
auto p = writeTemp("check.pravic", `
check "probe thing" {
    run = "true"
    exit_status = { not = 1 }
}

file /tmp/x { mode = "0400" }

check "check os" { run = "echo debian", exit_status = 0, output = "debian" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 3);
// statement order: probe thing first, file between, check os last
assert(loaded.jobs[0].target == "probe thing");
assert(loaded.jobs[1].kind == "file");
assert(loaded.jobs[2].kind == "check" && loaded.jobs[2].target == "check os");
assert(loaded.jobs[2].moduleName == "check");
assert(loaded.jobs[2].params["name"].str_ == "check os");    // injected
assert("exit_status" in loaded.jobs[0].params);

// duplicate check names are a load-time error (single + group form)
assertThrown!(TachyError)(loadTasksFile(writeTemp("check_dup.pravic",
    "check \"same\" { run = \"false\" }\nvar x = 1\n"
    ~ "check \"same\" { run = \"true\" }\n")));
// missing run
assertThrown!(TachyError)(loadTasksFile(writeTemp("check_norun.pravic",
    "check \"x\" { output = \"y\" }\n")));
// unknown attribute
assertThrown!(TachyError)(loadTasksFile(writeTemp("check_unk.pravic",
    "check \"x\" { run = \"true\", bogus = 1 }\n")));
// bad exit_status shape
assertThrown!(TachyError)(loadTasksFile(writeTemp("check_bad.pravic",
    "check \"x\" { run = \"true\", exit_status = \"0\" }\n")));
}

unittest // source order: no fixed order, no sorting
{
auto p = writeTemp("order.pravic", `
file /srv/tree/leaf.conf { content = "x" }

check "leaf exists" { run = "test -f /srv/tree/leaf.conf" }

directory /srv/tree { mode = "0755" }

service ssh { state = "started" }

directory /srv/other { mode = "0700" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 5);
// exactly the written order — a file before its directory is the
// author's choice now, not reordered
string[] order;
foreach (j; loaded.jobs)
    order ~= j.kind ~ " " ~ j.target;
assert(order == [
    "file /srv/tree/leaf.conf",
    "check leaf exists",
    "directory /srv/tree",
    "service ssh",
    "directory /srv/other",
], order.join(", "));
}

unittest // groups and users: statement order, validation
{
import std.exception : assertThrown;
auto p = writeTemp("accounts.pravic", `
group legacy { state = "absent" }

groups { epices { } }

user deploy {
    group = "epices"
    groups = ["epices"]
    shell = "/bin/bash"
    comment = "epices user"
    home = "/home/epices"
}
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 3);
assert(loaded.jobs[0].kind == "group" && loaded.jobs[0].target == "legacy");
assert(loaded.jobs[1].kind == "group" && loaded.jobs[1].target == "epices");
assert(loaded.jobs[2].kind == "user" && loaded.jobs[2].target == "deploy");
assert(loaded.jobs[2].params["group"].str_ == "epices");
assert(loaded.jobs[2].params["groups"].array_.length == 1);

// duplicate user names are a load-time error (across both forms)
assertThrown!(TachyError)(loadTasksFile(writeTemp("acc_dup.pravic",
    "user x { }\nusers { x { } }\n")));
// unknown attribute
assertThrown!(TachyError)(loadTasksFile(writeTemp("acc_unk.pravic",
    "user x { bogus = 1 }\n")));
// bad literal state
assertThrown!(TachyError)(loadTasksFile(writeTemp("acc_state.pravic",
    "group x { state = \"maybe\" }\n")));
}

unittest // include: vars = { ... } sub-table binding
{
import std.exception : assertThrown;
writeTemp("ap_files.pravic", `
file /tmp/ap-file { content = "{{ three }} {{ direct }} {{ nested.tbl.x }}" }
`);
auto p = writeTemp("ap_main.pravic", `
include "ap_files.pravic" {
    vars { three = "three", nested { tbl { x = "deep" } } }
    direct = "bound"
}
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 1);
auto ov = loaded.jobs[0].overlay;
assert(ov["three"].str_ == "three");
assert(ov["direct"].str_ == "bound");                 // direct binding merges
assert(ov["nested"].table_["tbl"].table_["x"].str_ == "deep");
assert("vars" !in ov);                                // the sub-table is unwrapped

// variable bound both directly and under vars: ambiguous -> error
assertThrown!(TachyError)(loadTasksFile(writeTemp("ap_dup.pravic", `
include "ap_files.pravic" {
    vars { three = "a" }
    three = "b"
}
`)));
// non-table vars
assertThrown!(TachyError)(loadTasksFile(writeTemp("ap_bad.pravic", `
include "ap_files.pravic" { vars = "nope" }
`)));
}

unittest // includes: position, var layering, path resolution
{
writeTemp("one.pravic", `
var from_one = "1"
file /tmp/one { mode = "0400" }
`);
writeTemp("two.pravic", `
file /tmp/two { mode = "0400" }
`);
auto p = writeTemp("compose.pravic", `
var top = "yes"
var override_me = "top"

include "one.pravic" { override_me = "one" }

include "two.pravic" { extra = "e" }

file /tmp/top { mode = "0400" }
`);
auto loaded = loadTasksFile(p);
// includes compose at their position, then the includer's own jobs
assert(loaded.jobs.length == 3);
// every composed file is recorded, entry first, resolved absolute
assert(loaded.sourceFiles.length == 3);
assert(loaded.sourceFiles[0].endsWith("compose.pravic"));
assert(loaded.sourceFiles[1].endsWith("one.pravic"));
assert(loaded.sourceFiles[2].endsWith("two.pravic"));
assert(isAbsolute(loaded.sourceFiles[0]));
assert(loaded.jobs[0].target == "/tmp/one");
assert(loaded.jobs[1].target == "/tmp/two");
assert(loaded.jobs[2].target == "/tmp/top");

// overlay: outer vars < include vars < included file's own vars
assert(loaded.jobs[0].overlay["top"].str_ == "yes");          // outer visible
assert(loaded.jobs[0].overlay["override_me"].str_ == "one");  // include var wins
assert(loaded.jobs[0].overlay["from_one"].str_ == "1");       // own vars of one.pravic
assert(loaded.jobs[1].overlay["extra"].str_ == "e");

// flow-through: statements after the includes see everything the
// includes contributed (child vars and bindings).
assert(loaded.jobs[2].overlay["top"].str_ == "yes");
assert(loaded.jobs[2].overlay["from_one"].str_ == "1");       // flowed from one.pravic
assert(loaded.jobs[2].overlay["extra"].str_ == "e");          // flowed from include vars
assert(loaded.jobs[2].overlay["override_me"].str_ == "one");  // last include wins
}

unittest // a statement before an include does not see its contribution
{
writeTemp("post.pravic", `
var from_post = "p"
file /tmp/post { mode = "0400" }
`);
auto p = writeTemp("ordered.pravic", `
var top = "yes"

file /tmp/own { mode = "0400" }

include "post.pravic" { post_var = "pt" }

file /tmp/after { mode = "0400" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 3);
assert(loaded.jobs[0].target == "/tmp/own");
assert(loaded.jobs[1].target == "/tmp/post");
assert(loaded.jobs[2].target == "/tmp/after");

// the statement before the include sees only outer + own vars
assert(loaded.jobs[0].overlay["top"].str_ == "yes");
assert("from_post" !in loaded.jobs[0].overlay);
// the include keeps binding semantics for its subtree
assert(loaded.jobs[1].overlay["post_var"].str_ == "pt");
assert(loaded.jobs[1].overlay["from_post"].str_ == "p");
// statements after it see the flowed-forward scope
assert(loaded.jobs[2].overlay["from_post"].str_ == "p");

// include participates in duplicate-target and cycle detection
writeTemp("dup_apply_inc.pravic", "file /tmp/x { mode = \"0600\" }\n");
assertThrown!(TachyError)(loadTasksFile(writeTemp("dup_inc.pravic",
    "file /tmp/x { mode = \"0644\" }\ninclude \"dup_apply_inc.pravic\" { }\n")));
writeTemp("cyc_a.pravic", "include \"cyc_b.pravic\" { }\n");
writeTemp("cyc_b.pravic", "include \"cyc_a.pravic\" { }\n");
assertThrown!(TachyError)(loadTasksFile(buildPath(
    dirName(writeTemp("cyc_seed.pravic", "")), "cyc_a.pravic")));
}

unittest // errors
{
import std.exception : assertThrown;
// duplicate target across files
writeTemp("dup_inc.pravic", "file /tmp/x { mode = \"0600\" }\n");
assertThrown!(TachyError)(loadTasksFile(writeTemp("dup.pravic",
    "include \"dup_inc.pravic\" { }\nfile /tmp/x { mode = \"0644\" }\n")));
// duplicate between files and directories
assertThrown!(TachyError)(loadTasksFile(writeTemp("dup2.pravic",
    "file /tmp/x { mode = \"0600\" }\ndirectory /tmp/x { mode = \"0700\" }\n")));
// include cycle
writeTemp("cy_a.pravic", "include \"cy_b.pravic\" { }\n");
writeTemp("cy_b.pravic", "include \"cy_a.pravic\" { }\n");
assertThrown!(TachyError)(loadTasksFile(buildPath(
    dirName(writeTemp("cy_seed.pravic", "")), "cy_a.pravic")));
// explicit path/name key forbidden (implied by the statement key)
assertThrown!(TachyError)(loadTasksFile(writeTemp("key.pravic",
    "file /tmp/x { path = \"/elsewhere\" }\n")));
assertThrown!(TachyError)(loadTasksFile(writeTemp("key2.pravic",
    "service app { name = \"other\" }\n")));
// bad directories state
assertThrown!(TachyError)(loadTasksFile(writeTemp("st.pravic",
    "directory /tmp/x { state = \"file\" }\n")));
// unknown top-level directive
assertThrown!(TachyError)(loadTasksFile(writeTemp("unk.pravic",
    "bogus = 1\n")));
// directives that belong to other file kinds
assertThrown!(TachyError)(loadTasksFile(writeTemp("unk2.pravic",
    "host web1 { }\n")));
// unknown param key inside an entry
assertThrown!(TachyError)(loadTasksFile(writeTemp("unk3.pravic",
    "file /tmp/x { bogus = 1 }\n")));
}

unittest // tasks-file vars may read the environment
{
import std.algorithm.searching : canFind;
import std.process : environment;
environment["TACHY_UT_MODEL"] = "model-value";

auto p = writeTemp("envvars.pravic", `
var something = { env = "TACHY_UT_MODEL" }

file "{{ something }}-target" { mode = "0400" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 1);
assert(loaded.jobs[0].overlay["something"].str_ == "model-value");
assert(loaded.jobs[0].target == "{{ something }}-target"); // rendered at run time

// unset variable: load-time error naming the file and the variable
string msg;
try
{
    loadTasksFile(writeTemp("envvars_missing.pravic",
        "var x = { env = \"TACHY_UT_MODEL_NOPE\" }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "vars.x"));
assert(canFind(msg, "TACHY_UT_MODEL_NOPE"));
}

unittest // vars { env, from } reads a dotenv file next to the file
{
import std.algorithm.searching : canFind;

writeTemp("proj.env", "TACHY_UT_DOTENV=from-dotenv-file\n");
const string p = writeTemp("envfrom.pravic", `
var secret_var = { env = "TACHY_UT_DOTENV", from = "proj.env" }

file /tmp/target { content = "{{ secret_var }}", mode = "0600" }
`);

auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 1);
assert(loaded.jobs[0].overlay["secret_var"].str_ == "from-dotenv-file");

// a missing dotenv file is a load-time error naming file and entry
string msg;
try
{
    loadTasksFile(writeTemp("envfrom_missing.pravic",
        "var x = { env = \"K\", from = \"nope.env\" }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "vars.x"));
assert(canFind(msg, "cannot read dotenv file"));
assert(canFind(msg, "nope.env"));
}

unittest // vars { age } is rejected in tasks files: decryption is controller-side
{
import std.algorithm.searching : canFind;
string msg;
try
{
    loadTasksFile(writeTemp("age_in_tasks.pravic",
        "var x = { age = \"secret.age\" }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "only supported in inventory"), msg);
assert(canFind(msg, "vars.x"), msg);
}

unittest // services with src / template / vars (unit file management)
{
import std.algorithm.searching : canFind;
auto loaded = loadTasksFile(writeTemp("svc_unit.pravic", `
service my_service {
    state = "started"
    template = "templates/my_service.service.tmpl"
    vars { service_user = "example" }
}

service second_service {
    state = "enabled"
    src = "services/second.service"
}
`));
assert(loaded.jobs.length == 2);
assert(loaded.jobs[0].params["template"].str_ == "templates/my_service.service.tmpl");
assert(loaded.jobs[0].params["vars"].table_["service_user"].str_ == "example");
assert(loaded.jobs[1].params["src"].str_ == "services/second.service");
assert(loaded.jobs[1].params["state"].str_ == "enabled");

// load-time validation: src and template are exclusive, vars needs template
string msg;
try
{
    loadTasksFile(writeTemp("svc_both.pravic",
        "service x { src = \"a\", template = \"b\" }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "mutually exclusive"));

try
{
    loadTasksFile(writeTemp("svc_vars_only.pravic",
        "service x { state = \"started\", vars { a = \"b\" } }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "only meaningful with 'template'"));

try
{
    loadTasksFile(writeTemp("svc_badvars.pravic",
        "service x { state = \"started\", template = \"t\", vars = \"nope\" }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "'vars' must be a table"));
}

unittest // import: collection, errors, direct-mode tolerance
{
import std.algorithm.searching : canFind;
import std.path : baseName, buildPath, dirName, isAbsolute;

auto p = writeTemp("imp_main.pravic", `
import tasks/imp_gogs { }
import "../imp_data" { }
`);
auto loaded = loadTasksFile(p);
assert(loaded.imports.length == 2);
// resolved absolute, relative to the defining file's directory
foreach (src; loaded.imports)
{
    assert(isAbsolute(src));
    assert(baseName(src).length);
}

// the same source imported by an included file deduplicates
writeTemp("imp_inner.pravic", "import \"../imp_data\" { }\n");
loaded = loadTasksFile(writeTemp("imp_across.pravic",
    "import \"../imp_data\" { }\ninclude \"imp_inner.pravic\" { }\n"));
assert(loaded.imports.length == 1);

// an import with no parameters may omit the braces
loaded = loadTasksFile(writeTemp("imp_bare.pravic",
    "import tasks/imp_gogs\n"));
assert(loaded.imports.length == 1);
// resolved relative to the defining file's directory (dirName of a
// writeTemp path; tempDir's trailing slash makes raw comparison brittle)
assert(isAbsolute(loaded.imports[0])
    && canFind(loaded.imports[0], "tachy_models_ut/tasks/imp_gogs"),
    loaded.imports[0]);

// duplicate import statements in ONE file are a parse-time error
import std.exception : assertThrown;
assertThrown!TachyError(loadTasksFile(writeTemp("imp_dup.pravic",
    "import a_dir { }\nimport \"a_dir\" { }\n")));

// no parameters accepted (strict)
{
    string msg;
    try
    {
        loadTasksFile(writeTemp("imp_param.pravic",
            "import a_dir { dest = \"x\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(canFind(msg, "take no parameters"), msg);
}
// non-block entry
assertThrown!TachyError(loadTasksFile(writeTemp("imp_scalar.pravic",
    "import x = 1\n")));
// imports do not create jobs
p = writeTemp("imp_jobs.pravic", "import a_dir { }\n");
assert(loadTasksFile(p).jobs.length == 0);
}

unittest // composition into an import destination: deferral
{
import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;

// layout: base/proj/main.pravic (the project), base/gogs_lib/ (the
// import source, a sibling directory outside the project)
auto base = buildPath(tempDir, "tachy_import_defer_ut");
if (exists(base)) rmdirRecurse(base);
mkdirRecurse(buildPath(base, "proj"));
mkdirRecurse(buildPath(base, "gogs_lib"));
scope (exit) rmdirRecurse(base);
write(buildPath(base, "gogs_lib", "setup.pravic"), `
file /tmp/defer-owned { content = "from the imported file with {{ flavor }}" }
`);
write(buildPath(base, "proj", "main.pravic"), `
var flavor = "vanilla"

import ../gogs_lib { }

file /tmp/defer-entry { content = "entry" }

include gogs_lib/setup.pravic { flavor = "chocolate" }
`);

// controller-side: gogs_lib/setup.pravic does not exist in the
// project, so the include defers instead of failing to load
auto loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
assert(loaded.jobs.length == 1);            // only the entry's own job
assert(loaded.jobs[0].target == "/tmp/defer-entry");
assert(loaded.deferred.length == 1);
assert(canFind(loaded.deferred[0], "gogs_lib")
    && canFind(loaded.deferred[0], "setup.pravic"));
assert(loaded.sourceFiles.length == 1);     // the deferred file is
                                            // not read here

// with the file present under the landing, it composes normally at
// its position (that is what the on-host inner run sees)
mkdirRecurse(buildPath(base, "proj", "gogs_lib"));
write(buildPath(base, "proj", "gogs_lib", "setup.pravic"), `
file /tmp/defer-owned { content = "x" }
`);
loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
assert(loaded.deferred.length == 0);
assert(loaded.jobs.length == 2);            // own job + included job
assert(loaded.jobs[1].target == "/tmp/defer-owned");
assert(loaded.jobs[1].overlay["flavor"].str_ == "chocolate");
rmdirRecurse(buildPath(base, "proj", "gogs_lib"));

// missing and NOT under an import landing is still a load error
assertThrown!TachyError(loadTasksFile(writeTemp("defer_missing.pravic",
    "include nowhere_lib/x.pravic { }\n")));
}

unittest // import search paths: settings.pravic resolution order
{
import std.algorithm.searching : canFind;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import tachy.settings : Settings;

auto base = buildPath(tempDir, "tachy_import_search_ut");
if (exists(base)) rmdirRecurse(base);
mkdirRecurse(buildPath(base, "proj", "local_lib"));
mkdirRecurse(buildPath(base, "libs1", "found1"));
mkdirRecurse(buildPath(base, "libs2", "found2"));
scope (exit) rmdirRecurse(base);
write(buildPath(base, "proj", "main.pravic"), `
import local_lib { }
import found1 { }
import found2 { }
import nowhere { }
`);

Settings settings;
settings.importPaths ~= buildPath(base, "libs1");
settings.importPaths ~= buildPath(base, "libs2");

auto loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"),
    settings);
assert(loaded.imports.length == 4);
foreach (src; loaded.imports)
{
    // defining-relative wins even with search paths configured
    if (canFind(src, "local_lib"))
        assert(canFind(src, buildPath(base, "proj", "local_lib")), src);
    else if (canFind(src, "found1"))
        assert(canFind(src, buildPath(base, "libs1", "found1")), src);
    else if (canFind(src, "found2"))
        assert(canFind(src, buildPath(base, "libs2", "found2")), src);
    else
        // unresolved: keeps the defining-relative guess
        assert(canFind(src, buildPath(base, "proj", "nowhere")), src);
}
// without settings, keys stay defining-relative
loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
foreach (src; loaded.imports)
    assert(canFind(src, buildPath(base, "proj")), src);
}

unittest // include naming the import landing itself (a dir)
{
import std.algorithm.searching : canFind;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;

// base/proj/main.pravic imports ../nvim (a directory of tasks);
// include "nvim" names the landing itself
auto base = buildPath(tempDir, "tachy_import_dir_ut");
if (exists(base)) rmdirRecurse(base);
mkdirRecurse(buildPath(base, "proj"));
mkdirRecurse(buildPath(base, "nvim"));
scope (exit) rmdirRecurse(base);
write(buildPath(base, "nvim", "main.pravic"), `
file /tmp/direct-owned { content = "from the imported dir entry point" }
`);
write(buildPath(base, "proj", "main.pravic"), `
import ../nvim { }

file /tmp/direct-entry { content = "entry" }

include nvim { }
`);

// controller: the landing itself defers (not only paths under it)
auto loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
assert(loaded.jobs.length == 1);
assert(loaded.deferred.length == 1);
assert(canFind(loaded.deferred[0], "nvim"));
assert(canFind(loaded.deferred[0], buildPath(base, "proj")));

// host view: the landed directory composes through its main.pravic
// (entry-point convention, like a directory CLI argument)
mkdirRecurse(buildPath(base, "proj", "nvim"));
write(buildPath(base, "proj", "nvim", "main.pravic"), `
file /tmp/direct-owned { content = "x" }
`);
loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
assert(loaded.deferred.length == 0);
assert(loaded.jobs.length == 2);
assert(loaded.jobs[1].target == "/tmp/direct-owned");

// a plain (non-import) directory entry also uses its main.pravic
write(buildPath(base, "proj", "main.pravic"), "include nvim { }\n");
loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
assert(loaded.jobs.length == 1);
assert(loaded.jobs[0].target == "/tmp/direct-owned");
}

unittest // compose: wiring, order, injection and validation
{
import std.exception : assertThrown;
auto p = writeTemp("compose.pravic", `
service app { state = "started" }

compose /srv/app {
    file = "compose.yml"
    project = "myapp"
    services = ["backend", "db"]
    pull = "always"
}

check "probe" { run = "true" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 3);
assert(loaded.jobs[0].kind == "service");                    // source order
assert(loaded.jobs[1].kind == "compose" && loaded.jobs[1].moduleName == "compose");
assert(loaded.jobs[1].target == "/srv/app");                 // dir injected
assert(loaded.jobs[1].params["dir"].str_ == "/srv/app");
assert(loaded.jobs[1].params["file"].str_ == "compose.yml");
assert(loaded.jobs[1].params["project"].str_ == "myapp");
assert(loaded.jobs[1].params["services"].array_.length == 2);
assert(loaded.jobs[1].params["pull"].str_ == "always");
assert("state" !in loaded.jobs[1].params);                   // module defaults it
assert(loaded.jobs[2].kind == "check");

// duplicates are load-time errors
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_dup.pravic",
    "compose /srv/app { file = \"a.yml\" }\nvar x = 1\n"
    ~ "compose /srv/app { file = \"b.yml\" }\n")));
// the dir key is implied
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_key.pravic",
    "compose /srv/app { dir = \"/elsewhere\", file = \"a.yml\" }\n")));
// unknown attribute
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_unk.pravic",
    "compose /srv/app { file = \"a.yml\", bogus = 1 }\n")));
// file is required
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_nofile.pravic",
    "compose /srv/app { project = \"x\" }\n")));
// bad state
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_state.pravic",
    "compose /srv/app { file = \"a.yml\", state = \"paused\" }\n")));
// bad pull policy
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_pull.pravic",
    "compose /srv/app { file = \"a.yml\", pull = \"sometimes\" }\n")));
// relative dir
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_rel.pravic",
    "compose srv/app { file = \"a.yml\" }\n")));
// invalid project name
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_proj.pravic",
    "compose /srv/app { file = \"a.yml\", project = \"MyApp\" }\n")));
// services must be an array of strings
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_svcs.pravic",
    "compose /srv/app { file = \"a.yml\", services = \"web\" }\n")));
// remove_volumes only with state = "absent"
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_rv.pravic",
    "compose /srv/app { file = \"a.yml\", remove_volumes = true }\n")));
// remove_orphans only with state = "stopped"
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_ro.pravic",
    "compose /srv/app { file = \"a.yml\", remove_orphans = true }\n")));
// wait only with state = "running"
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_wait.pravic",
    "compose /srv/app { file = \"a.yml\", state = \"stopped\", wait = false }\n")));
// wait_timeout only with wait = true
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_wt.pravic",
    "compose /srv/app { file = \"a.yml\", wait = false, wait_timeout = 10 }\n")));
// non-positive timeout
assertThrown!(TachyError)(loadTasksFile(writeTemp("compose_to.pravic",
    "compose /srv/app { file = \"a.yml\", timeout = 0 }\n")));
}
