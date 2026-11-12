//! CommonMark/GFM rendering with safe embedded HTML.
//!
//! Pipeline:
//!   0. Table-start separation: GFM tables cannot interrupt a paragraph or a
//!      list, so a missing blank line before a table header is inserted at
//!      render time (the stored Markdown is never rewritten).
//!   1. Footnote preprocessing (`[^label]` definitions and references), which
//!      MD4C does not implement natively.
//!   2. MD4C 0.5.3 (vendored, MIT) with `MD_DIALECT_GITHUB`: tables, task
//!      lists, strikethrough, permissive autolinks, XHTML output.
//!   3. An allowlist HTML sanitizer over a real tag-tokenizer. MD4C passes raw
//!      HTML from the note through, and emits link destinations verbatim, so
//!      every byte of HTML output is sanitized, including crafted links,
//!      nested tags, malformed fragments, and remote resources.
//!
//! The sanitizer never uses regular expressions. It tokenizes tags with an
//! explicit element stack, drops comments, escapes disallowed tags as text,
//! strips every non-allowlisted attribute (including all `on*` handlers and
//! `style`), validates numeric/enumerated attributes, and applies the link
//! policy below. `class` and `id` values are inert in HTML and are kept only
//! after re-escaping. No `eval`-like construct exists in HTML output.
//!
//! Output is bounded: the note body is already capped at 256 KiB, element
//! nesting is capped, and total output is capped. Any unexpected failure
//! fails closed and renders the source as escaped text.
const std = @import("std");
const util = @import("http_util.zig");
const md4c = @import("md4c");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const max_depth: usize = 64;
const max_output_bytes: usize = 4 * 1024 * 1024;

pub fn render(w: *Writer, source: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    try renderWithAlloc(arena_state.allocator(), w, source);
}

pub fn renderWithAlloc(alloc: Allocator, w: *Writer, source: []const u8) !void {
    // All intermediates live in a child arena so callers (including tests
    // with leak checking) see one allocation boundary for the whole render.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const inner = arena_state.allocator();
    const separated = try separateTables(inner, source);
    const footnote_state = try expandFootnotes(inner, separated);
    var combined = md4cToHtmlAlloc(inner, footnote_state.cleaned) catch {
        try writeEscapedFallback(w, source);
        return;
    };
    if (footnote_state.entries.len > 0) {
        combined = try appendFootnoteSectionAlloc(inner, combined, footnote_state);
        combined = try replaceFootnoteTokens(inner, combined, footnote_state.entries.len);
    }
    try sanitize(w, inner, combined);
}

fn md4cToHtmlAlloc(alloc: Allocator, source: []const u8) ![]u8 {
    var out_ptr: [*c]u8 = undefined;
    var out_size: usize = 0;
    const rc = md4c.fn_md_render(source.ptr, source.len, &out_ptr, &out_size);
    if (rc != 0) return error.MdRenderFailed;
    defer md4c.fn_md_free(out_ptr);
    return try alloc.dupe(u8, out_ptr[0..out_size]);
}

fn appendFootnoteSectionAlloc(alloc: Allocator, main_html: []const u8, state: FootnoteState) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, main_html);
    try buf.appendSlice(alloc, "<section class=\"footnotes\"><hr><ol>\n");
    for (state.entries, 0..) |entry, idx| {
        var num: [24]u8 = undefined;
        const n = try std.fmt.bufPrint(&num, "{d}", .{entry.number});
        try buf.appendSlice(alloc, "<li id=\"fn-");
        try buf.appendSlice(alloc, n);
        try buf.appendSlice(alloc, "\">");
        if (idx < state.rendered.len) try buf.appendSlice(alloc, state.rendered[idx]);
        try buf.appendSlice(alloc, " <a href=\"#fn-ref-");
        try buf.appendSlice(alloc, n);
        try buf.appendSlice(alloc, "\" class=\"footnote-backref\">\u{21a9}</a></li>\n");
    }
    try buf.appendSlice(alloc, "</ol></section>\n");
    return try buf.toOwnedSlice(alloc);
}

fn replaceFootnoteTokens(alloc: Allocator, html: []const u8, entry_count: usize) ![]u8 {
    if (std.mem.indexOf(u8, html, "@@FNREF:") == null) return try alloc.dupe(u8, html);
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], "@@FNREF:")) {
            if (std.mem.indexOf(u8, html[i + 8 ..], "@@")) |rel| {
                const num_text = html[i + 8 .. i + 8 + rel];
                const num = std.fmt.parseInt(usize, num_text, 10) catch 0;
                if (num >= 1 and num <= entry_count) {
                    var num_buf: [24]u8 = undefined;
                    const n = try std.fmt.bufPrint(&num_buf, "{d}", .{num});
                    try buf.appendSlice(alloc, "<sup class=\"footnote-ref\"><a href=\"#fn-");
                    try buf.appendSlice(alloc, n);
                    try buf.appendSlice(alloc, "\" id=\"fn-ref-");
                    try buf.appendSlice(alloc, n);
                    try buf.appendSlice(alloc, "\">");
                    try buf.appendSlice(alloc, n);
                    try buf.appendSlice(alloc, "</a></sup>");
                    i += 8 + rel + 2;
                    continue;
                }
            }
        }
        try buf.append(alloc, html[i]);
        i += 1;
    }
    return try buf.toOwnedSlice(alloc);
}

fn writeEscapedFallback(w: *Writer, source: []const u8) !void {
    if (source.len == 0) return;
    try w.writeAll("<p>");
    try util.escapeHtml(w, source);
    try w.writeAll("</p>\n");
}

// ------------------------------------------------------- table separation

fn lineIndent(text: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and text[n] == ' ') : (n += 1) {}
    if (n < text.len and text[n] == '\t') return 4;
    return n;
}

fn lineIsBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r").len == 0;
}

fn lineContainsPipe(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '|') {
            i += 2;
            continue;
        }
        if (text[i] == '|') return true;
    }
    return false;
}

fn lineIsTableDelimiter(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r");
    if (t.len == 0 or !lineContainsPipe(t)) return false;
    var cells = std.mem.splitScalar(u8, t, '|');
    var saw_cell = false;
    while (cells.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t\r");
        if (c.len == 0) continue;
        var k = c;
        if (k.len > 0 and k[0] == ':') k = k[1..];
        if (k.len > 0 and k[k.len - 1] == ':') k = k[0 .. k.len - 1];
        if (k.len == 0) return false;
        for (k) |ch| if (ch != '-') return false;
        saw_cell = true;
    }
    return saw_cell;
}

/// GFM tables cannot interrupt a paragraph or a list: the header line must
/// be preceded by a blank line (or start the document). Authors frequently
/// omit that blank line, and the whole table then renders as literal text.
/// Insert the missing blank line before a detected table start (pipe header
/// + delimiter row) when the previous line is non-blank and does not itself
/// contain a pipe, outside fenced code and indented code. Render-time only:
/// the stored Markdown is never rewritten. Returns the source unchanged when
/// no separator is needed.
fn separateTables(alloc: Allocator, source: []const u8) ![]const u8 {
    var starts: std.ArrayList(usize) = .empty;
    var lines: std.ArrayList(struct { start: usize, text: []const u8 }) = .empty;
    var pos: usize = 0;
    while (pos <= source.len) {
        const nl = std.mem.findScalarPos(u8, source[pos..], 0, '\n');
        const end = if (nl) |p| pos + p else source.len;
        try lines.append(alloc, .{ .start = pos, .text = std.mem.trimEnd(u8, source[pos..end], "\r") });
        if (nl == null) break;
        pos = end + 1;
    }
    var fence: ?Fence = null;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (fence) |f| {
            if (fenceMarker(line.text)) |m| {
                if (m.ch == f.ch and m.n >= f.n) fence = null;
            }
            continue;
        }
        if (fenceMarker(line.text)) |m| {
            fence = m;
            continue;
        }
        if (i == 0 or i + 1 >= lines.items.len) continue;
        if (lineIndent(line.text) >= 4) continue; // indented code stays intact
        if (!lineContainsPipe(line.text)) continue;
        if (!lineIsTableDelimiter(lines.items[i + 1].text)) continue;
        const prev = lines.items[i - 1].text;
        if (lineIsBlank(prev) or lineContainsPipe(prev)) continue;
        try starts.append(alloc, line.start);
    }
    if (starts.items.len == 0) return source;
    var buf: std.ArrayList(u8) = .empty;
    var cur: usize = 0;
    for (starts.items) |start| {
        try buf.appendSlice(alloc, source[cur..start]);
        try buf.append(alloc, '\n');
        cur = start;
    }
    try buf.appendSlice(alloc, source[cur..]);
    return try buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------- footnotes

const FootnoteDef = struct {
    label: []const u8,
    text: []const u8,
    number: usize = 0, // 0 means not referenced yet
};

const FootnoteState = struct {
    cleaned: []const u8,
    entries: []FootnoteDef,
    // Rendered definitions (MD4C output for each referenced definition).
    rendered: [][]const u8,
};

fn isLabelChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
}

fn parseFootnoteDefStart(line: []const u8) ?[]const u8 {
    // Up to three spaces of indentation, then `[^label]:`.
    var i: usize = 0;
    while (i < line.len and line[i] == ' ' and i < 3) : (i += 1) {}
    if (i + 2 > line.len or line[i] != '[' or line[i + 1] != '^') return null;
    var j = i + 2;
    while (j < line.len and isLabelChar(line[j])) : (j += 1) {}
    if (j == i + 2 or j + 1 >= line.len or line[j] != ']' or line[j + 1] != ':') return null;
    return line[i + 2 .. j];
}

const Fence = struct { ch: u8, n: usize };

fn fenceMarker(line: []const u8) ?Fence {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ' and i < 3) : (i += 1) {}
    if (i >= line.len or (line[i] != '`' and line[i] != '~')) return null;
    var n: usize = 0;
    while (i + n < line.len and line[i + n] == line[i]) : (n += 1) {}
    if (n < 3) return null;
    return .{ .ch = line[i], .n = n };
}

fn expandFootnotes(alloc: Allocator, source: []const u8) !FootnoteState {
    if (std.mem.indexOfScalar(u8, source, '[') == null) {
        return .{ .cleaned = source, .entries = &.{}, .rendered = &.{} };
    }
    var defs: std.ArrayList(FootnoteDef) = .empty;
    var cleaned: std.ArrayList(u8) = .empty;
    var in_fence: ?Fence = null;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = raw_line;
        const trimmed_end = std.mem.trimEnd(u8, line, "\r");
        if (in_fence) |f| {
            try cleaned.appendSlice(alloc, line);
            try cleaned.append(alloc, '\n');
            if (fenceMarker(trimmed_end)) |m| {
                if (m.ch == f.ch and m.n >= f.n) in_fence = null;
            }
            continue;
        }
        if (fenceMarker(trimmed_end)) |m| {
            in_fence = m;
            try cleaned.appendSlice(alloc, line);
            try cleaned.append(alloc, '\n');
            continue;
        }
        if (parseFootnoteDefStart(trimmed_end)) |label| {
            const start = std.mem.indexOf(u8, trimmed_end, label).?;
            const after_colon = start + label.len + 2; // label, ']', ':'
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(alloc, std.mem.trimStart(u8, trimmed_end[after_colon..], " \t"));
            // Continuation lines indented by 4 spaces or a tab belong to the
            // definition (commonmark footnote convention). Peek next lines.
            while (it.peek()) |peek_raw| {
                if (isIndented(peek_raw)) {
                    _ = it.next();
                    try buf.append(alloc, '\n');
                    try buf.appendSlice(alloc, stripIndent(peek_raw));
                } else break;
            }
            try defs.append(alloc, .{
                .label = try alloc.dupe(u8, label),
                .text = try buf.toOwnedSlice(alloc),
            });
            continue;
        }
        try cleaned.appendSlice(alloc, line);
        try cleaned.append(alloc, '\n');
    }
    if (defs.items.len == 0) {
        return .{ .cleaned = source, .entries = &.{}, .rendered = &.{} };
    }
    // Replace `[^label]` references (outside fenced code) with text tokens.
    const token_prefix = "@@FNREF:";
    var out: std.ArrayList(u8) = .empty;
    in_fence = null;
    var lit = std.mem.splitScalar(u8, cleaned.items, '\n');
    var first_line = true;
    while (lit.next()) |line| {
        if (!first_line) try out.append(alloc, '\n');
        first_line = false;
        if (in_fence) |f| {
            try out.appendSlice(alloc, line);
            if (fenceMarker(std.mem.trimEnd(u8, line, "\r"))) |m| {
                if (m.ch == f.ch and m.n >= f.n) in_fence = null;
            }
            continue;
        }
        if (fenceMarker(std.mem.trimEnd(u8, line, "\r"))) |m| {
            in_fence = m;
            try out.appendSlice(alloc, line);
            continue;
        }
        var i: usize = 0;
        while (i < line.len) {
            const ch = line[i];
            if (ch == '`') {
                // Copy inline code spans verbatim so footnote-like text
                // inside code is never rewritten.
                var run: usize = 0;
                while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
                var j = i + run;
                var done = false;
                while (j < line.len) {
                    if (line[j] != '`') {
                        j += 1;
                        continue;
                    }
                    var close: usize = 0;
                    while (j + close < line.len and line[j + close] == '`') : (close += 1) {}
                    if (close == run) {
                        try out.appendSlice(alloc, line[i .. j + run]);
                        i = j + run;
                        done = true;
                        break;
                    }
                    j += close;
                }
                if (!done) {
                    try out.appendSlice(alloc, line[i..]);
                    i = line.len;
                }
                continue;
            }
            if (ch == '[' and i + 1 < line.len and line[i + 1] == '^') {
                var j = i + 2;
                while (j < line.len and isLabelChar(line[j])) : (j += 1) {}
                if (j > i + 2 and j < line.len and line[j] == ']') {
                    const label = line[i + 2 .. j];
                    var found: ?*FootnoteDef = null;
                    for (defs.items) |*d| {
                        if (std.mem.eql(u8, d.label, label)) {
                            found = d;
                            break;
                        }
                    }
                    if (found) |d| {
                        if (d.number == 0) {
                            var count: usize = 0;
                            for (defs.items) |def| {
                                if (def.number != 0) count += 1;
                            }
                            d.number = count + 1;
                        }
                        if (d.number != 0) {
                            var tok: [48]u8 = undefined;
                            try out.appendSlice(alloc, token_prefix);
                            try out.appendSlice(alloc, try std.fmt.bufPrint(&tok, "{d}", .{d.number}));
                            try out.appendSlice(alloc, "@@");
                            i = j + 1;
                            continue;
                        }
                    }
                }
            }
            try out.append(alloc, ch);
            i += 1;
        }
    }
    // Renumber by first-reference order (already assigned above), keep only
    // referenced definitions, in reference order.
    var referenced: std.ArrayList(FootnoteDef) = .empty;
    var max_n: usize = 0;
    for (defs.items) |d| {
        if (d.number > max_n) max_n = d.number;
    }
    var rendered: std.ArrayList([]const u8) = .empty;
    var n: usize = 1;
    while (n <= max_n) : (n += 1) {
        for (defs.items) |d| {
            if (d.number == n) {
                try referenced.append(alloc, d);
                try rendered.append(alloc, md4cToHtmlAlloc(alloc, d.text) catch "");
                break;
            }
        }
    }
    return .{
        .cleaned = try out.toOwnedSlice(alloc),
        .entries = try referenced.toOwnedSlice(alloc),
        .rendered = try rendered.toOwnedSlice(alloc),
    };
}

fn isIndented(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "\t")) return true;
    return std.mem.startsWith(u8, line, "    ");
}

fn stripIndent(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "\t")) return line[1..];
    if (std.mem.startsWith(u8, line, "    ")) return line[4..];
    return line;
}

// ---------------------------------------------------------------- sanitizer

const TagKind = enum { allow, drop_content, void_elem };

fn tagKind(name: []const u8) TagKind {
    if (std.mem.eql(u8, name, "br") or std.mem.eql(u8, name, "hr") or
        std.mem.eql(u8, name, "img") or std.mem.eql(u8, name, "input"))
    {
        return .void_elem;
    }
    if (std.mem.eql(u8, name, "script") or std.mem.eql(u8, name, "style") or
        std.mem.eql(u8, name, "iframe") or std.mem.eql(u8, name, "object") or
        std.mem.eql(u8, name, "embed") or std.mem.eql(u8, name, "link") or
        std.mem.eql(u8, name, "meta") or std.mem.eql(u8, name, "base") or
        std.mem.eql(u8, name, "svg") or std.mem.eql(u8, name, "math") or
        std.mem.eql(u8, name, "title") or std.mem.eql(u8, name, "head"))
    {
        return .drop_content;
    }
    if (allowedTag(name)) return .allow;
    return .drop_content;
}

fn allowedTag(name: []const u8) bool {
    const allowed = [_][]const u8{
        "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
        "strong", "em", "del", "code", "pre", "blockquote",
        "ul", "ol", "li", "table", "thead", "tbody", "tfoot", "tr", "th", "td",
        "a", "img", "details", "summary", "mark", "kbd", "sup", "sub",
        "div", "span", "section", "input", "dl", "dt", "dd", "figure", "figcaption",
    };
    for (allowed) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

const Attr = struct { name: []const u8, value: []const u8, has_value: bool };

fn isAttrNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':' or ch == '.';
}

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-';
}

fn sanitize(w: *Writer, alloc: Allocator, html: []const u8) !void {
    var stack: [max_depth][]const u8 = undefined;
    var depth: usize = 0;
    var written: usize = 0;
    var i: usize = 0;

    const out = struct {
        fn put(ww: *Writer, n: *usize, s: []const u8) !void {
            try ww.writeAll(s);
            n.* +|= s.len;
        }
    };

    while (i < html.len) {
        if (written > max_output_bytes) break;
        const ch = html[i];
        if (ch != '<') {
            // Text run until the next '<'. Valid entities pass through;
            // a bare '&' is escaped so it cannot smuggle an entity.
            const start = i;
            while (i < html.len and html[i] != '<') : (i += 1) {}
            try writeSafeText(w, html[start..i]);
            written += i - start + 8;
            continue;
        }
        // Comments are dropped entirely.
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            if (std.mem.indexOf(u8, html[i + 4 ..], "-->")) |end| {
                i = i + 4 + end + 3;
            } else break;
            continue;
        }
        if (i + 1 < html.len and (html[i + 1] == '!' or html[i + 1] == '?')) {
            // Doctype / processing-instruction style declarations: drop.
            if (std.mem.indexOfScalar(u8, html[i..], '>')) |end| {
                i += end + 1;
                continue;
            }
            break;
        }
        var p = i + 1;
        const closing = p < html.len and html[p] == '/';
        if (closing) p += 1;
        if (p >= html.len or !isAsciiAlpha(html[p])) {
            try w.writeAll("&lt;");
            i += 1;
            continue;
        }
        const name_start = p;
        while (p < html.len and isNameChar(html[p])) : (p += 1) {}
        var name_buf: [32]u8 = undefined;
        const raw_name = html[name_start..p];
        if (raw_name.len >= name_buf.len) {
            // Over-long tag names cannot be allowlisted. Escape the tag.
            if (std.mem.indexOfScalar(u8, html[i..], '>')) |end| {
                try util.escapeHtml(w, html[i .. i + end + 1]);
                i += end + 1;
                continue;
            }
            break;
        }
        const name = std.ascii.lowerString(&name_buf, raw_name);
        // Parse attributes until '>' or '/>'.
        var attrs: [24]Attr = undefined;
        var attr_count: usize = 0;
        var self_closing = false;
        var saw_gt = false;
        var q = p;
        while (q < html.len) {
            while (q < html.len and isSpace(html[q])) : (q += 1) {}
            if (q >= html.len) break;
            if (html[q] == '>' or (html[q] == '/' and q + 1 < html.len and html[q + 1] == '>')) {
                self_closing = html[q] == '/' and q + 1 < html.len and html[q + 1] == '>';
                saw_gt = true;
                q += if (self_closing) 2 else 1;
                break;
            }
            if (!isAttrNameChar(html[q])) {
                q += 1; // stray character in the tag; skip it
                continue;
            }
            const astart = q;
            while (q < html.len and isAttrNameChar(html[q])) : (q += 1) {}
            const aname = html[astart..q];
            while (q < html.len and isSpace(html[q])) : (q += 1) {}
            var value: []const u8 = "";
            var has_value = false;
            if (q < html.len and html[q] == '=') {
                q += 1;
                while (q < html.len and isSpace(html[q])) : (q += 1) {}
                if (q < html.len and (html[q] == '"' or html[q] == '\'')) {
                    const quote = html[q];
                    q += 1;
                    const vs = q;
                    while (q < html.len and html[q] != quote) : (q += 1) {}
                    value = html[vs..q];
                    has_value = true;
                    if (q < html.len) q += 1;
                } else {
                    const vs = q;
                    while (q < html.len and !isSpace(html[q]) and html[q] != '>') : (q += 1) {}
                    value = html[vs..q];
                    has_value = true;
                }
            }
            if (attr_count < attrs.len) {
                attrs[attr_count] = .{ .name = aname, .value = value, .has_value = has_value };
                attr_count += 1;
            }
        }
        if (!saw_gt) break; // unterminated tag: drop the rest
        const tag_slice = html[i..q];
        i = q;

        if (closing) {
            // Close only to the matching open element on the stack.
            var idx: ?usize = null;
            var s: usize = depth;
            while (s > 0) {
                s -= 1;
                if (std.mem.eql(u8, stack[s], name)) {
                    idx = s;
                    break;
                }
            }
            if (idx) |at| {
                while (depth > at) {
                    depth -= 1;
                    try out.put(w, &written, "</");
                    try out.put(w, &written, stack[depth]);
                    try out.put(w, &written, ">");
                }
            } else if (allowedTag(name) and tagKind(name) == .allow) {
                // Stray closer for an allowed, non-void tag: ignore it.
            } else {
                try util.escapeHtml(w, tag_slice);
            }
            continue;
        }

        switch (tagKind(name)) {
            .void_elem => {
                try writeAllowedTag(w, alloc, name, attrs[0..attr_count]);
            },
            .drop_content => {
                // Fail closed: show the markup as text, never as an element.
                // Content between the tags is processed as ordinary text, so
                // nothing inside can become an element except allowlisted
                // markup - which the stack logic still sanitizes.
                try util.escapeHtml(w, tag_slice);
            },
            .allow => {
                if (depth >= max_depth) {
                    try util.escapeHtml(w, tag_slice);
                    continue;
                }
                try writeAllowedTag(w, alloc, name, attrs[0..attr_count]);
                if (!self_closing) {
                    stack[depth] = name;
                    depth += 1;
                }
            },
        }
    }
    while (depth > 0) {
        depth -= 1;
        try w.writeAll("</");
        try w.writeAll(stack[depth]);
        try w.writeAll(">");
    }
}

fn isAsciiAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0c';
}

fn writeSafeText(w: *Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '&') {
            if (validEntity(text, i)) |len| {
                try w.writeAll(text[i .. i + len]);
                i += len;
                continue;
            }
            try w.writeAll("&amp;");
            i += 1;
            continue;
        }
        if (ch == '<') {
            try w.writeAll("&lt;");
            i += 1;
            continue;
        }
        if (ch == '>') {
            try w.writeAll("&gt;");
            i += 1;
            continue;
        }
        try w.writeByte(ch);
        i += 1;
    }
}

fn validEntity(text: []const u8, at: usize) ?usize {
    // `&name;`, `&#123;`, or `&#x1F;`. The name itself is not restricted
    // because unknown entities render as literal text in browsers.
    var j = at + 1;
    if (j >= text.len) return null;
    if (text[j] == '#') {
        j += 1;
        if (j < text.len and (text[j] == 'x' or text[j] == 'X')) {
            j += 1;
            const start = j;
            while (j < text.len and hexVal(text[j]) != null) : (j += 1) {}
            if (j > start and j < text.len and text[j] == ';') return j - at + 1;
            return null;
        }
        const start = j;
        while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {}
        if (j > start and j < text.len and text[j] == ';') return j - at + 1;
        return null;
    }
    const start = j;
    while (j < text.len and std.ascii.isAlphanumeric(text[j])) : (j += 1) {}
    if (j > start and j - start <= 32 and j < text.len and text[j] == ';') return j - at + 1;
    return null;
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn writeAllowedTag(w: *Writer, alloc: Allocator, name: []const u8, attrs: []const Attr) !void {
    // Checkboxes are the only <input> allowed (GFM task lists).
    if (std.mem.eql(u8, name, "input")) {
        var type_ok = false;
        var any_checked = false;
        for (attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, "type") and std.ascii.eqlIgnoreCase(a.value, "checkbox")) {
                type_ok = true;
            }
            if (std.ascii.eqlIgnoreCase(a.name, "checked")) any_checked = true;
        }
        if (!type_ok) return; // drop non-checkbox inputs silently
        try w.writeAll("<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled");
        if (any_checked) try w.writeAll(" checked");
        try w.writeAll(">");
        return;
    }
    try w.writeByte('<');
    try w.writeAll(name);
    for (attrs) |a| {
        if (try writeAttr(w, alloc, name, a)) continue;
    }
    switch (tagKind(name)) {
        .void_elem => try w.writeAll(" />"),
        else => try w.writeAll(">"),
    }
}

fn writeAttr(w: *Writer, alloc: Allocator, tag: []const u8, a: Attr) !bool {
    if (std.ascii.eqlIgnoreCase(a.name, "href")) {
        if (!std.mem.eql(u8, tag, "a")) return false;
        const clean = decodeAttrEntities(alloc, a.value) catch return false;
        if (!safeHref(alloc, clean)) return false;
        try w.writeAll(" href=\"");
        try util.escapeHtml(w, clean);
        try w.writeAll("\"");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "src")) {
        if (!std.mem.eql(u8, tag, "img")) return false;
        const clean = decodeAttrEntities(alloc, a.value) catch return false;
        if (!safeImgSrc(alloc, clean)) return false;
        try w.writeAll(" src=\"");
        try util.escapeHtml(w, clean);
        try w.writeAll("\"");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "alt") or std.ascii.eqlIgnoreCase(a.name, "title")) {
        try w.writeAll(" ");
        try w.writeAll(a.name);
        try w.writeAll("=\"");
        try util.escapeHtml(w, a.value);
        try w.writeAll("\"");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "align")) {
        const v = a.value;
        if (std.mem.eql(u8, v, "left") or std.mem.eql(u8, v, "center") or std.mem.eql(u8, v, "right")) {
            try w.writeAll(" align=\"");
            try w.writeAll(v);
            try w.writeAll("\"");
            return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "colspan") or std.ascii.eqlIgnoreCase(a.name, "rowspan") or
        std.ascii.eqlIgnoreCase(a.name, "start"))
    {
        if (!isDigits(a.value) or a.value.len == 0) return false;
        try w.writeAll(" ");
        try w.writeAll(a.name);
        try w.writeAll("=\"");
        try w.writeAll(a.value);
        try w.writeAll("\"");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "scope")) {
        if (std.mem.eql(u8, a.value, "col") or std.mem.eql(u8, a.value, "row")) {
            try w.writeAll(" scope=\"");
            try w.writeAll(a.value);
            try w.writeAll("\"");
            return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "open")) {
        if (std.mem.eql(u8, tag, "details")) {
            try w.writeAll(" open");
            return true;
        }
        return false;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "class")) {
        // Class names are inert. Re-escape the value; CSS cannot execute.
        try w.writeAll(" class=\"");
        try util.escapeHtml(w, a.value);
        try w.writeAll("\"");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(a.name, "id")) {
        try w.writeAll(" id=\"");
        try util.escapeHtml(w, a.value);
        try w.writeAll("\"");
        return true;
    }
    return false;
}

fn isDigits(text: []const u8) bool {
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

// Decode HTML entities in an attribute value so scheme checks cannot be
// bypassed with `&#106;avascript:` and friends.
fn decodeAttrEntities(alloc: Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, '&') == null) return value;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '&') {
            try out.append(alloc, value[i]);
            i += 1;
            continue;
        }
        if (validEntity(value, i)) |len| {
            const entity = value[i + 1 .. i + len - 1]; // without & and ;
            if (entity.len > 0 and entity[0] == '#') {
                var cp: u21 = 0;
                if (entity.len > 1 and (entity[1] == 'x' or entity[1] == 'X')) {
                    cp = std.fmt.parseInt(u21, entity[2..], 16) catch 0;
                } else {
                    cp = std.fmt.parseInt(u21, entity[1..], 10) catch 0;
                }
                var utf: [4]u8 = undefined;
                if (cp == 0) {
                    try out.append(alloc, '?');
                } else if (std.unicode.utf8Encode(cp, &utf) catch null) |n| {
                    try out.appendSlice(alloc, utf[0..n]);
                } else {
                    try out.append(alloc, '?');
                }
            } else {
                try appendNamedEntity(alloc, &out, entity);
            }
            i += len;
            continue;
        }
        try out.append(alloc, value[i]);
        i += 1;
    }
    const snap = try out.toOwnedSlice(alloc);
    return snap;
}

fn appendNamedEntity(alloc: Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "amp", "&" }, .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" },
        .{ "apos", "'" }, .{ "colon", ":" }, .{ "sol", "/" }, .{ "comma", "," },
        .{ "period", "." },   .{ "tab", "\t" }, .{ "NewLine", "\n" },
        .{ "nbsp", "\xc2\xa0" }, .{ "lpar", "(" }, .{ "rpar", ")" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, name, row[0])) {
            try out.appendSlice(alloc, row[1]);
            return;
        }
    }
    // Unknown entities stay literal so resolution cannot hide a scheme.
    try out.append(alloc, '&');
    try out.appendSlice(alloc, name);
    try out.append(alloc, ';');
}

fn stripControls(alloc: Allocator, value: []const u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f) continue;
        if (ch == ' ') continue;
        try out.append(alloc, ch);
    }
    return out;
}

fn safeHref(alloc: Allocator, clean: []const u8) bool {
    var stripped = stripControls(alloc, clean) catch return false;
    defer stripped.deinit(alloc);
    const v = stripped.items;
    if (v.len == 0) return false;
    if (v[0] == '/' and v.len > 1 and v[1] == '/') return false; // protocol-relative
    if (v[0] == '#' or v[0] == '/' or v[0] == '?') return true;
    // A scheme is `alpha *alnum + - .` followed by ':' before any / ? #.
    var i: usize = 0;
    while (i < v.len and v[i] != ':' and v[i] != '/' and v[i] != '?' and v[i] != '#') : (i += 1) {}
    if (i < v.len and v[i] == ':') {
        if (i == 0 or !isAsciiAlpha(v[0])) return false;
        var j: usize = 1;
        while (j < i) : (j += 1) {
            const ch = v[j];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return false;
        }
        const scheme = v[0..i];
        return std.ascii.eqlIgnoreCase(scheme, "http") or
            std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "mailto");
    }
    return true; // scheme-relative path such as "notes/1" or "files/1/x"
}

fn safeImgSrc(alloc: Allocator, clean: []const u8) bool {
    var stripped = stripControls(alloc, clean) catch return false;
    defer stripped.deinit(alloc);
    const v = stripped.items;
    // Same-origin absolute paths only (CSP img-src 'self'); this also keeps
    // protocol-relative and remote tracking pixels out.
    if (v.len < 1 or v[0] != '/') return false;
    if (v.len > 1 and v[1] == '/') return false;
    return true;
}

// --------------------------------------------------------------------- tests

fn renderToString(alloc: Allocator, source: []const u8) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderWithAlloc(alloc, &w, source);
    return alloc.dupe(u8, w.buffered());
}

test "markdown renders the Fibonacci table as a real table" {
    const alloc = std.testing.allocator;
    const out = try renderToString(alloc, "# Fibonacci\n\n| Katsayi | Yuzde | Aciklama |\n|---------|-------|----------|\n| 0.000 | %0 | Baslangic |\n| 0.236 | %23,6 | Sig |\n");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<table") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<thead") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tbody") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Katsayi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "| Katsayi |") == null);
}

test "markdown renders a table that directly follows a list without a blank line" {
    const alloc = std.testing.allocator;
    const out = try renderToString(alloc, "- first item\n- second item\n| A | B |\n| --- | --- |\n| 1 | 2 |\n");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<table") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tbody") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "| A |") == null);
    // A table directly after a paragraph, inside fenced code, and inside
    // indented code: the first must render, the other two stay literal.
    const para = try renderToString(alloc, "Some intro text\n| A | B |\n| --- | --- |\n| 1 | 2 |\n");
    defer alloc.free(para);
    try std.testing.expect(std.mem.indexOf(u8, para, "<table") != null);
    const fenced = try renderToString(alloc, "```\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```\n");
    defer alloc.free(fenced);
    try std.testing.expect(std.mem.indexOf(u8, fenced, "<table") == null);
    try std.testing.expect(std.mem.indexOf(u8, fenced, "| A |") != null);
    const indented = try renderToString(alloc, "    | A | B |\n    | --- | --- |\n    | 1 | 2 |\n");
    defer alloc.free(indented);
    try std.testing.expect(std.mem.indexOf(u8, indented, "<table") == null);
    // A pipe line that is not a table start is untouched, and setext
    // headings (no pipe in the underline) are not misread as delimiters.
    const plain = try renderToString(alloc, "a | b is not a table\n\nTitle\n---\n");
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "<table") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "<h2") != null);
}

test "markdown renders GFM task lists, tables, and footnotes" {
    const alloc = std.testing.allocator;
    const out = try renderToString(alloc, "- [x] done\n- [ ] open\n\ntext[^1]\n\n[^1]: note text\n");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "checkbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "checked") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "note text") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FNREF") == null);
}

test "markdown escapes raw HTML and blocks XSS fixtures" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "<script>alert(1)</script>",
        "<a href=\"javascript:alert(1)\">x</a>",
        "<a href=\"&#106;avascript:alert(1)\">x</a>",
        "<img src=\"x\" onerror=\"alert(1)\">",
        "<svg onload=alert(1)>",
        "<iframe src=\"https://evil.example\">",
        "<div style=\"x:expression(alert(1))\">hi</div>",
        "[click](javascript:alert(1))",
        "[click](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)",
        "![remote](https://evil.example/pixel.png)",
        "![proto](//evil.example/pixel.png)",
    };
    for (cases) |c| {
        const out = try renderToString(alloc, c);
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "<script") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "javascript:") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "onerror") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "<svg") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "<iframe") == null);
        // `evil.example` may appear only as escaped text (the iframe tag is
        // shown, not executed); it must never reach a live src/href/pixel URL.
        try std.testing.expect(std.mem.indexOf(u8, out, "evil.example/pixel") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "src=\"https://evil.example/pixel") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "style=") == null);
    }
}

test "markdown preserves safe inline HTML and safe links" {
    const alloc = std.testing.allocator;
    const out = try renderToString(alloc, "<details><summary>s</summary>body</details> <mark>m</mark> [ok](/files/1/a.png) [web](https://example.com)\n");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<details") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<mark") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/files/1/a.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com") != null);
}

test "markdown renders nested emphasis, unicode, and Turkish characters" {
    const alloc = std.testing.allocator;
    const out = try renderToString(alloc, "# Grüße ğüşiöç\n\n**a *b* c** and `code|x`\n\n- one\n  - nested\n- two\n");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ğüşiöç") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<strong") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nested") != null);
}
