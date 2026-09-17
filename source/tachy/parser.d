module tachy.parser;

/**
 * The Pravic parser: a hand-written recursive descent implementing
 * LANGUAGE.md's grammar one production at a time.
 *
 * Configuration files (inventory, tasks, settings) are written in Pravic —
 * tachy's own configuration language, specified in `LANGUAGE.md` — and
 * parsed into `Val` trees plus an ordered statement list, so the rest of
 * the code never sees the parser's own types.
 *
 * A file is a sequence of statements, one per line:
 *
 *     vars { A = "x", port = 8080 }     # group form (plural directives)
 *     var A = "x"                       # single form
 *     file /etc/app.conf { mode = "0644" }
 *     check "name is unique" { run = "true" }
 *
 * Group-form blocks expand to one statement per entry, in source order;
 * a single-form statement names its key inline.  The canonical `kind` is
 * the plural directive ("vars", "files", ...) or the directive itself
 * ("apply", "ensure", "compose", "import").  Inside braces and brackets
 * newlines are transparent and entries separate by commas and/or newlines
 * (trailing commas allowed); unquoted keys are opaque strings (no dotted
 * paths).
 */
import tachy.errors;
import tachy.value : PracticDoc, PracticStmt, Val;
import std.array : Appender;

/// Parse a Pravic file.  Errors carry the file path and line:
/// `"<file>: line N: ..."`.  Duplicate keys (within a block, or the same
/// directive key stated twice) are load-time errors naming both lines.
PracticDoc loadPractic(string path)
{
    import std.file : readText;
    string src;
    try src = readText(path);
    catch (Exception e)
        throw new TachyError("cannot read '" ~ path ~ "': " ~ e.msg);
    return parsePractic(src, path);
}

// ---------------------------------------------------------------------------
// The parser: a hand-written recursive descent implementing LANGUAGE.md's
// grammar one production at a time.  One statement per line; inside braces
// and brackets newlines are transparent and entries separate by commas
// and/or newlines; unquoted keys are opaque strings (no dotted paths).
// ---------------------------------------------------------------------------

private struct Parser
{
    string src;
    string path;
    size_t i;
    size_t line = 1;

    private TachyError fail(string msg) @safe pure
    {
        import std.conv : text;
        return new TachyError(path ~ ": line " ~ text(line) ~ ": " ~ msg);
    }

    private bool atEnd() @safe pure nothrow const { return i >= src.length; }

    private char cur() @safe pure const
    {
        return i < src.length ? src[i] : '\0';
    }

    private char charAfter(size_t n) @safe pure const
    {
        return i + n < src.length ? src[i + n] : '\0';
    }

    private bool lookingAt(string lit) @safe pure const
    {
        return src.length - i >= lit.length && src[i .. i + lit.length] == lit;
    }

    /// Whether a `{` (spaces allowed) follows the n-character keyword
    /// at the cursor: the group form's opening brace.
    private bool groupFollows(size_t n) @safe pure const
    {
        size_t p = i + n;
        while (p < src.length && (src[p] == ' ' || src[p] == '\t'))
            p++;
        return p < src.length && src[p] == '{';
    }

    /// Whether the keyword also has a single form (dual-form keyword).
    private bool isSingleForm(string kw) @safe pure const
    {
        foreach (immutable k; singleKeywords)
            if (k == kw)
                return true;
        return false;
    }

    private void advance(size_t n = 1) @safe pure nothrow
    {
        foreach (size_t k; 0 .. n)
        {
            if (i < src.length && src[i] == '\n')
                line++;
            i++;
        }
    }

    /// Horizontal whitespace and comments; never crosses a newline.
    private void hs() @safe pure
    {
        while (!atEnd())
        {
            if (src[i] == ' ' || src[i] == '\t' || src[i] == '\r')
                i++;
            else if (src[i] == '#')
            {
                while (!atEnd() && src[i] != '\n')
                    i++;
            }
            else
                break;
        }
    }

    /// Full skip: blank/comment lines and horizontal whitespace.
    private void ws() @safe pure
    {
        while (!atEnd())
        {
            hs();
            if (!atEnd() && src[i] == '\n')
                advance();
            else
                break;
        }
    }

    private void expect(char c, string what) @safe pure
    {
        if (cur() != c)
            throw fail("expected '" ~ c ~ "' " ~ what);
        advance();
    }

    // -- statements -----------------------------------------------------------

    /// The statement keywords, split by form.  A keyword must be followed
    /// by a character that cannot continue a key, so `varsite` is an
    /// unknown directive, not `var site`, and long/short spellings never
    /// collide.  Order within a set does not matter (the guard decides).
    private static immutable string[] groupKeywords =
        ["vars", "files", "directories", "packages", "groups",
         "users", "services", "repos", "hosts", "imports", "webui",
         "identity", "output"];
    private static immutable string[] singleKeywords =
        ["var", "file", "directory", "package", "group", "user",
         "service", "host", "apply", "ensure", "compose", "import",
         "identity", "http", "repo"];

    /// Canonical directive names for the single-form keywords (group-form
    /// keywords are their own canonical name).
    private static string canonical(string kw) @safe pure nothrow
    {
        switch (kw)
        {
            case "var": return "vars";
            case "file": return "files";
            case "directory": return "directories";
            case "package": return "packages";
            case "group": return "groups";
            case "user": return "users";
            case "service": return "services";
            case "repo": return "repos";
            case "host": return "hosts";
            default: return kw; // apply, ensure, compose, import
        }
    }

    private bool isKeyChar(char c) @safe pure nothrow const
    {
        if (c <= ' ' || c == 0x7F)
            return false; // whitespace and control characters
        foreach (bad; "\"'{}[]=,#\\")
            if (c == bad)
                return false;
        return true;
    }

    private PracticStmt[] parseFile() @safe pure
    {
        PracticStmt[] stmts;
        size_t[string] firstSeen;
        ws();
        while (!atEnd())
        {
            hs();
            if (atEnd())
                break;
            auto fresh = parseStatement();
            foreach (ref s; fresh)
            {
                const string dedup = s.kind ~ '\0' ~ s.key;
                if (auto first = dedup in firstSeen)
                    throw new TachyError(path ~ ": line " ~ toText(s.line)
                        ~ ": duplicate " ~ s.kind ~ " \"" ~ s.key
                        ~ "\" (first stated at line " ~ toText(*first) ~ ")");
                firstSeen[dedup] = s.line;
                stmts ~= s;
            }
            // A statement ends at the end of its line; blank and comment
            // lines may follow before the next one.
            size_t newlines;
            hs();
            while (!atEnd() && src[i] == '\n')
            {
                advance();
                newlines++;
                hs();
            }
            if (atEnd())
                break;
            if (newlines == 0)
                throw fail("expected end of line after statement");
        }
        return stmts;
    }

    private PracticStmt[] parseStatement() @safe pure
    {
        const size_t stmtLine = line;
        foreach (immutable kw; groupKeywords)
            if (lookingAt(kw) && !isKeyChar(charAfter(kw.length)))
            {
                // A keyword with both forms (`identity`) takes its
                // group form when a block follows, and falls through
                // to the single form below otherwise; group-only
                // keywords must still open their block.
                if (groupFollows(kw.length) || !isSingleForm(kw))
                    return expandGroup(kw);
            }
        foreach (immutable kw; singleKeywords)
            if (lookingAt(kw) && !isKeyChar(charAfter(kw.length)))
                return [parseSingle(kw, stmtLine)];

        // Not a known directive: name the word for a useful error.
        size_t e = i;
        while (e < src.length && src[e] != '\n' && src[e] != '{' && src[e] != '=')
            e++;
        import std.string : strip;
        const string word = src[i .. e].strip();
        throw fail("unknown directive '" ~ word ~ "'");
    }

    private PracticStmt[] expandGroup(string kw) @safe pure
    {
        advance(kw.length);
        hs();
        if (cur() != '{')
            throw fail("directive '" ~ kw ~ "' opens a block: expected '{'");
        PracticStmt[] out_;
        foreach (ref entry; parseBlockEntries())
        {
            PracticStmt s;
            s.kind = kw;
            s.key = entry.key;
            s.value = entry.value;
            s.line = entry.line;
            checkChoosePlacement(kw, s.value, s.line);
            out_ ~= s;
        }
        return out_;
    }

    private PracticStmt parseSingle(string kw, size_t stmtLine) @safe pure
    {
        advance(kw.length);
        hs();
        const size_t keyLine = line;
        const string key = parseKey("a key after '" ~ kw ~ "'");
        hs();
        Val value;
        if (cur() == '{')
            value = tableOf(parseBlockEntries());
        else if (cur() == '=')
        {
            advance();
            ws();
            value = parseAssignedValue();
        }
        else if (cur() == '\n' || atEnd())
            // No attributes: an instruction whose block would be empty
            // may omit the braces (`directory /tmp/two`).
            value = emptyTable();
        else
            throw fail("expected '{', '=' or end of line after '"
                ~ kw ~ " " ~ key ~ "'");

        PracticStmt s;
        s.kind = canonical(kw);
        s.key = key;
        s.value = value;
        s.line = keyLine;
        checkChoosePlacement(s.kind, s.value, s.line);
        return s;
    }

    /// `choose` values are only legal inside a var assignation: the
    /// `var`/`vars` statements (either file) and, in an inventory, the
    /// `vars` blocks of `host` entries.  Anything else carrying a
    /// choose — job parameters, apply bindings, host attributes, config
    /// entries — is a load-time error.
    private void checkChoosePlacement(string kind, in Val v, size_t line)
        @safe pure
    {
        if (kind == "vars")
            return; // a var assignation: choose allowed anywhere in the value
        if (kind == "hosts")
        {
            // A host entry may hold choose values inside its `vars`
            // block only (inventory var assignations); its other
            // attributes are plain values.
            if (v.kind == Val.Kind.table_)
            {
                foreach (string k, const Val e; v.table_)
                    if (k != "vars")
                        checkChoosePlacement("hosts", e, line);
                return;
            }
        }
        if (hasChoose(v))
            throw fail("'choose' is only available inside a var assignation");
    }

    private static bool hasChoose(in Val v) @safe pure
    {
        final switch (v.kind)
        {
            case Val.Kind.choose_:
                return true;
            case Val.Kind.array_:
                foreach (const ref e; v.array_)
                    if (hasChoose(e))
                        return true;
                return false;
            case Val.Kind.table_:
                foreach (string k, const Val e; v.table_)
                    if (hasChoose(e))
                        return true;
                return false;
            case Val.Kind.string_:
            case Val.Kind.integer_:
            case Val.Kind.float_:
            case Val.Kind.boolean_:
                return false;
        }
    }

    // -- blocks and entries ----------------------------------------------------

    private struct Entry
    {
        string key;
        Val value;
        size_t line;
    }

    /// `{ entries }` in source order.  Entries separate by commas and/or
    /// newlines; a trailing comma is allowed; the block may span lines.
    private Entry[] parseBlockEntries() @safe pure
    {
        expect('{', "to open a block");
        Entry[] entries;
        ws();
        while (true)
        {
            if (atEnd())
                throw fail("unterminated block (missing '}')");
            if (cur() == '}')
            {
                advance();
                return entries;
            }
            Entry e;
            e.line = line;
            e.key = parseKey("a key");
            hs();
            if (cur() == '{')
                e.value = tableOf(parseBlockEntries());
            else if (cur() == '=')
            {
                advance();
                ws();
                e.value = parseAssignedValue();
            }
            else if (cur() == '}' || cur() == ',' || cur() == '\n' || atEnd())
                // Same rule as statements: an entry with no attributes
                // may omit the braces (`hosts { web1 }`).
                e.value = emptyTable();
            else
                throw fail("expected '{', '=' or a separator after key '"
                    ~ e.key ~ "'");
            foreach (const ref prev; entries)
                if (prev.key == e.key)
                    throw new TachyError(path ~ ": line " ~ toText(e.line)
                        ~ ": duplicate key '" ~ e.key ~ "' in this block"
                        ~ " (first set at line " ~ toText(prev.line) ~ ")");
            entries ~= e;

            // Separator: a comma and/or at least one newline; a trailing
            // separator before '}' is fine.
            size_t newlines;
            hs();
            while (!atEnd() && src[i] == '\n')
            {
                advance();
                newlines++;
                hs();
            }
            bool comma = false;
            if (cur() == ',')
            {
                advance();
                comma = true;
                hs();
                while (!atEnd() && src[i] == '\n')
                {
                    advance();
                    newlines++;
                    hs();
                }
            }
            if (cur() == '}')
                continue; // closing handled at the loop top
            if (atEnd())
                throw fail("unterminated block (missing '}')");
            if (!comma && newlines == 0)
                throw fail("expected ',' or a newline between entries after '"
                    ~ e.key ~ "'");
        }
    }

    private Val tableOf(in Entry[] entries) @trusted pure
    {
        Val r;
        r.kind = Val.Kind.table_;
        foreach (const ref e; entries)
            r.table_[e.key] = cast(Val) e.value;
        return r;
    }

    private static Val emptyTable() @safe pure nothrow
    {
        Val r;
        r.kind = Val.Kind.table_;
        return r;
    }

    // -- keys --------------------------------------------------------------------

    /// Quoted (single-line) or bare key.  Bare keys are opaque: any
    /// characters except whitespace, structural punctuation, quotes, `#`,
    /// `\` and control characters — `/etc/nginx.conf` and `apt:nginx`
    /// need no quotes.
    private string parseKey(string what) @safe pure
    {
        if (cur() == '"')
            return parseBasicString();
        if (cur() == '\'')
            return parseLiteralString();
        size_t e = i;
        while (e < src.length && isKeyChar(src[e]))
            e++;
        if (e == i)
            throw fail("expected " ~ what);
        const string key = src[i .. e];
        i = e;
        return key;
    }

    // -- values --------------------------------------------------------------------

    /// The right-hand side of an `=`: a plain value — or a choose
    /// wrapped in a block, `= { choose "..." { ... } }` (the TODO's
    /// spellings), which reads as a block whose only entry is the
    /// anonymous `choose` production.
    private Val parseAssignedValue() @safe pure
    {
        if (cur() == '{' && lookingAtWrappedChoose())
            return parseWrappedChoose();
        return parseValue();
    }

    /// Lookahead: a `{` whose first token is the `choose` keyword
    /// followed by a quoted subject.  Restores the cursor either way.
    private bool lookingAtWrappedChoose() @safe pure
    {
        const size_t saveI = i;
        const size_t saveLine = line;
        advance(); // '{'
        ws();
        const bool wrapped = lookingAt("choose") && !isKeyChar(charAfter(6))
            && nextNonHsIsQuote(6);
        i = saveI;
        line = saveLine;
        return wrapped;
    }

    /// Whether a quoted string follows the n-character keyword at the
    /// cursor (horizontal skips allowed).
    private bool nextNonHsIsQuote(size_t n) @safe pure
    {
        size_t p = i + n;
        while (p < src.length && (src[p] == ' ' || src[p] == '\t' || src[p] == '\r'))
            p++;
        return p < src.length && (src[p] == '"' || src[p] == '\'');
    }

    /// `{ choose "<subject>" <cases> }` — the wrapper holds exactly the
    /// choose, nothing else.
    private Val parseWrappedChoose() @safe pure
    {
        expect('{', "to open the choose block");
        ws();
        advance(6); // the keyword, known present
        auto r = parseChooseBody();
        ws(); // the wrapper's '}' may sit on its own line
        expect('}', "to close the choose block");
        return r;
    }

    private Val parseValue() @safe pure
    {
        if (cur() == 'c' && lookingAt("choose") && !isKeyChar(charAfter(6)))
        {
            advance(6);
            return parseChooseBody();
        }
        switch (cur())
        {
            case '"':
                if (lookingAt(`"""`))
                    return Val(parseMultilineBasic());
                return Val(parseBasicString());
            case '\'':
                if (lookingAt("'''"))
                    return Val(parseMultilineLiteral());
                return Val(parseLiteralString());
            case '[':
                return parseArray();
            case '{':
                return tableOf(parseBlockEntries());
            case 't':
            case 'f':
                return parseBoolean();
            case '+':
            case '-':
            case '0': .. case '9':
                return parseNumber();
            default:
                throw fail("expected a value");
        }
    }

    /// `choose "<subject>" { "pattern" = value, ..., _ = default }` — a
    /// switch/case value (the keyword already consumed).  The subject is
    /// a quoted string (usually a `"{{ ... }}"` template); the block's
    /// entries are the cases, their keys the patterns, and the `_` key
    /// the mandatory default.  Only legal inside a var assignation
    /// (checked at statement level).
    private Val parseChooseBody() @trusted pure
    {
        hs();
        if (cur() != '"' && cur() != '\'')
            throw fail("the choose selector must be a quoted string");
        Val r;
        r.kind = Val.Kind.choose_;
        r.str_ = parseValue().str_;
        hs();
        auto entries = parseBlockEntries();
        bool haveDefault;
        foreach (const ref e; entries)
        {
            if (e.key == "_")
                haveDefault = true;
            r.choosePatterns_ ~= e.key;
            r.chooseValues_ ~= cast(Val) e.value;
        }
        if (!haveDefault)
            throw fail("a choose block needs a default '_' case");
        return r;
    }

    private Val parseBoolean() @safe pure
    {
        if (lookingAt("true"))
        {
            advance(4);
            return Val(true);
        }
        if (lookingAt("false"))
        {
            advance(5);
            return Val(false);
        }
        throw fail("expected a value");
    }

    private Val parseNumber() @safe pure
    {
        const size_t start = i;
        bool neg;
        if (cur() == '+' || cur() == '-')
        {
            neg = cur() == '-';
            advance();
        }
        // Special floats.
        if ((lookingAt("inf") || lookingAt("nan")) && !isKeyChar(charAfter(3)))
        {
            const bool isInf = src[i] == 'i';
            advance(3);
            if (isInf)
                return Val(neg ? -double.infinity : double.infinity);
            return Val(neg ? -double.nan : double.nan);
        }
        // Radix prefixes are integers.
        if (src.length - i >= 2 && cur() == '0'
                && (src[i + 1] == 'x' || src[i + 1] == 'o' || src[i + 1] == 'b'))
        {
            const char radix = src[i + 1];
            advance(2);
            long v;
            size_t digits;
            while (!atEnd() && (isRadixDigit(src[i], radix) || src[i] == '_'))
            {
                if (src[i] != '_')
                {
                    v = v * radixValue(radix) + digitValue(src[i]);
                    digits++;
                }
                advance();
            }
            if (digits == 0)
                throw fail("expected digits after the number prefix");
            if (!atEnd() && isKeyChar(src[i]))
                throw fail("invalid characters in number '" ~ src[start .. i] ~ "'");
            return Val(neg ? -v : v);
        }
        // Decimal digits (with underscores) — integer or float.
        long mant;
        size_t digits;
        while (!atEnd() && (src[i] >= '0' && src[i] <= '9' || src[i] == '_'))
        {
            if (src[i] != '_')
            {
                mant = mant * 10 + (src[i] - '0');
                digits++;
            }
            advance();
        }
        if (digits == 0)
            throw fail("expected a value");
        const bool frac = cur() == '.';
        const bool exp = cur() == 'e' || cur() == 'E';
        if (!frac && !exp)
        {
            const size_t firstDigit = start + ((src[start] == '+' || src[start] == '-') ? 1 : 0);
            if (digits > 1 && src[firstDigit] == '0')
                throw fail("integers may not have leading zeros");
            if (!atEnd() && isKeyChar(src[i]))
                throw fail("invalid characters in number '" ~ src[start .. i] ~ "'");
            return Val(neg ? -mant : mant);
        }
        // Float: rescan from the start so the value builds exactly.
        double v = 0;
        size_t j = start;
        if (src[j] == '+' || src[j] == '-')
            j++;
        for (; j < src.length && (src[j] >= '0' && src[j] <= '9' || src[j] == '_'); j++)
            if (src[j] != '_')
                v = v * 10 + (src[j] - '0');
        if (j < src.length && src[j] == '.')
        {
            j++;
            double scale = 0.1;
            for (; j < src.length && (src[j] >= '0' && src[j] <= '9' || src[j] == '_'); j++)
            {
                if (src[j] != '_')
                {
                    v += (src[j] - '0') * scale;
                    scale /= 10;
                }
            }
            if (scale == 0.1)
                throw fail("a fractional part needs digits after '.'");
        }
        if (j < src.length && (src[j] == 'e' || src[j] == 'E'))
        {
            j++;
            bool eneg;
            if (j < src.length && (src[j] == '+' || src[j] == '-'))
            {
                eneg = src[j] == '-';
                j++;
            }
            long ep;
            size_t ed;
            for (; j < src.length && src[j] >= '0' && src[j] <= '9'; j++)
            {
                ep = ep * 10 + (src[j] - '0');
                ed++;
            }
            if (ed == 0)
                throw fail("an exponent needs digits");
            import std.math : pow;
            v *= pow(10.0, cast(double) (eneg ? -ep : ep));
        }
        if (j < src.length && isKeyChar(src[j]))
            throw fail("invalid characters in number '" ~ src[start .. j] ~ "'");
        i = j;
        return Val(neg ? -v : v);
    }


    private static bool isRadixDigit(char c, char radix) @safe pure nothrow
    {
        switch (radix)
        {
            case 'x': return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F';
            case 'o': return c >= '0' && c <= '7';
            case 'b': return c == '0' || c == '1';
            default: assert(0);
        }
    }

    private static long radixValue(char radix) @safe pure nothrow
    {
        return radix == 'x' ? 16 : radix == 'o' ? 8 : 2;
    }

    private static long digitValue(char c) @safe pure nothrow
    {
        if (c <= '9')
            return c - '0';
        if (c <= 'F')
            return c - 'A' + 10;
        return c - 'a' + 10;
    }

    private Val parseArray() @safe pure
    {
        expect('[', "to open an array");
        Val r;
        r.kind = Val.Kind.array_;
        ws();
        if (cur() == ']')
        {
            advance();
            return r;
        }
        while (true)
        {
            ws();
            r.array_ ~= parseValue();
            ws();
            if (cur() == ',')
            {
                advance();
                ws();
                if (cur() == ']') // trailing comma
                    break;
                continue;
            }
            if (cur() == ']')
                break;
            throw fail("expected ',' or ']' between array elements");
        }
        if (atEnd() || cur() != ']')
            throw fail("unterminated array (missing ']')");
        advance();
        return r;
    }

    // -- strings ---------------------------------------------------------------------

    private string parseBasicString() @safe pure
    {
        expect('"', "to open a string");
        import std.array : appender;
        auto app = appender!string;
        while (true)
        {
            if (atEnd() || src[i] == '\n')
                throw fail("unterminated string");
            if (src[i] == '"')
            {
                advance();
                return app.data;
            }
            if (src[i] == '\\')
            {
                advance();
                parseEscape(app);
                continue;
            }
            app.put(src[i]);
            advance();
        }
    }

    private string parseLiteralString() @safe pure
    {
        expect('\'', "to open a string");
        size_t e = i;
        while (e < src.length && src[e] != '\'' && src[e] != '\n')
            e++;
        if (e == src.length || src[e] != '\'')
            throw fail("unterminated string");
        const string s = src[i .. e];
        advance(e - i + 1);
        return s;
    }

    private string parseMultilineBasic() @safe pure
    {
        advance(3);
        // A newline immediately after the opening quotes is trimmed.
        if (cur() == '\r')
            advance();
        if (cur() == '\n')
            advance();
        import std.array : appender;
        auto app = appender!string;
        while (true)
        {
            if (atEnd())
                throw fail("unterminated multi-line string");
            if (src[i] == '"')
            {
                // TOML rule: a run of quotes closes at its last trio; one
                // or two extra quotes before it belong to the content.
                size_t run = 0;
                while (i + run < src.length && src[i + run] == '"')
                    run++;
                if (run < 3)
                {
                    foreach (size_t k; 0 .. run)
                        app.put('"');
                    advance(run);
                    continue;
                }
                if (run > 5)
                    throw fail("too many consecutive '\"' — escape them");
                foreach (size_t k; 0 .. run - 3)
                    app.put('"');
                advance(run);
                return app.data;
            }
            if (src[i] == '\\')
            {
                // A backslash at end of line trims all whitespace up to
                // the next non-whitespace character.
                size_t j = i + 1;
                while (j < src.length && (src[j] == ' ' || src[j] == '\t' || src[j] == '\r'))
                    j++;
                if (j < src.length && src[j] == '\n')
                {
                    j++;
                    while (j < src.length && (src[j] == ' ' || src[j] == '\t'
                            || src[j] == '\r' || src[j] == '\n'))
                        j++;
                    line += countNewlines(src[i .. j]);
                    i = j;
                    continue;
                }
                advance();
                parseEscape(app);
                continue;
            }
            app.put(src[i]);
            advance();
        }
    }

    private string parseMultilineLiteral() @safe pure
    {
        advance(3);
        if (cur() == '\r')
            advance();
        if (cur() == '\n')
            advance();
        size_t e = i;
        while (e < src.length)
        {
            if (src[e] == '\'')
            {
                size_t run = 0;
                while (e + run < src.length && src[e + run] == '\'')
                    run++;
                if (run >= 3)
                    break;
                e += run;
            }
            else
                e++;
        }
        if (e >= src.length)
            throw fail("unterminated multi-line string");
        // The closer is the last trio of the run: content keeps run - 3.
        size_t run = 0;
        while (e + run < src.length && src[e + run] == '\'')
            run++;
        if (run > 5)
            throw fail("too many consecutive \"'\" — use a basic string");
        import std.array : appender;
        auto app = appender!string;
        foreach (size_t k; 0 .. run - 3)
            app.put('\'');
        const size_t end = e + run;
        const string body = src[i .. e];
        app.put(body);
        line += countNewlines(src[i .. end]);
        i = end;
        return app.data;
    }

    private void parseEscape(ref Appender!string app) @safe pure
    {
        if (atEnd())
            throw fail("unterminated escape sequence");
        const char c = src[i];
        advance();
        switch (c)
        {
            case 'b': app.put('\b'); break;
            case 't': app.put('\t'); break;
            case 'n': app.put('\n'); break;
            case 'f': app.put('\f'); break;
            case 'r': app.put('\r'); break;
            case '"': app.put('"'); break;
            case '\\': app.put('\\'); break;
            case 'u': app.put(hexChar(4)); break;
            case 'U': app.put(hexChar(8)); break;
            case '\n':
                throw fail("a backslash at the end of the line is only"
                    ~ " valid in a multi-line string");
            default:
                throw fail("unknown escape '\\" ~ c ~ "'");
        }
    }

    private string hexChar(size_t n) @safe pure
    {
        if (src.length - i < n)
            throw fail("expected " ~ toText(n) ~ " hexadecimal digits");
        dchar cp;
        foreach (size_t k; 0 .. n)
        {
            const char c = src[i + k];
            long v;
            if (c >= '0' && c <= '9')
                v = c - '0';
            else if (c >= 'a' && c <= 'f')
                v = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                v = c - 'A' + 10;
            else
                throw fail("expected hexadecimal digits after '\\"
                    ~ (n == 4 ? 'u' : 'U'));
            cp = cast(dchar) (cp * 16 + v);
        }
        advance(n);
        import std.utf : encode;
        char[4] buf;
        const size_t len = encode(buf, cp);
        return buf[0 .. len].idup;
    }

    private static size_t countNewlines(in char[] s) @safe pure nothrow
    {
        size_t n;
        foreach (char c; s)
            if (c == '\n')
                n++;
        return n;
    }
}

private string toText(T)(T v) @safe pure
{
    import std.conv : text;
    return text(v);
}

/// Parse Pravic from a string (the file loader's core; `path` names errors).
package(tachy) PracticDoc parsePractic(string src, string path) @safe pure
{
    auto p = Parser(src, path, 0, 1);
    return PracticDoc(p.parseFile());
}
