//! Password hashing, session tokens, CSRF helpers and login throttling.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const argon_params: std.crypto.pwhash.argon2.Params =
    std.crypto.pwhash.argon2.Params.owasp_2id;

pub const min_password_len = 12;
pub const max_password_len = 1024;

pub fn validatePassword(password: []const u8) !void {
    if (password.len < min_password_len) return error.PasswordTooShort;
    if (password.len > max_password_len) return error.PasswordTooLong;
    if (!std.unicode.utf8ValidateSlice(password)) return error.InvalidPasswordEncoding;
}

pub fn hashPassword(allocator: Allocator, io: Io, password: []const u8, out: []u8) ![]const u8 {
    return try std.crypto.pwhash.argon2.strHash(password, .{
        .allocator = allocator,
        .params = argon_params,
        .mode = .argon2id,
        .encoding = .phc,
    }, out, io);
}

/// Verifies a password against a stored PHC string. Returns false for any
/// malformed hash rather than leaking which part failed.
pub fn verifyPassword(allocator: Allocator, io: Io, stored: []const u8, password: []const u8) bool {
    if (password.len > max_password_len) return false;
    std.crypto.pwhash.argon2.strVerify(stored, password, .{
        .allocator = allocator,
    }, io) catch return false;
    return true;
}

pub const NewSession = struct {
    token_hex: [64]u8,
    token_hash_hex: [64]u8,
    csrf_hex: [64]u8,
};

pub fn newSession(io: Io) NewSession {
    var token_raw: [32]u8 = undefined;
    var csrf_raw: [32]u8 = undefined;
    io.random(&token_raw);
    io.random(&csrf_raw);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token_raw, &digest, .{});

    return .{
        .token_hex = std.fmt.bytesToHex(token_raw, .lower),
        .token_hash_hex = std.fmt.bytesToHex(digest, .lower),
        .csrf_hex = std.fmt.bytesToHex(csrf_raw, .lower),
    };
}

/// Hashes a hex session token from a cookie. Returns null for malformed input.
pub fn tokenHashFromHex(token_hex: []const u8) ?[64]u8 {
    if (token_hex.len != 64) return null;
    var raw: [32]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&raw, token_hex) catch return null;
    if (decoded.len != 32) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&raw, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn csrfMatches(expected_hex: []const u8, supplied_hex: []const u8) bool {
    if (expected_hex.len != 64 or supplied_hex.len != 64) return false;
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    const da = std.fmt.hexToBytes(&a, expected_hex) catch return false;
    const db = std.fmt.hexToBytes(&b, supplied_hex) catch return false;
    if (da.len != 32 or db.len != 32) return false;
    return std.crypto.timing_safe.eql([32]u8, a, b);
}

pub const LoginDecision = struct {
    ticket: ?usize = null,
    limited: bool = false,
    busy: bool = false,
};

/// Small fixed-size in-process login limiter. It bounds memory as well as
/// password-guessing work; it is intentionally not a distributed rate limiter.
pub const LoginLimiter = struct {
    const max_entries = 128;
    const window_seconds: i64 = 15 * 60;
    const max_failures: u32 = 5;
    const max_concurrent: u32 = 2;

    const Entry = struct {
        key: [64]u8 = undefined,
        key_len: u8 = 0,
        failures: u32 = 0,
        window_start: i64 = 0,
    };

    mutex: Io.Mutex = .init,
    entries: [max_entries]Entry = @splat(.{}),
    next_slot: usize = 0,
    active: u32 = 0,

    pub fn begin(self: *LoginLimiter, io: Io, key: []const u8, now: i64) LoginDecision {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const idx = self.findOrCreate(key, now);
        const entry = &self.entries[idx];
        if (entry.failures >= max_failures and now - entry.window_start < window_seconds) {
            return .{ .limited = true };
        }
        if (self.active >= max_concurrent) return .{ .busy = true };
        self.active += 1;
        return .{ .ticket = idx };
    }

    pub fn finish(self: *LoginLimiter, io: Io, ticket: usize, success: bool, now: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.active > 0) self.active -= 1;
        if (ticket >= self.entries.len) return;
        const entry = &self.entries[ticket];
        if (success) {
            entry.failures = 0;
            entry.window_start = now;
        } else {
            if (now - entry.window_start >= window_seconds) {
                entry.window_start = now;
                entry.failures = 1;
            } else {
                entry.failures +|= 1;
            }
        }
    }

    fn findOrCreate(self: *LoginLimiter, key: []const u8, now: i64) usize {
        const clipped = key[0..@min(key.len, 64)];
        for (&self.entries, 0..) |*entry, i| {
            if (entry.key_len != 0 and std.mem.eql(u8, entry.key[0..entry.key_len], clipped)) {
                if (now - entry.window_start >= window_seconds) {
                    entry.failures = 0;
                    entry.window_start = now;
                }
                return i;
            }
        }
        // Reuse an empty slot, or the next slot in round-robin order.
        var idx = self.next_slot;
        for (0..max_entries) |_| {
            if (self.entries[idx].key_len == 0 or
                now - self.entries[idx].window_start >= window_seconds)
            {
                break;
            }
            idx = (idx + 1) % max_entries;
        }
        self.next_slot = (idx + 1) % max_entries;
        const entry = &self.entries[idx];
        entry.* = .{ .failures = 0, .window_start = now };
        @memcpy(entry.key[0..clipped.len], clipped);
        entry.key_len = @intCast(clipped.len);
        return idx;
    }
};

test "password hashing round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var hash_buf: [256]u8 = undefined;
    const hash = try hashPassword(arena, io, "correct horse battery staple", &hash_buf);
    try std.testing.expect(std.mem.startsWith(u8, hash, "$argon2id$"));
    try std.testing.expect(verifyPassword(arena, io, hash, "correct horse battery staple"));
    try std.testing.expect(!verifyPassword(arena, io, hash, "wrong password"));
    try std.testing.expect(!verifyPassword(arena, io, "not a hash", "x"));
}

test "session tokens and csrf comparison" {
    const io = std.testing.io;
    const s = newSession(io);
    try std.testing.expectEqual(@as(usize, 64), s.token_hex.len);
    try std.testing.expect(tokenHashFromHex(&s.token_hex) != null);
    try std.testing.expect(tokenHashFromHex("short") == null);
    try std.testing.expect(csrfMatches(&s.csrf_hex, &s.csrf_hex));
    var other = s.csrf_hex;
    other[0] = if (other[0] == 'a') 'b' else 'a';
    try std.testing.expect(!csrfMatches(&s.csrf_hex, &other));
}

test "login limiter bounds failures" {
    var limiter: LoginLimiter = .{};
    const io = std.testing.io;
    const key = "127.0.0.1";
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const decision = limiter.begin(io, key, 1000);
        try std.testing.expect(decision.ticket != null);
        limiter.finish(io, decision.ticket.?, false, 1000);
    }
    try std.testing.expect(limiter.begin(io, key, 1000).limited);
    try std.testing.expect(limiter.begin(io, key, 1000 + 901).ticket != null);
}
