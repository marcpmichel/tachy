/// Tests for tachy.inventory, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.inventory;

import tachy.inventory;

import std.file : exists, mkdirRecurse;
import std.path : buildPath;
import std.file : tempDir;
import std.stdio : File;
import tachy.errors : TachyError;

string writeTemp(string name, string content)
{
    auto dir = tempDir ~ "/tachy_inventory_ut";
    if (!exists(dir)) mkdirRecurse(dir);
    auto p = buildPath(dir, name);
    auto f = File(p, "w");
    f.write(content);
    f.close();
    return p;
}

@("hosts, tags, selection, vars precedence")
unittest
{
auto inv = Inventory.load(writeTemp("basic.pravic", `
var admin = "root"

host web1 {
    address = "10.0.0.1"
    tags = ["web", "front"]
    vars { http_port = 81 }
}

host web2 {
    address = "10.0.0.2"
    tags = ["web"]
    vars { http_port = 82 }
}

host buildbox {
    connection = "local"
}
`));

assert(inv.select("web1").length == 1);
assert(inv.select("web1")[0].address == "10.0.0.1");

auto web = inv.select("@web");
assert(web.length == 2);
assert(web[0].name == "web1" && web[1].name == "web2"); // sorted

assert(inv.select("web1,@web").length == 2);            // union, deduped
assert(inv.select("all").length == 3);
assert(inv.select("@front")[0].name == "web1");
assert(inv.select("@front,buildbox").length == 2);      // mixed host + tag

auto vars1 = inv.varsFor("web1");
assert(vars1["inventory_hostname"].str_ == "web1");
assert(vars1["admin"].str_ == "root");                  // global var
assert(vars1["http_port"].integer_ == 81);              // host var wins
}

@("vars may read the environment: { env = \"NAME\" }")
unittest
{
import std.exception : assertThrown;
import std.process : environment;
environment["TACHY_UT_INV"] = "inv-value";

auto inv = Inventory.load(writeTemp("env.pravic", `
var token = { env = "TACHY_UT_INV" }

host web1 {
    vars {
        secret = { env = "TACHY_UT_INV" }
        plain = "literal"
    }
}
`));

auto vars = inv.varsFor("web1");
assert(vars["token"].str_ == "inv-value");   // global, controller env
assert(vars["secret"].str_ == "inv-value");  // host var
assert(vars["plain"].str_ == "literal");

// unset environment variable is a load-time error with context
string msg;
try
{
    Inventory.load(writeTemp("env_missing.pravic",
        "var x = { env = \"TACHY_UT_INV_NOPE\" }\nhost a { }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
import std.algorithm.searching : canFind;
assert(canFind(msg, "vars.x"));
assert(canFind(msg, "TACHY_UT_INV_NOPE"));
}

@("vars may read a dotenv file: { env, from }")
unittest
{
import std.algorithm.searching : canFind;
import std.process : environment;
environment["TACHY_UT_INV"] = "inv-value"; // 'from' must ignore this

writeTemp("inv.env", "TACHY_UT_INV=dotenv-value\nTACHY_UT_EMPTY=\n");
auto inv = Inventory.load(writeTemp("envfrom.pravic", `
var token = { env = "TACHY_UT_INV", from = "inv.env" }

host web1 {
    vars {
        secret = { env = "TACHY_UT_INV", from = "inv.env" }
        fallback = { env = "TACHY_UT_ABSENT", from = "inv.env", default = "fb" }
        empty = { env = "TACHY_UT_EMPTY", from = "inv.env" }
    }
}
`));

auto vars = inv.varsFor("web1");
assert(vars["token"].str_ == "dotenv-value");
assert(vars["secret"].str_ == "dotenv-value");
assert(vars["fallback"].str_ == "fb");       // default covers a missing key
assert(vars["empty"].str_.length == 0);      // empty value is a value

// a missing dotenv file is a load-time error
string msg;
try
{
    Inventory.load(writeTemp("envfrom_missing.pravic",
        "var x = { env = \"K\", from = \"nope.env\" }\nhost a { }\n"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "cannot read dotenv file"));
}

@("vars may be age-encrypted: { age } (controller side)")
unittest
{
import std.algorithm.searching : canFind;
import std.file : tempDir;
import std.path : buildPath;
import tachy.vars : AgeIdentity, ageDecrypt;


writeTemp("db.age", "ciphertext\n");
writeTemp("age_id.txt", "# identity\n");

auto saved = ageDecrypt;
scope (exit) ageDecrypt = saved;
ageDecrypt = (string agePath, in AgeIdentity identity, string where)
{
    return "inventory-secret\n";
};

auto inv = Inventory.load(writeTemp("agevars.pravic", `
var db_password = { age = "db.age" }

host web1 {
    vars {
        token = { age = "db.age" }
        plain = "literal"
    }
}
`), buildPath(tempDir, "tachy_inventory_ut", "age_id.txt"));

auto vars = inv.varsFor("web1");
assert(vars["db_password"].str_ == "inventory-secret"); // global
assert(vars["token"].str_ == "inventory-secret");       // host var
assert(vars["plain"].str_ == "literal");

// a failing decryption is a load-time error with context
ageDecrypt = (string agePath, in AgeIdentity identity, string where)
{
    throw new TachyError("no identity matched");
};
string msg;
try
{
    Inventory.load(writeTemp("agevars_bad.pravic",
        "var x = { age = \"db.age\" }\nhost a { }\n"),
        buildPath(tempDir, "tachy_inventory_ut", "age_id.txt"));
    assert(false, "expected TachyError");
}
catch (TachyError e)
    msg = e.msg;
assert(canFind(msg, "vars.x"), msg);
assert(canFind(msg, "no identity matched"), msg);
}

@("both host spellings, group form, validation errors")
unittest
{
import std.exception : assertThrown;
auto inv = Inventory.load(writeTemp("forms.pravic", `
hosts {
    a {
        tags = ["x"]
    }
    b { }
}
`));
assert(inv.select("a")[0].tags == ["x"]);
assert(inv.select("b").length == 1);

assertThrown!(TachyError)(Inventory.load(writeTemp("err_empty.pravic", ""))); // no hosts
assertThrown!(TachyError)(Inventory.load(writeTemp("err1b.pravic",
    "host a { unknown = 1 }\n")));
assertThrown!(TachyError)(Inventory.load(writeTemp("err2.pravic",
    "host a { tags = \"not-an-array\" }\n")));
assertThrown!(TachyError)(Inventory.load(writeTemp("err3.pravic",
    "group g { }\n"))); // directives of other file kinds
assertThrown!(TachyError)(Inventory.load(writeTemp("err4.pravic",
    "file /tmp/x { }\n")));

auto ok = Inventory.load(writeTemp("ok.pravic",
    "host a { tags = [\"x\"] }\n"));
assertThrown!(TachyError)(ok.select("nope"));   // unknown host
assertThrown!(TachyError)(ok.select("@nope"));  // unknown tag
assertThrown!(TachyError)(ok.select("@"));      // empty tag
}
