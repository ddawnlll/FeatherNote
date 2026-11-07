//! Shared attachment helpers for the HTTP server and the MCP server.
const std = @import("std");
const util = @import("http_util.zig");

const Allocator = std.mem.Allocator;

pub fn isImage(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, "image/");
}

pub fn sniffMime(data: []const u8) []const u8 {
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (data.len >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff) return "image/jpeg";
    if (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a")) return "image/gif";
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "image/webp";
    if (data.len >= 12 and std.mem.eql(u8, data[4..8], "ftyp") and
        (std.mem.eql(u8, data[8..12], "avif") or std.mem.eql(u8, data[8..12], "avis"))) return "image/avif";
    if (std.mem.startsWith(u8, data, "%PDF-")) return "application/pdf";
    if (std.mem.findScalar(u8, data, 0) == null and std.unicode.utf8ValidateSlice(data)) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

pub fn sanitizeFilename(arena: Allocator, raw: []const u8) ![]const u8 {
    const base_raw = basename(raw);
    const valid_utf8 = std.unicode.utf8ValidateSlice(base_raw);
    var out: std.ArrayList(u8) = .empty;
    for (base_raw) |ch| {
        if (out.items.len >= 120) break;
        const keep = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or
            ch == ' ' or ch == '(' or ch == ')' or (valid_utf8 and ch >= 0x80);
        try out.append(arena, if (keep) ch else '_');
    }
    const trimmed = std.mem.trim(u8, out.items, " .");
    if (trimmed.len == 0) return arena.dupe(u8, "file");
    return trimmed;
}

pub fn asciiFilename(arena: Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |ch| {
        if (ch >= 0x20 and ch < 0x7f and ch != '"' and ch != '\\') {
            try out.append(arena, ch);
        } else {
            try out.append(arena, '_');
        }
    }
    const trimmed = std.mem.trim(u8, out.items, " ");
    if (trimmed.len == 0) return arena.dupe(u8, "file");
    return trimmed;
}

pub fn appendFileLink(arena: Allocator, body: []const u8, attachment_id: i64, filename: []const u8, mime: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, body);
    if (body.len > 0) try out.appendSlice(arena, "\n\n");
    var encoded_buffer: [1024]u8 = undefined;
    var ew = std.Io.Writer.fixed(&encoded_buffer);
    try util.urlEncode(&ew, filename);
    const encoded = ew.buffered();
    if (isImage(mime)) {
        try out.appendSlice(arena, "![");
        try out.appendSlice(arena, filename);
        try out.appendSlice(arena, "](/files/");
    } else {
        try out.appendSlice(arena, "[");
        try out.appendSlice(arena, filename);
        try out.appendSlice(arena, "](/files/");
    }
    const tail = try std.fmt.allocPrint(arena, "{d}/{s})", .{ attachment_id, encoded });
    try out.appendSlice(arena, tail);
    return out.toOwnedSlice(arena);
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    const idx: ?usize = if (slash == null) backslash else if (backslash == null) slash else @max(slash.?, backslash.?);
    if (idx) |i| return path[i + 1 ..];
    return path;
}

test "media sniffing and filename hygiene" {
    try std.testing.expectEqualStrings("image/png", sniffMime("\x89PNG\r\n\x1a\nabc"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", sniffMime("hello"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("passwd", try sanitizeFilename(arena, "../../etc/passwd"));
    try std.testing.expectEqualStrings("evil_.svg", try sanitizeFilename(arena, "evil?.svg"));
    const link = try appendFileLink(arena, "body", 7, "a b.png", "image/png");
    try std.testing.expectEqualStrings("body\n\n![a b.png](/files/7/a%20b.png)", link);
}
