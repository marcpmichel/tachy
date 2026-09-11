/// Tests for tachy.events, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.events;

import tachy.events;

import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import std.array;
import tachy.errors : TachyError;

private string[] rendered(JobEvent[] events, bool tty = false, bool verbose = false)
{
    string[] lines;
    auto r = TextRenderer((string l) { lines ~= l[0 .. $ - 1]; }, tty, verbose);
    foreach (ev; events)
        r.handle(ev);
    return lines;
}

@("renderer: exact classic output")
unittest
{
    auto lines = rendered([
        evFileStart("main.toml", ["localhost"]),
        evJob("localhost", "main.toml", "file /tmp/x", "changed", "created file"),
        evJob("localhost", "main.toml", "execute say hi", "ok", "exit 0",
            ["cmd: echo hi", "out: hi"]),
        evJob("localhost", "main.toml", `main.toml: execute "boom"`, "failed",
            "exit status 3, expected 0"),
        evFileDone("main.toml", 1, 1, 1, false),
    ]);
    assert(lines.length == 5, lines.join("\n"));
    assert(lines[0] == "== main.toml | hosts: localhost");
    assert(lines[1] == "localhost | changed         | file /tmp/x: created file", lines[1]);
    assert(lines[2] == "localhost | ok              | execute say hi: exit 0", lines[2]);
    // details only under -v (not here)
    assert(lines[3] == `localhost | failed          | main.toml: execute "boom": exit status 3, expected 0`, lines[3]);
    assert(lines[4] == "-- main.toml: ok=1 changed=1 failed=1", lines[4]);

    // name padding: widest host pads the others
    auto multi = rendered([
        evFileStart("f.toml", ["web1", "longhost"]),
        evJob("web1", "f.toml", "service ssh", "ok", "up to date"),
    ]);
    assert(multi[1] == "web1     | ok              | service ssh: up to date", multi[1]);
}

@("renderer: verbose details, check suffix, colors")
unittest
{
    auto lines = rendered([
        evFileStart("f.toml", ["h"]),
        evJob("h", "f.toml", "l", "ok", "m", ["cmd: x", "detail y"]),
    ], false, true);
    assert(lines[2] == "    cmd: x", lines[2]);
    assert(lines[3] == "    detail y", lines[3]);

    auto done = rendered([evFileDone("f.toml", 0, 0, 0, true)]);
    assert(done[0] == "-- f.toml: ok=0 changed=0 failed=0 (check mode, nothing applied)", done[0]);

    auto colored = rendered([evJob("h", "f", "l", "failed", "m")], true);
    assert(canFind(colored[0], "\033[31m"), colored[0]);
    assert(canFind(colored[0], "\033[0m"));
    auto coloredChk = rendered([evJob("h", "f", "l", "changed (check)", "m")], true);
    assert(canFind(coloredChk[0], "\033[33m"), coloredChk[0]);
}

@("foldCounters")
unittest
{
    ulong ok, changed, failed;
    foreach (ev; [
        evJob("h", "f", "l", "ok", "m"),
        evJob("h", "f", "l", "changed", "m"),
        evJob("h", "f", "l", "changed (check)", "m"),
        evJob("h", "f", "l", "failed", "m"),
        evFileDone("f", 9, 9, 9, false), // not folded
    ])
        foldCounters(ev, ok, changed, failed);
    assert(ok == 1 && changed == 2 && failed == 1);
}

@("eventLine/parseEventLine round trip, incl. escaping")
unittest
{
    JobEvent[] events = [
        evFileStart("main.toml", ["web1", "web2"]),
        evJob("web1", "main.toml", `file "/tmp/a "b\"`, "changed (check)",
            "line1\nline2\ttab \\ back", ["det\"ail", "d2"], 4242),
        evFileDone("main.toml", 3, 2, 1, true),
    ];
    foreach (ref const ev; events)
    {
        const string line = eventLine(ev);
        assert(!canFind(line, "\n") || canFind(line, "\\n"), line); // one line
        JobEvent back;
        assert(parseEventLine(line, back));
        assert(back.kind == ev.kind);
        assert(back.file == ev.file && back.host == ev.host);
        assert(back.label == ev.label && back.status == ev.status);
        assert(back.msg == ev.msg);
        assert(back.details == ev.details);
        assert(back.hosts == ev.hosts);
        assert(back.ms == ev.ms);
        assert(back.ok == ev.ok && back.changed == ev.changed && back.failed == ev.failed);
        assert(back.check == ev.check);
    }

    // non-event lines are refused, not errors
    JobEvent ev;
    assert(!parseEventLine("", ev));
    assert(!parseEventLine("ssh: connect refused", ev));

    // malformed event lines are errors naming the problem
    assertThrown!(TachyError)(parseEventLine("{\"t\":\"job\"", ev));
    assertThrown!(TachyError)(parseEventLine("{\"t\":\"bogus\"}", ev));
    assertThrown!(TachyError)(parseEventLine("{\"t\":\"job\" trailing}", ev));
}
