module tachy.webdoc;

/**
 * The `webdoc` command: serve the documentation as a small multi-page
 * HTML site — one page per section, a left menu to pick one.
 *
 * The source is DOCUMENTATION.md, embedded in the binary at compile time
 * with `import("...")` (like the webui's assets): the server shows
 * exactly the reference for the binary being run, with no file to
 * discover.  `##` headings become menu groups (each with its own intro
 * page), `###` headings become the pages inside them.
 *
 * Markdown is converted by a deliberately small subset renderer —
 * headings, fenced code blocks, pipe tables, bullet lists, paragraphs
 * and inline code/bold/italic/links; anything the file does not use is
 * not implemented.  Internal `#anchor` links (the file uses both the
 * hyphenated and the compact spelling) are resolved against every
 * heading of every page and rewritten to `/doc/<page>#<anchor>`.
 *
 * The HTTP layer and the stylesheet are the webui's: `tachy.web`'s
 * thread-per-connection server and `:param` router (GETs on localhost
 * by default, `--address`/`--port`), and `webui/app.css` itself —
 * one CSS for both sites, so the docs share the console's dark theme
 * (the doc rules scope under `body.webdoc`).
 */
import std.algorithm.searching : canFind, startsWith;
import std.array : appender, join;
import std.conv : text, to;
import std.regex : regex;
import std.socket : InternetAddress;
import std.stdio : stdout;
import std.string : strip, stripLeft;

import tachy.errors;
import tachy.runner : RunOptions;
import tachy.web : Request, Response, Router, asset, bindListener,
    browserUrl, serveForever, tryOpenBrowser, webListener;

package(tachy) enum string docSource = import("DOCUMENTATION.md");

int runWebDoc(const RunOptions opts) @trusted
{
    if(opts.webPort < 0 || opts.webPort > 65535)
        throw new TachyError("--port must be between 0 and 65535");

    auto site = new DocSite(docSource);

    auto listener = webListener(opts);
    auto addr = cast(InternetAddress) listener.localAddress();
    stdout.writefln("tachy webdoc listening on http://%s — Ctrl-C to stop",
            addr.toString());
    stdout.writefln("serving the compiled-in DOCUMENTATION.md (%d sections)",
            site.sections.length);
    stdout.flush();

    if(!opts.noBrowser)
        tryOpenBrowser(browserUrl(addr.toAddrString(), addr.port));

    import tachy.signals : installSignalHandlers, signalExitCode;

    installSignalHandlers();
    serveForever(listener, site.router);
    return signalExitCode();
}

// ---------------------------------------------------------------------------
// The site: sections parsed out of the markdown, plus routes
// ---------------------------------------------------------------------------

private struct Section {
    string slug; // "3-command-line"; the reading-order prefix keeps
    // slugs unique and the menu ordered
    string title; // heading text, backticks stripped
    string[] lines; // raw markdown, rendered in the second pass
    string html; // rendered body, without the page chrome
    bool isGroup; // a ## section (its page holds the group's intro)
    string groupSlug; // owning group's slug (a group's own slug)
}

package(tachy) final class DocSite {
    Router router;
    Section[] sections;
    Section[string] bySlug;
    string[string] anchorPage; // heading id (and compact alias) -> page slug

    this(string md)
    {
        sections = splitSections(md, anchorPage);
        foreach(ref s; sections)
            bySlug[s.slug] = s;
        router = new Router;
        router.add("GET", "/", (req, p) => page(sections[0].slug));
        router.add("GET", "/doc/:slug", (req, p) => page(p["slug"]));
        router.add("GET", "/favicon.ico", (req, p) => new Response);
    }

    private Response page(string slug)
    {
        auto s = slug in bySlug;
        if(s is null) {
            auto r = asset(layout("No such section", menuHtml(sections, null),
                    "<p>There is no section at this address.</p>"),
                    "text/html; charset=utf-8");
            r.status = 404;
            return r;
        }
        return asset(layout((*s).title, menuHtml(sections, slug),
                "<h1>" ~ inlineMd((*s).title, null) ~ "</h1>\n" ~ (*s).html),
                "text/html; charset=utf-8");
    }
}

// ---------------------------------------------------------------------------
// Splitting the file into sections
// ---------------------------------------------------------------------------

/// `##` headings open groups, `###` headings open pages; the H1 line and
/// anything before the first `##` (nothing, in practice) are dropped.
/// A group's own page (its intro) is emitted when its first `###`
/// appears — or when the group closes, when it has none — so sections
/// come out in reading order, numbered as they are emitted (the number
/// keeps slugs unique and the menu ordered).  Each rendered heading
/// registers its slug (and compact alias) in `anchorPage` so internal
/// links can be rewritten to the right page.
package(tachy) Section[] splitSections(string md, ref string[string] anchorPage)
{
    import std.string : splitLines;

    Section[] secs;
    auto lines = splitLines(md);
    size_t first = lines.length && lines[0].startsWith("# ") ? 1 : 0;

    size_t n;
    string groupTitle, curGroupSlug;
    bool groupEmitted;
    string[] intro; // the open group's intro lines
    string subTitle;
    string[] body; // the open subsection's lines

    void emitGroup()
    {
        if(!groupTitle.length || groupEmitted)
            return;
        groupEmitted = true;
        n++;
        Section s;
        s.title = stripTicks(groupTitle);
        s.slug = text(n) ~ "-" ~ slugify(s.title);
        s.isGroup = true;
        s.groupSlug = s.slug;
        s.lines = intro.dup;
        registerAnchor(anchorPage, slugify(s.title), s.slug);
        secs ~= s;
        curGroupSlug = s.slug;
    }

    void emitSub()
    {
        if(!subTitle.length)
            return;
        n++;
        Section s;
        s.title = stripTicks(subTitle);
        s.slug = text(n) ~ "-" ~ slugify(s.title);
        s.groupSlug = curGroupSlug;
        s.lines = body.dup;
        registerAnchor(anchorPage, slugify(s.title), s.slug);
        secs ~= s;
        subTitle = "";
        body = [];
    }

    foreach(size_t i; first .. lines.length) {
        auto l = lines[i];
        if(l.startsWith("## ")) {
            emitSub(); // close the open subsection, then the group
            emitGroup(); // (an intro-only group closes here)
            groupTitle = l[3 .. $];
            intro = [];
            groupEmitted = false;
        } else if(l.startsWith("### ")) {
            emitSub();
            emitGroup(); // the intro ends here: the group's page comes first
            subTitle = l[4 .. $];
            body = [];
        } else if(subTitle.length)
            body ~= l;
        else
            intro ~= l;
    }
    emitSub();
    emitGroup();

    // Second pass: the anchor map is complete only now — a group's page
    // links to sections that come after it — so in-page headings are
    // registered and the bodies rendered against the full map.
    foreach(ref s; secs)
        foreach(l; s.lines)
            if(l.startsWith("#### "))
                registerAnchor(anchorPage, slugify(l[5 .. $]), s.slug);
    foreach(ref s; secs) {
        auto rend = MdRenderer(s.slug, anchorPage);
        s.html = rend.render(s.lines);
    }
    return secs;
}

// ---------------------------------------------------------------------------
// Markdown subset renderer (block level)
// ---------------------------------------------------------------------------

package(tachy) struct MdRenderer {
    string pageSlug;
    private string[string]* anchors; // anchor map, by reference

    this(string pageSlug, ref string[string] anchorPage)
    {
        this.pageSlug = pageSlug;
        this.anchors = &anchorPage;
    }

    string render(string[] lines)
    {
        auto app = appender!string;
        string[] para;
        void flushPara()
        {
            if(para.length) {
                app.put("<p>" ~ inlineMd(para.join(" "), anchors) ~ "</p>\n");
                para = [];
            }
        }

        size_t i;
        while(i < lines.length) {
            auto l = lines[i];

            if(l.startsWith("```")) // fenced code block
            {
                flushPara();
                auto lang = stripLeft(l[3 .. $]);
                if(!isWord(lang))
                    lang = "";
                auto code = appender!(string[]);
                for(i++; i < lines.length && !lines[i].startsWith("```"); i++)
                    code.put(lines[i]);
                i++; // the closing fence
                app.put("<pre><code" ~ (lang.length ? " class=\"lang-" ~ lang ~ "\"" : "")
                        ~ ">" ~ htmlEscape(
                            code.data.join("\n") ~ "\n") ~ "</code></pre>\n");
                continue;
            }

            if(l.startsWith("### ") || l.startsWith("#### ")) {
                flushPara();
                app.put(heading(l));
                i++;
                continue;
            }

            if(l.length && l[0] == '|' && i + 1 < lines.length
                    && isTableSeparator(lines[i + 1])) {
                flushPara();
                app.put("<table>\n<thead>\n<tr>");
                foreach(c; tableCells(l))
                    app.put("<th>" ~ inlineMd(c, anchors) ~ "</th>");
                app.put("</tr>\n</thead>\n<tbody>\n");
                for(i += 2; i < lines.length && lines[i].length && lines[i][0] == '|'; i++) {
                    app.put("<tr>");
                    foreach(c; tableCells(lines[i]))
                        app.put("<td>" ~ inlineMd(c, anchors) ~ "</td>");
                    app.put("</tr>\n");
                }
                app.put("</tbody>\n</table>\n");
                continue;
            }

            if(l.startsWith("- ") || l == "-") {
                flushPara();
                app.put("<ul>\n");
                while(i < lines.length && (lines[i].startsWith("- ") || lines[i] == "-")) {
                    string item = lines[i] == "-" ? "" : lines[i][2 .. $];
                    for(i++; i < lines.length && lines[i].length && lines[i][0] == ' '
                            && strip(lines[i]).length; i++)
                        item ~= " " ~ strip(lines[i]); // wrapped item text
                    app.put("<li>" ~ inlineMd(item, anchors) ~ "</li>\n");
                }
                app.put("</ul>\n");
                continue;
            }

            if(!strip(l).length) {
                flushPara();
                i++;
                continue;
            }

            para ~= strip(l);
            i++;
        }
        flushPara();
        return app.data;
    }

    /// A `###`/`####` heading becomes an h2/h3 with an id; the id (and
    /// its compact alias) points link rewrites at this page.
    private string heading(string l)
    {
        const bool h3 = l.startsWith("#### ");
        const string text = l[h3 ? 5 : 4 .. $];
        const string id = slugify(text);
        registerAnchor(*anchors, id, pageSlug);
        return "<h" ~ (h3 ? "3" : "2") ~ " id=\"" ~ id ~ "\">"
            ~ inlineMd(text, anchors) ~ "</h" ~ (h3 ? "3" : "2") ~ ">\n";
    }
}

// ---------------------------------------------------------------------------
// Inline markdown: escape, `code`, [link](#anchor|url), **bold**, *italic*
// ---------------------------------------------------------------------------

package(tachy) string inlineMd(string s, const(string[string])* anchors)
{
    import std.regex : replaceAll;

    s = htmlEscape(s);

    // Code spans first: their content must not see the other rules.
    string[] codes;
    s = replaceAll!(m => codeSpan(codes, m[1]))(s, regex("`([^`]+)`"));

    s = replaceAll!(m => makeLink(m[1], m[2], anchors))(s, regex(`\[([^\]]+)\]\(([^)]+)\)`));
    s = replaceAll!(m => "<strong>" ~ m[1] ~ "</strong>")(s, regex(`\*\*(.+?)\*\*`));
    s = replaceAll!(m => "<em>" ~ m[1] ~ "</em>")(s, regex(`\*([^*]+)\*`));

    // Restore code spans (placeholders never match the rules above).
    s = replaceAll!(m => codes[to!size_t(m[1])])(s, regex("\x01([0-9]+)\x01"));
    return s;
}

private string codeSpan(ref string[] codes, string content)
{
    codes ~= "<code>" ~ content ~ "</code>"; // content is escaped already
    return "\x01" ~ text(codes.length - 1) ~ "\x01";
}

private string makeLink(string label, string href, const(string[string])* anchors)
{
    if(href.length > 1 && href[0] == '#' && anchors !is null) {
        const string id = href[1 .. $];
        if(auto page = id in *anchors)
            href = "/doc/" ~ *page ~ "#" ~ id;
    }
    return "<a href=\"" ~ href ~ "\">" ~ label ~ "</a>";
}

// ---------------------------------------------------------------------------
// Slugs, anchors, small string helpers
// ---------------------------------------------------------------------------

/// Lowercase; alphanumerics kept, whitespace becomes a '-' separator
/// (runs collapse), every other character is dropped — GitHub-style
/// slugs, matching the file's link spellings ("Config
/// (config.pravic)" -> config-configpravic).
package(tachy) string slugify(string t) @safe pure
{
    import std.ascii : isDigit, isLower, toLower;

    string r;
    bool sep;
    foreach(char c; stripTicks(t)) {
        c = toLower(c);
        if(isDigit(c) || isLower(c)) {
            r ~= c;
            sep = false;
        } else if((c == ' ' || c == '\t') && !sep && r.length) {
            r ~= '-';
            sep = true;
        }
    }
    while(r.length && r[$ - 1] == '-')
        r = r[0 .. $ - 1];
    return r;
}
/// Alphanumerics only (the compact anchor spelling the file also uses).
package(tachy) string compactOf(string id) @safe pure
{
    import std.ascii : isDigit, isLower;

    string r;
    foreach(char c; id)
        if(isDigit(c) || isLower(c))
            r ~= c;
    return r;
}

private void registerAnchor(ref string[string] map, string id, string page)
{
    if(!id.length || id in map)
        return;
    map[id] = page;
    const string compact = compactOf(id);
    if(compact.length && compact != id && compact !in map)
        map[compact] = page;
}

private string stripTicks(string s) @safe pure
{
    import std.array : replace;

    return s.replace("`", "");
}

private string htmlEscape(string s) @safe pure
{
    string r;
    foreach(char c; s)switch(c) {
        case '&':
            r ~= "&amp;";
            break;
        case '<':
            r ~= "&lt;";
            break;
        case '>':
            r ~= "&gt;";
            break;
        case '"':
            r ~= "&quot;";
            break;
        default:
            r ~= c;
    }
    return r;
}

private bool isWord(string s) @safe pure
{
    import std.ascii : isDigit, isLower;

    foreach(char c; s)
        if(!isLower(c) && !isDigit(c) && c != '-')
            return false;
    return s.length > 0;
}

/// A table separator row: `|---|:---:|` (pipes optional at both ends).
private bool isTableSeparator(string l) @safe pure
{
    import std.algorithm.searching : all;

    auto s = l.strip;
    if(s.length && s[0] == '|')
        s = s[1 .. $];
    if(s.length && s[$ - 1] == '|')
        s = s[0 .. $ - 1];
    if(!s.length)
        return false;
    return s.splitPipe().all!(c => isDashCell(strip(c)));
}

private bool isDashCell(string c) @safe pure
{
    if(!c.length)
        return false;
    if(c[0] == ':')
        c = c[1 .. $];
    if(c.length && c[$ - 1] == ':')
        c = c[0 .. $ - 1];
    if(!c.length)
        return false;
    foreach(char ch; c)
        if(ch != '-')
            return false;
    return true;
}

/// Split a table row into cells: strip the outer pipes, split on `|`
/// (a `\|` inside a cell is a literal pipe, not a separator).
private string[] tableCells(string row) @safe pure
{
    auto s = row.strip;
    if(s.length && s[0] == '|')
        s = s[1 .. $];
    if(s.length && s[$ - 1] == '|' && !endsWithEscapedPipe(s))
        s = s[0 .. $ - 1];
    return splitPipe(s);
}

/// Split on unescaped pipes; `\|` stays in the cell as `|`.
private string[] splitPipe(string s) @safe pure
{
    import std.algorithm.searching : canFind;

    string[] cells;
    string cur;
    for(size_t i = 0; i < s.length; i++) {
        if(s[i] == '\\' && i + 1 < s.length && s[i + 1] == '|') {
            cur ~= '|';
            i++;
        } else if(s[i] == '|') {
            cells ~= cur;
            cur = "";
        } else
            cur ~= s[i];
    }
    cells ~= cur;
    foreach(ref c; cells)
        c = c.strip;
    return cells;
}

/// True when the row's last character is a real (unescaped) pipe.
private bool endsWithEscapedPipe(string s) @safe pure
{
    return s.length >= 2 && s[$ - 1] == '|' && s[$ - 2] == '\\';
}

// ---------------------------------------------------------------------------
// Page chrome: menu, layout, CSS
// ---------------------------------------------------------------------------

package(tachy) string menuHtml(in Section[] all, string current)
{
    auto app = appender!string;
    app.put("<a class=\"brand\" href=\"/doc/" ~ all[0].slug ~ "\">tachy<span>documentation</span></a>\n<ul>\n");
    bool inGroup;
    foreach(ref const s; all) {
        if(s.isGroup) {
            if(inGroup) {
                app.put("</ul>\n</li>\n");
                inGroup = false;
            }
            app.put("<li><a class=\"group" ~ (s.slug == current ? " active" : "")
                    ~ "\" href=\"/doc/" ~ s.slug ~ "\">" ~ inlineMd(
                        s.title, null)
                    ~ "</a>\n<ul>\n");
            inGroup = true;
        } else {
            app.put("<li><a" ~ (s.slug == current ? " class=\"active\"" : "")
                    ~ " href=\"/doc/" ~ s.slug ~ "\">" ~ inlineMd(s.title, null)
                    ~ "</a></li>\n");
        }
    }
    if(inGroup)
        app.put("</ul>\n</li>\n");
    app.put("</ul>\n");
    return app.data;
}

package(tachy) string layout(string title, string menu, string content)
{
    return "<!doctype html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>"
        ~ htmlEscape(
                title) ~ " — tachy documentation</title>\n<style>"
        ~ pageCss ~ "</style>\n</head>\n<body class=\"webdoc\">\n<nav id=\"menu\">" ~ menu
        ~ "</nav>\n<main>" ~ content ~ "</main>\n</body>\n</html>\n";
}

private enum string pageCss = import("tachy/webui/app.css");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
