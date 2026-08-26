module tachy.inventory;

/**
 * Inventory: hosts with tags and variables.
 *
 *     [hosts.web1]                       # required, at least one host
 *     address = "192.168.1.10"           # default: host name
 *     user = "deploy"                    # ssh login (default: ssh's default)
 *     port = 22
 *     key = "~/.ssh/id_ed25519"
 *     connection = "ssh"                 # "ssh" (default) or "local"
 *     tags = ["web", "front"]            # used for host selection
 *     [hosts.web1.vars]
 *     http_port = 80
 *
 *     [vars]                             # optional, applies to every host
 *     admin = "root"
 *
 * Hosts are selected by name or by tag; see `select`.
 */
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : text;
import std.string : join;

import tachy.errors;
import tachy.value;
import tachy.vars : deepMerge;

struct HostConfig
{
    string name;
    string connection = "ssh"; // "ssh" or "local"
    string address;            // empty → use name
    string user;               // empty → ssh default
    int port = 22;
    string key;                // identity file, empty → ssh default
    string[] tags;
    Val[string] vars;
}

class Inventory
{
    private HostConfig[string] hosts_;
    private Val[string] globalVars_;

    static Inventory load(string path)
    {
        auto root = loadToml(path);
        auto t = root.table_;
        checkKeys(t, ["hosts", "vars"], path);
        if ("hosts" !in t)
            throw new TachyError(path ~ ": missing [hosts] table");
        if (t["hosts"].kind != Val.Kind.table_)
            throw new TachyError(path ~ ": 'hosts' must be a table");

        auto inv = new Inventory;
        foreach (string hname, const Val hv; t["hosts"].table_)
        {
            auto ctx = path ~ ": hosts." ~ hname;
            if (hv.kind != Val.Kind.table_)
                throw new TachyError(ctx ~ " must be a table");
            auto ht = hv.table_;
            checkKeys(ht, ["address", "user", "port", "key", "connection", "tags", "vars"], ctx);

            HostConfig h;
            h.name = hname;
            h.address = optString(ht, "address", ctx);
            h.user = optString(ht, "user", ctx);
            h.port = cast(int) optInt(ht, "port", ctx, 22);
            if (h.port < 1 || h.port > 65535)
                throw new TachyError(ctx ~ ": 'port' must be between 1 and 65535");
            h.key = optString(ht, "key", ctx);
            h.connection = optString(ht, "connection", ctx, "ssh");
            if (h.connection != "ssh" && h.connection != "local")
                throw new TachyError(ctx ~ ": 'connection' must be \"ssh\" or \"local\", not \"" ~ h.connection ~ "\"");
            h.tags = optStringArray(ht, "tags", ctx);
            h.vars = optTable(ht, "vars", ctx);
            inv.hosts_[hname] = h;
        }
        if (inv.hosts_.length == 0)
            throw new TachyError(path ~ ": [hosts] defines no hosts");

        if ("vars" in t)
            inv.globalVars_ = optTable(t, "vars", path);

        return inv;
    }

    /// Select hosts by a comma-separated list of host names and `#tag`
    /// selectors; `all` selects everything. Result is sorted by name.
    HostConfig[] select(string selection)
    {
        import std.string : split;
        import std.algorithm.iteration : map, splitter;
        import std.array : array;

        bool[string] picked;
        foreach (rawItem; splitter(selection, ','))
        {
            import std.string : strip;
            const string item = strip(rawItem);
            if (!item.length)
                continue;
            if (item == "all")
            {
                foreach (n; hosts_.byKey)
                    picked[n] = true;
            }
            else if (item[0] == '#')
            {
                const string tag = item[1 .. $];
                size_t found = 0;
                foreach (n, const ref h; hosts_)
                    foreach (tg; h.tags)
                        if (tg == tag)
                        {
                            picked[n] = true;
                            found++;
                        }
                if (found == 0)
                    throw new TachyError("no host has tag '" ~ tag ~ "' (known tags: "
                        ~ knownTags().join(", ") ~ ")");
            }
            else if (auto _ = item in hosts_)
                picked[item] = true;
            else
                throw new TachyError("unknown host '" ~ item ~ "' (known: "
                    ~ knownNames().join(", ") ~ ")");
        }

        auto names = picked.byKey.array;
        names.sort();
        return names.map!(n => hosts_[n]).array;
    }

    /// Effective variables for a host: global < host.
    /// `inventory_hostname` is injected as a builtin.
    Val[string] varsFor(string hostName) const
    {
        Val[string] result = dupTable(globalVars_);
        if (auto h = hostName in hosts_)
            result = deepMerge(result, (*h).vars);
        result["inventory_hostname"] = Val(hostName);
        return result;
    }

    private string[] knownNames() const
    {
        auto names = hosts_.byKey.array;
        names.sort();
        return names;
    }

    private string[] knownTags() const
    {
        bool[string] seen;
        foreach (const ref h; cast() hosts_)
            foreach (tg; h.tags)
                seen[tg] = true;
        auto tags = seen.byKey.array;
        tags.sort();
        return tags;
    }
}

// ---------------------------------------------------------------------------

version (unittest) private
{
    import std.file : exists, mkdirRecurse;
    import std.path : buildPath;
    import std.file : tempDir;
    import std.stdio : File;

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
}

unittest // hosts, tags, selection, vars precedence
{
    auto inv = Inventory.load(writeTemp("basic.toml", `
[vars]
admin = "root"

[hosts.web1]
address = "10.0.0.1"
tags = ["web", "front"]
[hosts.web1.vars]
http_port = 81

[hosts.web2]
address = "10.0.0.2"
tags = ["web"]
[hosts.web2.vars]
http_port = 82

[hosts.buildbox]
connection = "local"
`));

    assert(inv.select("web1").length == 1);
    assert(inv.select("web1")[0].address == "10.0.0.1");

    auto web = inv.select("#web");
    assert(web.length == 2);
    assert(web[0].name == "web1" && web[1].name == "web2"); // sorted

    assert(inv.select("web1,#web").length == 2);            // union, deduped
    assert(inv.select("all").length == 3);
    assert(inv.select("#front")[0].name == "web1");
    assert(inv.select("#front,buildbox").length == 2);      // mixed host + tag

    auto vars1 = inv.varsFor("web1");
    assert(vars1["inventory_hostname"].str_ == "web1");
    assert(vars1["admin"].str_ == "root");                  // global var
    assert(vars1["http_port"].integer_ == 81);              // host var wins
}

unittest // validation errors
{
    import std.exception : assertThrown;
    assertThrown!(TachyError)(Inventory.load(writeTemp("err1.toml", "[hosts]\n"))); // empty hosts
    assertThrown!(TachyError)(Inventory.load(writeTemp("err1b.toml", "[hosts.a]\nunknown = 1\n")));
    assertThrown!(TachyError)(Inventory.load(writeTemp("err2.toml",
        "[hosts.a]\ntags = \"not-an-array\"\n")));
    assertThrown!(TachyError)(Inventory.load(writeTemp("err3.toml", "[hosts.a]\n[groups.g]\n"))); // groups are gone

    auto inv = Inventory.load(writeTemp("ok.toml", "[hosts.a]\ntags = [\"x\"]\n"));
    assertThrown!(TachyError)(inv.select("nope"));   // unknown host
    assertThrown!(TachyError)(inv.select("#nope"));  // unknown tag
    assertThrown!(TachyError)(inv.select("#"));      // empty tag
}
