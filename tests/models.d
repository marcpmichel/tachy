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

@("both statement forms, param injection, defaults")
unittest
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

@("ensure: name injection, source order, validation")
unittest
{
import std.exception : assertThrown;
auto p = writeTemp("ensure.pravic", `
ensure "probe thing" {
    run = "true"
    exit_status = { not = 1 }
}

file /tmp/x { mode = "0400" }

ensure "check os" { run = "echo debian", exit_status = 0, output = "debian" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 3);
// statement order: probe thing first, file between, check os last
assert(loaded.jobs[0].target == "probe thing");
assert(loaded.jobs[1].kind == "file");
assert(loaded.jobs[2].kind == "ensure" && loaded.jobs[2].target == "check os");
assert(loaded.jobs[2].moduleName == "ensure");
assert(loaded.jobs[2].params["name"].str_ == "check os");    // injected
assert("exit_status" in loaded.jobs[0].params);

// duplicate ensure names are a load-time error (single + group form)
assertThrown!(TachyError)(loadTasksFile(writeTemp("ensure_dup.pravic",
    "ensure \"same\" { run = \"false\" }\nvar x = 1\n"
    ~ "ensure \"same\" { run = \"true\" }\n")));
// missing run
assertThrown!(TachyError)(loadTasksFile(writeTemp("ensure_norun.pravic",
    "ensure \"x\" { output = \"y\" }\n")));
// unknown attribute
assertThrown!(TachyError)(loadTasksFile(writeTemp("ensure_unk.pravic",
    "ensure \"x\" { run = \"true\", bogus = 1 }\n")));
// bad exit_status shape
assertThrown!(TachyError)(loadTasksFile(writeTemp("ensure_bad.pravic",
    "ensure \"x\" { run = \"true\", exit_status = \"0\" }\n")));
}

@("source order: no fixed order, no sorting")
unittest
{
auto p = writeTemp("order.pravic", `
file /srv/tree/leaf.conf { content = "x" }

ensure "leaf exists" { run = "test -f /srv/tree/leaf.conf" }

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
    "ensure leaf exists",
    "directory /srv/tree",
    "service ssh",
    "directory /srv/other",
], order.join(", "));
}

@("groups and users: statement order, validation")
unittest
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

@("apply: vars = { ... } sub-table binding")
unittest
{
import std.exception : assertThrown;
writeTemp("ap_files.pravic", `
file /tmp/ap-file { content = "{{ three }} {{ direct }} {{ nested.tbl.x }}" }
`);
auto p = writeTemp("ap_main.pravic", `
apply "ap_files.pravic" {
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
apply "ap_files.pravic" {
    vars { three = "a" }
    three = "b"
}
`)));
// non-table vars
assertThrown!(TachyError)(loadTasksFile(writeTemp("ap_bad.pravic", `
apply "ap_files.pravic" { vars = "nope" }
`)));
}

@("apply bindings resolve { run } / { env } markers at load")
unittest
{
import std.algorithm.searching : canFind;

// the reported shape: a run marker nested in the vars sub-table
writeTemp("ab_child.pravic", `
file /tmp/ab.conf { content = "{{ system.kernel }}" }
`);
auto loaded = loadTasksFile(writeTemp("ab_main.pravic", `
apply "ab_child.pravic" {
    vars = { system = { kernel = { run = "echo 6.1.0-tachy" } } }
}
`));
assert(loaded.jobs[0].overlay["system"].table_["kernel"].str_
    == "6.1.0-tachy", "run marker resolved in the binding, nested walked");

// direct entry-key bindings resolve too, and the resolved values flow
// forward to statements after the apply
loaded = loadTasksFile(writeTemp("ab_direct.pravic", `
apply "ab_child.pravic" { system = { kernel = { run = "echo direct" } } }

file /tmp/after { content = "{{ system.kernel }}" }
`));
assert(loaded.jobs[0].overlay["system"].table_["kernel"].str_ == "direct");
assert(loaded.jobs[1].overlay["system"].table_["kernel"].str_ == "direct");

// env markers read the loading process's environment
loaded = loadTasksFile(writeTemp("ab_env.pravic", `
apply "ab_child.pravic" { path_var = { env = "PATH" } }
`));
assert(loaded.jobs[0].overlay["path_var"].str_.length > 0);

// age markers are rejected: tasks-file bindings hold no identity
string msg;
try
{
    loadTasksFile(writeTemp("ab_age.pravic", `
apply "ab_child.pravic" { s = { age = "f.age" } }
`));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "only supported in inventory"), msg);

// a failing command fails the load before the child is read
try
{
    loadTasksFile(writeTemp("ab_fail.pravic", `
apply "ab_child.pravic" { k = { run = "exit 9" } }
`));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "ab_fail.pravic: vars.k"), msg);
assert(canFind(msg, "exit status 9"), msg);
}

@("applies: position, var layering, path resolution")
unittest
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

apply "one.pravic" { override_me = "one" }

apply "two.pravic" { extra = "e" }

file /tmp/top { mode = "0400" }
`);
auto loaded = loadTasksFile(p);
// applies compose at their position, then the applier's own jobs
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

// overlay: outer vars < apply vars < applied file's own vars
assert(loaded.jobs[0].overlay["top"].str_ == "yes");          // outer visible
assert(loaded.jobs[0].overlay["override_me"].str_ == "one");  // apply var wins
assert(loaded.jobs[0].overlay["from_one"].str_ == "1");       // own vars of one.pravic
assert(loaded.jobs[1].overlay["extra"].str_ == "e");

// flow-through: statements after the applies see everything the
// applies contributed (child vars and bindings).
assert(loaded.jobs[2].overlay["top"].str_ == "yes");
assert(loaded.jobs[2].overlay["from_one"].str_ == "1");       // flowed from one.pravic
assert(loaded.jobs[2].overlay["extra"].str_ == "e");          // flowed from apply vars
assert(loaded.jobs[2].overlay["override_me"].str_ == "one");  // last apply wins
}

@("a statement before an apply does not see its contribution")
unittest
{
writeTemp("post.pravic", `
var from_post = "p"
file /tmp/post { mode = "0400" }
`);
auto p = writeTemp("ordered.pravic", `
var top = "yes"

file /tmp/own { mode = "0400" }

apply "post.pravic" { post_var = "pt" }

file /tmp/after { mode = "0400" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 3);
assert(loaded.jobs[0].target == "/tmp/own");
assert(loaded.jobs[1].target == "/tmp/post");
assert(loaded.jobs[2].target == "/tmp/after");

// the statement before the apply sees only outer + own vars
assert(loaded.jobs[0].overlay["top"].str_ == "yes");
assert("from_post" !in loaded.jobs[0].overlay);
// the apply keeps binding semantics for its subtree
assert(loaded.jobs[1].overlay["post_var"].str_ == "pt");
assert(loaded.jobs[1].overlay["from_post"].str_ == "p");
// statements after it see the flowed-forward scope
assert(loaded.jobs[2].overlay["from_post"].str_ == "p");

// apply participates in duplicate-target and cycle detection
writeTemp("dup_apply_inc.pravic", "file /tmp/x { mode = \"0600\" }\n");
assertThrown!(TachyError)(loadTasksFile(writeTemp("dup_inc.pravic",
    "file /tmp/x { mode = \"0644\" }\napply \"dup_apply_inc.pravic\" { }\n")));
writeTemp("cyc_a.pravic", "apply \"cyc_b.pravic\" { }\n");
writeTemp("cyc_b.pravic", "apply \"cyc_a.pravic\" { }\n");
assertThrown!(TachyError)(loadTasksFile(buildPath(
    dirName(writeTemp("cyc_seed.pravic", "")), "cyc_a.pravic")));
}

@("errors")
unittest
{
import std.exception : assertThrown;
// duplicate target across files
writeTemp("dup_inc.pravic", "file /tmp/x { mode = \"0600\" }\n");
assertThrown!(TachyError)(loadTasksFile(writeTemp("dup.pravic",
    "apply \"dup_inc.pravic\" { }\nfile /tmp/x { mode = \"0644\" }\n")));
// duplicate between files and directories
assertThrown!(TachyError)(loadTasksFile(writeTemp("dup2.pravic",
    "file /tmp/x { mode = \"0600\" }\ndirectory /tmp/x { mode = \"0700\" }\n")));
// apply cycle
writeTemp("cy_a.pravic", "apply \"cy_b.pravic\" { }\n");
writeTemp("cy_b.pravic", "apply \"cy_a.pravic\" { }\n");
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

@("file: local vars for the template, validated at load time")
unittest
{
import std.algorithm.searching : canFind;
import tachy.value : Val;

// vars + template loads and reaches the module as a param table
auto loaded = loadTasksFile(writeTemp("file_vars.pravic", `
file /tmp/app.conf {
    template = "app.conf.tmpl"
    vars { env = "prod", ttl = 3600 }
}
`));
assert(loaded.jobs.length == 1);
auto v = loaded.jobs[0].params["vars"];
assert(v.kind == Val.Kind.table_);
assert(v.table_["env"].str_ == "prod");
assert(v.table_["ttl"].integer_ == 3600);

// vars without template is rejected, whatever the other source
foreach (t; ["file /tmp/x { vars { a = 1 } }\n",
    "file /tmp/x { content = \"c\", vars { a = 1 } }\n",
    "file /tmp/x { src = \"s\", vars { a = 1 } }\n"])
{
    string msg;
    try { loadTasksFile(writeTemp("file_vars_alone.pravic", t)); assert(false); }
    catch (TachyError e) { msg = e.msg; }
    assert(canFind(msg, "'vars' is only meaningful with 'template'"), msg);
}

// non-table vars is a type error
string msg;
try { loadTasksFile(writeTemp("file_vars_bad.pravic",
    "file /tmp/x { template = \"t\", vars = \"nope\" }\n")); assert(false); }
catch (TachyError e) { msg = e.msg; }
assert(canFind(msg, "'vars' must be a table"), msg);
}

@("file/service local vars resolve { run } / { env } markers at load")
unittest
{
import tachy.value : Val;
import std.algorithm.searching : canFind;

// the reported shape: a run marker nested inside the local vars table
auto loaded = loadTasksFile(writeTemp("file_vars_run.pravic", `
file /tmp/app.conf {
    template = "app.tmpl"
    vars { myservice = { host = { run = "echo myhost" } } }
}
`));
auto v = loaded.jobs[0].params["vars"];
assert(v.table_["myservice"].table_["host"].str_ == "myhost",
    "run marker resolved at load, nested tables walked");

// env markers read the loading process's environment, like file vars
auto lsvc = loadTasksFile(writeTemp("svc_vars_env.pravic", `
service app {
    template = "app.service.tmpl"
    vars { path_var = { env = "PATH" } }
}
`));
assert(lsvc.jobs[0].params["vars"].table_["path_var"].str_.length > 0);

// age markers are rejected (tasks-file vars hold no identity)
string msg;
try
{
    loadTasksFile(writeTemp("file_vars_age.pravic", `
file /tmp/x { template = "t", vars { s = { age = "f.age" } } }
`));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "only supported in inventory"), msg);

// a failing command is a load-time error naming file and variable
try
{
    loadTasksFile(writeTemp("file_vars_runfail.pravic", `
file /tmp/x { template = "t", vars { h = { run = "exit 4" } } }
`));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "file_vars_runfail.pravic: vars.h"), msg);
assert(canFind(msg, "exit status 4"), msg);
}

@("tasks-file vars may read the environment")
unittest
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

@("vars { env, from } reads a dotenv file next to the file")
unittest
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

@("vars { run } captures a command's output at load time")
unittest
{
import tachy.vars : renderParams;
import std.algorithm.searching : canFind;

const string p = writeTemp("runvars.pravic", `
vars {
    ip = { run = "echo 192.0.2.10" },
    errv = { run = "printf bad >&2", stream = "stderr" },
}

file /tmp/hosts.conf { content = "{{ ip }} {{ errv }}\n" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 1);
assert(loaded.jobs[0].overlay["ip"].str_ == "192.0.2.10"); // stdout, trimmed
assert(loaded.jobs[0].overlay["errv"].str_ == "bad");      // stderr stream
auto params = renderParams(loaded.jobs[0].params, loaded.jobs[0].overlay);
assert(params["content"].str_ == "192.0.2.10 bad\n");

// a failing command is a load-time error naming the file and variable
string msg;
try
{
    loadTasksFile(writeTemp("runvars_fail.pravic",
        "var x = { run = \"exit 7\" }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "runvars_fail.pravic: vars.x"), msg);
assert(canFind(msg, "exit status 7"), msg);

// run does not combine with the env family
try
{
    loadTasksFile(writeTemp("runvars_combo.pravic",
        `var x = { run = "true", env = "PATH" }` ~ "\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    assert(canFind(e.msg, "'run' cannot be combined"), e.msg);
}

@("vars { age } is rejected in tasks files: decryption is controller-side")
unittest
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

@("services with src / template / vars (unit file management)")
unittest
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

@("import: collection, errors, direct-mode tolerance")
unittest
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

// the same source imported by an applied file deduplicates
writeTemp("imp_inner.pravic", "import \"../imp_data\" { }\n");
loaded = loadTasksFile(writeTemp("imp_across.pravic",
    "import \"../imp_data\" { }\napply \"imp_inner.pravic\" { }\n"));
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

@("composition into an import destination: deferral")
unittest
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

apply gogs_lib/setup.pravic { flavor = "chocolate" }
`);

// project, so the apply defers instead of failing to load
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
assert(loaded.jobs.length == 2);            // own job + applied job
assert(loaded.jobs[1].target == "/tmp/defer-owned");
assert(loaded.jobs[1].overlay["flavor"].str_ == "chocolate");
rmdirRecurse(buildPath(base, "proj", "gogs_lib"));

// missing and NOT under an import landing is still a load error
assertThrown!TachyError(loadTasksFile(writeTemp("defer_missing.pravic",
    "apply nowhere_lib/x.pravic { }\n")));
}

@("import search paths: config.pravic resolution order")
unittest
{
import std.algorithm.searching : canFind;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import tachy.config : Config;

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

Config cfg;
cfg.importPaths ~= buildPath(base, "libs1");
cfg.importPaths ~= buildPath(base, "libs2");

auto loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"),
    cfg);
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
// without config, keys stay defining-relative
loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
foreach (src; loaded.imports)
    assert(canFind(src, buildPath(base, "proj")), src);
}

@("apply naming the import landing itself (a dir)")
unittest
{
import std.algorithm.searching : canFind;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;

// base/proj/main.pravic imports ../nvim (a directory of tasks);
// apply "nvim" names the landing itself
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

apply nvim { }
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
write(buildPath(base, "proj", "main.pravic"), "apply nvim { }\n");
loaded = loadTasksFile(buildPath(base, "proj", "main.pravic"));
assert(loaded.jobs.length == 1);
assert(loaded.jobs[0].target == "/tmp/direct-owned");
}

@("compose: wiring, order, injection and validation")
unittest
{
import std.exception : assertThrown;
auto p = writeTemp("stack.pravic", `
service app { state = "started" }

compose /srv/app {
    file = "compose.yml"
    project = "myapp"
    services = ["backend", "db"]
    pull = "always"
}

ensure "probe" { run = "true" }
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
assert(loaded.jobs[2].kind == "ensure");

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

@("file age = true: load-time validation")
unittest
{
import tachy.value : Val;
// the boolean marks src as age-encrypted and rides along as a param
auto p = writeTemp("age_ok.pravic", `
file /etc/tls/tls.key {
    src = "secrets/tls.key.age"
    age = true
    mode = "0600"
}
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 1);
assert(loaded.jobs[0].params["age"].kind == Val.Kind.boolean_);
assert(loaded.jobs[0].params["age"].boolean_);
assert(loaded.jobs[0].params["src"].str_ == "secrets/tls.key.age");

// age without src
{
    auto q = writeTemp("age_nosrc.pravic", `
file /tmp/x { age = true }
`);
    string msg;
    try
    {
        loadTasksFile(q);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("'age' requires 'src'") >= 0, msg);
}
// non-boolean age
{
    auto q = writeTemp("age_str.pravic", `
file /tmp/x { src = "a.age", age = "yes" }
`);
    string msg;
    try
    {
        loadTasksFile(q);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("'age' must be a boolean") >= 0, msg);
}
// false needs no src and changes nothing
{
    auto q = writeTemp("age_false.pravic", `
file /tmp/x { age = false }
`);
    auto l2 = loadTasksFile(q);
    assert(l2.jobs.length == 1 && !l2.jobs[0].params["age"].boolean_);
}
}

@("probe: url injection, wiring, load-time errors")
unittest
{
import tachy.value : Val;
auto p = writeTemp("probe.pravic", `
probe "http://localhost:9/h" {
    type = "POST"
    headers = ["X-T=1"]
    data = "{}"
    code = 201
    output = { contains = "ok" }
    timeout = 2
}

ensure "after" { run = "true" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 2);
assert(loaded.jobs[0].kind == "probe" && loaded.jobs[0].moduleName == "probe");
assert(loaded.jobs[0].target == "http://localhost:9/h");
assert(loaded.jobs[0].params["url"].str_ == "http://localhost:9/h");
assert(loaded.jobs[0].params["type"].str_ == "POST");
assert(loaded.jobs[0].params["headers"].kind == Val.Kind.array_);
assert(loaded.jobs[0].params["code"].integer_ == 201);
assert(loaded.jobs[0].params["timeout"].integer_ == 2);
assert(loaded.jobs[1].kind == "ensure"); // source order

// unknown key is a load-time error
{
    auto q = writeTemp("probe_bad.pravic", `
probe "http://x/" { verb = "GET" }
`);
    string msg;
    try
    {
        loadTasksFile(q);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("unknown key 'verb'") >= 0, msg);
}
// the statement key is the url: setting it by hand is an error
{
    auto q = writeTemp("probe_url.pravic", `
probe "http://x/" { url = "http://y/" }
`);
    string msg;
    try
    {
        loadTasksFile(q);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("'url' is implied by the statement key") >= 0, msg);
}
// duplicate targets across a composition (the same file twice over is a
// parser duplicate error, like every directive)
{
    writeTemp("probe_inner.pravic", `
probe "http://x/a" { }
`);
    auto q = writeTemp("probe_dup.pravic", `
apply "probe_inner.pravic" { }
probe "http://x/a" { }
`);
    string msg;
    try
    {
        loadTasksFile(q);
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("already managed") >= 0, msg);
}
}

@("repo: statement wiring, path injection, load-time errors")
unittest
{
import tachy.value : Val;
auto p = writeTemp("repo.pravic", `
repo /srv/app {
    type = "git"
    url = "git@example.com/me/app.git"
    branch = "main"
}

ensure "after" { run = "true" }
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 2);
assert(loaded.jobs[0].kind == "repo" && loaded.jobs[0].moduleName == "repo");
assert(loaded.jobs[0].target == "/srv/app");
assert(loaded.jobs[0].params["path"].str_ == "/srv/app");
assert(loaded.jobs[0].params["url"].str_ == "git@example.com/me/app.git");
assert(loaded.jobs[0].params["branch"].str_ == "main");
assert(loaded.jobs[1].kind == "ensure"); // source order

// the group form composes the same jobs
loaded = loadTasksFile(writeTemp("repo_group.pravic", `
repos {
    /srv/one { url = "git@example.com/one.git" }
    /srv/two { url = "git@example.com/two.git", tag = "v1" }
}
`));
assert(loaded.jobs.length == 2);
assert(loaded.jobs[0].kind == "repo" && loaded.jobs[0].target == "/srv/one");
assert(loaded.jobs[0].params["path"].str_ == "/srv/one");
assert(loaded.jobs[1].target == "/srv/two"
    && loaded.jobs[1].params["tag"].str_ == "v1");

// the statement key is the path: setting it by hand is an error
{
    string msg;
    try
    {
        loadTasksFile(writeTemp("repo_key.pravic",
            "repo /srv/app { url = \"u\", path = \"/elsewhere\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("'path' is implied by the statement key") >= 0, msg);
}
// url is required
{
    string msg;
    try
    {
        loadTasksFile(writeTemp("repo_nourl.pravic",
            "repo /srv/app { branch = \"main\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("'url' is required") >= 0, msg);
}
// branch and tag are mutually exclusive
{
    string msg;
    try
    {
        loadTasksFile(writeTemp("repo_both.pravic",
            "repo /srv/app { url = \"u\", branch = \"a\", tag = \"v1\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("mutually exclusive") >= 0, msg);
}
// only git exists (literal values are checked at load time)
{
    string msg;
    try
    {
        loadTasksFile(writeTemp("repo_type.pravic",
            "repo /srv/app { url = \"u\", type = \"hg\" }\n"));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("unsupported repository type 'hg'") >= 0, msg);
}
// a templated type defers to run time (params render per host later)
{
    auto q = writeTemp("repo_tmpl.pravic",
        "var t = \"git\"\nrepo /srv/app { url = \"u\", type = \"{{ t }}\" }\n");
    auto l = loadTasksFile(q);
    assert(l.jobs.length == 1 && l.jobs[0].params["type"].str_ == "{{ t }}");
}
// non-string url
assertThrown!(TachyError)(loadTasksFile(writeTemp("repo_int.pravic",
    "repo /srv/app { url = 7 }\n")));
// duplicate repositories across a composition
{
    writeTemp("repo_inner.pravic", "repo /srv/app { url = \"u\" }\n");
    string msg;
    try
    {
        loadTasksFile(writeTemp("repo_dup.pravic", `
apply "repo_inner.pravic" { }
repo /srv/app { url = "u" }
`));
        assert(false, "expected TachyError");
    }
    catch (TachyError e)
        msg = e.msg;
    assert(msg.indexOf("repository '/srv/app' is already managed") >= 0, msg);
}
}

@("assert: name injection, both forms, load-time validation")
unittest
{
auto p = writeTemp("assert.pravic", `
assert "one" {
    value = "{{ v }}"
    equals = "x"
}
asserts {
    "two" = { value = "b", contains = "b" }
}
`);
auto loaded = loadTasksFile(p);
assert(loaded.jobs.length == 2);
assert(loaded.jobs[0].kind == "assert" && loaded.jobs[0].moduleName == "assert");
assert(loaded.jobs[0].target == "one");
assert(loaded.jobs[0].params["name"].str_ == "one");        // injected
assert(loaded.jobs[0].params["value"].str_ == "{{ v }}");   // rendered per host later
assert(loaded.jobs[1].target == "two");
assert(loaded.jobs[1].params["contains"].str_ == "b");

// the same assertion name through both spellings is a load-time error
assertThrown!(TachyError)(loadTasksFile(writeTemp("assert_dup.pravic",
    `assert "same" { value = "a", equals = "a" }` ~ "\n"
    ~ `asserts { "same" = { value = "b", equals = "b" } }` ~ "\n")));
// missing value
assertThrown!(TachyError)(loadTasksFile(writeTemp("assert_novalue.pravic",
    `assert "x" { equals = "y" }` ~ "\n")));
// no expectation at all
assertThrown!(TachyError)(loadTasksFile(writeTemp("assert_noexp.pravic",
    `assert "x" { value = "y" }` ~ "\n")));
// unknown attribute
assertThrown!(TachyError)(loadTasksFile(writeTemp("assert_unk.pravic",
    `assert "x" { value = "y", bogus = 1 }` ~ "\n")));
// a bad regex compiles at load
assertThrown!(TachyError)(loadTasksFile(writeTemp("assert_regex.pravic",
    `assert "x" { value = "y", matches = "(" }` ~ "\n")));
}
