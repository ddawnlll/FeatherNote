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
    deleted_at: ?i64 = null,
};

pub const AttachmentData = struct {
    meta: Attachment,
    data: []const u8,
};

pub const WriteResult = enum { ok, not_found, deleted, conflict };

/// Who performed a mutation. Persisted with every revision so history has
/// provenance without storing note content in operational logs.
pub const Origin = enum { web, mcp, import, admin, system };

pub const RevisionAction = enum {
    baseline,
    create,
    update,
    pin,
    unpin,
    delete,
    restore,
    restore_revision,
};

pub const Revision = struct {
    id: i64,
    note_id: i64,
    revision_no: i64,
    note_version: i64,
    title: []const u8,
    body: []const u8,
    is_pinned: bool,
    deleted_at: ?i64,
    created_at: i64,
    origin: Origin,
    action: RevisionAction,
    summary: []const u8,
    checksum: []const u8,
    label: []const u8,
};

pub const RevisionRow = struct {
    revision_no: i64,
    note_version: i64,
    title: []const u8,
    created_at: i64,
    origin: Origin,
    action: RevisionAction,
    summary: []const u8,
    checksum: []const u8,
    label: []const u8,
};

pub const RevisionAsset = struct {
    attachment_id: i64,
    filename: []const u8,
    mime: []const u8,
    size: i64,
    sha256: []const u8,
};

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
    read_only: bool = false,

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
        if (!self.read_only) _ = self.execRaw("PRAGMA wal_checkpoint(TRUNCATE);") catch {};
        _ = c.sqlite3_close(self.handle);
    }

    /// Read-only open for doctor/verification. Never migrates or writes.
    pub fn openReadOnly(allocator: Allocator, io: Io, path: []const u8) DbError!*Db {
        const path_z = allocator.dupeSentinel(u8, path, 0) catch return DbError.OpenFailed;
        defer allocator.free(path_z);

        var handle_opt: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX;
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
        self.* = .{ .handle = handle, .io = io, .allocator = allocator, .read_only = true };
        try self.execRaw("PRAGMA query_only=ON;");
        try self.execRaw("PRAGMA foreign_keys=ON;");
        try self.execRaw("PRAGMA trusted_schema=OFF;");
        return self;
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
        if (current > 6) return DbError.VersionMismatch;
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
        if (current <= 3) {
            try self.execRaw("BEGIN IMMEDIATE;");
            errdefer _ = self.execRaw("ROLLBACK;") catch {};
            try self.execRaw(assets.migration_0004);
            try self.seedBaselineRevisions();
            try self.execRaw("UPDATE schema_meta SET version = 4;");
            try self.execRaw("COMMIT;");
        }
        if (current <= 4) {
            try self.execRaw("BEGIN IMMEDIATE;");
            errdefer _ = self.execRaw("ROLLBACK;") catch {};
            try self.execRaw(assets.migration_0005);
            try self.execRaw("UPDATE schema_meta SET version = 5;");
            try self.execRaw("COMMIT;");
        }
        if (current <= 5) {
            try self.execRaw("BEGIN IMMEDIATE;");
            errdefer _ = self.execRaw("ROLLBACK;") catch {};
            try self.execRaw(assets.migration_0006);
            try self.execRaw("UPDATE schema_meta SET version = 6;");
            try self.execRaw("COMMIT;");
        }
    }

    /// The v4 migration point. Existing notes get exactly one baseline revision
    /// with their current bytes; no earlier history is invented. Runs inside the
    /// migration transaction.
    fn seedBaselineRevisions(self: *Db) DbError!void {
        var stmt = self.prepare(
            "SELECT id FROM notes WHERE NOT EXISTS (SELECT 1 FROM note_revisions r WHERE r.note_id = notes.id)",
        ) catch return DbError.MigrationFailed;
        defer stmt.deinit();
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(self.allocator);
        while (true) {
            const rc = stmt.step() catch return DbError.MigrationFailed;
            if (rc != c.SQLITE_ROW) break;
            ids.append(self.allocator, c.sqlite3_column_int64(stmt.handle, 0)) catch return DbError.MigrationFailed;
        }
        for (ids.items) |id| {
            self.insertRevisionLocked(id, null, .system, .baseline, "Baseline revision created by the v2 migration") catch return DbError.MigrationFailed;
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

        fn bindNull(self: *Stmt, index: c_int) !void {
            if (c.sqlite3_bind_null(self.handle, index) != c.SQLITE_OK) return error.Sqlite;
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
            \\SELECT id, note_id, filename, mime, size, sha256, created_at, data, deleted_at
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
                .deleted_at = if (c.sqlite3_column_type(stmt.handle, 8) == c.SQLITE_NULL)
                    null
                else
                    c.sqlite3_column_int64(stmt.handle, 8),
            },
            .data = try self.columnBlob(&stmt, 7, allocator),
        };
    }

    pub fn attachmentsForNote(self: *Db, allocator: Allocator, note_id: i64) ![]Attachment {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT id, note_id, filename, mime, size, sha256, created_at
            \\FROM attachments WHERE note_id = ? AND deleted_at IS NULL ORDER BY id ASC
        );
        defer stmt.deinit();
        try stmt.bindInt(1, note_id);
        var rows: std.ArrayList(Attachment) = .empty;
        errdefer rows.deinit(allocator);
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
        // Soft delete: history must keep referencing the exact bytes.
        var stmt = try self.prepare(
            "UPDATE attachments SET deleted_at = unixepoch() WHERE id = ? AND note_id = ? AND deleted_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        try stmt.bindInt(2, note_id);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        return c.sqlite3_changes(self.handle) == 1;
    }

    /// Rollback helper for a failed upload/link sequence. Unlike deleteAttachment
    /// this removes bytes that were never acknowledged as part of a revision.
    pub fn discardUnlinkedAttachment(self: *Db, id: i64, note_id: i64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            "DELETE FROM attachments WHERE id = ? AND note_id = ? AND deleted_at IS NULL",
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        try stmt.bindInt(2, note_id);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
    }

    // ---- notes ----

    pub fn createNote(self: *Db, allocator: Allocator, title: []const u8, body: []const u8, now: i64) !i64 {
        return self.createNoteFrom(allocator, title, body, now, .system);
    }

    pub fn createNoteFrom(
        self: *Db,
        allocator: Allocator,
        title: []const u8,
        body: []const u8,
        now: i64,
        origin: Origin,
    ) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer self.rollbackWrite();
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
        const id = c.sqlite3_last_insert_rowid(self.handle);
        try self.insertRevisionLocked(id, now, origin, .create, "Created note");
        try self.execRaw("COMMIT;");
        return id;
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

    const NoteState = struct {
        version: i64,
        title: []const u8,
        body: []const u8,
        is_pinned: bool,
        deleted_at: ?i64,
        updated_at: i64,

        fn deinit(self: NoteState, allocator: Allocator) void {
            allocator.free(self.title);
            allocator.free(self.body);
        }
    };

    fn readNoteStateLocked(self: *Db, allocator: Allocator, id: i64) !?NoteState {
        var stmt = try self.prepare(
            "SELECT version, deleted_at, title, body, is_pinned, updated_at FROM notes WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        if (try stmt.step() != c.SQLITE_ROW) return null;
        const title = try self.columnText(&stmt, 2, allocator);
        errdefer allocator.free(title);
        const body = try self.columnText(&stmt, 3, allocator);
        return .{
            .version = c.sqlite3_column_int64(stmt.handle, 0),
            .deleted_at = if (c.sqlite3_column_type(stmt.handle, 1) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_int64(stmt.handle, 1),
            .title = title,
            .body = body,
            .is_pinned = c.sqlite3_column_int64(stmt.handle, 4) != 0,
            .updated_at = c.sqlite3_column_int64(stmt.handle, 5),
        };
    }

    fn rollbackWrite(self: *Db) void {
        _ = self.execRaw("ROLLBACK;") catch {};
    }

    /// Appends the current note state as an immutable revision. Must be called
    /// inside the same transaction as the note mutation it describes.
    fn insertRevisionLocked(
        self: *Db,
        note_id: i64,
        created_at: ?i64,
        origin: Origin,
        action: RevisionAction,
        summary: []const u8,
    ) !void {
        const allocator = self.allocator;
        const state = (try self.readNoteStateLocked(allocator, note_id)) orelse return error.Sqlite;
        defer state.deinit(allocator);

        const checksum = try noteChecksum(allocator, state.title, state.body);
        defer allocator.free(checksum);

        var number_stmt = try self.prepare(
            "SELECT COALESCE(MAX(revision_no), 0) + 1 FROM note_revisions WHERE note_id = ?",
        );
        defer number_stmt.deinit();
        try number_stmt.bindInt(1, note_id);
        if (try number_stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        const revision_no = c.sqlite3_column_int64(number_stmt.handle, 0);

        var insert = try self.prepare(
            \\INSERT INTO note_revisions(
            \\  note_id, revision_no, note_version, title, body, is_pinned,
            \\  deleted_at, created_at, origin, action, summary, checksum
            \\) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer insert.deinit();
        try insert.bindInt(1, note_id);
        try insert.bindInt(2, revision_no);
        try insert.bindInt(3, state.version);
        try insert.bindText(4, state.title);
        try insert.bindText(5, state.body);
        try insert.bindInt(6, if (state.is_pinned) 1 else 0);
        if (state.deleted_at) |stamp| try insert.bindInt(7, stamp) else try insert.bindNull(7);
        try insert.bindInt(8, created_at orelse state.updated_at);
        try insert.bindText(9, @tagName(origin));
        try insert.bindText(10, @tagName(action));
        try insert.bindText(11, summary);
        try insert.bindText(12, checksum);
        if (try insert.step() != c.SQLITE_DONE) return error.Sqlite;
        const revision_id = c.sqlite3_last_insert_rowid(self.handle);

        var asset_insert = try self.prepare(
            \\INSERT INTO revision_assets(revision_id, attachment_id, filename, mime, size, sha256)
            \\SELECT ?, id, filename, mime, size, sha256 FROM attachments
            \\WHERE note_id = ? AND deleted_at IS NULL
        );
        defer asset_insert.deinit();
        try asset_insert.bindInt(1, revision_id);
        try asset_insert.bindInt(2, note_id);
        if (try asset_insert.step() != c.SQLITE_DONE) return error.Sqlite;
    }

    pub fn updateNote(
        self: *Db,
        id: i64,
        expected_version: i64,
        title: []const u8,
        body: []const u8,
        now: i64,
    ) !WriteResult {
        return self.updateNoteFrom(id, expected_version, title, body, now, .web);
    }

    pub fn updateNoteFrom(
        self: *Db,
        id: i64,
        expected_version: i64,
        title: []const u8,
        body: []const u8,
        now: i64,
        origin: Origin,
    ) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer self.rollbackWrite();

        const state = (try self.readNoteStateLocked(self.allocator, id)) orelse {
            self.rollbackWrite();
            return .not_found;
        };
        defer state.deinit(self.allocator);
        if (state.deleted_at != null) {
            self.rollbackWrite();
            return .deleted;
        }
        if (state.version != expected_version) {
            self.rollbackWrite();
            return .conflict;
        }
        // No-op saves acknowledge without bumping the version or inventing history.
        if (std.mem.eql(u8, state.title, title) and std.mem.eql(u8, state.body, body)) {
            try self.execRaw("COMMIT;");
            return .ok;
        }

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
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) != 1) return error.Sqlite;

        try self.insertRevisionLocked(id, now, origin, .update, "Edited title or body");
        try self.execRaw("COMMIT;");
        return .ok;
    }

    pub fn togglePin(self: *Db, id: i64, expected_version: i64, now: i64) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer self.rollbackWrite();
        const state = (try self.readNoteStateLocked(self.allocator, id)) orelse {
            self.rollbackWrite();
            return .not_found;
        };
        const was_pinned = state.is_pinned;
        state.deinit(self.allocator);
        return self.setPinnedLocked(id, expected_version, !was_pinned, now, .web);
    }

    pub fn setPinned(self: *Db, id: i64, expected_version: i64, pinned: bool, now: i64) !WriteResult {
        return self.setPinnedFrom(id, expected_version, pinned, now, .web);
    }

    pub fn setPinnedFrom(
        self: *Db,
        id: i64,
        expected_version: i64,
        pinned: bool,
        now: i64,
        origin: Origin,
    ) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer self.rollbackWrite();
        return self.setPinnedLocked(id, expected_version, pinned, now, origin);
    }

    fn setPinnedLocked(
        self: *Db,
        id: i64,
        expected_version: i64,
        pinned: bool,
        now: i64,
        origin: Origin,
    ) !WriteResult {
        const state = (try self.readNoteStateLocked(self.allocator, id)) orelse {
            self.rollbackWrite();
            return .not_found;
        };
        defer state.deinit(self.allocator);
        if (state.deleted_at != null) {
            self.rollbackWrite();
            return .deleted;
        }
        if (state.version != expected_version) {
            self.rollbackWrite();
            return .conflict;
        }
        if (state.is_pinned == pinned) {
            try self.execRaw("COMMIT;");
            return .ok;
        }
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
        if (c.sqlite3_changes(self.handle) != 1) return error.Sqlite;
        try self.insertRevisionLocked(
            id,
            now,
            origin,
            if (pinned) .pin else .unpin,
            if (pinned) "Pinned note" else "Unpinned note",
        );
        try self.execRaw("COMMIT;");
        return .ok;
    }

    pub fn softDelete(self: *Db, id: i64, expected_version: i64, now: i64) !WriteResult {
        return self.softDeleteFrom(id, expected_version, now, .web);
    }

    pub fn softDeleteFrom(self: *Db, id: i64, expected_version: i64, now: i64, origin: Origin) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer self.rollbackWrite();
        const state = (try self.readNoteStateLocked(self.allocator, id)) orelse {
            self.rollbackWrite();
            return .not_found;
        };
        defer state.deinit(self.allocator);
        if (state.deleted_at != null) {
            self.rollbackWrite();
            return .deleted;
        }
        if (state.version != expected_version) {
            self.rollbackWrite();
            return .conflict;
        }
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
        if (c.sqlite3_changes(self.handle) != 1) return error.Sqlite;
        try self.insertRevisionLocked(id, now, origin, .delete, "Moved to Trash");
        try self.execRaw("COMMIT;");
        return .ok;
    }

    pub fn restore(self: *Db, id: i64, expected_version: i64, now: i64) !WriteResult {
        return self.restoreFrom(id, expected_version, now, .web);
    }

    pub fn restoreFrom(self: *Db, id: i64, expected_version: i64, now: i64, origin: Origin) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer self.rollbackWrite();
        const state = (try self.readNoteStateLocked(self.allocator, id)) orelse {
            self.rollbackWrite();
            return .not_found;
        };
        defer state.deinit(self.allocator);
        if (state.deleted_at == null) {
            self.rollbackWrite();
            return .conflict;
        }
        if (state.version != expected_version) {
            self.rollbackWrite();
            return .conflict;
        }
        var stmt = try self.prepare(
            \\UPDATE notes SET deleted_at = NULL, version = version + 1, updated_at = ?
            \\WHERE id = ? AND version = ? AND deleted_at IS NOT NULL
        );
        defer stmt.deinit();
        try stmt.bindInt(1, now);
        try stmt.bindInt(2, id);
        try stmt.bindInt(3, expected_version);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) != 1) return error.Sqlite;
        try self.insertRevisionLocked(id, now, origin, .restore, "Restored from Trash");
        try self.execRaw("COMMIT;");
        return .ok;
    }

    /// Restores an old revision as a new head revision. Historical rows are
    /// never rewritten.
    pub fn restoreRevision(
        self: *Db,
        allocator: Allocator,
        id: i64,
        expected_version: i64,
        revision_no: i64,
        now: i64,
        origin: Origin,
    ) !WriteResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer self.rollbackWrite();

        const state = (try self.readNoteStateLocked(allocator, id)) orelse {
            self.rollbackWrite();
            return .not_found;
        };
        defer state.deinit(allocator);
        if (state.deleted_at != null) {
            self.rollbackWrite();
            return .deleted;
        }
        if (state.version != expected_version) {
            self.rollbackWrite();
            return .conflict;
        }
        const revision = (try self.getRevisionLocked(allocator, id, revision_no)) orelse {
            self.rollbackWrite();
            return error.RevisionNotFound;
        };
        defer allocator.free(revision.title);
        defer allocator.free(revision.body);
        defer allocator.free(revision.summary);
        defer allocator.free(revision.checksum);

        var stmt = try self.prepare(
            \\UPDATE notes SET title = ?, body = ?, updated_at = ?, version = version + 1
            \\WHERE id = ? AND version = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, revision.title);
        try stmt.bindText(2, revision.body);
        try stmt.bindInt(3, now);
        try stmt.bindInt(4, id);
        try stmt.bindInt(5, expected_version);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        if (c.sqlite3_changes(self.handle) != 1) return error.Sqlite;

        // Restoring a snapshot brings back the files that snapshot referenced.
        // Bytes were never deleted, so this is a state change, not a copy.
        var resurrect = try self.prepare(
            \\UPDATE attachments SET deleted_at = NULL
            \\WHERE note_id = ? AND id IN (
            \\  SELECT attachment_id FROM revision_assets WHERE revision_id = ?
            \\)
        );
        defer resurrect.deinit();
        try resurrect.bindInt(1, id);
        try resurrect.bindInt(2, revision.id);
        if (try resurrect.step() != c.SQLITE_DONE) return error.Sqlite;

        var summary_buf: [64]u8 = undefined;
        const summary = try std.fmt.bufPrint(&summary_buf, "Restored revision {d}", .{revision_no});
        try self.insertRevisionLocked(id, now, origin, .restore_revision, summary);
        try self.execRaw("COMMIT;");
        return .ok;
    }

    fn revisionFromRowLocked(self: *Db, stmt: *Stmt, allocator: Allocator) !Revision {
        const origin_text = try self.columnText(stmt, 9, allocator);
        defer allocator.free(origin_text);
        const action_text = try self.columnText(stmt, 10, allocator);
        defer allocator.free(action_text);
        return .{
            .id = c.sqlite3_column_int64(stmt.handle, 0),
            .note_id = c.sqlite3_column_int64(stmt.handle, 1),
            .revision_no = c.sqlite3_column_int64(stmt.handle, 2),
            .note_version = c.sqlite3_column_int64(stmt.handle, 3),
            .title = try self.columnText(stmt, 4, allocator),
            .body = try self.columnText(stmt, 5, allocator),
            .is_pinned = c.sqlite3_column_int64(stmt.handle, 6) != 0,
            .deleted_at = if (c.sqlite3_column_type(stmt.handle, 7) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_int64(stmt.handle, 7),
            .created_at = c.sqlite3_column_int64(stmt.handle, 8),
            .origin = std.meta.stringToEnum(Origin, origin_text) orelse .system,
            .action = std.meta.stringToEnum(RevisionAction, action_text) orelse .update,
            .summary = try self.columnText(stmt, 11, allocator),
            .checksum = try self.columnText(stmt, 12, allocator),
            .label = try self.columnText(stmt, 13, allocator),
        };
    }

    fn getRevisionLocked(self: *Db, allocator: Allocator, id: i64, revision_no: i64) !?Revision {
        var stmt = try self.prepare(
            \\SELECT id, note_id, revision_no, note_version, title, body, is_pinned,
            \\       deleted_at, created_at, origin, action, summary, checksum, label
            \\FROM note_revisions WHERE note_id = ? AND revision_no = ?
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        try stmt.bindInt(2, revision_no);
        if (try stmt.step() != c.SQLITE_ROW) return null;
        return try self.revisionFromRowLocked(&stmt, allocator);
    }

    pub fn getRevision(self: *Db, allocator: Allocator, id: i64, revision_no: i64) !?Revision {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.getRevisionLocked(allocator, id, revision_no);
    }

    /// Snapshot content that the submitted form version was based on. State
    /// changes such as pin may advance note_version without changing text, so
    /// the latest content snapshot at or before the version is the correct base.
    pub fn revisionAtVersion(self: *Db, allocator: Allocator, id: i64, note_version: i64) !?Revision {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT id, note_id, revision_no, note_version, title, body, is_pinned,
            \\       deleted_at, created_at, origin, action, summary, checksum, label
            \\FROM note_revisions WHERE note_id = ? AND note_version <= ?
            \\ORDER BY note_version DESC, revision_no DESC LIMIT 1
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        try stmt.bindInt(2, note_version);
        if (try stmt.step() != c.SQLITE_ROW) return null;
        return try self.revisionFromRowLocked(&stmt, allocator);
    }

    pub fn listRevisions(
        self: *Db,
        allocator: Allocator,
        id: i64,
        offset: usize,
        limit: usize,
    ) ![]RevisionRow {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT revision_no, note_version, title, created_at, origin, action, summary, checksum, label
            \\FROM note_revisions WHERE note_id = ?
            \\ORDER BY revision_no DESC LIMIT ? OFFSET ?
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        try stmt.bindInt(2, @intCast(limit));
        try stmt.bindInt(3, @intCast(offset));
        var rows: std.ArrayList(RevisionRow) = .empty;
        errdefer rows.deinit(allocator);
        while (try stmt.step() == c.SQLITE_ROW) {
            const origin_text = try self.columnText(&stmt, 4, allocator);
            defer allocator.free(origin_text);
            const action_text = try self.columnText(&stmt, 5, allocator);
            defer allocator.free(action_text);
            try rows.append(allocator, .{
                .revision_no = c.sqlite3_column_int64(stmt.handle, 0),
                .note_version = c.sqlite3_column_int64(stmt.handle, 1),
                .title = try self.columnText(&stmt, 2, allocator),
                .created_at = c.sqlite3_column_int64(stmt.handle, 3),
                .origin = std.meta.stringToEnum(Origin, origin_text) orelse .system,
                .action = std.meta.stringToEnum(RevisionAction, action_text) orelse .update,
                .summary = try self.columnText(&stmt, 6, allocator),
                .checksum = try self.columnText(&stmt, 7, allocator),
                .label = try self.columnText(&stmt, 8, allocator),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    /// Labels are annotations on immutable revisions, not new revisions. The
    /// content checksum intentionally excludes the label.
    pub fn setRevisionLabel(self: *Db, id: i64, revision_no: i64, label: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            "UPDATE note_revisions SET label = ? WHERE note_id = ? AND revision_no = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, label);
        try stmt.bindInt(2, id);
        try stmt.bindInt(3, revision_no);
        if (try stmt.step() != c.SQLITE_DONE) return error.Sqlite;
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn countRevisions(self: *Db, id: i64) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT COUNT(*) FROM note_revisions WHERE note_id = ?");
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    pub fn latestRevisionNo(self: *Db, id: i64) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT COALESCE(MAX(revision_no), 0) FROM note_revisions WHERE note_id = ?");
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    /// First revision still available for a note. Returns 1 when nothing has
    /// been purged, including for notes without a retention row.
    pub fn historyFloor(self: *Db, id: i64) !i64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare("SELECT floor_revision FROM note_history_retention WHERE note_id = ?");
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        if (try stmt.step() != c.SQLITE_ROW) return 1;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    pub fn revisionAssets(
        self: *Db,
        allocator: Allocator,
        id: i64,
        revision_no: i64,
    ) ![]RevisionAsset {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT a.attachment_id, a.filename, a.mime, a.size, a.sha256
            \\FROM revision_assets a JOIN note_revisions r ON r.id = a.revision_id
            \\WHERE r.note_id = ? AND r.revision_no = ? ORDER BY a.attachment_id
        );
        defer stmt.deinit();
        try stmt.bindInt(1, id);
        try stmt.bindInt(2, revision_no);
        var rows: std.ArrayList(RevisionAsset) = .empty;
        errdefer rows.deinit(allocator);
        while (try stmt.step() == c.SQLITE_ROW) {
            try rows.append(allocator, .{
                .attachment_id = c.sqlite3_column_int64(stmt.handle, 0),
                .filename = try self.columnText(&stmt, 1, allocator),
                .mime = try self.columnText(&stmt, 2, allocator),
                .size = c.sqlite3_column_int64(stmt.handle, 3),
                .sha256 = try self.columnText(&stmt, 4, allocator),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn revisionHasAsset(self: *Db, note_id: i64, revision_no: i64, attachment_id: i64) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = try self.prepare(
            \\SELECT 1 FROM revision_assets a JOIN note_revisions r ON r.id = a.revision_id
            \\WHERE r.note_id = ? AND r.revision_no = ? AND a.attachment_id = ? LIMIT 1
        );
        defer stmt.deinit();
        try stmt.bindInt(1, note_id);
        try stmt.bindInt(2, revision_no);
        try stmt.bindInt(3, attachment_id);
        return (try stmt.step()) == c.SQLITE_ROW;
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
        var stmt = try self.prepare("SELECT COUNT(*) FROM attachments WHERE deleted_at IS NULL");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    fn scalarLocked(self: *Db, sql: [:0]const u8) !i64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    fn scalarOneParamLocked(self: *Db, sql: [:0]const u8, a: i64) !i64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.bindInt(1, a);
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    fn scalarTwoParamLocked(self: *Db, sql: [:0]const u8, a: i64, b: i64) !i64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.bindInt(1, a);
        try stmt.bindInt(2, b);
        if (try stmt.step() != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }

    pub const PurgeOptions = struct {
        /// Newest revisions kept per note regardless of age/labels.
        keep_last: usize,
        /// 0 disables the age test; otherwise only revisions older than this
        /// many days may be removed.
        older_than_days: u32 = 0,
        /// False performs a dry run in a transaction and rolls it back.
        apply: bool = false,
    };

    pub const PurgeResult = struct {
        notes_scanned: usize = 0,
        revisions_removed: i64 = 0,
        labelled_protected: i64 = 0,
        floors_updated: usize = 0,
        verified: bool = false,
        applied: bool = false,
    };

    /// Explicit prefix retention. Per note, keep the newest `keep_last`
    /// revisions, every labelled revision, and every revision newer than the
    /// age cutoff. Only the contiguous unlabelled prefix older than all of
    /// those is removed, so revision numbers stay contiguous above a recorded
    /// floor. Never runs automatically; `apply=false` rolls back after
    /// verification.
    pub fn purgeHistory(self: *Db, now: i64, options: PurgeOptions) !PurgeResult {
        if (options.keep_last < 1) return error.InvalidRetentionPolicy;
        const keep_last: i64 = @intCast(options.keep_last);
        const cutoff = now - @as(i64, @intCast(options.older_than_days)) * std.time.s_per_day;

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.execRaw("BEGIN IMMEDIATE;");
        errdefer _ = self.execRaw("ROLLBACK;") catch {};
        var result = PurgeResult{};
        const labelled_before = try self.scalarLocked("SELECT COUNT(*) FROM note_revisions WHERE label <> ''");
        result.labelled_protected = labelled_before;

        var note_ids: std.ArrayList(i64) = .empty;
        defer note_ids.deinit(self.allocator);
        {
            var stmt = try self.prepare("SELECT id FROM notes ORDER BY id");
            defer stmt.deinit();
            while (try stmt.step() == c.SQLITE_ROW) {
                try note_ids.append(self.allocator, c.sqlite3_column_int64(stmt.handle, 0));
            }
        }

        for (note_ids.items) |note_id| {
            result.notes_scanned += 1;
            const total = try self.scalarOneParamLocked(
                "SELECT COUNT(*) FROM note_revisions WHERE note_id = ?",
                note_id,
            );
            if (total == 0) continue;
            const oldest = try self.scalarOneParamLocked(
                "SELECT MIN(revision_no) FROM note_revisions WHERE note_id = ?",
                note_id,
            );
            const newest_keep = try self.scalarTwoParamLocked(
                \\SELECT MIN(revision_no) FROM (
                \\  SELECT revision_no FROM note_revisions WHERE note_id = ?
                \\  ORDER BY revision_no DESC LIMIT ?
                \\)
            , note_id, keep_last);
            var floor = newest_keep;
            const first_label = try self.scalarOneParamLocked(
                "SELECT COALESCE(MIN(revision_no), 0) FROM note_revisions WHERE note_id = ? AND label <> ''",
                note_id,
            );
            if (first_label > 0 and first_label < floor) floor = first_label;
            if (options.older_than_days > 0) {
                const first_too_young = try self.scalarTwoParamLocked(
                    \\SELECT COALESCE(MIN(revision_no), 0) FROM note_revisions
                    \\WHERE note_id = ? AND label = '' AND created_at >= ?
                , note_id, cutoff);
                if (first_too_young > 0 and first_too_young < floor) floor = first_too_young;
            }
            if (floor <= oldest) continue;

            const removed: i64 = blk: {
                var del = try self.prepare(
                    "DELETE FROM note_revisions WHERE note_id = ? AND revision_no < ? AND label = ''",
                );
                defer del.deinit();
                try del.bindInt(1, note_id);
                try del.bindInt(2, floor);
                if (try del.step() != c.SQLITE_DONE) return error.Sqlite;
                break :blk @intCast(c.sqlite3_changes(self.handle));
            };
            if (removed == 0) continue;

            {
                var upsert = try self.prepare(
                    \\INSERT INTO note_history_retention(note_id, floor_revision, purged_at, purged_count)
                    \\VALUES(?, ?, ?, ?)
                    \\ON CONFLICT(note_id) DO UPDATE SET
                    \\  floor_revision = excluded.floor_revision,
                    \\  purged_at = excluded.purged_at,
                    \\  purged_count = note_history_retention.purged_count + excluded.purged_count
                );
                defer upsert.deinit();
                try upsert.bindInt(1, note_id);
                try upsert.bindInt(2, floor);
                try upsert.bindInt(3, now);
                try upsert.bindInt(4, removed);
                if (try upsert.step() != c.SQLITE_DONE) return error.Sqlite;
            }

            result.revisions_removed += removed;
            result.floors_updated += 1;
        }

        result.verified = try self.verifyRetentionLocked(labelled_before);
        if (options.apply and result.verified) {
            try self.execRaw("COMMIT;");
            result.applied = true;
        } else {
            try self.execRaw("ROLLBACK;");
        }
        return result;
    }

    fn verifyRetentionLocked(self: *Db, labelled_before: i64) !bool {
        var ok = true;
        const labelled_after = try self.scalarLocked("SELECT COUNT(*) FROM note_revisions WHERE label <> ''");
        ok = ok and labelled_after == labelled_before;

        const missing_history = try self.scalarLocked(
            "SELECT COUNT(*) FROM notes n WHERE NOT EXISTS (SELECT 1 FROM note_revisions r WHERE r.note_id = n.id)",
        );
        ok = ok and missing_history == 0;

        const broken_chains = try self.scalarLocked(
            \\SELECT COUNT(*) FROM (
            \\  SELECT r.note_id AS note_id, MIN(r.revision_no) AS lo, MAX(r.revision_no) AS hi, COUNT(*) AS n
            \\  FROM note_revisions r GROUP BY r.note_id
            \\) c LEFT JOIN note_history_retention h ON h.note_id = c.note_id
            \\WHERE c.lo <> COALESCE(h.floor_revision, 1) OR c.hi <> c.lo + c.n - 1
        );
        ok = ok and broken_chains == 0;

        const bad_floors = try self.scalarLocked(
            \\SELECT COUNT(*) FROM note_history_retention h
            \\LEFT JOIN note_revisions lo ON lo.note_id = h.note_id AND lo.revision_no = h.floor_revision
            \\LEFT JOIN (
            \\  SELECT note_id, MAX(revision_no) AS hi FROM note_revisions GROUP BY note_id
            \\) x ON x.note_id = h.note_id
            \\WHERE h.floor_revision <= 1 OR lo.id IS NULL OR h.floor_revision > x.hi
        );
        ok = ok and bad_floors == 0;

        const orphan_assets = try self.scalarLocked(
            "SELECT COUNT(*) FROM revision_assets a LEFT JOIN attachments t ON t.id = a.attachment_id WHERE t.id IS NULL",
        );
        ok = ok and orphan_assets == 0;

        var integrity = try self.prepare("PRAGMA integrity_check");
        defer integrity.deinit();
        const integrity_ok = if (try integrity.step() == c.SQLITE_ROW) blk: {
            const text = c.sqlite3_column_text(integrity.handle, 0);
            break :blk text != null and std.mem.eql(u8, std.mem.span(text), "ok");
        } else false;
        return ok and integrity_ok;
    }

    /// Read-only whole-database verification. Returns false if any check fails;
    /// the writer receives one PASS/FAIL line per invariant.
    pub fn diagnose(self: *Db, writer: *std.Io.Writer) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var ok = true;

        try writer.writeAll("FeatherNote database doctor\n");
        const schema_version = try self.schemaVersion();
        try writer.print("schema version: {d}\n", .{schema_version});
        try reportCheck(writer, &ok, schema_version >= 1 and schema_version <= 6, "schema version is supported");

        var integrity = try self.prepare("PRAGMA integrity_check");
        const integrity_ok = blk: {
            defer integrity.deinit();
            if (try integrity.step() != c.SQLITE_ROW) break :blk false;
            const text = c.sqlite3_column_text(integrity.handle, 0);
            break :blk text != null and std.mem.eql(u8, std.mem.span(text), "ok");
        };
        try reportCheck(writer, &ok, integrity_ok, "SQLite integrity_check");

        var foreign_keys = try self.prepare("PRAGMA foreign_key_check");
        const fk_ok = blk: {
            defer foreign_keys.deinit();
            break :blk (try foreign_keys.step()) != c.SQLITE_ROW;
        };
        try reportCheck(writer, &ok, fk_ok, "foreign_key_check has no violations");

        const notes = try self.scalarLocked("SELECT COUNT(*) FROM notes");
        const fts_rows = try self.scalarLocked("SELECT COUNT(*) FROM notes_fts");
        try writer.print("notes: {d}, fts rows: {d}\n", .{ notes, fts_rows });
        try reportCheck(writer, &ok, notes == fts_rows, "FTS row count matches notes");

        const missing_history = try self.scalarLocked(
            "SELECT COUNT(*) FROM notes n WHERE NOT EXISTS (SELECT 1 FROM note_revisions r WHERE r.note_id = n.id)",
        );
        try writer.print("notes without revisions: {d}\n", .{missing_history});
        try reportCheck(writer, &ok, missing_history == 0, "every note has a revision chain");

        const broken_chains = if (schema_version >= 6)
            try self.scalarLocked(
                \\SELECT COUNT(*) FROM (
                \\  SELECT r.note_id AS note_id, MIN(r.revision_no) AS lo, MAX(r.revision_no) AS hi, COUNT(*) AS n
                \\  FROM note_revisions r GROUP BY r.note_id
                \\) c LEFT JOIN note_history_retention h ON h.note_id = c.note_id
                \\WHERE c.lo <> COALESCE(h.floor_revision, 1) OR c.hi <> c.lo + c.n - 1
            )
        else
            try self.scalarLocked(
                \\SELECT COUNT(*) FROM (
                \\  SELECT note_id FROM note_revisions GROUP BY note_id
                \\  HAVING MIN(revision_no) <> 1 OR MAX(revision_no) <> COUNT(*) OR COUNT(*) <> MAX(revision_no)
                \\)
            );
        try writer.print("broken revision chains: {d}\n", .{broken_chains});
        try reportCheck(writer, &ok, broken_chains == 0, "revision numbers are contiguous above any retention floor");

        var checksum_stmt = try self.prepare("SELECT title, body, checksum FROM note_revisions");
        var checksum_mismatches: i64 = 0;
        {
            defer checksum_stmt.deinit();
            while (try checksum_stmt.step() == c.SQLITE_ROW) {
                const title = try self.columnText(&checksum_stmt, 0, self.allocator);
                defer self.allocator.free(title);
                const body = try self.columnText(&checksum_stmt, 1, self.allocator);
                defer self.allocator.free(body);
                const stored = try self.columnText(&checksum_stmt, 2, self.allocator);
                defer self.allocator.free(stored);
                const computed = try noteChecksum(self.allocator, title, body);
                defer self.allocator.free(computed);
                if (!std.mem.eql(u8, stored, computed)) checksum_mismatches += 1;
            }
        }
        try writer.print("revision checksum mismatches: {d}\n", .{checksum_mismatches});
        try reportCheck(writer, &ok, checksum_mismatches == 0, "revision checksums match content");

        const head_mismatches = try self.scalarLocked(
            \\SELECT COUNT(*) FROM notes n JOIN (
            \\  SELECT r.* FROM note_revisions r JOIN (
            \\    SELECT note_id, MAX(revision_no) AS m FROM note_revisions GROUP BY note_id
            \\  ) x ON x.note_id = r.note_id AND x.m = r.revision_no
            \\) h ON h.note_id = n.id
            \\WHERE n.title <> h.title OR n.body <> h.body OR n.version <> h.note_version
            \\   OR n.is_pinned <> h.is_pinned OR n.deleted_at IS NOT h.deleted_at
        );
        try writer.print("current-state/head mismatches: {d}\n", .{head_mismatches});
        try reportCheck(writer, &ok, head_mismatches == 0, "current notes match their head revisions");

        const orphan_assets = try self.scalarLocked(
            "SELECT COUNT(*) FROM revision_assets a LEFT JOIN attachments t ON t.id = a.attachment_id WHERE t.id IS NULL",
        );
        try writer.print("revision assets without attachment bytes: {d}\n", .{orphan_assets});
        try reportCheck(writer, &ok, orphan_assets == 0, "revision asset manifests resolve");

        const orphan_attachments = try self.scalarLocked(
            "SELECT COUNT(*) FROM attachments a LEFT JOIN notes n ON n.id = a.note_id WHERE n.id IS NULL",
        );
        try writer.print("attachments without notes: {d}\n", .{orphan_attachments});
        try reportCheck(writer, &ok, orphan_attachments == 0, "attachments belong to existing notes");

        const bad_blobs = try self.scalarLocked(
            "SELECT COUNT(*) FROM attachments WHERE size <> length(data) OR length(sha256) <> 64",
        );
        try writer.print("attachments with size/hash shape mismatch: {d}\n", .{bad_blobs});
        try reportCheck(writer, &ok, bad_blobs == 0, "attachment size and hash shape");

        var blob_stmt = try self.prepare("SELECT size, sha256, data FROM attachments");
        var blob_hash_mismatches: i64 = 0;
        {
            defer blob_stmt.deinit();
            while (try blob_stmt.step() == c.SQLITE_ROW) {
                const size = c.sqlite3_column_int64(blob_stmt.handle, 0);
                const stored = try self.columnText(&blob_stmt, 1, self.allocator);
                defer self.allocator.free(stored);
                const data = try self.columnBlob(&blob_stmt, 2, self.allocator);
                defer self.allocator.free(data);
                const computed = try blobChecksum(self.allocator, data);
                defer self.allocator.free(computed);
                if (size != @as(i64, @intCast(data.len)) or stored.len != 64 or !std.mem.eql(u8, stored, computed)) {
                    blob_hash_mismatches += 1;
                }
            }
        }
        try writer.print("attachment blob hash mismatches: {d}\n", .{blob_hash_mismatches});
        try reportCheck(writer, &ok, blob_hash_mismatches == 0, "attachment bytes match their SHA-256");

        const bad_labels = try self.scalarLocked("SELECT COUNT(*) FROM note_revisions WHERE length(label) > 80");
        try reportCheck(writer, &ok, bad_labels == 0, "checkpoint labels are within bounds");

        if (schema_version >= 6) {
            const bad_floors = try self.scalarLocked(
                \\SELECT COUNT(*) FROM note_history_retention h
                \\LEFT JOIN note_revisions lo ON lo.note_id = h.note_id AND lo.revision_no = h.floor_revision
                \\LEFT JOIN (
                \\  SELECT note_id, MAX(revision_no) AS hi FROM note_revisions GROUP BY note_id
                \\) x ON x.note_id = h.note_id
                \\WHERE h.floor_revision <= 1 OR lo.id IS NULL OR h.floor_revision > x.hi
            );
            try writer.print("invalid retention floors: {d}\n", .{bad_floors});
            try reportCheck(writer, &ok, bad_floors == 0, "retention floors point at a kept revision");
        }

        return ok;
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

/// Content hash for revision integrity checks. Length prefixes keep title and
/// body unambiguous without copying the note body.
fn noteChecksum(allocator: Allocator, title: []const u8, body: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var length_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &length_buf, title.len, .little);
    hasher.update(&length_buf);
    hasher.update(title);
    std.mem.writeInt(u64, &length_buf, body.len, .little);
    hasher.update(&length_buf);
    hasher.update(body);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn blobChecksum(allocator: Allocator, data: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn reportCheck(writer: *std.Io.Writer, ok: *bool, passed: bool, label: []const u8) !void {
    if (!passed) ok.* = false;
    try writer.print("{s} {s}\n", .{ if (passed) "PASS" else "FAIL", label });
}

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

test "revision engine: immutable snapshots, no-op, conflict and restore" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "rev.db" });
    defer testing.allocator.free(db_path);

    const db = try Db.open(testing.allocator, io, db_path);
    defer db.close(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = try db.createNoteFrom(arena, "Original", "alpha\nbeta", 1000, .web);
    try testing.expectEqual(@as(i64, 1), try db.countRevisions(id));
    const first = (try db.getRevision(arena, id, 1)).?;
    try testing.expectEqualStrings("alpha\nbeta", first.body);
    try testing.expectEqual(Origin.web, first.origin);
    try testing.expectEqual(RevisionAction.create, first.action);
    try testing.expectEqual(@as(usize, 64), first.checksum.len);
    try testing.expect(try db.setRevisionLabel(id, 1, "original draft"));
    const labelled = (try db.getRevision(arena, id, 1)).?;
    try testing.expectEqualStrings("original draft", labelled.label);
    const labelled_rows = try db.listRevisions(arena, id, 0, 10);
    try testing.expectEqualStrings("original draft", labelled_rows[0].label);
    try testing.expect(try db.setRevisionLabel(id, 1, ""));
    try testing.expectEqualStrings("", (try db.getRevision(arena, id, 1)).?.label);

    // A no-op save does not bump the version or invent a revision.
    try testing.expectEqual(WriteResult.ok, try db.updateNoteFrom(id, 1, "Original", "alpha\nbeta", 1001, .mcp));
    try testing.expectEqual(@as(i64, 1), (try db.getNote(arena, id, false)).?.version);
    try testing.expectEqual(@as(i64, 1), try db.countRevisions(id));

    // Meaningful edit is append-only and records MCP provenance.
    try testing.expectEqual(WriteResult.ok, try db.updateNoteFrom(id, 1, "Edited", "alpha\ngamma", 1002, .mcp));
    try testing.expectEqual(@as(i64, 2), try db.countRevisions(id));
    const second = (try db.getRevision(arena, id, 2)).?;
    try testing.expectEqualStrings("alpha\ngamma", second.body);
    try testing.expectEqual(Origin.mcp, second.origin);
    try testing.expect(!std.mem.eql(u8, first.checksum, second.checksum));
    const base_at_v1 = (try db.revisionAtVersion(arena, id, 1)).?;
    try testing.expectEqual(@as(i64, 1), base_at_v1.revision_no);
    try testing.expectEqualStrings("alpha\nbeta", base_at_v1.body);

    // A stale write returns conflict and appends nothing.
    try testing.expectEqual(WriteResult.conflict, try db.updateNoteFrom(id, 1, "Stale", "nope", 1003, .web));
    try testing.expectEqual(@as(i64, 2), try db.countRevisions(id));

    // Pin and delete are versioned events too.
    try testing.expectEqual(WriteResult.ok, try db.setPinnedFrom(id, 2, true, 1004, .mcp));
    try testing.expectEqual(@as(i64, 3), try db.countRevisions(id));
    try testing.expectEqual(WriteResult.ok, try db.softDeleteFrom(id, 3, 1005, .mcp));
    try testing.expectEqual(@as(i64, 4), try db.countRevisions(id));
    try testing.expectEqual(WriteResult.ok, try db.restoreFrom(id, 4, 1006, .mcp));
    try testing.expectEqual(@as(i64, 5), try db.countRevisions(id));

    // Restore revision 1 as revision 6; revision 1 stays byte-identical.
    try testing.expectEqual(WriteResult.ok, try db.restoreRevision(arena, id, 5, 1, 1007, .web));
    try testing.expectEqual(@as(i64, 6), try db.countRevisions(id));
    try testing.expectEqual(@as(i64, 6), (try db.getNote(arena, id, false)).?.version);
    try testing.expectEqualStrings("alpha\nbeta", (try db.getNote(arena, id, false)).?.body);
    try testing.expectEqualStrings("alpha\nbeta", (try db.getRevision(arena, id, 1)).?.body);
    const restored = (try db.getRevision(arena, id, 6)).?;
    try testing.expectEqual(RevisionAction.restore_revision, restored.action);

    // Historical attachment manifests survive soft deletion of the file.
    const attachment_id = try db.insertAttachment(.{
        .note_id = id,
        .filename = "diagram.png",
        .mime = "image/png",
        .sha256 = &"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*,
        .data = "png-bytes",
    }, 1008);
    try testing.expectEqual(WriteResult.ok, try db.updateNoteFrom(id, 6, "With file", "alpha\nbeta\n![x](/files/1/diagram.png)", 1009, .web));
    const asset_rows = try db.revisionAssets(arena, id, 7);
    try testing.expectEqual(@as(usize, 1), asset_rows.len);
    try testing.expectEqual(attachment_id, asset_rows[0].attachment_id);
    try testing.expect(try db.deleteAttachment(attachment_id, id));
    try testing.expectEqual(@as(usize, 1), (try db.revisionAssets(arena, id, 7)).len);
    try testing.expect((try db.attachment(arena, attachment_id)) != null);
    try testing.expectEqual(@as(usize, 0), (try db.attachmentsForNote(arena, id)).len);

    // Restoring the revision that referenced the file brings it back.
    try testing.expectEqual(WriteResult.ok, try db.restoreRevision(arena, id, 7, 7, 1010, .web));
    try testing.expectEqual(@as(usize, 1), (try db.attachmentsForNote(arena, id)).len);
    try testing.expectEqual(@as(usize, 1), (try db.revisionAssets(arena, id, 8)).len);

    try testing.expect(try db.integrityCheck());
}

test "v4 migration seeds one baseline revision without fabricating history" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "upgrade.db" });
    defer testing.allocator.free(db_path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try Db.open(testing.allocator, io, db_path);
    const id = try db.createNoteFrom(arena, "Pre-v4 note", "old body", 2000, .web);
    // Simulate a database that predates the revision migration.
    try db.execRaw("DROP INDEX attachments_live;");
    try db.execRaw("ALTER TABLE attachments DROP COLUMN deleted_at;");
    try db.execRaw("DROP TABLE revision_assets;");
    try db.execRaw("DROP TABLE note_revisions;");
    try db.execRaw("DROP TABLE note_history_retention;");
    try db.execRaw("UPDATE schema_meta SET version = 3;");
    db.close(testing.allocator);

    db = try Db.open(testing.allocator, io, db_path);
    defer db.close(testing.allocator);
    try testing.expectEqual(@as(i64, 6), try db.schemaVersion());
    try testing.expectEqual(@as(i64, 1), try db.countRevisions(id));
    const baseline = (try db.getRevision(arena, id, 1)).?;
    try testing.expectEqual(RevisionAction.baseline, baseline.action);
    try testing.expectEqual(Origin.system, baseline.origin);
    try testing.expectEqualStrings("old body", baseline.body);
    try testing.expectEqual(@as(i64, 2000), baseline.created_at);
}

test "retention purge keeps labels, heads and a verified floor" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "retention.db" });
    defer testing.allocator.free(db_path);

    const database = try Db.open(testing.allocator, io, db_path);
    defer database.close(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = try database.createNoteFrom(arena, "v1", "body 1", 1000, .web);
    for (2..11) |version| {
        try testing.expectEqual(WriteResult.ok, try database.updateNoteFrom(
            id,
            @intCast(version - 1),
            try std.fmt.allocPrint(arena, "v{d}", .{version}),
            try std.fmt.allocPrint(arena, "body {d}", .{version}),
            1000 + @as(i64, @intCast(version)),
            .web,
        ));
    }
    try testing.expect(try database.setRevisionLabel(id, 6, "keep me"));
    try testing.expectEqual(@as(i64, 10), try database.countRevisions(id));

    // Dry run proves the plan but commits nothing.
    const dry = try database.purgeHistory(2000, .{ .keep_last = 2 });
    try testing.expectEqual(@as(i64, 5), dry.revisions_removed);
    try testing.expect(dry.verified);
    try testing.expect(!dry.applied);
    try testing.expectEqual(@as(i64, 10), try database.countRevisions(id));
    try testing.expectEqual(@as(i64, 1), try database.historyFloor(id));

    // Labels pin the floor: r6 is kept even though only two newest are wanted.
    const applied = try database.purgeHistory(2000, .{ .keep_last = 2, .apply = true });
    try testing.expectEqual(@as(i64, 5), applied.revisions_removed);
    try testing.expect(applied.verified and applied.applied);
    try testing.expectEqual(@as(i64, 5), try database.countRevisions(id));
    try testing.expectEqual(@as(i64, 6), try database.historyFloor(id));
    try testing.expect((try database.getRevision(arena, id, 6)) != null);
    try testing.expectEqualStrings("keep me", (try database.getRevision(arena, id, 6)).?.label);
    try testing.expect((try database.getRevision(arena, id, 1)) == null);
    try testing.expectEqual(@as(i64, 10), (try database.getNote(arena, id, false)).?.version);

    // A second pass cannot move the floor past the labelled checkpoint.
    const again = try database.purgeHistory(2001, .{ .keep_last = 1, .apply = true });
    try testing.expectEqual(@as(i64, 0), again.revisions_removed);
    try testing.expectEqual(@as(i64, 6), try database.historyFloor(id));

    var doctor = std.Io.Writer.Allocating.init(testing.allocator);
    defer doctor.deinit();
    try testing.expect(try database.diagnose(&doctor.writer));
    try testing.expect(std.mem.find(u8, doctor.written(), "PASS retention floors point at a kept revision") != null);
}

test "retention age policy keeps young revisions" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "retention-age.db" });
    defer testing.allocator.free(db_path);

    const database = try Db.open(testing.allocator, io, db_path);
    defer database.close(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now: i64 = 100 * std.time.s_per_day;
    const id = try database.createNoteFrom(arena, "old", "old", now - 20 * std.time.s_per_day, .web);
    _ = try database.updateNoteFrom(id, 1, "recent", "recent", now - 2 * std.time.s_per_day, .web);
    _ = try database.updateNoteFrom(id, 2, "head", "head", now, .web);

    const result = try database.purgeHistory(now, .{
        .keep_last = 1,
        .older_than_days = 5,
        .apply = true,
    });
    try testing.expectEqual(@as(i64, 1), result.revisions_removed);
    try testing.expect(result.verified);
    try testing.expectEqual(@as(i64, 2), try database.historyFloor(id));
    try testing.expectEqual(@as(i64, 2), try database.countRevisions(id));
    try testing.expectEqualStrings("recent", (try database.getRevision(arena, id, 2)).?.body);
}

test "database doctor accepts healthy history and rejects a bad checksum" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "doctor.db" });
    defer testing.allocator.free(db_path);

    const database = try Db.open(testing.allocator, io, db_path);
    defer database.close(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = try database.createNoteFrom(arena, "Doctor note", "body", 3000, .web);
    _ = try database.updateNoteFrom(id, 1, "Doctor note v2", "body two", 3001, .mcp);
    _ = try database.setRevisionLabel(id, 2, "checkpoint");

    var healthy = std.Io.Writer.Allocating.init(testing.allocator);
    defer healthy.deinit();
    try testing.expect(try database.diagnose(&healthy.writer));
    try testing.expect(std.mem.find(u8, healthy.written(), "PASS revision checksums match content") != null);

    try database.execRaw(
        "UPDATE note_revisions SET checksum = '0000000000000000000000000000000000000000000000000000000000000000'",
    );
    var broken = std.Io.Writer.Allocating.init(testing.allocator);
    defer broken.deinit();
    try testing.expect(!try database.diagnose(&broken.writer));
    try testing.expect(std.mem.find(u8, broken.written(), "FAIL revision checksums match content") != null);
}

test "doctor detects attachment bytes that no longer match their hash" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "blob-hash.db" });
    defer testing.allocator.free(db_path);

    const database = try Db.open(testing.allocator, io, db_path);
    defer database.close(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = try database.createNoteFrom(arena, "Blob note", "body", 4000, .web);
    const data = "png-bytes";
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    _ = try database.insertAttachment(.{
        .note_id = id,
        .filename = "image.png",
        .mime = "image/png",
        .sha256 = &hex,
        .data = data,
    }, 4001);

    var healthy = std.Io.Writer.Allocating.init(testing.allocator);
    defer healthy.deinit();
    try testing.expect(try database.diagnose(&healthy.writer));
    try testing.expect(std.mem.find(u8, healthy.written(), "PASS attachment bytes match their SHA-256") != null);

    try database.execRaw("UPDATE attachments SET data = 'bad-bytes'");
    var broken = std.Io.Writer.Allocating.init(testing.allocator);
    defer broken.deinit();
    try testing.expect(!try database.diagnose(&broken.writer));
    try testing.expect(std.mem.find(u8, broken.written(), "FAIL attachment bytes match their SHA-256") != null);
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
