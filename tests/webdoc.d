/// Tests for tachy.webdoc, moved from the module's in-file
/// unittest blocks (tests/ is compiled only under `dub test`).
module tachy.tests.webdoc;

import tachy.webdoc;

import std.string : splitLines;
import std.regex : matchAll, regex;
import tachy.web : Request;
import std.algorithm.searching : canFind;
import std.conv : text;

private Request getReq(string path)
{
auto r = new Request;
r.method = "GET";
r.path = path;
return r;
}

@("slugify and compact aliases match the file's link spellings")
unittest
{
assert(slugify("`[compose]` — Docker Compose stacks")
    == "compose-docker-compose-stacks");
assert(slugify("Web UI (tachy webui)") == "web-ui-tachy-webui");
assert(slugify("Config (config.pravic)") == "config-configpravic");
assert(compactOf("config-configpravic") == "configconfigpravic");
assert(slugify("Purpose") == "purpose");
assert(slugify("A b") == "a-b");
}

@("inline markdown: escaping, code, bold, italic, links")
unittest
{
string[string] anchors;
anchors["generate"] = "4-generate";
anchors["configconfigpravic"] = "6-config-configpravic";

assert(inlineMd("a < b & c", null) == "a &lt; b &amp; c");
assert(inlineMd("`a < b`", null) == "<code>a &lt; b</code>");
assert(inlineMd("**bold** *it* x", null) == "<strong>bold</strong> <em>it</em> x");
// code spans shield their content from emphasis and links
assert(inlineMd("`**not bold** [x](y)`", null) == "<code>**not bold** [x](y)</code>",
    inlineMd("`**not bold** [x](y)`", null));
// internal anchors resolve to their page, both spellings
assert(inlineMd("[g](#generate)", &anchors)
    == `<a href="/doc/4-generate#generate">g</a>`);
assert(inlineMd("[s](#configconfigpravic)", &anchors)
    == `<a href="/doc/6-config-configpravic#configconfigpravic">s</a>`);
// unknown anchors and external urls stay as written
assert(inlineMd("[x](#nowhere)", &anchors) == `<a href="#nowhere">x</a>`);
assert(inlineMd("[x](https://example.invalid/a?b=1&c)", null)
    == `<a href="https://example.invalid/a?b=1&amp;c">x</a>`);
}

@("block rendering: fences, tables, lists, wrapped paragraphs")
unittest
{
string[string] anchors;
auto rend = MdRenderer("1-x", anchors);

{
    auto html = rend.render(splitLines("```pravic\nvar a = \"<b>\"\n```"));
    assert(html.canFind("<pre><code class=\"lang-pravic\">var a = &quot;&lt;b&gt;&quot;\n</code></pre>"),
        html);
}
{
    auto html = rend.render(splitLines("``` \nplain <i>\n```"));
    assert(html.canFind("<pre><code>plain &lt;i&gt;"), html);
}
{
    auto html = rend.render(splitLines(
        "| Attribute | Default |\n|---|:---:|\n| `run` | `0` |\n| b \\| c | d |"));
    assert(html.canFind("<th>Attribute</th><th>Default</th>"), html);
    assert(html.canFind("<td><code>run</code></td><td><code>0</code></td>"), html);
    assert(html.canFind("<td>b | c</td><td>d</td>"), html); // escaped pipe
}
{
    auto html = rend.render(splitLines("- **a** b\n  wrapped\n- second\n\npara"));
    assert(html.canFind("<li><strong>a</strong> b wrapped</li>"), html);
    assert(html.canFind("<li>second</li>"), html);
    assert(html.canFind("<p>para</p>"), html);
}
{
    auto html = rend.render(splitLines("line one\nline two\n\nnext para"));
    assert(html.canFind("<p>line one line two</p>"), html);
    assert(html.canFind("<p>next para</p>"), html);
}
{
    auto html = rend.render(splitLines("### `Tools` here\nbody"));
    assert(html.canFind(`<h2 id="tools-here"><code>Tools</code> here</h2>`), html);
    assert(anchors["tools-here"] == "1-x");
    assert(anchors["toolshere"] == "1-x");
}
}

@("section splitting: reading order, group pages, anchors")
unittest
{
string[string] anchors;
auto secs = splitSections(
    "# tachy — documentation\n\n## Purpose\n\nintro text\n\n### A simple example\n\nexample body\n\n## Command line\n\ncli intro\n\n### Options\n\noptions body\n\n### More\n\nmore body\n",
    anchors);
assert(secs.length == 5);
assert(secs[0].isGroup && secs[0].title == "Purpose" && secs[0].slug == "1-purpose");
assert(!secs[1].isGroup && secs[1].title == "A simple example"
    && secs[1].groupSlug == "1-purpose");
assert(secs[1].html.canFind("<p>example body</p>"));
assert(secs[0].html.canFind("<p>intro text</p>")); // the group's page
// a group's page precedes its subsections; numbers follow reading order
assert(secs[2].isGroup && secs[2].title == "Command line"
    && secs[2].slug == "3-command-line"
    && secs[2].html.canFind("<p>cli intro</p>"));
assert(!secs[3].isGroup && secs[3].title == "Options"
    && secs[3].slug == "4-options" && secs[3].groupSlug == "3-command-line");
assert(secs[4].title == "More" && secs[4].slug == "5-more"
    && secs[4].groupSlug == "3-command-line");
// page titles are anchors too
assert(anchors["a-simple-example"] == "2-a-simple-example");
assert(anchors["options"] == "4-options");
assert(anchors["command-line"] == "3-command-line");
}

@("the site: dispatch, menu, 404")
unittest
{
auto site = new DocSite("# t\n\n## Group One\n\nintro\n\n### Sub A\n\na body\n\n### Sub B\n\nb body\n");

auto root = site.router.dispatch(getReq("/"));
assert(root.status == 200 && root.body.canFind("<h1>Group One</h1>"), root.body);
assert(root.body.canFind("Sub A") && root.body.canFind("Group One")); // menu present

auto sub = site.router.dispatch(getReq("/doc/2-sub-a"));
assert(sub.status == 200 && sub.body.canFind("a body"));
assert(sub.body.canFind(`href="/doc/2-sub-a" class="active"`)
    || sub.body.canFind(`class="active" href="/doc/2-sub-a"`), sub.body);

auto nf = site.router.dispatch(getReq("/doc/nope"));
assert(nf.status == 404 && nf.body.canFind("No such section"));
}

@("the real file: every section and every internal link resolves")
unittest
{
string[string] anchors;
auto secs = splitSections(docSource, anchors);
assert(secs.length > 15, text(secs.length));
assert(secs[0].isGroup && secs[0].title == "Purpose");
// the menu shows every section
auto menu = menuHtml(secs, null);
foreach (ref const s; secs)
    assert(menu.canFind("href=\"/doc/" ~ s.slug ~ "\""), s.slug);
// every heading id (and compact alias) maps to the page that holds it
foreach (ref const s; secs)
    assert(anchors[slugify(s.title)] == s.slug);
// every internal link in the file points at a known heading
foreach (m; docSource.matchAll(regex(`\]\(#([^)\s]+)\)`)))
{
    const string id = m[1];
    assert(id in anchors, "broken internal link: #" ~ id);
}
}
