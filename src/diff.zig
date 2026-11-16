//! Minimal line-level diff for revision comparison. Server-side only: the
//! result is rendered as escaped HTML with no client JavaScript.
const std = @import("std");

pub const Kind = enum { same, removed, added };

pub const Row = struct {
    kind: Kind,
    text: []const u8,
};

/// Largest dynamic-programming matrix we are willing to allocate. Above this,
/// the middle section is reported as a coarse remove/add block so a hostile
/// note cannot force unbounded memory or CPU in a page render.
const max_cells: usize = 2_000_000;

pub fn lineDiff(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8) ![]Row {
    const old_lines = try splitLines(allocator, old_text);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new_text);
    defer allocator.free(new_lines);

    if (old_lines.len * new_lines.len > max_cells) {
        return coarseDiff(allocator, old_lines, new_lines);
    }
    return lcsDiff(allocator, old_lines, new_lines);
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    if (text.len == 0) return allocator.alloc([]const u8, 0);
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    // A single trailing newline is a terminator, not an extra empty line.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return lines.toOwnedSlice(allocator);
}

fn lcsDiff(allocator: std.mem.Allocator, old_lines: []const []const u8, new_lines: []const []const u8) ![]Row {
    const n = old_lines.len;
    const m = new_lines.len;
    const stride = m + 1;
    // Use u16 when the matrix is small; u32 for larger histories.
    const cells = try allocator.alloc(u32, (n + 1) * stride);
    defer allocator.free(cells);
    @memset(cells, 0);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        var j: usize = 1;
        while (j <= m) : (j += 1) {
            cells[i * stride + j] = if (std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1]))
                cells[(i - 1) * stride + (j - 1)] + 1
            else
                @max(cells[(i - 1) * stride + j], cells[i * stride + (j - 1)]);
        }
    }

    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);
    var r = n;
    var c = m;
    while (r > 0 or c > 0) {
        if (r > 0 and c > 0 and std.mem.eql(u8, old_lines[r - 1], new_lines[c - 1])) {
            try rows.append(allocator, .{ .kind = .same, .text = old_lines[r - 1] });
            r -= 1;
            c -= 1;
        } else if (r > 0 and (c == 0 or cells[(r - 1) * stride + c] >= cells[r * stride + (c - 1)])) {
            try rows.append(allocator, .{ .kind = .removed, .text = old_lines[r - 1] });
            r -= 1;
        } else {
            try rows.append(allocator, .{ .kind = .added, .text = new_lines[c - 1] });
            c -= 1;
        }
    }
    std.mem.reverse(Row, rows.items);
    return rows.toOwnedSlice(allocator);
}

fn coarseDiff(allocator: std.mem.Allocator, old_lines: []const []const u8, new_lines: []const []const u8) ![]Row {
    var prefix: usize = 0;
    while (prefix < old_lines.len and prefix < new_lines.len and
        std.mem.eql(u8, old_lines[prefix], new_lines[prefix])) : (prefix += 1)
    {}
    var suffix: usize = 0;
    while (suffix + prefix < old_lines.len and suffix + prefix < new_lines.len and
        std.mem.eql(u8, old_lines[old_lines.len - 1 - suffix], new_lines[new_lines.len - 1 - suffix])) : (suffix += 1)
    {}

    const rows = try allocator.alloc(Row, prefix + (old_lines.len - prefix - suffix) + (new_lines.len - prefix - suffix) + suffix);
    var at: usize = 0;
    for (old_lines[0..prefix]) |line| {
        rows[at] = .{ .kind = .same, .text = line };
        at += 1;
    }
    for (old_lines[prefix .. old_lines.len - suffix]) |line| {
        rows[at] = .{ .kind = .removed, .text = line };
        at += 1;
    }
    for (new_lines[prefix .. new_lines.len - suffix]) |line| {
        rows[at] = .{ .kind = .added, .text = line };
        at += 1;
    }
    for (old_lines[old_lines.len - suffix ..]) |line| {
        rows[at] = .{ .kind = .same, .text = line };
        at += 1;
    }
    return rows;
}

test "line diff marks changed lines and keeps context" {
    const allocator = std.testing.allocator;
    const rows = try lineDiff(allocator, "a\nb\nc", "a\nB\nc\nd");
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqual(Kind.same, rows[0].kind);
    try std.testing.expectEqual(Kind.removed, rows[1].kind);
    try std.testing.expectEqualStrings("b", rows[1].text);
    try std.testing.expectEqual(Kind.added, rows[2].kind);
    try std.testing.expectEqualStrings("B", rows[2].text);
    try std.testing.expectEqual(Kind.same, rows[3].kind);
    try std.testing.expectEqual(Kind.added, rows[4].kind);
}

test "line diff handles empty and unicode input" {
    const allocator = std.testing.allocator;
    const empty = try lineDiff(allocator, "", "");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const unicode = try lineDiff(allocator, "Türkçe\nğüşiöç", "Türkçe\n日本語\nğüşiöç");
    defer allocator.free(unicode);
    try std.testing.expectEqual(@as(usize, 4), unicode.len);
    try std.testing.expectEqual(Kind.added, unicode[1].kind);
    try std.testing.expectEqualStrings("日本語", unicode[1].text);
}

test "line diff trailing newline is not an extra line" {
    const allocator = std.testing.allocator;
    const rows = try lineDiff(allocator, "one\n", "one\n");
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(Kind.same, rows[0].kind);
}
