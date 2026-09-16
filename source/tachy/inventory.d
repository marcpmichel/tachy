module tachy.inventory;

/**
 * Inventory: hosts with tags and variables (Pravic; see LANGUAGE.md).
 *
 *     host web1 {                        # required, at least one host
 *         address = "192.168.1.10"       # default: host name
 *         user = "deploy"                # ssh login (default: ssh's default)
 *         port = 22
 *         key = "~/.ssh/id_ed25519"
 *         connection = "ssh"             # "ssh" (default) or "local"
 *         tags = ["web", "front"]        # used for host selection
 *         vars { http_port = 80 }        # host variables
 *     }
 *
 *     var admin = "root"                 # optional, applies to every host
 *
 * Hosts are selected by name or by tag; see `select`.
 */
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : text;
import std.string : join;

import tachy.errors;
import tachy.parser : loadPractic;
import tachy.value;
import tachy.vars : AgeConfig, deepMerge, resolveEnvVars;

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

    static Inventory load(string path, string ageIdentity = null)
    {
        auto doc = loadPractic(path);
        auto inv = new Inventory;
        Val[string] globalVars;
        foreach (const ref s; doc.stmts)
        {
            if (s.kind == "hosts")
            {
                const string ctx = path ~ ": hosts." ~ s.key;
                if (s.value.kind != Val.Kind.table_)
                    throw new TachyError(ctx ~ " must be a block of parameters");
                auto ht = s.value.table_;
                checkKeys(ht, ["address", "user", "port", "key", "connection", "tags", "vars"], ctx);

                HostConfig h;
                h.name = s.key;
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
                h.vars = resolveEnvVars(optTable(ht, "vars", ctx), ctx,
                    AgeConfig(true, ageIdentity));
                inv.hosts_[s.key] = h;
            }
            else if (s.kind == "vars")
                globalVars[s.key] = cast(Val) s.value;
            else
                throw new TachyError(path ~ ": line " ~ text(s.line) ~ ": '"
                    ~ s.kind ~ "' is not valid in an inventory file");
        }
        if (inv.hosts_.length == 0)
            throw new TachyError(path ~ ": no hosts — define at least one host");
        inv.globalVars_ = resolveEnvVars(globalVars, path,
            AgeConfig(true, ageIdentity));
        return inv;
    }

    /// Select hosts by a comma-separated list of host names and `@tag`
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
            else if (item[0] == '@')
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

    /// One host by exact name; an unknown name is an error listing the
    /// known hosts (tags and `all` are selection syntax, not names).
    HostConfig host(string name)
    {
        if (auto h = name in hosts_)
            return *h;
        throw new TachyError("unknown host '" ~ name ~ "' (known: "
            ~ knownNames().join(", ") ~ ")");
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
