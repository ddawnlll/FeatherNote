//! Small, safe Markdown renderer.
//!
//! The output is HTML that FeatherNote generates itself. Source text is escaped
//! before it is written, raw HTML is never passed through, and link/image URLs
//! are restricted to http(s), mailto, and same-origin absolute paths.
const std = @import("std");
const util = @import("http_util.zig");

const Writer = std.Io.Writer;
const max_depth: usize = 8;

pub fn render(w: *Writer, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var paragraph_open = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) {
            try closeParagraph(w, &paragraph_open);
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            try closeParagraph(w, &paragraph_open);
            try renderFence(w, &lines, line[3..]);
            continue;
        }
        if (isIndented(line)) {
            try closeParagraph(w, &paragraph_open);
            try w.writeAll("<pre><code>");
            var current = line;
            var first = true;
            while (true) {
                if (!first) try w.writeByte('\n');
                try util.escapeHtml(w, stripIndent(current));
                first = false;
                const peek_raw = lines.peek() orelse break;
                const next = std.mem.trimEnd(u8, peek_raw, "\r");
                if (!isIndented(next)) break;
                _ = lines.next();
                current = next;
            }
            try w.writeAll("</code></pre>\n");
            continue;
        }
        if (headingLevel(line)) |level| {
            try closeParagraph(w, &paragraph_open);
            try w.print("<h{d}>", .{level});
            try renderInline(w, line[level + 1 ..], 0);
            try w.print("</h{d}>\n", .{level});
            continue;
        }
        if (isRule(line)) {
            try closeParagraph(w, &paragraph_open);
            try w.writeAll("<hr>\n");
            continue;
        }
        if (std.mem.startsWith(u8, line, ">")) {
            try closeParagraph(w, &paragraph_open);
            try w.writeAll("<blockquote><p>");
            try renderInline(w, std.mem.trimStart(u8, line[1..], " "), 0);
            while (lines.peek()) |next_raw| {
                const next = std.mem.trimEnd(u8, next_raw, "\r");
                if (!std.mem.startsWith(u8, next, ">")) break;
                _ = lines.next();
                try w.writeAll("<br>\n");
                try renderInline(w, std.mem.trimStart(u8, next[1..], " "), 0);
            }
            try w.writeAll("</p></blockquote>\n");
            continue;
        }
        if (listItem(line)) |item| {
            try closeParagraph(w, &paragraph_open);
            try renderList(w, &lines, item);
            continue;
        }
        if (!paragraph_open) {
            try w.writeAll("<p>");
            paragraph_open = true;
        } else {
            try w.writeAll("<br>\n");
        }
        try renderInline(w, line, 0);
    }
    try closeParagraph(w, &paragraph_open);
}

fn closeParagraph(w: *Writer, open: *bool) !void {
    if (!open.*) return;
    try w.writeAll("</p>\n");
    open.* = false;
}

const ListItem = struct { ordered: bool, text: []const u8 };

fn listItem(line: []const u8) ?ListItem {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
        return .{ .ordered = false, .text = line[2..] };
    }
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') {
        return .{ .ordered = true, .text = line[i + 2 ..] };
    }
    return null;
}

fn renderList(w: *Writer, lines: *std.mem.SplitIterator(u8, .scalar), first: ListItem) !void {
    const tag: []const u8 = if (first.ordered) "ol" else "ul";
    try w.print("<{s}>\n", .{tag});
    try w.writeAll("<li>");
    try renderInline(w, first.text, 0);
    try w.writeAll("</li>\n");
    while (lines.peek()) |peek_raw| {
        const peek = std.mem.trimEnd(u8, peek_raw, "\r");
        const item = listItem(peek) orelse break;
        if (item.ordered != first.ordered) break;
        _ = lines.next();
        try w.writeAll("<li>");
        try renderInline(w, item.text, 0);
        try w.writeAll("</li>\n");
    }
    try w.print("</{s}>\n", .{tag});
}

fn renderFence(w: *Writer, lines: *std.mem.SplitIterator(u8, .scalar), info: []const u8) !void {
    const lang = std.mem.trim(u8, info, " \t");
    if (lang.len > 0) {
        try w.writeAll("<pre><code class=\"language-");
        try writeSafeClass(w, lang);
        try w.writeAll("\">");
    } else {
        try w.writeAll("<pre><code>");
    }
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "```")) break;
        if (!first) try w.writeByte('\n');
        try util.escapeHtml(w, line);
        first = false;
    }
    try w.writeAll("</code></pre>\n");
}

fn writeSafeClass(w: *Writer, lang: []const u8) !void {
    for (lang) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '+') {
            try w.writeByte(ch);
        }
    }
}

fn headingLevel(line: []const u8) ?usize {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') : (level += 1) {}
    if (level == 0 or level > 6 or level >= line.len or line[level] != ' ') return null;
    return level;
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

fn isRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    var count: usize = 0;
    var marker: ?u8 = null;
    for (trimmed) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (marker == null) {
            if (ch != '-' and ch != '*' and ch != '_') return false;
            marker = ch;
        }
        if (ch != marker.?) return false;
        count += 1;
    }
    return count >= 3;
}

fn renderInline(w: *Writer, text: []const u8, depth: usize) anyerror!void {
    if (depth > max_depth) {
        try util.escapeHtml(w, text);
        return;
    }
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\\' and i + 1 < text.len) {
            try util.escapeHtml(w, text[i + 1 .. i + 2]);
            i += 2;
            continue;
        }
        if (ch == '`') {
            if (try renderCodeSpan(w, text, &i)) continue;
        }
        if (ch == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (try renderImage(w, text, &i)) continue;
        }
        if (ch == '[') {
            if (try renderLink(w, text, &i, depth)) continue;
        }
        if (ch == '*' or ch == '_' or ch == '~') {
            if (try renderEmphasis(w, text, &i, depth)) continue;
        }
        try util.escapeHtml(w, text[i .. i + 1]);
        i += 1;
    }
}

fn renderCodeSpan(w: *Writer, text: []const u8, i: *usize) anyerror!bool {
    var run: usize = 0;
    while (i.* + run < text.len and text[i.* + run] == '`') : (run += 1) {}
    if (run == 0) return false;
    const content_start = i.* + run;
    var j = content_start;
    while (j < text.len) {
        if (text[j] != '`') {
            j += 1;
            continue;
        }
        var close_run: usize = 0;
        while (j + close_run < text.len and text[j + close_run] == '`') : (close_run += 1) {}
        if (close_run == run) {
            try w.writeAll("<code>");
            try util.escapeHtml(w, text[content_start..j]);
            try w.writeAll("</code>");
            i.* = j + run;
            return true;
        }
        j += close_run;
    }
    return false;
}

fn renderEmphasis(w: *Writer, text: []const u8, i: *usize, depth: usize) anyerror!bool {
    const marker = text[i.*];
    const start = i.*;
    if (marker == '_' and start > 0 and isWordChar(text[start - 1])) return false;
    var run: usize = 0;
    while (start + run < text.len and text[start + run] == marker) : (run += 1) {}
    const double = run >= 2;
    if (marker == '~' and !double) return false;
    const width: usize = if (double) 2 else 1;
    const content_start = start + width;
    if (content_start >= text.len) return false;
    var j = content_start;
    while (j < text.len) {
        if (text[j] == '\\') {
            j += 2;
            continue;
        }
        if (text[j] != marker) {
            j += 1;
            continue;
        }
        var close_run: usize = 0;
        while (j + close_run < text.len and text[j + close_run] == marker) : (close_run += 1) {}
        const enough = if (double) close_run >= 2 else close_run == 1;
        const end_ok = j + width <= text.len;
        const boundary_ok = !(marker == '_' and j + width < text.len and isWordChar(text[j + width]));
        if (enough and end_ok and boundary_ok) {
            const tag_open: []const u8 = switch (marker) {
                '~' => "<del>",
                else => if (double) "<strong>" else "<em>",
            };
            const tag_close: []const u8 = switch (marker) {
                '~' => "</del>",
                else => if (double) "</strong>" else "</em>",
            };
            try w.writeAll(tag_open);
            try renderInline(w, text[content_start..j], depth + 1);
            try w.writeAll(tag_close);
            i.* = j + width;
            return true;
        }
        j += close_run;
    }
    return false;
}

fn renderLink(w: *Writer, text: []const u8, i: *usize, depth: usize) anyerror!bool {
    const start = i.*;
    const close_bracket = std.mem.findScalarPos(u8, text, start + 1, ']') orelse return false;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return false;
    const close_paren = std.mem.findScalarPos(u8, text, close_bracket + 2, ')') orelse return false;
    const label = text[start + 1 .. close_bracket];
    const url = text[close_bracket + 2 .. close_paren];
    if (!safeUrl(url, false)) return false;
    try w.writeAll("<a href=\"");
    try util.escapeHtml(w, url);
    try w.writeAll("\" rel=\"nofollow noopener\">");
    try renderInline(w, label, depth + 1);
    try w.writeAll("</a>");
    i.* = close_paren + 1;
    return true;
}

fn renderImage(w: *Writer, text: []const u8, i: *usize) anyerror!bool {
    const start = i.*;
    const close_bracket = std.mem.findScalarPos(u8, text, start + 2, ']') orelse return false;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return false;
    const close_paren = std.mem.findScalarPos(u8, text, close_bracket + 2, ')') orelse return false;
    const alt = text[start + 2 .. close_bracket];
    const url = text[close_bracket + 2 .. close_paren];
    if (!safeUrl(url, true)) return false;
    try w.writeAll("<img src=\"");
    try util.escapeHtml(w, url);
    try w.writeAll("\" alt=\"");
    try util.escapeHtml(w, alt);
    try w.writeAll("\" loading=\"lazy\" decoding=\"async\">");
    i.* = close_paren + 1;
    return true;
}

fn safeUrl(url: []const u8, image: bool) bool {
    if (url.len == 0 or url.len > 2048) return false;
    for (url) |ch| {
        if (std.ascii.isControl(ch) or ch == ' ' or ch == '"' or ch == '\'' or ch == '<' or ch == '>') return false;
    }
    if (std.mem.startsWith(u8, url, "//")) return false;
    if (image) return std.mem.startsWith(u8, url, "/");
    if (startsWithIgnoreCase(url, "https://") or startsWithIgnoreCase(url, "http://")) return true;
    if (startsWithIgnoreCase(url, "mailto:")) return true;
    return std.mem.startsWith(u8, url, "/");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

// ---- tests ----

test "markdown escapes raw HTML and unsafe links" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try render(&w, "<script>alert(1)</script>\n\n[click](javascript:alert(1))\n\n![x](data:text/html,hi)");
    const out = w.buffered();
    try std.testing.expect(std.mem.find(u8, out, "<script>") == null);
    try std.testing.expect(std.mem.find(u8, out, "href=\"javascript:") == null);
    try std.testing.expect(std.mem.find(u8, out, "src=\"data:") == null);
    try std.testing.expect(std.mem.find(u8, out, "&lt;script&gt;") != null);
}

test "markdown renders headings, lists, code, and safe links" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try render(&w,
        \\# Title
        \\
        \\Hello **bold** and `code`.
        \\
        \\- one
        \\- two
        \\
        \\```zig
        \\const x = 1 < 2;
        \\```
        \\
        \\[docs](https://example.com/a?b=1)
    );
    const out = w.buffered();
    try std.testing.expect(std.mem.find(u8, out, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.find(u8, out, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.find(u8, out, "<code>code</code>") != null);
    try std.testing.expect(std.mem.find(u8, out, "<ul>") != null);
    try std.testing.expect(std.mem.find(u8, out, "1 &lt; 2") != null);
    try std.testing.expect(std.mem.find(u8, out, "href=\"https://example.com/a?b=1\"") != null);
}

test "markdown leaves snake_case alone and renders images" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try render(&w, "snake_case_name\n\n![cat](/files/3/cat.png)");
    const out = w.buffered();
    try std.testing.expect(std.mem.find(u8, out, "<em>") == null);
    try std.testing.expect(std.mem.find(u8, out, "src=\"/files/3/cat.png\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "alt=\"cat\"") != null);
}

test "markdown keeps images same-origin" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try render(&w, "![remote](https://example.com/track.png)\n\n![local](/files/1/a.png)");
    const out = w.buffered();
    try std.testing.expect(std.mem.find(u8, out, "src=\"https://example.com/track.png\"") == null);
    try std.testing.expect(std.mem.find(u8, out, "src=\"/files/1/a.png\"") != null);
}

test "markdown renders indented code blocks" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try render(&w, "Intro\n\n    const x = 1 < 2;\n    const y = 3;");
    const out = w.buffered();
    try std.testing.expect(std.mem.find(u8, out, "<pre><code>const x = 1 &lt; 2;") != null);
    try std.testing.expect(std.mem.find(u8, out, "\nconst y = 3;</code></pre>") != null);
}
