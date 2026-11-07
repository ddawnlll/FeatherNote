//! Request parsing, validation and output encoding helpers.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_title_bytes: usize = 1024;
pub const max_title_codepoints: usize = 200;
pub const max_body_bytes: usize = 256 * 1024;
pub const max_request_body: usize = 320 * 1024;
pub const max_upload_bytes: usize = 8 * 1024 * 1024;
pub const max_upload_request: usize = max_upload_bytes + 64 * 1024;
pub const max_search_bytes: usize = 100;
pub const page_size: usize = 50;

pub const ParseError = error{
    OutOfMemory,
    InvalidEncoding,
    InvalidForm,
    DuplicateField,
    TooManyFields,
    FieldTooLong,
};

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Form = struct {
    fields: []Field,

    pub fn get(self: Form, name: []const u8) ?[]const u8 {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.value;
        }
        return null;
    }

    pub fn require(self: Form, name: []const u8) ParseError![]const u8 {
        return self.get(name) orelse ParseError.InvalidForm;
    }
};

/// Parses application/x-www-form-urlencoded data. Duplicate field names are
/// rejected because every FeatherNote form has a fixed, unambiguous shape.
pub fn parseForm(arena: Allocator, body: []const u8) ParseError!Form {
    var fields: std.ArrayList(Field) = .empty;
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        if (fields.items.len >= 32) return ParseError.TooManyFields;
        const eq = std.mem.findScalar(u8, pair, '=') orelse return ParseError.InvalidForm;
        const raw_name = pair[0..eq];
        const raw_value = pair[eq + 1 ..];
        const name = try percentDecode(arena, raw_name, true);
        const value = try percentDecode(arena, raw_value, true);
        if (name.len == 0 or name.len > 64) return ParseError.InvalidForm;
        if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(value)) {
            return ParseError.InvalidEncoding;
        }
        for (fields.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return ParseError.DuplicateField;
        }
        try fields.append(arena, .{ .name = name, .value = value });
    }
    return .{ .fields = try fields.toOwnedSlice(arena) };
}

pub fn percentDecode(arena: Allocator, input: []const u8, plus_as_space: bool) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, input.len) catch return ParseError.InvalidForm;
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch == '%') {
            if (i + 2 >= input.len) return ParseError.InvalidEncoding;
            const hi = hexValue(input[i + 1]) orelse return ParseError.InvalidEncoding;
            const lo = hexValue(input[i + 2]) orelse return ParseError.InvalidEncoding;
            out.appendAssumeCapacity((hi << 4) | lo);
            i += 3;
        } else if (ch == '+' and plus_as_space) {
            out.appendAssumeCapacity(' ');
            i += 1;
        } else {
            out.appendAssumeCapacity(ch);
            i += 1;
        }
    }
    const decoded = out.items;
    if (!std.unicode.utf8ValidateSlice(decoded)) return ParseError.InvalidEncoding;
    return decoded;
}

fn hexValue(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

pub fn validateTitle(title: []const u8) ParseError!void {
    if (title.len > max_title_bytes) return ParseError.FieldTooLong;
    if (!std.unicode.utf8ValidateSlice(title)) return ParseError.InvalidEncoding;
    const count = std.unicode.utf8CountCodepoints(title) catch return ParseError.InvalidEncoding;
    if (count > max_title_codepoints) return ParseError.FieldTooLong;
}

pub fn validateBody(body: []const u8) ParseError!void {
    if (body.len > max_body_bytes) return ParseError.FieldTooLong;
    if (!std.unicode.utf8ValidateSlice(body)) return ParseError.InvalidEncoding;
}

pub fn validateSearch(q: []const u8) ParseError!void {
    if (q.len > max_search_bytes) return ParseError.FieldTooLong;
    if (!std.unicode.utf8ValidateSlice(q)) return ParseError.InvalidEncoding;
}

pub fn escapeHtml(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(ch),
        }
    }
}

pub fn urlEncode(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '.' or ch == '_' or ch == '~')
        {
            try w.writeByte(ch);
        } else {
            try w.print("%{X:0>2}", .{ch});
        }
    }
}

pub fn formatDateShort(w: *std.Io.Writer, unix_seconds: i64) !void {
    const parts = dateParts(unix_seconds);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ parts.year, parts.month, parts.day });
}

pub fn formatDateFull(w: *std.Io.Writer, unix_seconds: i64) !void {
    const parts = dateParts(unix_seconds);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        parts.year, parts.month, parts.day, parts.hour, parts.minute,
    });
}

const DateParts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

fn dateParts(unix_seconds: i64) DateParts {
    const secs: u64 = if (unix_seconds < 0) 0 else @intCast(unix_seconds);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = @intCast(md.month.numeric()),
        .day = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
    };
}

pub fn parsePage(raw: ?[]const u8) usize {
    const text = raw orelse return 1;
    if (text.len == 0 or text.len > 9) return 1;
    const n = std.fmt.parseInt(usize, text, 10) catch return 1;
    return if (n < 1) 1 else n;
}

pub fn findHeaderCookie(request: anytype, name: []const u8, buffer: []u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "cookie")) continue;
        var cookies = std.mem.splitScalar(u8, header.value, ';');
        while (cookies.next()) |raw| {
            const item = std.mem.trim(u8, raw, " \t");
            const eq = std.mem.findScalar(u8, item, '=') orelse continue;
            if (!std.mem.eql(u8, item[0..eq], name)) continue;
            const value = item[eq + 1 ..];
            if (value.len > buffer.len) return null;
            @memcpy(buffer[0..value.len], value);
            return buffer[0..value.len];
        }
    }
    return null;
}

pub fn findHeader(request: anytype, name: []const u8, buffer: []u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (header.value.len > buffer.len) return null;
        @memcpy(buffer[0..header.value.len], header.value);
        return buffer[0..header.value.len];
    }
    return null;
}

test "form parsing rejects duplicates and decodes UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const form = try parseForm(arena_state.allocator(), "title=Gr%C3%BC%C3%9Fe+aus+K%C3%B6ln&body=%3C%2Ftextarea%3E");
    try std.testing.expectEqualStrings("Grüße aus Köln", form.get("title").?);
    try std.testing.expectEqualStrings("</textarea>", form.get("body").?);
    try std.testing.expectError(ParseError.DuplicateField, parseForm(arena_state.allocator(), "a=1&a=2"));
    try std.testing.expectError(ParseError.InvalidEncoding, parseForm(arena_state.allocator(), "a=%FF"));
}

test "date formatting is stable" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatDateFull(&w, 1762521600);
    try std.testing.expectEqualStrings("2025-11-07 13:20 UTC", w.buffered());
}
