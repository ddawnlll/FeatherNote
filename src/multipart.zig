//! Minimal multipart/form-data parser for authenticated file uploads.
//!
//! It deliberately supports one flat part list, bounded part count, bounded
//! header size, and no nested multipart. Field and file names are slices into
//! the request body; the caller validates them before use.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_parts: usize = 16;
pub const max_header_bytes: usize = 4096;

pub const ParseError = error{
    InvalidContentType,
    Malformed,
    TooManyParts,
    HeaderTooLarge,
};

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: []const u8,
};

/// Extracts the boundary value from a `multipart/form-data` content type.
/// Returns null when the header is not multipart or has no boundary.
pub fn boundaryFromContentType(content_type: []const u8) ?[]const u8 {
    const semi = std.mem.findScalar(u8, content_type, ';') orelse return null;
    const media = std.mem.trim(u8, content_type[0..semi], " \t");
    if (!std.ascii.eqlIgnoreCase(media, "multipart/form-data")) return null;

    var it = std.mem.splitScalar(u8, content_type[semi + 1 ..], ';');
    while (it.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const eq = std.mem.findScalar(u8, param, '=') orelse continue;
        const key = std.mem.trim(u8, param[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "boundary")) continue;
        var value = std.mem.trim(u8, param[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (value.len == 0 or value.len > 128) return null;
        return value;
    }
    return null;
}

pub fn parse(arena: Allocator, body: []const u8, boundary: []const u8) ParseError![]Part {
    if (boundary.len == 0 or boundary.len > 128) return ParseError.InvalidContentType;

    const delimiter = std.fmt.allocPrint(arena, "--{s}", .{boundary}) catch return ParseError.Malformed;
    const part_separator = std.fmt.allocPrint(arena, "\r\n--{s}", .{boundary}) catch return ParseError.Malformed;

    var pos: usize = 0;
    if (std.mem.startsWith(u8, body, delimiter)) {
        pos = delimiter.len;
    } else if (std.mem.find(u8, body, part_separator)) |first| {
        // Tolerate a preamble before the first boundary.
        pos = first + 2 + delimiter.len;
    } else {
        return ParseError.Malformed;
    }

    var parts: std.ArrayList(Part) = .empty;
    while (true) {
        if (parts.items.len >= max_parts) return ParseError.TooManyParts;
        if (pos + 2 <= body.len and std.mem.eql(u8, body[pos .. pos + 2], "--")) break;
        if (pos + 2 > body.len or !std.mem.eql(u8, body[pos .. pos + 2], "\r\n")) return ParseError.Malformed;
        pos += 2;

        const header_end = std.mem.find(u8, body[pos..], "\r\n\r\n") orelse return ParseError.Malformed;
        if (header_end > max_header_bytes) return ParseError.HeaderTooLarge;
        const header_block = body[pos .. pos + header_end];
        pos += header_end + 4;

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var part_type: ?[]const u8 = null;

        var header_lines = std.mem.splitScalar(u8, header_block, '\n');
        while (header_lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
                name = dispositionParam(header_value, "name");
                filename = dispositionParam(header_value, "filename");
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                part_type = header_value;
            }
        }
        if (name == null) return ParseError.Malformed;

        const next = std.mem.find(u8, body[pos..], part_separator) orelse return ParseError.Malformed;
        const data_end = pos + next;
        parts.append(arena, .{
            .name = name.?,
            .filename = filename,
            .content_type = part_type,
            .data = body[pos..data_end],
        }) catch return ParseError.Malformed;
        pos = data_end + part_separator.len;
    }
    return parts.toOwnedSlice(arena) catch return ParseError.Malformed;
}

fn dispositionParam(value: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, value, ';');
    _ = it.next();
    while (it.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const eq = std.mem.findScalar(u8, param, '=') orelse continue;
        const name = std.mem.trim(u8, param[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(name, key)) continue;
        var out = std.mem.trim(u8, param[eq + 1 ..], " \t");
        if (out.len >= 2 and out[0] == '"' and out[out.len - 1] == '"') {
            out = out[1 .. out.len - 1];
        }
        return out;
    }
    return null;
}

// ---- tests ----

test "multipart parses a field and a file" {
    const body =
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"csrf\"\r\n" ++
        "\r\n" ++
        "abc123\r\n" ++
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"cat.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "\x89PNG\r\n\x1a\n" ++
        "\r\n--X--\r\n";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parts = try parse(arena_state.allocator(), body, "X");
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("csrf", parts[0].name);
    try std.testing.expectEqualStrings("abc123", parts[0].data);
    try std.testing.expectEqualStrings("cat.png", parts[1].filename.?);
    try std.testing.expectEqualStrings("image/png", parts[1].content_type.?);
    try std.testing.expect(std.mem.startsWith(u8, parts[1].data, "\x89PNG"));
}

test "multipart boundary is extracted from a quoted parameter" {
    try std.testing.expectEqualStrings(
        "----abc",
        boundaryFromContentType("multipart/form-data; boundary=\"----abc\"").?,
    );
    try std.testing.expect(boundaryFromContentType("application/x-www-form-urlencoded") == null);
}

test "multipart rejects a truncated body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        ParseError.Malformed,
        parse(arena_state.allocator(), "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue", "X"),
    );
}
