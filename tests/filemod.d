/// Tests for tachy.modules.filemod, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.filemod;

import tachy.modules.filemod;

import std.file : exists, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.file : tempDir;
import tachy.transport : LocalTransport;
import tachy.value : Val;
import tachy.modules : TaskContext;
import tachy.errors : TachyError;
import std.algorithm.searching : canFind;
import std.conv : octal;

// Tests run in parallel under the silly runner: every call gets its
// own directory (an atomically increasing suffix), so concurrent
// tests cannot delete each other's scratch tree.
string freshDir()
{
    import core.atomic : atomicFetchAdd;
    import std.conv : text;
    static shared int seq;
    auto dir = buildPath(tempDir, "tachy_filemod_ut"
        ~ text(atomicFetchAdd(seq, 1)));
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

TaskContext ctxLocal(string dir, bool check = false, Val[string] vars = null)
{
    TaskContext ctx = TaskContext(new LocalTransport, check, "localhost", dir);
    ctx.vars = vars;
    return ctx;
}

Val[string] P(string k, string v)
{
    Val[string] p;
    p[k] = Val(v);
    return p;
}

unittest // directory lifecycle: create, idempotence, mode fix, idempotence
{
import std.file : isDir;
import tachy.transport : statPath;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

auto sub = buildPath(dir, "etc/app");
Val[string] p;
p["path"] = Val(sub);
p["state"] = Val("directory");
p["mode"] = Val("0750");

auto r1 = runFileModule(p, ctx);
assert(r1.changed && isDir(sub));
auto r2 = runFileModule(p, ctx);
assert(!r2.changed, r2.msg);
assert(statPath(ctx.transport, sub).mode == octal!750);

p["mode"] = Val("0700");
auto r3 = runFileModule(p, ctx);
assert(r3.changed && statPath(ctx.transport, sub).mode == octal!700);
auto r4 = runFileModule(p, ctx);
assert(!r4.changed);
}

unittest // file content lifecycle: create, idempotence, drift, repair
{
import std.file : readText, write;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

auto f = buildPath(dir, "app.conf");
Val[string] p;
p["path"] = Val(f);
p["content"] = Val("port = 8080\n");

auto r1 = runFileModule(p, ctx);
assert(r1.changed && readText(f) == "port = 8080\n");
auto r2 = runFileModule(p, ctx);
assert(!r2.changed, r2.msg);

write(f, "port = 9090\n"); // drift
auto r3 = runFileModule(p, ctx);
assert(r3.changed && readText(f) == "port = 8080\n");

// check mode: drift is detected but not repaired
write(f, "tampered\n");
auto r4 = runFileModule(p, ctxLocal(dir, true));
assert(r4.changed && readText(f) == "tampered\n");
}

unittest // src = binary file: byte-exact copy, checksum compare, idempotent
{
import std.file : read, write;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

// Invalid UTF-8 on purpose (OpenPGP keyring-like bytes).
const ubyte[] key = cast(ubyte[]) "\x89PNG\r\n\x1a\n\xff\x00\x80\xfe binary \x93key\x94 bytes";
auto srcPath = buildPath(dir, "docker.gpg");
write(srcPath, key);

auto f = buildPath(dir, "keyring.gpg");
Val[string] p;
p["path"] = Val(f);
p["src"] = Val("docker.gpg");

auto r1 = runFileModule(p, ctx);
assert(r1.changed, r1.msg);
assert(read(f) == key, "byte-exact copy");
auto r2 = runFileModule(p, ctx);
assert(!r2.changed, r2.msg); // checksum compare, no decode

write(f, cast(ubyte[])[0x00, 0x01, 0x02]);
auto r3 = runFileModule(p, ctx);
assert(r3.changed && read(f) == key, "binary drift repaired");
}

unittest // template = <path>: render that file with the host scope
{
import std.exception : assertThrown;
import std.file : readText, write;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);

Val[string] vars;
vars["name"] = Val("web1");
vars["port"] = Val(8080L);
vars["nested"] = Val(1.5); // floats render through scalarToString
Val t;
t.kind = Val.Kind.table_;
t.table_["env"] = Val("prod");
vars["opts"] = t;
auto ctx = ctxLocal(dir, false, vars);

write(buildPath(dir, "app.tmpl"),
    "server {{ name }} : {{ port }} (env={{ opts.env }}, f={{ nested }})\n");
auto f = buildPath(dir, "app.conf");
Val[string] p;
p["path"] = Val(f);
p["template"] = Val("app.tmpl");

auto r1 = runFileModule(p, ctx);
assert(r1.changed);
assert(readText(f) == "server web1 : 8080 (env=prod, f=1.5)\n", readText(f));
assert(!runFileModule(p, ctx).changed); // idempotent against rendered form

// variable drift: same template, different scope -> rewritten
vars["name"] = Val("web2");
auto r3 = runFileModule(p, ctxLocal(dir, false, vars));
assert(r3.changed && readText(f) == "server web2 : 8080 (env=prod, f=1.5)\n");

// verbatim copy: src alone never processes {{ }}
write(buildPath(dir, "raw.src"), "literal {{ name }}\n");
Val[string] praw;
praw["path"] = Val(buildPath(dir, "raw.conf"));
praw["src"] = Val("raw.src");
runFileModule(praw, ctx);
assert(readText(buildPath(dir, "raw.conf")) == "literal {{ name }}\n");

// undefined variable in the template is a hard error naming the template
write(buildPath(dir, "bad.tmpl"), "{{ missing }}\n");
Val[string] pbad;
pbad["path"] = Val(buildPath(dir, "bad.conf"));
pbad["template"] = Val("bad.tmpl");
assertThrown!(TachyError)(runFileModule(pbad, ctx));

// missing template file is an error naming the path
Val[string] pmiss;
pmiss["path"] = Val(buildPath(dir, "miss.conf"));
pmiss["template"] = Val("nope.tmpl");
assertThrown!(TachyError)(runFileModule(pmiss, ctx));

// check mode renders and compares but does not write
write(f, "drifted\n");
auto rc = runFileModule(p, ctxLocal(dir, true, vars));
assert(rc.changed && readText(f) == "drifted\n");
}

unittest // template = <path>: combination errors
{
import std.exception : assertThrown;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

// template with src (copy and render are distinct sources)
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["src"] = Val("a");
    p["template"] = Val("b");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// template with content
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["content"] = Val("a");
    p["template"] = Val("b");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// template with line
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["template"] = Val("b");
    p["line"] = Val("a");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// template with a non-file state
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["state"] = Val("directory");
    p["template"] = Val("b");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// template with state=link
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["state"] = Val("link");
    p["src"] = Val("a");
    p["template"] = Val("b");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
}
unittest // line lifecycle: create, idempotence, append, mid-line non-match
{
import std.file : readText, write;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

auto f = buildPath(dir, "sysctl.conf");
Val[string] p;
p["path"] = Val(f);
p["line"] = Val("vm.swappiness = 10");

auto r1 = runFileModule(p, ctx);
assert(r1.changed && readText(f) == "vm.swappiness = 10\n");
assert(!runFileModule(p, ctx).changed); // idempotent

write(f, "kernel.panic = 10\n");        // line missing again
auto r3 = runFileModule(p, ctx);
assert(r3.changed && readText(f) == "kernel.panic = 10\nvm.swappiness = 10\n");
assert(!runFileModule(p, ctx).changed);

write(f, "vm.swappiness = 100\n");      // partial line is not the line
auto r4 = runFileModule(p, ctx);
assert(r4.changed && readText(f) == "vm.swappiness = 100\nvm.swappiness = 10\n");

write(f, "a");                          // no trailing newline on last line
auto r5 = runFileModule(p, ctx);
assert(r5.changed && readText(f) == "a\nvm.swappiness = 10\n");

// whole-line match without trailing newline needs no change
write(f, "vm.swappiness = 10");
assert(!runFileModule(p, ctx).changed);

// check mode: missing line is reported but not written
write(f, "other\n");
auto r7 = runFileModule(p, ctxLocal(dir, true));
assert(r7.changed && readText(f) == "other\n");
}

unittest // block lifecycle: append contiguous lines, idempotence, mid-file match
{
import std.file : readText, write;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

auto f = buildPath(dir, "fstab");
Val[string] p;
p["path"] = Val(f);
p["block"] = Val("# tachy: managed\n/tmp none none\n");

auto r1 = runFileModule(p, ctx);
assert(r1.changed && readText(f) == "# tachy: managed\n/tmp none none\n");
assert(!runFileModule(p, ctx).changed); // idempotent

write(f, "/dev/sda1 / ext4 defaults 0 1\n");
auto r3 = runFileModule(p, ctx);
assert(r3.changed
    && readText(f) == "/dev/sda1 / ext4 defaults 0 1\n# tachy: managed\n/tmp none none\n");
assert(!runFileModule(p, ctx).changed);

// block present mid-file, different context around it: no change
write(f, "before\n# tachy: managed\n/tmp none none\nafter\n");
assert(!runFileModule(p, ctx).changed);

// block without trailing newline in the param matches the same lines
write(f, "x\n# tachy: managed\n/tmp none none\n");
Val[string] p2;
p2["path"] = Val(f);
p2["block"] = Val("# tachy: managed\n/tmp none none");
assert(!runFileModule(p2, ctx).changed);

// out-of-order lines are not the block
write(f, "/tmp none none\n# tachy: managed\n");
assert(runFileModule(p2, ctx).changed);
}

unittest // state=absent
{
import std.file : exists, write;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

auto f = buildPath(dir, "junk");
write(f, "x");

Val[string] p;
p["path"] = Val(f);
p["state"] = Val("absent");

assert(runFileModule(p, ctx).changed && !exists(f));
assert(!runFileModule(p, ctx).changed);
}

unittest // symlink lifecycle
{
import std.file : symlink, readLink;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

auto link = buildPath(dir, "current");
Val[string] p;
p["path"] = Val(link);
p["state"] = Val("link");
p["src"] = Val("/usr/bin/env");

assert(runFileModule(p, ctx).changed);
assert(readLink(link) == "/usr/bin/env");
assert(!runFileModule(p, ctx).changed); // idempotent

p["src"] = Val("/bin/sh");
assert(runFileModule(p, ctx).changed && readLink(link) == "/bin/sh");
}

unittest // error cases
{
import std.exception : assertThrown;
import std.file : mkdirRecurse;
auto dir = freshDir;
scope (exit) rmdirRecurse(dir);
auto ctx = ctxLocal(dir);

auto d = buildPath(dir, "d");
mkdirRecurse(d);

// existing directory, state=file
{
    Val[string] p;
    p["path"] = Val(d);
    p["content"] = Val("x");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// content + src conflict
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["content"] = Val("x");
    p["src"] = Val("y");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// line + block conflict
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["line"] = Val("a");
    p["block"] = Val("b");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// line + content conflict
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["line"] = Val("a");
    p["content"] = Val("b");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// block + src conflict
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["block"] = Val("a\nb");
    p["src"] = Val("y");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// multi-line line
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["line"] = Val("a\nb");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// line with state=directory
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["state"] = Val("directory");
    p["line"] = Val("a");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// link without src
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["state"] = Val("link");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// invalid state value
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["state"] = Val("bogus");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}
// bad mode
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "x"));
    p["mode"] = Val("0999");
    assertThrown!(TachyError)(runFileModule(p, ctx));
}

}

unittest // check mode before creation: attrs on a suppressed creation
{
import std.file : mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;

auto dir = buildPath(tempDir, "tachy_filemod_chk_ut");
if (exists(dir)) rmdirRecurse(dir);
mkdirRecurse(dir);
scope (exit) rmdirRecurse(dir);

auto t = new LocalTransport;
TaskContext ctx = TaskContext(t, true, "h", dir, null); // check mode
const string sub = buildPath(dir, "never");

// a directory that would be created with a mode: reported as a
// would-be change, not a probe failure
{
    Val[string] p;
    p["path"] = Val(sub);
    p["state"] = Val("directory");
    p["mode"] = Val("0750");
    auto r = runFileModule(p, ctx);
    assert(r.changed, r.msg);
    assert(r.msg.canFind("created directory"), r.msg);
}
// same for a file with content + owner attrs
{
    Val[string] p;
    p["path"] = Val(buildPath(dir, "never-file"));
    p["content"] = Val("x");
    p["mode"] = Val("0600");
    auto r = runFileModule(p, ctx);
    assert(r.changed && r.msg.canFind("created file"), r.msg);
}
assert(!exists(sub));
}
