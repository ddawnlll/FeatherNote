//! Lossless Markdown block mapping for the server-driven block editor.
//!
//! The note body is split into blocks described by byte ranges
//! `[start, end)` over the original body. The separator bytes between blocks
//! (newlines and blank lines) belong to neither block, so splicing one block
//! never rewrites its neighbors: unedited blocks, including unsupported
//! constructs (fenced code, tables, reference definitions, raw HTML), keep
//! their exact bytes. Opening the block editor and changing nothing writes
//! nothing at all.
//!
//! Block kinds mirror the renderer in `src/markdown.zig`. Constructs the
//! editor cannot regenerate without loss (indented code, nested lists,
//! reference definitions, HTML blocks, multi-paragraph quotes, ...) are
//! classified as `raw` and stay editable as verbatim Markdown (the source
//! fallback) instead of being destructively converted.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_blocks: usize = 200;
/// Largest number of table cells the block editor will render.
pub const max_table_cells: usize = 512;

pub const Kind = enum {
    paragraph,
    heading,
    list_unordered,
    list_ordered,
    list_task,
    quote,
    code,
    table,
    hr,
    link,
    image,
    raw,
};

pub const Block = struct {
    start: usize,
    end: usize,
    kind: Kind,
    level: u8 = 0, // headings only
    lang: []const u8 = "", // code blocks only (slice into body or a buffer)
};

pub fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .paragraph => "Paragraph",
        .heading => "Heading",
        .list_unordered => "List",
        .list_ordered => "Numbered list",
        .list_task => "Checklist",
        .quote => "Quote",
        .code => "Code",
        .table => "Table",
        .hr => "Separator",
        .link => "Link",
        .image => "Image",
        .raw => "Source block (raw)",
    };
}

const Line = struct { start: usize, end: usize, text: []const u8 }; // text excludes '\n' and trailing '\r'

fn isBlank(line: Line) bool {
    return std.mem.trim(u8, line.text, " \t").len == 0;
}

fn leftIndent(text: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and text[n] == ' ') : (n += 1) {}
    if (n < text.len and text[n] == '\t') return 4; // tabs count as one level
    return n;
}

fn fenceRun(text: []const u8) ?struct { ch: u8, n: usize, info: []const u8 } {
    const i = leftIndent(text);
    if (i > 3 or i >= text.len or (text[i] != '`' and text[i] != '~')) return null;
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == text[i]) : (n += 1) {}
    if (n < 3) return null;
    return .{ .ch = text[i], .n = n, .info = text[i + n ..] };
}

fn headingLine(text: []const u8) ?u8 {
    var i = leftIndent(text);
    if (i > 3) return null;
    var level: u8 = 0;
    while (i < text.len and text[i] == '#' and level < 7) : (i += 1) {
        level += 1;
    }
    if (level == 0 or level > 6) return null;
    if (i < text.len and text[i] != ' ' and text[i] != '\t') return null;
    return level;
}

fn isThematic(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len < 3) return false;
    var marker: u8 = 0;
    var count: usize = 0;
    for (t) |ch| {
        if (ch == '-' or ch == '*' or ch == '_') {
            if (marker == 0) marker = ch;
            if (ch != marker) return false;
            count += 1;
        } else if (ch != ' ' and ch != '\t') return false;
    }
    return count >= 3;
}

fn setextLevel(text: []const u8) ?u8 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    if (t[0] == '=') {
        for (t) |ch| if (ch != '=') return null;
        return 1;
    }
    if (t[0] == '-') {
        for (t) |ch| if (ch != '-') return null;
        return 2;
    }
    return null;
}

fn quoteStart(text: []const u8) bool {
    const i = leftIndent(text);
    return i <= 3 and i < text.len and text[i] == '>';
}

fn listMarker(text: []const u8) ?struct { ordered: bool, task: bool, indent: usize } {
    const i = leftIndent(text);
    const indent = i;
    if (i > 3 or i >= text.len) return null;
    if (text[i] == '-' or text[i] == '*' or text[i] == '+') {
        if (i + 1 >= text.len or (text[i + 1] != ' ' and text[i + 1] != '\t')) return null;
        var task = false;
        const rest = text[i + 1 ..];
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        if (std.mem.startsWith(u8, trimmed, "[ ] ") or std.mem.startsWith(u8, trimmed, "[x] ") or std.mem.startsWith(u8, trimmed, "[X] ") or std.mem.eql(u8, trimmed, "[ ]") or std.mem.eql(u8, trimmed, "[x]")) task = true;
        return .{ .ordered = false, .task = task, .indent = indent };
    }
    var j = i;
    while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {}
    if (j > i and j + 1 < text.len and text[j] == '.' and (text[j + 1] == ' ' or text[j + 1] == '\t')) {
        return .{ .ordered = true, .task = false, .indent = indent };
    }
    return null;
}

fn isTableDelimiter(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0 or std.mem.indexOfScalar(u8, t, '|') == null) return false;
    var cells = std.mem.splitScalar(u8, t, '|');
    while (cells.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        if (c.len == 0) continue;
        var k = c;
        if (k.len > 0 and k[0] == ':') k = k[1..];
        if (k.len > 0 and k[k.len - 1] == ':') k = k[0 .. k.len - 1];
        if (k.len == 0) return false;
        for (k) |ch| if (ch != '-') return false;
    }
    return true;
}

fn containsPipe(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '|') != null;
}

fn refDefStart(text: []const u8) ?[]const u8 {
    // `[label]: ...` or `[^label]: ...` (footnote definitions).
    var i = leftIndent(text);
    if (i > 3 or i + 1 >= text.len or text[i] != '[') return null;
    if (text[i + 1] == '^') i += 1;
    var j = i + 1;
    while (j < text.len and text[j] != ']' and text[j] != '\n') : (j += 1) {}
    if (j == i + 1 or j >= text.len or text[j] != ']' or j + 1 >= text.len or text[j + 1] != ':') return null;
    return text[i + 1 .. j];
}

fn htmlBlockTag(text: []const u8) bool {
    var i = leftIndent(text);
    if (i > 3 or i >= text.len or text[i] != '<') return false;
    i += 1;
    if (i < text.len and text[i] == '/') i += 1;
    var j = i;
    while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '-')) : (j += 1) {}
    if (j == i) return false;
    const tag = text[i..j];
    const block_tags = [_][]const u8{
        "address", "article", "aside", "blockquote", "details", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2",
        "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol",
        "p", "pre", "script", "section", "style", "table", "ul",
    };
    for (block_tags) |t| if (std.ascii.eqlIgnoreCase(tag, t)) return true;
    return false;
}

fn splitLines(body: []const u8) []Line {
    var lines: std.ArrayList(Line) = .empty;
    const alloc = std.heap.page_allocator;
    var start: usize = 0;
    while (start <= body.len) {
        const nl = std.mem.findScalarPos(u8, body, start, '\n');
        const end = nl orelse body.len;
        var text = body[start..end];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        lines.append(alloc, .{ .start = start, .end = end, .text = text }) catch break;
        if (nl == null) break;
        start = nl.? + 1;
    }
    return lines.toOwnedSlice(alloc) catch &.{};
}

fn firstWordAlloc(alloc: Allocator, info: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, info, " \t");
    var i: usize = 0;
    while (i < t.len and t[i] != ' ' and t[i] != '\t') : (i += 1) {}
    return try alloc.dupe(u8, t[0..i]);
}

pub fn parseBlocks(alloc: Allocator, body: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    const lines = splitLines(body);
    var idx: usize = 0;
    while (idx < lines.len) {
        const first = lines[idx];
        if (isBlank(first)) {
            idx += 1;
            continue;
        }
        if (out.items.len >= max_blocks) break;
        var end_idx = idx;
        var block = Block{ .start = first.start, .end = first.end, .kind = .paragraph };
        if (fenceRun(first.text)) |f| {
            block.kind = .code;
            block.lang = try firstWordAlloc(alloc, f.info);
            // Consume until closing fence (same char, at least as long).
            var j = idx + 1;
            while (j < lines.len) {
                end_idx = j;
                if (fenceRun(lines[j].text)) |m| {
                    if (m.ch == f.ch and m.n >= f.n) {
                        j += 1;
                        break;
                    }
                }
                j += 1;
            }
            idx = j;
            block.end = lines[end_idx].end;
            try out.append(alloc, block);
            continue;
        }
        if (headingLine(first.text)) |level| {
            block.kind = .heading;
            block.level = level;
            idx += 1;
            try out.append(alloc, block);
            continue;
        }
        if (isThematic(first.text)) {
            block.kind = .hr;
            idx += 1;
            try out.append(alloc, block);
            continue;
        }
        if (quoteStart(first.text)) {
            block.kind = .quote;
            var j = idx;
            while (j + 1 < lines.len and !isBlank(lines[j + 1]) and quoteStart(lines[j + 1].text)) : (j += 1) {
                end_idx = j + 1;
            }
            if (j == idx) end_idx = idx;
            block.end = lines[end_idx].end;
            idx = end_idx + 1;
            try out.append(alloc, block);
            continue;
        }
        if (listMarker(first.text) != null) {
            // A list runs until a blank line, except that a table start ends
            // it even without a blank separator, so the block editor splits
            // the table out instead of swallowing it as lazy continuation.
            var j = idx;
            while (j + 1 < lines.len and !isBlank(lines[j + 1])) : (j += 1) {
                if (containsPipe(lines[j + 1].text) and j + 2 < lines.len and isTableDelimiter(lines[j + 2].text)) break;
                end_idx = j + 1;
            }
            block.end = lines[end_idx].end;
            idx = end_idx + 1;
            // Classify by first marker; nested (indented markers) or mixed
            // ordered/unordered markers keep the block raw so bytes are
            // preserved verbatim instead of being destructively converted.
            var saw_task = false;
            var saw_ordered = false;
            var nested = false;
            var mixed = false;
            classifyList(body[block.start..block.end], &saw_task, &saw_ordered, &nested, &mixed);
            if (nested or mixed) {
                block.kind = .raw;
            } else if (saw_task) {
                block.kind = .list_task;
            } else if (saw_ordered) {
                block.kind = .list_ordered;
            } else {
                block.kind = .list_unordered;
            }
            try out.append(alloc, block);
            continue;
        }
        if (containsPipe(first.text) and idx + 1 < lines.len and isTableDelimiter(lines[idx + 1].text)) {
            block.kind = .table;
            var j = idx;
            while (j + 1 < lines.len and !isBlank(lines[j + 1]) and containsPipe(lines[j + 1].text)) : (j += 1) {
                end_idx = j + 1;
            }
            block.end = lines[end_idx].end;
            idx = end_idx + 1;
            try out.append(alloc, block);
            continue;
        }
        if (idx + 1 < lines.len and setextLevel(lines[idx + 1].text) != null) {
            block.kind = .heading;
            block.level = setextLevel(lines[idx + 1].text).?;
            block.end = lines[idx + 1].end;
            idx += 2;
            try out.append(alloc, block);
            continue;
        }
        if (leftIndent(first.text) >= 4 or std.mem.startsWith(u8, first.text, "\t")) {
            block.kind = .raw;
            var j = idx;
            while (j + 1 < lines.len and !isBlank(lines[j + 1]) and (leftIndent(lines[j + 1].text) >= 4 or std.mem.startsWith(u8, lines[j + 1].text, "\t"))) : (j += 1) {
                end_idx = j + 1;
            }
            block.end = lines[end_idx].end;
            idx = end_idx + 1;
            try out.append(alloc, block);
            continue;
        }
        if (refDefStart(first.text) != null) {
            block.kind = .raw;
            var j = idx;
            while (j + 1 < lines.len and !isBlank(lines[j + 1]) and (leftIndent(lines[j + 1].text) >= 4 or std.mem.startsWith(u8, lines[j + 1].text, "\t"))) : (j += 1) {
                end_idx = j + 1;
            }
            block.end = lines[end_idx].end;
            idx = end_idx + 1;
            try out.append(alloc, block);
            continue;
        }
        if (htmlBlockTag(first.text)) {
            block.kind = .raw;
            var j = idx;
            while (j + 1 < lines.len and !isBlank(lines[j + 1])) : (j += 1) {
                end_idx = j + 1;
            }
            block.end = lines[end_idx].end;
            idx = end_idx + 1;
            try out.append(alloc, block);
            continue;
        }
        // Paragraph, link, or image. Consume until a blank line or a line
        // that starts a new block (fence/heading/table/list/quote/hr).
        var j = idx;
        while (j + 1 < lines.len and !isBlank(lines[j + 1])) {
            const next = lines[j + 1];
            if (fenceRun(next.text) != null or headingLine(next.text) != null or
                isThematic(next.text) or quoteStart(next.text) or listMarker(next.text) != null or htmlBlockTag(next.text))
            {
                break;
            }
            if (containsPipe(next.text) and j + 2 < lines.len and isTableDelimiter(lines[j + 2].text)) break;
            j += 1;
            end_idx = j;
        }
        block.end = lines[end_idx].end;
        idx = end_idx + 1;
        // Single-line link/image paragraphs get their own kinds.
        if (end_idx == idx - 1) {
            const single = body[block.start..block.end];
            if (isSingleLinkOrImage(single)) |k| block.kind = k;
        }
        try out.append(alloc, block);
    }
    return try out.toOwnedSlice(alloc);
}

fn classifyList(text: []const u8, saw_task: *bool, saw_ordered: *bool, nested: *bool, mixed: *bool) void {
    var seen_ordered: ?bool = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const marker = listMarker(line) orelse continue;
        if (marker.indent >= 2) nested.* = true;
        if (seen_ordered == null) seen_ordered = marker.ordered;
        if (marker.ordered) saw_ordered.* = true;
        if (marker.task) saw_task.* = true;
        if (seen_ordered.? != marker.ordered) mixed.* = true;
    }
}

fn isSingleLinkOrImage(single: []const u8) ?Kind {
    const t = std.mem.trim(u8, single, " \t\r");
    if (t.len == 0 or std.mem.indexOfScalar(u8, t, '\n') != null) return null;
    if (std.mem.startsWith(u8, t, "![")) {
        const close = std.mem.indexOf(u8, t, "](") orelse return null;
        if (!std.mem.endsWith(u8, t, ")")) return null;
        _ = close;
        return .image;
    }
    if (std.mem.startsWith(u8, t, "[")) {
        const close = std.mem.indexOf(u8, t, "](") orelse return null;
        if (!std.mem.endsWith(u8, t, ")")) return null;
        if (std.mem.indexOf(u8, t[0..close], "[") != null and close < 2) return null;
        return .link;
    }
    return null;
}

// ---------------------------------------------------------------- tables

pub const TableCell = struct { row: usize, col: usize };
pub const Table = struct {
    header: [][]const u8,
    aligns: []u8, // 'l', 'c', 'r', or 0 for none, one per column
    rows: [][]const u8, // flattened row-major cells
    cols: usize,
};

fn splitTableRow(alloc: Allocator, row_text: []const u8) ![][]const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    const t = std.mem.trim(u8, row_text, " \t");
    var i: usize = 0;
    if (t.len > 0 and t[0] == '|') i = 1;
    var cell_start = i;
    var in_code: usize = 0;
    while (i < t.len) {
        const ch = t[i];
        if (ch == '\\' and i + 1 < t.len and t[i + 1] == '|') {
            i += 2;
            continue;
        }
        if (ch == '`') {
            var run: usize = 0;
            while (i + run < t.len and t[i + run] == '`') : (run += 1) {}
            if (in_code == 0) in_code = run else if (in_code == run) in_code = 0;
            i += run;
            continue;
        }
        if (ch == '|' and in_code == 0) {
            try cells.append(alloc, std.mem.trim(u8, t[cell_start..i], " \t"));
            i += 1;
            cell_start = i;
            continue;
        }
        i += 1;
    }
    // Include the final cell (unless the row ends with a trailing pipe, in
    // which case cell_start == t.len and there is no extra empty cell).
    if (cell_start < t.len or (t.len > 0 and t[t.len - 1] != '|')) {
        try cells.append(alloc, std.mem.trim(u8, t[cell_start..], " \t"));
    }
    return try cells.toOwnedSlice(alloc);
}

pub fn parseTable(alloc: Allocator, source: []const u8) !Table {
    var row_lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        try row_lines.append(alloc, line);
    }
    if (row_lines.items.len < 2) return .{ .header = &.{}, .aligns = &.{}, .rows = &.{}, .cols = 0 };
    const header = try splitTableRow(alloc, row_lines.items[0]);
    const delim = try splitTableRow(alloc, row_lines.items[1]);
    var aligns: std.ArrayList(u8) = .empty;
    for (delim) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        const left = c.len > 0 and c[0] == ':';
        const right = c.len > 0 and c[c.len - 1] == ':';
        try aligns.append(alloc, if (left and right) 'c' else if (right) 'r' else if (left) 'l' else 0);
    }
    while (aligns.items.len < header.len) try aligns.append(alloc, 0);
    var rows: std.ArrayList([]const u8) = .empty;
    var r: usize = 2;
    while (r < row_lines.items.len) : (r += 1) {
        const cells = try splitTableRow(alloc, row_lines.items[r]);
        var c: usize = 0;
        while (c < header.len) : (c += 1) {
            try rows.append(alloc, if (c < cells.len) cells[c] else "");
        }
    }
    return .{ .header = header, .aligns = try aligns.toOwnedSlice(alloc), .rows = try rows.toOwnedSlice(alloc), .cols = header.len };
}

pub fn generateTable(alloc: Allocator, table: Table) ![]u8 {
    if (table.cols == 0) return try alloc.dupe(u8, "");
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(alloc, '|');
    for (table.header) |cell| {
        try buf.appendSlice(alloc, " ");
        try buf.appendSlice(alloc, cell);
        try buf.appendSlice(alloc, " |");
    }
    try buf.append(alloc, '\n');
    try buf.append(alloc, '|');
    for (table.aligns) |a| {
        try buf.appendSlice(alloc, switch (a) {
            'c' => " :---: |",
            'r' => " ---: |",
            'l' => " :--- |",
            else => " --- |",
        });
    }
    for (0..(table.rows.len / table.cols)) |r| {
        try buf.append(alloc, '\n');
        try buf.append(alloc, '|');
        var c: usize = 0;
        while (c < table.cols) : (c += 1) {
            try buf.appendSlice(alloc, " ");
            try buf.appendSlice(alloc, table.rows[r * table.cols + c]);
            try buf.appendSlice(alloc, " |");
        }
    }
    return try buf.toOwnedSlice(alloc);
}

// ------------------------------------------------------- field conversions

pub fn stripKind(alloc: Allocator, kind: Kind, source: []const u8) ![]u8 {
    // Text shown in the editor for editing: kind syntax removed.
    var buf: std.ArrayList(u8) = .empty;
    switch (kind) {
        .paragraph, .raw => return try alloc.dupe(u8, source),
        .heading => {
            if (headingLine(source)) |level| {
                var i: usize = 0;
                while (i < source.len and source[i] == ' ') : (i += 1) {}
                const text = std.mem.trimStart(u8, source[i + level ..], " \t");
                return try alloc.dupe(u8, text);
            }
            return try alloc.dupe(u8, source);
        },
        .hr => return &.{},
        .code => {
            // Strip the first fence line and the closing fence line.
            var rest = source;
            if (std.mem.findScalarPos(u8, source, 0, '\n')) |nl| rest = source[nl + 1 ..];
            var lit = std.mem.splitScalar(u8, rest, '\n');
            var lines: std.ArrayList([]const u8) = .empty;
            while (lit.next()) |l| lines.append(alloc, l) catch {};
            if (lines.items.len > 0 and fenceRun(std.mem.trimEnd(u8, lines.items[lines.items.len - 1], "\r")) != null) {
                lines.items.len -= 1;
            }
            for (lines.items, 0..) |l, li| {
                if (li > 0) try buf.append(alloc, '\n');
                try buf.appendSlice(alloc, std.mem.trimEnd(u8, l, "\r"));
            }
            return try buf.toOwnedSlice(alloc);
        },
        .quote => {
            var it = std.mem.splitScalar(u8, source, '\n');
            var first = true;
            while (it.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                var s = line;
                const i = leftIndent(s);
                if (i <= 3 and i < s.len and s[i] == '>') s = s[i + 1 ..];
                s = std.mem.trimStart(u8, s, " \t");
                if (!first) try buf.append(alloc, '\n');
                first = false;
                try buf.appendSlice(alloc, s);
            }
            return try buf.toOwnedSlice(alloc);
        },
        .list_unordered => {
            var it = std.mem.splitScalar(u8, source, '\n');
            var first = true;
            while (it.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                var s = std.mem.trimStart(u8, line, " \t");
                if (s.len >= 1 and (s[0] == '-' or s[0] == '*' or s[0] == '+')) s = std.mem.trimStart(u8, s[1..], " \t");
                if (!first) try buf.append(alloc, '\n');
                first = false;
                try buf.appendSlice(alloc, s);
            }
            return try buf.toOwnedSlice(alloc);
        },
        .list_ordered => {
            var it = std.mem.splitScalar(u8, source, '\n');
            var first = true;
            while (it.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                var s = std.mem.trimStart(u8, line, " \t");
                var j: usize = 0;
                while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {}
                if (j > 0 and j < s.len and s[j] == '.') s = std.mem.trimStart(u8, s[j + 1 ..], " \t");
                if (!first) try buf.append(alloc, '\n');
                first = false;
                try buf.appendSlice(alloc, s);
            }
            return try buf.toOwnedSlice(alloc);
        },
        .list_task => {
            var it = std.mem.splitScalar(u8, source, '\n');
            var first = true;
            while (it.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                var s = std.mem.trimStart(u8, line, " \t");
                if (s.len >= 1 and (s[0] == '-' or s[0] == '*' or s[0] == '+')) s = std.mem.trimStart(u8, s[1..], " \t");
                if (!first) try buf.append(alloc, '\n');
                first = false;
                try buf.appendSlice(alloc, s);
            }
            return try buf.toOwnedSlice(alloc);
        },
        .link, .image, .table => return try alloc.dupe(u8, source),
    }
}

pub fn generateBlock(alloc: Allocator, kind: Kind, text: []const u8, level: u8, lang: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    switch (kind) {
        .paragraph, .raw => {
            try buf.appendSlice(alloc, std.mem.trim(u8, text, " \t\n\r"));
        },
        .heading => {
            const lv: u8 = if (level >= 1 and level <= 6) level else 2;
            var i: usize = 0;
            while (i < lv) : (i += 1) try buf.append(alloc, '#');
            try buf.append(alloc, ' ');
            const t = std.mem.trim(u8, text, " \t\n\r");
            // Headings are single-line; keep only the first line.
            const nl = std.mem.findScalarPos(u8, t, 0, '\n');
            try buf.appendSlice(alloc, if (nl) |p| t[0..p] else t);
        },
        .quote => {
            var it = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) try buf.append(alloc, '\n');
                first = false;
                try buf.appendSlice(alloc, "> ");
                try buf.appendSlice(alloc, line);
            }
            if (first) try buf.appendSlice(alloc, ">");
        },
        .list_unordered => {
            var it = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (it.next()) |line| {
                if (line.len == 0 and std.mem.trim(u8, line, " \t").len == 0) continue;
                if (!first) try buf.append(alloc, '\n');
                first = false;
                try buf.appendSlice(alloc, "- ");
                try buf.appendSlice(alloc, std.mem.trimStart(u8, line, " \t"));
            }
            if (first) try buf.appendSlice(alloc, "- item");
        },
        .list_ordered => {
            var n: u32 = 1;
            var it = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (it.next()) |line| {
                if (std.mem.trim(u8, line, " \t").len == 0) continue;
                if (!first) try buf.append(alloc, '\n');
                first = false;
                var num: [12]u8 = undefined;
                try buf.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}. ", .{n}));
                try buf.appendSlice(alloc, std.mem.trimStart(u8, line, " \t"));
                n += 1;
            }
            if (first) try buf.appendSlice(alloc, "1. item");
        },
        .list_task => {
            var it = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \t");
                if (t.len == 0) continue;
                if (!first) try buf.append(alloc, '\n');
                first = false;
                if (std.mem.startsWith(u8, t, "[x] ") or std.mem.startsWith(u8, t, "[X] ") or std.mem.startsWith(u8, t, "[ ] ")) {
                    try buf.appendSlice(alloc, "- ");
                    try buf.appendSlice(alloc, t);
                } else {
                    try buf.appendSlice(alloc, "- [ ] ");
                    try buf.appendSlice(alloc, t);
                }
            }
            if (first) try buf.appendSlice(alloc, "- [ ] task");
        },
        .code => {
            const cl = std.mem.trim(u8, lang, " \t");
            try buf.appendSlice(alloc, "```");
            try buf.appendSlice(alloc, cl);
            try buf.append(alloc, '\n');
            try buf.appendSlice(alloc, std.mem.trimEnd(u8, text, "\n\r"));
            try buf.appendSlice(alloc, "\n```");
        },
        .hr => try buf.appendSlice(alloc, "---"),
        .link => {
            try buf.append(alloc, '[');
            try buf.appendSlice(alloc, std.mem.trim(u8, text, " \t"));
            try buf.appendSlice(alloc, "]()");
        },
        .image => {
            try buf.appendSlice(alloc, "![");
            try buf.appendSlice(alloc, std.mem.trim(u8, text, " \t"));
            try buf.appendSlice(alloc, "]()");
        },
        .table => {
            // Tables are edited through generateTable; regenerate a
            // minimal placeholder if one is requested without cells.
            try buf.appendSlice(alloc, "| Column |\n| --- |\n| cell |");
        },
    }
    return try buf.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------ tests

test "blocks split losslessly and keep fenced code together" {
    const alloc = std.testing.allocator;
    const body = "# Title\n\nPara one\n\n```zig\nblank\n\ninside fence\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n- [x] done\n\n[^1]: note\n";
    const blocks = try parseBlocks(alloc, body);
    // Joining block slices with their separators rebuilds the body.
    var rebuilt = std.ArrayList(u8).empty;
    var pos: usize = 0;
    for (blocks) |b| {
        try rebuilt.appendSlice(alloc, body[pos..b.start]);
        try rebuilt.appendSlice(alloc, body[b.start..b.end]);
        pos = b.end;
    }
    try rebuilt.appendSlice(alloc, body[pos..]);
    try std.testing.expectEqualStrings(body, rebuilt.items);
    var kinds: [16]Kind = undefined;
    for (blocks, 0..) |b, i| kinds[i] = b.kind;
    try std.testing.expectEqual(Kind.heading, kinds[0]);
    try std.testing.expectEqual(Kind.code, kinds[2]);
    try std.testing.expectEqual(Kind.table, kinds[3]);
    try std.testing.expectEqual(Kind.list_task, kinds[4]);
    try std.testing.expectEqual(Kind.raw, kinds[5]);
}

test "generateBlock round-trips editable kinds" {
    const alloc = std.testing.allocator;
    const para = try generateBlock(alloc, .paragraph, "hello world", 0, "");
    try std.testing.expectEqualStrings("hello world", para);
    const head = try generateBlock(alloc, .heading, "Title", 3, "");
    try std.testing.expectEqualStrings("### Title", head);
    const list = try generateBlock(alloc, .list_unordered, "one\ntwo", 0, "");
    try std.testing.expectEqualStrings("- one\n- two", list);
    const tasks = try generateBlock(alloc, .list_task, "[x] done\ntodo", 0, "");
    try std.testing.expectEqualStrings("- [x] done\n- [ ] todo", tasks);
    const quote = try generateBlock(alloc, .quote, "wise\nwords", 0, "");
    try std.testing.expectEqualStrings("> wise\n> words", quote);
    const code = try generateBlock(alloc, .code, "let x = 1;", 0, "zig");
    try std.testing.expectEqualStrings("```zig\nlet x = 1;\n```", code);
}

test "tables split and regenerate with alignment" {
    const alloc = std.testing.allocator;
    const table = try parseTable(alloc, "| a | b |\n|:--:|--:|\n| 1 | 2 |");
    try std.testing.expectEqual(@as(usize, 2), table.cols);
    try std.testing.expectEqualStrings("a", table.header[0]);
    try std.testing.expectEqualStrings("2", table.rows[1]);
    const out = try generateTable(alloc, table);
    try std.testing.expect(std.mem.indexOf(u8, out, ":---:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "| 1 | 2 |") != null);
}

test "table cells keep escaped and code pipes" {
    const alloc = std.testing.allocator;
    const table = try parseTable(alloc, "| a\\|b | `c|d` |\n| --- | --- |\n| 1 | 2 |");
    try std.testing.expectEqual(@as(usize, 2), table.cols);
    try std.testing.expectEqualStrings("a\\|b", table.header[0]);
    try std.testing.expectEqualStrings("`c|d`", table.header[1]);
}

test "a table directly after a list splits into two blocks" {
    const alloc = std.testing.allocator;
    const body = "- one\n- two\n| A | B |\n| --- | --- |\n| 1 | 2 |\n";
    const bs = try parseBlocks(alloc, body);
    try std.testing.expectEqual(@as(usize, 2), bs.len);
    try std.testing.expectEqual(Kind.list_unordered, bs[0].kind);
    try std.testing.expectEqual(Kind.table, bs[1].kind);
}

test "table row addition regenerates a wider table" {
    const alloc = std.testing.allocator;
    const body = "| Alpha | Column |\n| --- | --- |\n| 1 | cell |\n";
    const bs = try parseBlocks(alloc, body);
    try std.testing.expectEqual(@as(usize, 1), bs.len);
    const t = try parseTable(alloc, body[bs[0].start..bs[0].end]);
    try std.testing.expectEqual(@as(usize, 2), t.cols);
    // Simulate tableaddrow: keep header/rows, append one empty row.
    var rows: std.ArrayList([]const u8) = .empty;
    for (t.rows) |c| try rows.append(alloc, c);
    for (0..t.cols) |_| try rows.append(alloc, "");
    const grown: Table = .{ .header = t.header, .aligns = t.aligns, .rows = try rows.toOwnedSlice(alloc), .cols = t.cols };
    const out = try generateTable(alloc, grown);
    try std.testing.expect(std.mem.indexOf(u8, out, "|  |  |") != null);
    // Zero-column tables never panic.
    const empty = try generateTable(alloc, .{ .header = &.{}, .aligns = &.{}, .rows = &.{}, .cols = 0 });
    try std.testing.expectEqualStrings("", empty);
}
