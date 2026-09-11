/// Tests for tachy.project, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.project;

import tachy.project;

import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, readText, tempDir;
import std.path : buildPath;
import std.stdio : File;
import tachy.transport : LocalTransport;
import tachy.value : parsePractic;
import tachy.errors : TachyError;
import tachy.value : Val;
import std.path : isAbsolute;

@("hostInventoryPravic round-trips through the Pravic parser")
unittest
{
    Val[string] vars;
    vars["str"] = Val("it's \"quoted\"\n");
    vars["int"] = Val(42L);
    vars["float"] = Val(1.5);
    vars["whole-float"] = Val(2.0);
    vars["bool"] = Val(true);
    Val nested;
    nested.kind = Val.Kind.table_;
    nested.table_["x"] = Val(1L);
    vars["nested"] = nested;
    Val deep;
    deep.kind = Val.Kind.table_;
    deep.table_["in"] = Val("side");
    nested.table_["deep"] = deep;
    Val arr;
    arr.kind = Val.Kind.array_;
    arr.array_ ~= Val("one");
    arr.array_ ~= Val("two");
    vars["list"] = arr;

    auto text = hostInventoryPravic("web 1", vars);
    auto doc = parsePractic(text, "generated-inventory.pravic");
    assert(doc.stmts.length == 1);
    assert(doc.stmts[0].kind == "hosts" && doc.stmts[0].key == "web 1");
    auto host = doc.stmts[0].value.table_;
    assert(host["connection"].str_ == "local");
    auto got = host["vars"].table_;
    assert(got["str"].str_ == "it's \"quoted\"\n");
    assert(got["int"].integer_ == 42);
    assert(got["float"].float_ == 1.5);
    assert(got["whole-float"].kind == Val.Kind.float_);
    assert(got["bool"].boolean_);
    assert(got["nested"].table_["x"].integer_ == 1);
    assert(got["nested"].table_["deep"].table_["in"].str_ == "side");
    assert(got["list"].array_.length == 2);
    assert(got["list"].array_[0].str_ == "one");
    assert(got["list"].array_[1].str_ == "two");
}

@("empty vars still produce a valid inventory")
unittest
{
    auto text = hostInventoryPravic("plain", null);
    auto doc = parsePractic(text, "generated-inventory.pravic");
    assert(doc.stmts[0].key == "plain");
    auto host = doc.stmts[0].value.table_;
    assert(host["connection"].str_ == "local");
    assert("vars" in host);
}

@("parseReport")
unittest
{
    ulong ok, changed, failed;
    assert(parseReport("3 2 1\n", ok, changed, failed));
    assert(ok == 3 && changed == 2 && failed == 1);
    assert(!parseReport("", ok, changed, failed));
    assert(!parseReport("1 2", ok, changed, failed));
    assert(!parseReport("1 2 x", ok, changed, failed));
    assert(!parseReport("1 2 3 4", ok, changed, failed));
}

@("deployProject + removeBundle over the local transport")
unittest
{
    auto dir = buildPath(tempDir, "tachy_project_ut", "proj");
    if (!exists(dir)) mkdirRecurse(dir);
    {
        auto f = File(buildPath(dir, "main.pravic"), "w");
        f.write("file /tmp/x { }\n");
        f.close();
    }
    if (!exists(buildPath(dir, "sub"))) mkdirRecurse(buildPath(dir, "sub"));
    {
        auto f = File(buildPath(dir, "sub", "data.txt"), "w");
        f.write("payload");
        f.close();
    }

    auto t = new LocalTransport;
    Val[string] vars;
    vars["k"] = Val("v");
    auto b = deployProject(t, dir, "h1", vars);
    scope (exit) removeBundle(t, b);

    assert(isAbsolute(b.root));
    assert(exists(buildPath(b.projectDir, "main.pravic")));
    assert(readText(buildPath(b.projectDir, "sub", "data.txt")) == "payload");
    assert(exists(b.tachyPath));
    auto inv = readText(b.inventoryPath);
    assert(canFind(inv, `connection = "local"`));
    assert(canFind(inv, `"k" = "v"`));
    assert(canFind(inv, `host "h1"`));
    auto cmd = innerTachyCommand(b, "h1", "main.pravic", true, false, true,
        buildPath(b.root, "report"));
    assert(canFind(cmd, "cd "));
    assert(canFind(cmd, " check --direct --events --color"));
    assert(canFind(cmd, "--direct-report"));
    assert(canFind(cmd, "h1"));
    assert(canFind(cmd, "'main.pravic'"));
    // without check mode the inner run uses the apply command
    cmd = innerTachyCommand(b, "h1", "main.pravic", false, false, false,
        buildPath(b.root, "report"));
    assert(canFind(cmd, " apply --direct --events"));
    assert(!canFind(cmd, " check"));
    assert(!canFind(cmd, " --check"));
}

@("imports are copied into the bundle; collisions are errors")
unittest
{
import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.path : baseName, buildPath;

auto base = buildPath(tempDir, "tachy_project_import_ut");
if (exists(base)) rmdirRecurse(base);
mkdirRecurse(buildPath(base, "proj"));
mkdirRecurse(buildPath(base, "tasks", "install_gogs"));
mkdirRecurse(buildPath(base, "shared"));
scope (exit) rmdirRecurse(base);
{
    import std.stdio : File;
    auto f = File(buildPath(base, "proj", "main.pravic"), "w");
    f.write("file /tmp/x { }\n");
    f = File(buildPath(base, "tasks", "install_gogs", "setup.sh"), "w");
    f.write("#!/bin/sh\necho gogs\n");
    f.close();
    f = File(buildPath(base, "shared", "data.conf"), "w");
    f.write("key = value\n");
    f.close();
    // collides with the import destination below
    f = File(buildPath(base, "proj", "clash"), "w");
    f.write("project content\n");
    f.close();
}

const string proj = buildPath(base, "proj");
const string gogs = buildPath(base, "tasks", "install_gogs");
const string sharedDir = buildPath(base, "shared");

auto t = new LocalTransport;
ImportSpec[] imports = [ImportSpec(gogs, baseName(gogs)),
    ImportSpec(sharedDir, baseName(sharedDir))];
auto b = deployProject(t, proj, "h1", null, imports);
scope (exit) removeBundle(t, b);

assert(readText(buildPath(b.projectDir, "install_gogs", "setup.sh"))
    .canFind("gogs"));
assert(readText(buildPath(b.projectDir, "shared", "data.conf"))
    .canFind("key = value"));
assert(exists(buildPath(b.projectDir, "main.pravic")));

// missing source
assertThrown!TachyError(deployProject(t, proj, "h1", null,
    [ImportSpec(buildPath(base, "nope"), "nope")]));

// destination clashing with project content
assertThrown!TachyError(deployProject(t, proj, "h1", null,
    [ImportSpec(buildPath(base, "tasks"), "clash")]));

// two imports with the same destination
assertThrown!TachyError(deployProject(t, proj, "h1", null,
    [ImportSpec(gogs, "same"), ImportSpec(sharedDir, "same")]));
}
