//! Theme registry. The ids must match the `[data-theme="..."]` blocks in
//! web/style.css. Legacy ids from earlier releases map onto the new set.
const std = @import("std");

pub const Theme = struct {
    id: []const u8,
    name: []const u8,
    mode: []const u8,
};

pub const all = [_]Theme{
    .{ .id = "paper", .name = "Paper", .mode = "light" },
    .{ .id = "ink", .name = "Ink", .mode = "dark" },
    .{ .id = "midnight", .name = "Midnight", .mode = "dark" },
    .{ .id = "graphite", .name = "Graphite", .mode = "dark" },
    .{ .id = "forest", .name = "Forest", .mode = "dark" },
    .{ .id = "fjord", .name = "Fjord", .mode = "dark" },
    .{ .id = "wine", .name = "Wine", .mode = "dark" },
    .{ .id = "ember", .name = "Ember", .mode = "dark" },
    .{ .id = "sand", .name = "Sand", .mode = "light" },
    .{ .id = "newsprint", .name = "Newsprint", .mode = "light" },
    .{ .id = "rose", .name = "Rose", .mode = "light" },
    .{ .id = "signal", .name = "Signal", .mode = "dark" },
};

pub fn isValid(id: []const u8) bool {
    for (all) |theme| {
        if (std.mem.eql(u8, theme.id, id)) return true;
    }
    return false;
}

/// Maps ids used by earlier releases onto the current palette family.
pub fn canonical(id: []const u8) []const u8 {
    const legacy = [_]struct { old: []const u8, new: []const u8 }{
        .{ .old = "feather", .new = "paper" },
        .{ .old = "feather-dark", .new = "ink" },
        .{ .old = "obsidian", .new = "graphite" },
        .{ .old = "ocean", .new = "fjord" },
        .{ .old = "plum", .new = "wine" },
        .{ .old = "mono", .new = "newsprint" },
        .{ .old = "neon", .new = "signal" },
    };
    for (legacy) |entry| {
        if (std.mem.eql(u8, entry.old, id)) return entry.new;
    }
    return if (isValid(id)) id else "paper";
}

test "theme ids are unique and legacy ids map" {
    for (all, 0..) |theme, i| {
        try std.testing.expect(isValid(theme.id));
        for (all[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, theme.id, other.id));
        }
    }
    try std.testing.expect(!isValid("missing"));
    try std.testing.expectEqualStrings("paper", canonical("feather"));
    try std.testing.expectEqualStrings("signal", canonical("neon"));
    try std.testing.expectEqualStrings("paper", canonical("nonsense"));
}
