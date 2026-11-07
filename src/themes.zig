//! Theme registry. The ids must match the `[data-theme="..."]` blocks in
//! web/style.css.
const std = @import("std");

pub const Theme = struct {
    id: []const u8,
    name: []const u8,
    mode: []const u8,
};

pub const all = [_]Theme{
    .{ .id = "feather", .name = "Feather", .mode = "light" },
    .{ .id = "feather-dark", .name = "Feather Dark", .mode = "dark" },
    .{ .id = "midnight", .name = "Midnight", .mode = "dark" },
    .{ .id = "obsidian", .name = "Obsidian", .mode = "dark" },
    .{ .id = "forest", .name = "Forest", .mode = "dark" },
    .{ .id = "ocean", .name = "Ocean", .mode = "dark" },
    .{ .id = "plum", .name = "Plum", .mode = "dark" },
    .{ .id = "ember", .name = "Ember", .mode = "dark" },
    .{ .id = "sand", .name = "Sand", .mode = "light" },
    .{ .id = "mono", .name = "Mono", .mode = "light" },
    .{ .id = "rose", .name = "Rose", .mode = "light" },
    .{ .id = "neon", .name = "Neon", .mode = "dark" },
};

pub fn isValid(id: []const u8) bool {
    for (all) |theme| {
        if (std.mem.eql(u8, theme.id, id)) return true;
    }
    return false;
}

test "theme ids are unique and valid" {
    for (all, 0..) |theme, i| {
        try std.testing.expect(isValid(theme.id));
        for (all[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, theme.id, other.id));
        }
    }
    try std.testing.expect(!isValid("missing"));
}
