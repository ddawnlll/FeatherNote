//! SQLite persistence layer. All public methods serialize on one connection.
const std = @import("std");
const c = @import("sqlite3");
const assets = @import("assets");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const DbError = error{
    Sqlite,
    OpenFailed,
    VersionMismatch,
    MigrationFailed,
};

pub const NoteRow = struct {
    id: i64,
    title: []const u8,
    updated_at: i64,
    version: i64,
    is_pinned: bool,
};

pub const SearchRow = struct {
    id: i64,
    title: []const u8,
    snippet: []const u8,
    updated_at: i64,
    version: i64,
    is_pinned: bool,
};

pub const Note = struct {
    id: i64,
    title: []const u8,
    body: []const u8,
    created_at: i64,
    updated_at: i64,
    version: i64,
    is_pinned: bool,
    deleted_at: ?i64,
};

pub const TrashRow = struct {
    id: i64,
    title: []const u8,
    updated_at: i64,
    deleted_at: i64,
    version: i64,
};

pub const Session = struct {
    owner_id: i64,
    csrf_token: []const u8,
};

pub const Attachment = struct {
    id: i64,
    note_id: i64,
    filename: []const u8,
    mime: []const u8,
    size: i64,
    sha256: []const u8,
    created_at: i64,
};

pub const AttachmentData = struct {
    meta: Attachment,
    data: []const u8,
};

pub const WriteResult = enum { ok, not_found, deleted, conflict };

/// Creates a consistent copy using SQLite's online backup API. Safe while a
/// server process is writing; a plain file copy of a WAL database is not.
pub fn backupTo(allocator: Allocator, io: Io, src_path: []const u8, dest_path: []const u8) !void {
    _ = io;
    const src_z = try allocator.dupeSentinel(u8, src_path, 0);
    defer allocator.free(src_z);
    const dest_z = try allocator.dupeSentinel(u8, dest_path, 0);
    defer allocator.free(dest_z);

    var src_opt: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(src_z.ptr, &src_opt, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
        if (src_opt) |h| _ = c.sqlite3_close(h);
        return error.OpenFailed;
    }
    const src = src_opt.?;
    defer _ = c.sqlite3_close(src);

    var dest_opt: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(dest_z.ptr, &dest_opt, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
        if (dest_opt) |h| _ = c.sqlite3_close(h);
        return error.OpenFailed;
    }
    const dest = dest_opt.?;
    defer _ = c.sqlite3_close(dest);

    _ = c.sqlite3_busy_timeout(src, 5000);
    _ = c.sqlite3_busy_timeout(dest, 5000);
    _ = c.sqlite3_exec(dest, "PRAGMA journal_mode=DELETE;", null, null, null);

    const backup = c.sqlite3_backup_init(dest, "main", src, "main");
    if (backup == null) return error.BackupFailed;
    const rc = c.sqlite3_backup_step(backup, -1);
    const finish_rc = c.sqlite3_backup_finish(backup);
    if (rc != c.SQLITE_DONE or finish_rc != c.SQLITE_OK) return error.BackupFailed;

    var check_opt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(dest, "PRAGMA integrity_check", -1, &check_opt, null) != c.SQLITE_OK)
        return error.BackupFailed;
    defer _ = c.sqlite3_finalize(check_opt);
    if (c.sqlite3_step(check_opt) != c.SQLITE_ROW) return error.BackupFailed;
    const result = c.sqlite3_column_text(check_opt, 0);
    if (result == null or !std.mem.eql(u8, std.mem.span(result), "ok")) return error.BackupFailed;
}

pub const Db = struct {
    handle: *c.sqlite3,
    mutex: Io.Mutex = .init,
    io: Io,
    allocator: Allocator,

    pub fn open(allocator: Allocator, io: Io, path: []const u8) DbError!*Db {
        const path_z = allocator.dupeSentinel(u8, path, 0) catch return DbError.OpenFailed;
        defer allocator.free(path_z);

        var handle_opt: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path_z.ptr, &handle_opt, flags, null) != c.SQLITE_OK) {
            if (handle_opt) |h| _ = c.sqlite3_close(h);
            return DbError.OpenFailed;
        }
        const handle = handle_opt orelse return DbError.OpenFailed;
        errdefer _ = c.sqlite3_close(handle);

        _ = c.sqlite3_extended_result_codes(handle, 1);
        _ = c.sqlite3_busy_timeout(handle, 5000);

        const self = allocator.create(Db) catch return DbError.OpenFailed;
        errdefer allocator.destroy(self);
        self.* = .{ .handle = handle, .io = io, .allocator = allocator };
        try self.execRaw("PRAGMA journal_mode=WAL;");
        try self.execRaw("PRAGMA synchronous=FULL;");
        try self.execRaw("PRAGMA foreign_keys=ON;");
        try self.execRaw("PRAGMA trusted_schema=OFF;");
        try self.execRaw("PRAGMA temp_store=MEMORY;");
        try self.execRaw("PRAGMA cache_size=-512;");
        try self.migrate();
        return self;
    }

    pub fn close(self: *Db, allocator: Allocator) void {
        defer allocator.destroy(self);
        _ = self.execRaw("PRAGMA wal_checkpoint(TRUNCATE);") catch {};
        _ = c.sqlite3_close(self.handle);
    }

    pub fn version(self: *Db) []const u8 {
        _ = self;
        return std.mem.span(c.sqlite3_libversion());
    }

    fn migrate(self: *Db) DbError!void {
        try self.execRaw(
            \\CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER NOT NULL);
            \\INSERT INTO schema_meta(version)
            \\SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM schema_meta);
        );
        const current = self.schemaVersion() catch return DbError.MigrationFailed;
        if (current > 3) return DbError.VersionMismatch;
        if (current == 0) {
            try self.execRaw("BEGIN IMMEDIATE;");
            errdefer _ = self.execRaw("ROLLBACK;") catch {};
            try self.execRaw(assets.migration_0001);
            try self.execRaw("UPDATE schema_meta SET version = 1;");
            try self.execRaw("COMMIT;");
        }
        if (current <= 1) {
            try self.execRaw("BEGIN IMMEDIATE;");
            errdefer _ = self.execRaw("ROLLBACK;") catch {};
            try self.execRaw(assets.migration_0002);
            try self.execRaw("UPDATE schema_meta SET version = 2;");
            try self.execRaw("COMMIT;");
        }
        if (current <= 2) {
            try self.execRaw("BEGIN IMMEDIATE;");
            errdefer _ = self.execRaw("ROLLBACK;") catch {};
            try self.execRaw(assets.migration_0003);
            try self.execRaw("UPDATE schema_meta SET version = 3;");
            try self.execRaw("COMMIT;");
        }
    }

    fn schemaVersion(self: *Db) !i64 {
        var stmt = try self.prepare("SELECT version FROM schema_meta LIMIT 1");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    fn execRaw(self: *Db, sql: [:0]const u8) DbError!void {
        var msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &msg);
        if (msg != null) c.sqlite3_free(msg);
        if (rc != c.SQLITE_OK) {
            std.log.err("sqlite exec failed ({d}): {s}", .{ rc, std.mem.span(c.sqlite3_errmsg(self.handle)) });
            return DbError.Sqlite;
        }
    }

    const Stmt = struct {
        handle: *c.sqlite3_stmt,

        fn deinit(self: *Stmt) void {
            _ = c.sqlite3_finalize(self.handle);
            self.* = undefined;
        }

        fn step(self: *Stmt) !c_int {
            return c.sqlite3_step(self.handle);
        }

        fn bindText(self: *Stmt, index: c_int, text: []const u8) !void {
            const rc = c.sqlite3_bind_text(self.handle, index, text.ptr, @intCast(text.len), null);
            if (rc != c.SQLITE_OK) return error.Sqlite;
        }

        fn bindInt(self: *Stmt, index: c_int, value: i64) !void {
            if (c.sqlite3_bind_int64(self.handle, index, value) != c.SQLITE_OK) return error.Sqlite;
        }

        fn bindBlob(self: *Stmt, index: c_int, data: []const u8) !void {
            const rc = c.sqlite3_bind_blob(self.handle, index, data.ptr, @intCast(data.len), null);
            if (rc != c.SQLITE_OK) return error.Sqlite;
        }
    };

    fn prepare(self: *Db, sql: [:0]const u8) !Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &handle, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("sqlite prepare failed ({d}): {s}", .{ rc, std.mem.span(c.sqlite3_errmsg(self.handle)) });
            return error.Sqlite;
        }
        return .{ .handle = handle orelse return error.Sqlite };
    }

    fn columnText(self: *Db, stmt: *Stmt, index: c_int, allocator: Allocator) ![]const u8 {
        _ = self;
        const ptr = c.sqlite3_column_text(stmt.handle, index);
        const n: usize = @intCast(c.sqlite3_column_bytes(stmt.handle, index));
        if (ptr == null) return allocator.dupe(u8, "");
        return allocator.dupe(u8, ptr[0..n]);
    }

    fn columnBlob(self: *Db, stmt: *Stmt, index: c_int, allocator: Allocator) ![]const u8 {
        _ = self;
        const ptr = c.sqlite3_column_blob(stmt.handle, index);
        const n: usize = @intCast(c.sqlite3_column_bytes(stmt.handle, index));
        if (ptr == null or n == 0) return allocator.dupe(u8, "");
        const bytes: [*]const u8 = @ptrCast(ptr);
        return allocator.dupe(u8, bytes[0..n]);
    }

    // ---- owner and sessions ----

    pub fn hasOwner(self: *Db, allocator: Allocator) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT COUNT(*) FROM owner");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        _ = allocator;
        return c.sqlite3_column_int64(stmt.handle, 0) > 0;
    }

    pub fn ownerHash(self: *Db, allocator: Allocator) !?[]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT password_hash FROM owner WHERE id = 1");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return null;
        return try self.columnText(&stmt, 0, allocator);
    }

    pub fn setOwnerPassword(self: *Db, hash: []const u8, now: i64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        _ = try self.execRawNoLock("BEGIN IMMEDIATE;");
        errdefer _ = self.execRawNoLock("ROLLBACK;") catch {};
        var stmt = try self.prepare(
            \\INSERT INTO owner(id, password_hash, created_at) VALUES(1, ?, ?)
            \\ON CONFLICT(id) DO UPDATE SET password_hash = excluded.password_hash
        );
        defer stmt.deinit();
        try stmt.bindText(1, hash);
        try stmt.bindInt(2, now);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        var del = try self.prepare("DELETE FROM sessions");
        defer del.deinit();
        if (try del.step() != c.SQLITE_DONE) return error.Sqlite;
        try self.execRawNoLock("COMMIT;");
    }

    fn execRawNoLock(self: *Db, sql: [:0]const u8) DbError!void {
        return self.execRaw(sql);
    }

    pub fn createSession(
        self: *Db,
        token_hash: []const u8,
        csrf_token: []const u8,
        now: i64,
        expires_at: i64,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var prune = try self.prepare("DELETE FROM sessions WHERE expires_at <= ? OR revoked = 1");
        defer prune.deinit();
        try prune.bindInt(1, now);
        _ = try prune.step();

        var stmt = try self.prepare(
            \\INSERT INTO sessions(token_hash, owner_id, csrf_token, issued_at, last_used_at, expires_at, revoked)
            \\VALUES(?, 1, ?, ?, ?, ?, 0)
        );
        defer stmt.deinit();
        try stmt.bindText(1, token_hash);
        try stmt.bindText(2, csrf_token);
        try stmt.bindInt(3, now);
        try stmt.bindInt(4, now);
        try stmt.bindInt(5, expires_at);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
    }

    pub fn findSession(self: *Db, allocator: Allocator, token_hash: []const u8, now: i64) !?Session {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const found = blk: {
            var stmt = try self.prepare(
                \\SELECT owner_id, csrf_token, last_used_at FROM sessions
                \\WHERE token_hash = ? AND revoked = 0 AND expires_at > ?
            );
            defer stmt.deinit();
            try stmt.bindText(1, token_hash);
            try stmt.bindInt(2, now);
            if (try stmt.step() != c.SQLITE_ROW) return null;
            const owner_id = c.sqlite3_column_int64(stmt.handle, 0);
            const csrf = try self.columnText(&stmt, 1, allocator);
            const last_used = c.sqlite3_column_int64(stmt.handle, 2);
            break :blk .{ .owner_id = owner_id, .csrf = csrf, .last_used = last_used };
        };
        if (now - found.last_used > 3600) {
            var touch = try self.prepare("UPDATE sessions SET last_used_at = ? WHERE token_hash = ?");
            defer touch.deinit();
            try touch.bindInt(1, now);
            try touch.bindText(2, token_hash);
            _ = try touch.step();
        }
        return .{ .owner_id = found.owner_id, .csrf_token = found.csrf };
    }

    pub fn revokeSession(self: *Db, token_hash: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("UPDATE sessions SET revoked = 1 WHERE token_hash = ?");
        defer stmt.deinit();
        try stmt.bindText(1, token_hash);
        _ = try stmt.step();
    }

    // ---- appearance ----

    pub fn theme(self: *Db, allocator: Allocator) ![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT theme FROM owner WHERE id = 1");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return allocator.dupe(u8, "feather");
        return self.columnText(&stmt, 0, allocator);
    }

    pub fn setTheme(self: *Db, theme_id: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("UPDATE owner SET theme = ? WHERE id = 1");
        defer stmt.deinit();
        try stmt.bindText(1, theme_id);
        _ = try stmt.step();
    }

    // ---- attachments ----

    pub const NewAttachment = struct {
        note_id: i64,
        filename: []const u8,
        mime: []const u8,
        sha256: []const u8,
        data: []const u8,
    };

    pub fn insertAttachment(self: *Db, row: NewAttachment, now: i64) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\INSERT INTO attachments(note_id, filename, mime, size, sha256, data, created_at)
            \\VALUES(?, ?, ?, ?, ?, ?, ?)
        );
        defer stmt.deinit();
        try stmt.bindInt(1, row.note_id);
        try stmt.bindText(2, row.filename);
        try stmt.bindText(3, row.mime);
        try stmt.bindInt(4, @intCast(row.data.len));
        try stmt.bindText(5, row.sha256);
        try stmt.bindBlob(6, row.data);
        try stmt.bindInt(7, now);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn attachment(self: *Db, allocator: Allocator, id: i64) !?AttachmentData {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT id, note_id, filename, mime, size, sha256, created_at, data
            \\FROM attachments WHERE id = ?
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        if (try stmt.step() != c.SQLITE_ROW) return null;
        return .{
            .meta = .{
                .id = c.sqlite3_column_int64(stmt.handle, 0),
                .note_id = c.sqlite3_column_int64(stmt.handle, 1),
                .filename = try self.columnText(&stmt, 2, allocator),
                .mime = try self.columnText(&stmt, 3, allocator),
                .size = c.sqlite3_column_int64(stmt.handle, 4),
                .sha256 = try self.columnText(&stmt, 5, allocator),
                .created_at = c.sqlite3_column_int64(stmt.handle, 6),
            },
            .data = try self.columnBlob(&stmt, 7, allocator),
        };
    }

    pub fn attachmentsForNote(self: *Db, allocator: Allocator, note_id: i64) ![]Attachment {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT id, note_id, filename, mime, size, sha256, created_at
            \\FROM attachments WHERE note_id = ? ORDER BY id ASC
        );
        defer stmt.deinit();
        try stmt.bindInt(1, note_id);
        var rows: std.ArrayList(Attachment) = .empty;
        while (try stmt.step() == c.SQLITE_ROW) {
            try rows.append(allocator, .{
                .id = c.sqlite3_column_int64(stmt.handle, 0),
                .note_id = c.sqlite3_column_int64(stmt.handle, 1),
                .filename = try self.columnText(&stmt, 2, allocator),
                .mime = try self.columnText(&stmt, 3, allocator),
                .size = c.sqlite3_column_int64(stmt.handle, 4),
                .sha256 = try self.columnText(&stmt, 5, allocator),
                .created_at = c.sqlite3_column_int64(stmt.handle, 6),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn deleteAttachment(self: *Db, id: i64, note_id: i64) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("DELETE FROM attachments WHERE id = ? AND note_id = ?");
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        try stmt.bindInt(2, note_id);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        return c.sqlite3_changes(self.handle) == 1;
    }

    // ---- notes ----

    pub fn createNote(self: *Db, allocator: Allocator, title: []const u8, body: []const u8, now: i64) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\INSERT INTO notes(title, body, created_at, updated_at, version, is_pinned, deleted_at)
            \\VALUES(?, ?, ?, ?, 1, 0, NULL)
        );
        defer stmt.deinit();
        try stmt.bindText(1, title);
        try stmt.bindText(2, body);
        try stmt.bindInt(3, now);
        try stmt.bindInt(4, now);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        _ = allocator;
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn getNote(self: *Db, allocator: Allocator, id: i64, include_deleted: bool) !?Note {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const sql: [:0]const u8 = if (include_deleted)
            "SELECT id,title,body,created_at,updated_at,version,is_pinned,deleted_at FROM notes WHERE id = ?"
        else
            "SELECT id,title,body,created_at,updated_at,version,is_pinned,deleted_at FROM notes WHERE id = ? AND deleted_at IS NULL";
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        if (try stmt.step() != c.SQLITE_ROW) return null;
        return .{
            .id = c.sqlite3_column_int64(stmt.handle, 0),
            .title = try self.columnText(&stmt, 1, allocator),
            .body = try self.columnText(&stmt, 2, allocator),
            .created_at = c.sqlite3_column_int64(stmt.handle, 3),
            .updated_at = c.sqlite3_column_int64(stmt.handle, 4),
            .version = c.sqlite3_column_int64(stmt.handle, 5),
            .is_pinned = c.sqlite3_column_int64(stmt.handle, 6) != 0,
            .deleted_at = if (c.sqlite3_column_type(stmt.handle, 7) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_int64(stmt.handle, 7),
        };
    }

    pub fn updateNote(
        self: *Db,
        id: i64,
        expected_version: i64,
        title: []const u8,
        body: []const u8,
        now: i64,
    ) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\UPDATE notes SET title = ?, body = ?, updated_at = ?, version = version + 1
            \\WHERE id = ? AND version = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, title);
        try stmt.bindText(2, body);
        try stmt.bindInt(3, now);
        try stmt.bindInt(4, id);
        try stmt.bindInt(5, expected_version);
        const rc = try stmt.step();
        if (rc != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) == 1) return .ok;
        return self.classifyWriteFailure(id);
    }

    fn classifyWriteFailure(self: *Db, id: i64) !WriteResult {
        var stmt = try self.prepare("SELECT version, deleted_at FROM notes WHERE id = ?");
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        if (try stmt.step() != c.SQLITE_ROW) return .not_found;
        if (c.sqlite3_column_type(stmt.handle, 1) != c.SQLITE_NULL) return .deleted;
        return .conflict;
    }

    pub fn togglePin(self: *Db, id: i64, expected_version: i64, now: i64) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\UPDATE notes SET is_pinned = 1 - is_pinned, version = version + 1, updated_at = ?
            \\WHERE id = ? AND version = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindInt(1, now);
        try stmt.bindInt(2, id);
        try stmt.bindInt(3, expected_version);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) == 1) return .ok;
        return self.classifyWriteFailure(id);
    }

    pub fn setPinned(self: *Db, id: i64, expected_version: i64, pinned: bool, now: i64) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\UPDATE notes SET is_pinned = ?, version = version + 1, updated_at = ?
            \\WHERE id = ? AND version = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindInt(1, if (pinned) 1 else 0);
        try stmt.bindInt(2, now);
        try stmt.bindInt(3, id);
        try stmt.bindInt(4, expected_version);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) == 1) return .ok;
        return self.classifyWriteFailure(id);
    }

    pub fn softDelete(self: *Db, id: i64, expected_version: i64, now: i64) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\UPDATE notes SET deleted_at = ?, version = version + 1, updated_at = ?
            \\WHERE id = ? AND version = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindInt(1, now);
        try stmt.bindInt(2, now);
        try stmt.bindInt(3, id);
        try stmt.bindInt(4, expected_version);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) == 1) return .ok;
        return self.classifyWriteFailure(id);
    }

    pub fn restore(self: *Db, id: i64, expected_version: i64, now: i64) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\UPDATE notes SET deleted_at = NULL, version = version + 1, updated_at = ?
            \\WHERE id = ? AND version = ? AND deleted_at IS NOT NULL
        );
        defer stmt.deinit();
        try stmt.bindInt(1, now);
        try stmt.bindInt(2, id);
        try stmt.bindInt(3, expected_version);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) == 1) return .ok;
        return self.classifyWriteFailure(id);
    }

    pub fn listNotes(
        self: *Db,
        allocator: Allocator,
        search: ?[]const u8,
        offset: usize,
        limit: usize,
    ) ![]NoteRow {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var rows: std.ArrayList(NoteRow) = .empty;
        errdefer rows.deinit(allocator);
        if (search) |q| {
            const fts = try makeFtsQuery(allocator, q);
            defer if (fts) |text| allocator.free(text);
            if (fts == null) return rows.toOwnedSlice(allocator);
            var stmt = try self.prepare(
                \\SELECT n.id,n.title,n.updated_at,n.version,n.is_pinned
                \\FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
                \\WHERE notes_fts MATCH ? AND n.deleted_at IS NULL
                \\ORDER BY n.is_pinned DESC, n.updated_at DESC, n.id DESC LIMIT ? OFFSET ?
            );
            defer stmt.deinit();
            try stmt.bindText(1, fts.?);
            try stmt.bindInt(2, @intCast(limit));
            try stmt.bindInt(3, @intCast(offset));
            while (try stmt.step() == c.SQLITE_ROW) {
                try rows.append(allocator, .{
                    .id = c.sqlite3_column_int64(stmt.handle, 0),
                    .title = try self.columnText(&stmt, 1, allocator),
                    .updated_at = c.sqlite3_column_int64(stmt.handle, 2),
                    .version = c.sqlite3_column_int64(stmt.handle, 3),
                    .is_pinned = c.sqlite3_column_int64(stmt.handle, 4) != 0,
                });
            }
        } else {
            var stmt = try self.prepare(
                \\SELECT id,title,updated_at,version,is_pinned FROM notes
                \\WHERE deleted_at IS NULL
                \\ORDER BY is_pinned DESC, updated_at DESC, id DESC LIMIT ? OFFSET ?
            );
            defer stmt.deinit();
            try stmt.bindInt(1, @intCast(limit));
            try stmt.bindInt(2, @intCast(offset));
            while (try stmt.step() == c.SQLITE_ROW) {
                try rows.append(allocator, .{
                    .id = c.sqlite3_column_int64(stmt.handle, 0),
                    .title = try self.columnText(&stmt, 1, allocator),
                    .updated_at = c.sqlite3_column_int64(stmt.handle, 2),
                    .version = c.sqlite3_column_int64(stmt.handle, 3),
                    .is_pinned = c.sqlite3_column_int64(stmt.handle, 4) != 0,
                });
            }
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn countNotes(self: *Db, search: ?[]const u8) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (search) |q| {
            const fts = try makeFtsQuery(self.allocator, q);
            defer if (fts) |text| self.allocator.free(text);
            if (fts == null) return 0;
            var stmt = try self.prepare(
                \\SELECT COUNT(*) FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
                \\WHERE notes_fts MATCH ? AND n.deleted_at IS NULL
            );
            defer stmt.deinit();
            try stmt.bindText(1, fts.?);
            if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
            return c.sqlite3_column_int64(stmt.handle, 0);
        }
        var stmt = try self.prepare("SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    pub fn searchNotes(
        self: *Db,
        allocator: Allocator,
        query: []const u8,
        offset: usize,
        limit: usize,
    ) ![]SearchRow {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var rows: std.ArrayList(SearchRow) = .empty;
        errdefer rows.deinit(allocator);
        const fts = try makeFtsQuery(allocator, query);
        defer if (fts) |text| allocator.free(text);
        if (fts == null) return rows.toOwnedSlice(allocator);
        var stmt = try self.prepare(
            \\SELECT n.id, n.title, snippet(notes_fts, 1, '', '', '…', 14),
            \\       n.updated_at, n.version, n.is_pinned
            \\FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
            \\WHERE notes_fts MATCH ? AND n.deleted_at IS NULL
            \\ORDER BY n.is_pinned DESC, n.updated_at DESC, n.id DESC LIMIT ? OFFSET ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, fts.?);
        try stmt.bindInt(2, @intCast(limit));
        try stmt.bindInt(3, @intCast(offset));
        while (try stmt.step() == c.SQLITE_ROW) {
            try rows.append(allocator, .{
                .id = c.sqlite3_column_int64(stmt.handle, 0),
                .title = try self.columnText(&stmt, 1, allocator),
                .snippet = try self.columnText(&stmt, 2, allocator),
                .updated_at = c.sqlite3_column_int64(stmt.handle, 3),
                .version = c.sqlite3_column_int64(stmt.handle, 4),
                .is_pinned = c.sqlite3_column_int64(stmt.handle, 5) != 0,
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn listTrash(self: *Db, allocator: Allocator, offset: usize, limit: usize) ![]TrashRow {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT id,title,updated_at,deleted_at,version FROM notes
            \\WHERE deleted_at IS NOT NULL
            \\ORDER BY deleted_at DESC, id DESC LIMIT ? OFFSET ?
        );
        defer stmt.deinit();
        try stmt.bindInt(1, @intCast(limit));
        try stmt.bindInt(2, @intCast(offset));
        var rows: std.ArrayList(TrashRow) = .empty;
        errdefer rows.deinit(allocator);
        while (try stmt.step() == c.SQLITE_ROW) {
            try rows.append(allocator, .{
                .id = c.sqlite3_column_int64(stmt.handle, 0),
                .title = try self.columnText(&stmt, 1, allocator),
                .updated_at = c.sqlite3_column_int64(stmt.handle, 2),
                .deleted_at = c.sqlite3_column_int64(stmt.handle, 3),
                .version = c.sqlite3_column_int64(stmt.handle, 4),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn countTrash(self: *Db) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT COUNT(*) FROM notes WHERE deleted_at IS NOT NULL");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    pub fn countAttachments(self: *Db) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT COUNT(*) FROM attachments");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    pub fn integrityCheck(self: *Db) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("PRAGMA integrity_check");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return false;
        const result = c.sqlite3_column_text(stmt.handle, 0);
        if (result == null) return false;
        return std.mem.eql(u8, std.mem.span(result), "ok");
    }

    pub fn checkpoint(self: *Db) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("PRAGMA wal_checkpoint(TRUNCATE);");
    }
};

fn makeFtsQuery(allocator: Allocator, q: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var any = false;
    var tokens = std.mem.tokenizeAny(u8, q, " \t\r\n");
    while (tokens.next()) |term| {
        var searchable = false;
        for (term) |ch| {
            if (ch >= 0x80 or std.ascii.isAlphanumeric(ch)) {
                searchable = true;
                break;
            }
        }
        if (!searchable) continue;
        if (any) try out.appendSlice(allocator, " AND ");
        try out.append(allocator, '"');
        for (term) |ch| {
            if (ch == '"') try out.append(allocator, '"');
            try out.append(allocator, ch);
        }
        try out.append(allocator, '"');
        any = true;
    }
    if (!any) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

// ---- tests ----

test "note lifecycle, search, version conflict and soft delete" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "test.db" });
    defer testing.allocator.free(db_path);

    const db = try Db.open(testing.allocator, io, db_path);
    defer db.close(testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = try db.createNote(arena, "First note", "hello <world>", 1000);
    const note = (try db.getNote(arena, id, false)).?;
    try testing.expectEqualStrings("First note", note.title);
    try testing.expectEqual(@as(i64, 1), note.version);

    try testing.expectEqual(WriteResult.conflict, try db.updateNote(id, 99, "stale", "x", 1001));
    try testing.expectEqual(WriteResult.ok, try db.updateNote(id, 1, "Updated", "body two", 1002));
    try testing.expectEqual(@as(i64, 2), (try db.getNote(arena, id, false)).?.version);

    const found = try db.listNotes(arena, "body two", 0, 50);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("Updated", found[0].title);
    try testing.expectEqual(@as(i64, 1), try db.countNotes("body two"));
    try testing.expectEqual(@as(i64, 1), try db.countNotes("Updated"));
    try testing.expectEqual(@as(i64, 0), try db.countNotes("%"));
    try testing.expectEqual(@as(i64, 0), try db.countNotes("\"quoted\""));

    try testing.expectEqual(WriteResult.ok, try db.togglePin(id, 2, 1003));
    try testing.expect((try db.getNote(arena, id, false)).?.is_pinned);
    try testing.expectEqual(WriteResult.ok, try db.togglePin(id, 3, 1004));

    try testing.expectEqual(WriteResult.ok, try db.softDelete(id, 4, 1005));
    try testing.expect((try db.getNote(arena, id, false)) == null);
    try testing.expectEqual(@as(i64, 1), try db.countTrash());
    try testing.expectEqual(WriteResult.ok, try db.restore(id, 5, 1006));
    try testing.expect((try db.getNote(arena, id, false)) != null);

    try testing.expect(try db.integrityCheck());
}

test "sessions and owner" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "test.db" });
    defer testing.allocator.free(db_path);

    const db = try Db.open(testing.allocator, io, db_path);
    defer db.close(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(!try db.hasOwner(arena));
    try db.setOwnerPassword("$argon2id$fake", 100);
    try testing.expect(try db.hasOwner(arena));
    try testing.expectEqualStrings("$argon2id$fake", (try db.ownerHash(arena)).?);

    try db.createSession("hash1", "csrf1", 100, 1000);
    const session = (try db.findSession(arena, "hash1", 101)).?;
    try testing.expectEqualStrings("csrf1", session.csrf_token);
    try testing.expect((try db.findSession(arena, "hash1", 1001)) == null);
    try db.revokeSession("hash1");
    try testing.expect((try db.findSession(arena, "hash1", 101)) == null);
}
