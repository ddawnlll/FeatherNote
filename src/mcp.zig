//! Local stdio MCP server for FeatherNote.
//!
//! Protocol: JSON-RPC 2.0, one JSON object per line on stdin/stdout, as
//! specified by the Model Context Protocol stdio transport. Diagnostics go to
//! stderr only; stdout carries protocol messages and nothing else.
const std = @import("std");
const db = @import("db.zig");
const util = @import("http_util.zig");
const themes = @import("themes.zig");
const media = @import("media.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Object = std.json.ObjectMap;

pub const protocol_versions = [_][]const u8{
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

const latest_protocol = protocol_versions[0];
const server_version = "1.0.0";
const max_message_bytes = 12 * 1024 * 1024;
const default_limit = 20;
const max_limit = 100;

const instructions =
    \\FeatherNote is a single-owner Markdown notebook. Tools read and write notes in the local SQLite database.
    \\Read tools are always available. Write tools appear only when the server was started with --allow-write.
    \\Updates require the version returned by a read. A stale version returns a conflict with the latest note, never a silent overwrite.
    \\Note bodies are Markdown. Attachment tools exchange base64 and are capped at 8 MiB.
;

pub const Options = struct {
    db_path: []const u8,
    allow_write: bool,
};

const App = struct {
    database: *db.Db,
    io: Io,
    allow_write: bool,
};

const ToolResult = struct {
    payload: []const u8,
    is_error: bool = false,
};

const Tool = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    schema: []const u8,
    write: bool,
    destructive: bool = false,
    idempotent: bool = true,
};

const tools = [_]Tool{
    .{
        .name = "list_notes",
        .title = "List notes",
        .description = "List active notes, pinned first and then most recently updated.",
        .schema =
        \\{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100,"default":20},"offset":{"type":"integer","minimum":0,"default":0}},"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "search_notes",
        .title = "Search notes",
        .description = "Full-text search across note titles and bodies with FTS5. Returns highlighted snippets.",
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":100},"limit":{"type":"integer","minimum":1,"maximum":100,"default":20},"offset":{"type":"integer","minimum":0,"default":0}},"required":["query"],"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "get_note",
        .title = "Get note",
        .description = "Read one note by id, including its Markdown body, version, timestamps, and attachment metadata.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":1},"include_trash":{"type":"boolean","default":false}},"required":["id"],"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "list_trash",
        .title = "List trash",
        .description = "List soft-deleted notes that can still be restored.",
        .schema =
        \\{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100,"default":20},"offset":{"type":"integer","minimum":0,"default":0}},"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "list_attachments",
        .title = "List attachments",
        .description = "List attachment metadata for a note without returning file contents.",
        .schema =
        \\{"type":"object","properties":{"note_id":{"type":"integer","minimum":1}},"required":["note_id"],"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "get_attachment",
        .title = "Get attachment",
        .description = "Read one attachment as base64 together with its filename, MIME type, size, and SHA-256.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":1}},"required":["id"],"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "get_library_stats",
        .title = "Library stats",
        .description = "Return note, trash, and attachment counts plus the current theme and SQLite version.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "get_theme",
        .title = "Get theme",
        .description = "Return the current theme id, display name, and mode.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
        .write = false,
    },
    .{
        .name = "create_note",
        .title = "Create note",
        .description = "Create a new Markdown note. Returns the stored note with its version.",
        .schema =
        \\{"type":"object","properties":{"title":{"type":"string","maxLength":200},"body":{"type":"string","maxLength":262144}},"required":["title","body"],"additionalProperties":false}
        ,
        .write = true,
        .idempotent = false,
    },
    .{
        .name = "update_note",
        .title = "Update note",
        .description = "Replace a note's title and Markdown body. Requires the current version and refuses stale writes.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":1},"version":{"type":"integer","minimum":1},"title":{"type":"string","maxLength":200},"body":{"type":"string","maxLength":262144}},"required":["id","version","title","body"],"additionalProperties":false}
        ,
        .write = true,
        .idempotent = false,
    },
    .{
        .name = "append_note",
        .title = "Append to note",
        .description = "Append Markdown to the end of a note, separated by a blank line. Requires the current version.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":1},"version":{"type":"integer","minimum":1},"text":{"type":"string","maxLength":65536}},"required":["id","version","text"],"additionalProperties":false}
        ,
        .write = true,
        .idempotent = false,
    },
    .{
        .name = "set_pinned",
        .title = "Set pinned",
        .description = "Pin or unpin a note. Requires the current version.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":1},"version":{"type":"integer","minimum":1},"pinned":{"type":"boolean"}},"required":["id","version","pinned"],"additionalProperties":false}
        ,
        .write = true,
        .idempotent = false,
    },
    .{
        .name = "delete_note",
        .title = "Delete note",
        .description = "Move a note to Trash. Requires the current version. Recoverable with restore_note.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":1},"version":{"type":"integer","minimum":1}},"required":["id","version"],"additionalProperties":false}
        ,
        .write = true,
        .destructive = true,
        .idempotent = false,
    },
    .{
        .name = "restore_note",
        .title = "Restore note",
        .description = "Restore a note from Trash. Requires the trash version.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":1},"version":{"type":"integer","minimum":1}},"required":["id","version"],"additionalProperties":false}
        ,
        .write = true,
        .idempotent = false,
    },
    .{
        .name = "attach_file",
        .title = "Attach file",
        .description = "Attach a base64 file up to 8 MiB, store it in SQLite, and append its Markdown link to the note. Requires the current note version.",
        .schema =
        \\{"type":"object","properties":{"note_id":{"type":"integer","minimum":1},"version":{"type":"integer","minimum":1},"filename":{"type":"string","maxLength":200},"content_base64":{"type":"string","maxLength":12000000}},"required":["note_id","version","filename","content_base64"],"additionalProperties":false}
        ,
        .write = true,
        .idempotent = false,
    },
    .{
        .name = "delete_attachment",
        .title = "Delete attachment",
        .description = "Remove an attachment from a note. The Markdown link in the body is left untouched.",
        .schema =
        \\{"type":"object","properties":{"note_id":{"type":"integer","minimum":1},"attachment_id":{"type":"integer","minimum":1}},"required":["note_id","attachment_id"],"additionalProperties":false}
        ,
        .write = true,
        .destructive = true,
    },
    .{
        .name = "set_theme",
        .title = "Set theme",
        .description = "Set the server-side theme id. Use get_theme or the theme list to discover values.",
        .schema =
        \\{"type":"object","properties":{"theme":{"type":"string"}},"required":["theme"],"additionalProperties":false}
        ,
        .write = true,
        .idempotent = true,
    },
};

pub fn run(gpa: Allocator, io: Io, options: Options) !void {
    const database = try db.Db.open(gpa, io, options.db_path);
    defer database.close(gpa);
    var app = App{ .database = database, .io = io, .allow_write = options.allow_write };

    const in_buffer = try gpa.alloc(u8, max_message_bytes);
    defer gpa.free(in_buffer);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, in_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const reader = &stdin_reader.interface;
    const out = &stdout_writer.interface;

    std.debug.print("feathernote mcp: db={s} writes={s}\n", .{ options.db_path, if (options.allow_write) "enabled" else "disabled" });

    while (true) {
        const raw = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("mcp: message exceeds {d} bytes\n", .{max_message_bytes});
                return error.MessageTooLong;
            },
            else => return err,
        } orelse break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        handleLine(&app, arena, line, out) catch |err| {
            std.debug.print("mcp: request failed: {t}\n", .{err});
        };
        try out.flush();
    }
}

fn handleLine(app: *App, arena: Allocator, line: []const u8, out: *Writer) !void {
    const parsed = std.json.parseFromSlice(Value, arena, line, .{}) catch {
        try sendError(out, arena, null, -32700, "Parse error");
        return;
    };
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            try sendError(out, arena, null, -32600, "Invalid Request");
            return;
        },
    };
    const method = valueString(root.get("method")) orelse {
        try sendError(out, arena, root.get("id"), -32600, "Invalid Request");
        return;
    };
    const id = root.get("id");
    const params = root.get("params");

    if (id == null) {
        // Notifications never receive a response.
        return;
    }

    if (std.mem.eql(u8, method, "initialize")) {
        try handleInitialize(out, arena, id, params);
    } else if (std.mem.eql(u8, method, "ping")) {
        try sendResult(out, arena, id, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try sendResult(out, arena, id, try toolsPayload(app, arena));
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolCall(app, out, arena, id, params);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        try sendResult(out, arena, id, try resourcesPayload(app, arena));
    } else if (std.mem.eql(u8, method, "resources/templates/list")) {
        try sendResult(out, arena, id, try resourceTemplatesPayload(arena));
    } else if (std.mem.eql(u8, method, "resources/read")) {
        try handleResourceRead(app, out, arena, id, params);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        try sendResult(out, arena, id, "{\"prompts\":[]}");
    } else {
        try sendError(out, arena, id, -32601, "Method not found");
    }
}

fn handleInitialize(out: *Writer, arena: Allocator, id: ?Value, params: ?Value) !void {
    var requested: ?[]const u8 = null;
    if (params) |p| {
        if (p == .object) requested = valueString(p.object.get("protocolVersion"));
    }
    var negotiated: []const u8 = latest_protocol;
    if (requested) |version| {
        for (protocol_versions) |supported| {
            if (std.mem.eql(u8, version, supported)) {
                negotiated = version;
                break;
            }
        }
    }

    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("protocolVersion");
    try jw.write(negotiated);
    try jw.objectField("capabilities");
    try jw.beginObject();
    try jw.objectField("tools");
    try jw.beginObject();
    try jw.objectField("listChanged");
    try jw.write(false);
    try jw.endObject();
    try jw.objectField("resources");
    try jw.beginObject();
    try jw.objectField("subscribe");
    try jw.write(false);
    try jw.objectField("listChanged");
    try jw.write(false);
    try jw.endObject();
    try jw.endObject();
    try jw.objectField("serverInfo");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("feathernote");
    try jw.objectField("title");
    try jw.write("FeatherNote");
    try jw.objectField("version");
    try jw.write(server_version);
    try jw.endObject();
    try jw.objectField("instructions");
    try jw.write(instructions);
    try jw.endObject();
    try sendResult(out, arena, id, aw.written());
}

fn toolsPayload(app: *App, arena: Allocator) ![]const u8 {
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("tools");
    try jw.beginArray();
    for (tools) |tool| {
        if (tool.write and !app.allow_write) continue;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(tool.name);
        try jw.objectField("title");
        try jw.write(tool.title);
        try jw.objectField("description");
        try jw.write(tool.description);
        try jw.objectField("inputSchema");
        try jw.beginWriteRaw();
        try jw.writer.writeAll(tool.schema);
        jw.endWriteRaw();
        try jw.objectField("annotations");
        try jw.beginObject();
        try jw.objectField("readOnlyHint");
        try jw.write(!tool.write);
        try jw.objectField("destructiveHint");
        try jw.write(tool.destructive);
        try jw.objectField("idempotentHint");
        try jw.write(tool.idempotent);
        try jw.objectField("openWorldHint");
        try jw.write(false);
        try jw.endObject();
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    return aw.written();
}

fn handleToolCall(app: *App, out: *Writer, arena: Allocator, id: ?Value, params: ?Value) !void {
    const object = switch (params orelse return sendError(out, arena, id, -32602, "Missing params")) {
        .object => |obj| obj,
        else => return sendError(out, arena, id, -32602, "params must be an object"),
    };
    const name = valueString(object.get("name")) orelse {
        return sendError(out, arena, id, -32602, "Tool name is required");
    };
    const args_value = object.get("arguments");
    const args: Object = if (args_value) |v| switch (v) {
        .object => |obj| obj,
        else => return sendError(out, arena, id, -32602, "arguments must be an object"),
    } else .{};

    const tool = findTool(name) orelse return sendToolResult(out, arena, id, .{
        .payload = try errorPayload(arena, "unknown_tool", "No such tool."),
        .is_error = true,
    });
    if (tool.write and !app.allow_write) {
        return sendToolResult(out, arena, id, .{
            .payload = try errorPayload(arena, "writes_disabled", "Write tools are disabled. Start the server with --allow-write."),
            .is_error = true,
        });
    }

    const result = dispatchTool(app, arena, tool.name, args) catch |err| blk: {
        std.debug.print("mcp: tool {s} failed: {t}\n", .{ tool.name, err });
        if (err == error.InvalidArguments) {
            break :blk ToolResult{ .payload = try errorPayload(arena, "invalid_arguments", "The tool arguments are invalid."), .is_error = true };
        }
        break :blk ToolResult{ .payload = try errorPayload(arena, "internal_error", "The tool failed. Nothing was changed."), .is_error = true };
    };
    try sendToolResult(out, arena, id, result);
}

fn findTool(name: []const u8) ?Tool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn dispatchTool(app: *App, arena: Allocator, name: []const u8, args: Object) !ToolResult {
    if (std.mem.eql(u8, name, "list_notes")) return toolListNotes(app, arena, args);
    if (std.mem.eql(u8, name, "search_notes")) return toolSearchNotes(app, arena, args);
    if (std.mem.eql(u8, name, "get_note")) return toolGetNote(app, arena, args);
    if (std.mem.eql(u8, name, "list_trash")) return toolListTrash(app, arena, args);
    if (std.mem.eql(u8, name, "list_attachments")) return toolListAttachments(app, arena, args);
    if (std.mem.eql(u8, name, "get_attachment")) return toolGetAttachment(app, arena, args);
    if (std.mem.eql(u8, name, "get_library_stats")) return toolStats(app, arena, args);
    if (std.mem.eql(u8, name, "get_theme")) return toolGetTheme(app, arena, args);
    if (std.mem.eql(u8, name, "create_note")) return toolCreateNote(app, arena, args);
    if (std.mem.eql(u8, name, "update_note")) return toolUpdateNote(app, arena, args);
    if (std.mem.eql(u8, name, "append_note")) return toolAppendNote(app, arena, args);
    if (std.mem.eql(u8, name, "set_pinned")) return toolSetPinned(app, arena, args);
    if (std.mem.eql(u8, name, "delete_note")) return toolDeleteNote(app, arena, args);
    if (std.mem.eql(u8, name, "restore_note")) return toolRestoreNote(app, arena, args);
    if (std.mem.eql(u8, name, "attach_file")) return toolAttachFile(app, arena, args);
    if (std.mem.eql(u8, name, "delete_attachment")) return toolDeleteAttachment(app, arena, args);
    if (std.mem.eql(u8, name, "set_theme")) return toolSetTheme(app, arena, args);
    return .{ .payload = try errorPayload(arena, "unknown_tool", "No such tool."), .is_error = true };
}

// ---- read tools ----

fn toolListNotes(app: *App, arena: Allocator, args: Object) !ToolResult {
    const limit = try optInt(args, "limit", default_limit);
    const offset = try optInt(args, "offset", 0);
    if (limit < 1 or limit > max_limit or offset < 0) return error.InvalidArguments;
    const rows = try app.database.listNotes(arena, null, @intCast(offset), @intCast(limit));
    const total = try app.database.countNotes(null);
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("total");
    try jw.write(total);
    try jw.objectField("offset");
    try jw.write(offset);
    try jw.objectField("limit");
    try jw.write(limit);
    try jw.objectField("notes");
    try jw.beginArray();
    for (rows) |row| try writeNoteRow(&jw, row);
    try jw.endArray();
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolSearchNotes(app: *App, arena: Allocator, args: Object) !ToolResult {
    const query = try reqString(args, "query");
    if (query.len == 0 or query.len > util.max_search_bytes) return error.InvalidArguments;
    const limit = try optInt(args, "limit", default_limit);
    const offset = try optInt(args, "offset", 0);
    if (limit < 1 or limit > max_limit or offset < 0) return error.InvalidArguments;
    const rows = try app.database.searchNotes(arena, query, @intCast(offset), @intCast(limit));
    const total = try app.database.countNotes(query);
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("query");
    try jw.write(query);
    try jw.objectField("total");
    try jw.write(total);
    try jw.objectField("results");
    try jw.beginArray();
    for (rows) |row| {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(row.id);
        try jw.objectField("title");
        try jw.write(row.title);
        try jw.objectField("snippet");
        try jw.write(row.snippet);
        try jw.objectField("updated_at");
        try jw.write(row.updated_at);
        try jw.objectField("version");
        try jw.write(row.version);
        try jw.objectField("pinned");
        try jw.write(row.is_pinned);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolGetNote(app: *App, arena: Allocator, args: Object) !ToolResult {
    const id = try reqInt(args, "id");
    const include_trash = try optBool(args, "include_trash", false);
    const note = try app.database.getNote(arena, id, include_trash) orelse {
        return .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true };
    };
    const attachments = try app.database.attachmentsForNote(arena, id);
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("note");
    try writeNote(&jw, note, true);
    try jw.objectField("attachments");
    try jw.beginArray();
    for (attachments) |file| try writeAttachmentMeta(&jw, file);
    try jw.endArray();
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolListTrash(app: *App, arena: Allocator, args: Object) !ToolResult {
    const limit = try optInt(args, "limit", default_limit);
    const offset = try optInt(args, "offset", 0);
    if (limit < 1 or limit > max_limit or offset < 0) return error.InvalidArguments;
    const rows = try app.database.listTrash(arena, @intCast(offset), @intCast(limit));
    const total = try app.database.countTrash();
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("total");
    try jw.write(total);
    try jw.objectField("notes");
    try jw.beginArray();
    for (rows) |row| {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(row.id);
        try jw.objectField("title");
        try jw.write(row.title);
        try jw.objectField("updated_at");
        try jw.write(row.updated_at);
        try jw.objectField("deleted_at");
        try jw.write(row.deleted_at);
        try jw.objectField("version");
        try jw.write(row.version);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolListAttachments(app: *App, arena: Allocator, args: Object) !ToolResult {
    const note_id = try reqInt(args, "note_id");
    _ = try app.database.getNote(arena, note_id, true) orelse {
        return .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true };
    };
    const attachments = try app.database.attachmentsForNote(arena, note_id);
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("note_id");
    try jw.write(note_id);
    try jw.objectField("attachments");
    try jw.beginArray();
    for (attachments) |file| try writeAttachmentMeta(&jw, file);
    try jw.endArray();
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolGetAttachment(app: *App, arena: Allocator, args: Object) !ToolResult {
    const id = try reqInt(args, "id");
    const file = try app.database.attachment(arena, id) orelse {
        return .{ .payload = try errorPayload(arena, "not_found", "No attachment with that id."), .is_error = true };
    };
    const encoded_size = std.base64.standard.Encoder.calcSize(file.data.len);
    const encoded = try arena.alloc(u8, encoded_size);
    _ = std.base64.standard.Encoder.encode(encoded, file.data);
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(file.meta.id);
    try jw.objectField("note_id");
    try jw.write(file.meta.note_id);
    try jw.objectField("filename");
    try jw.write(file.meta.filename);
    try jw.objectField("mime");
    try jw.write(file.meta.mime);
    try jw.objectField("size");
    try jw.write(file.meta.size);
    try jw.objectField("sha256");
    try jw.write(file.meta.sha256);
    try jw.objectField("content_base64");
    try jw.write(encoded);
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolStats(app: *App, arena: Allocator, args: Object) !ToolResult {
    _ = args;
    const notes = try app.database.countNotes(null);
    const trash = try app.database.countTrash();
    const attachments = try app.database.countAttachments();
    const theme = themes.canonical(try app.database.theme(arena));
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("notes");
    try jw.write(notes);
    try jw.objectField("trash");
    try jw.write(trash);
    try jw.objectField("attachments");
    try jw.write(attachments);
    try jw.objectField("theme");
    try jw.write(theme);
    try jw.objectField("sqlite_version");
    try jw.write(app.database.version());
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolGetTheme(app: *App, arena: Allocator, args: Object) !ToolResult {
    _ = args;
    const stored = try app.database.theme(arena);
    const current = themes.canonical(stored);
    var name: []const u8 = current;
    var mode: []const u8 = "light";
    for (themes.all) |theme| {
        if (std.mem.eql(u8, theme.id, current)) {
            name = theme.name;
            mode = theme.mode;
            break;
        }
    }
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("theme");
    try jw.write(current);
    try jw.objectField("name");
    try jw.write(name);
    try jw.objectField("mode");
    try jw.write(mode);
    try jw.objectField("themes");
    try jw.beginArray();
    for (themes.all) |theme| try jw.write(theme.id);
    try jw.endArray();
    try jw.endObject();
    return .{ .payload = aw.written() };
}

// ---- write tools ----

fn toolCreateNote(app: *App, arena: Allocator, args: Object) !ToolResult {
    const title = try reqString(args, "title");
    const body = try reqString(args, "body");
    validateDraft(title, body) catch return .{ .payload = try errorPayload(arena, "invalid_note", "Title or body is too long or not valid UTF-8."), .is_error = true };
    const id = try app.database.createNote(arena, title, body, nowSeconds(app.io));
    return noteResult(app, arena, id, false);
}

fn toolUpdateNote(app: *App, arena: Allocator, args: Object) !ToolResult {
    const id = try reqInt(args, "id");
    const version = try reqInt(args, "version");
    const title = try reqString(args, "title");
    const body = try reqString(args, "body");
    validateDraft(title, body) catch return .{ .payload = try errorPayload(arena, "invalid_note", "Title or body is too long or not valid UTF-8."), .is_error = true };
    const result = try app.database.updateNote(id, version, title, body, nowSeconds(app.io));
    return switch (result) {
        .ok => noteResult(app, arena, id, false),
        .conflict => conflictResult(app, arena, id, "The note changed since that version was read."),
        .deleted => conflictResult(app, arena, id, "The note is in Trash. Restore it before editing."),
        .not_found => .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true },
    };
}

fn toolAppendNote(app: *App, arena: Allocator, args: Object) !ToolResult {
    const id = try reqInt(args, "id");
    const version = try reqInt(args, "version");
    const text = try reqString(args, "text");
    if (text.len == 0) return error.InvalidArguments;
    const note = try app.database.getNote(arena, id, false) orelse {
        return .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true };
    };
    var combined: std.ArrayList(u8) = .empty;
    try combined.appendSlice(arena, note.body);
    if (note.body.len > 0) try combined.appendSlice(arena, "\n\n");
    try combined.appendSlice(arena, text);
    const body = try combined.toOwnedSlice(arena);
    util.validateBody(body) catch return .{ .payload = try errorPayload(arena, "invalid_note", "The appended note would exceed 256 KiB."), .is_error = true };
    const result = try app.database.updateNote(id, version, note.title, body, nowSeconds(app.io));
    return switch (result) {
        .ok => noteResult(app, arena, id, false),
        .conflict => conflictResult(app, arena, id, "The note changed since that version was read."),
        .deleted => conflictResult(app, arena, id, "The note is in Trash."),
        .not_found => .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true },
    };
}

fn toolSetPinned(app: *App, arena: Allocator, args: Object) !ToolResult {
    const id = try reqInt(args, "id");
    const version = try reqInt(args, "version");
    const pinned = try reqBool(args, "pinned");
    const result = try app.database.setPinned(id, version, pinned, nowSeconds(app.io));
    return switch (result) {
        .ok => noteResult(app, arena, id, false),
        .conflict => conflictResult(app, arena, id, "The note changed since that version was read."),
        .deleted => conflictResult(app, arena, id, "The note is in Trash."),
        .not_found => .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true },
    };
}

fn toolDeleteNote(app: *App, arena: Allocator, args: Object) !ToolResult {
    const id = try reqInt(args, "id");
    const version = try reqInt(args, "version");
    const result = try app.database.softDelete(id, version, nowSeconds(app.io));
    return switch (result) {
        .ok => noteResult(app, arena, id, true),
        .conflict => conflictResult(app, arena, id, "The note changed since that version was read."),
        .deleted => .{ .payload = try errorPayload(arena, "already_deleted", "The note is already in Trash."), .is_error = true },
        .not_found => .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true },
    };
}

fn toolRestoreNote(app: *App, arena: Allocator, args: Object) !ToolResult {
    const id = try reqInt(args, "id");
    const version = try reqInt(args, "version");
    const result = try app.database.restore(id, version, nowSeconds(app.io));
    return switch (result) {
        .ok => noteResult(app, arena, id, false),
        .conflict, .deleted => conflictResult(app, arena, id, "The note changed since that version was read."),
        .not_found => .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true },
    };
}

fn toolAttachFile(app: *App, arena: Allocator, args: Object) !ToolResult {
    const note_id = try reqInt(args, "note_id");
    const version = try reqInt(args, "version");
    const raw_name = try reqString(args, "filename");
    const encoded = try reqString(args, "content_base64");
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return .{
        .payload = try errorPayload(arena, "invalid_base64", "content_base64 is not valid base64."),
        .is_error = true,
    };
    if (decoded_size > util.max_upload_bytes) {
        return .{ .payload = try errorPayload(arena, "too_large", "Attachments are limited to 8 MiB."), .is_error = true };
    }
    const data = try arena.alloc(u8, decoded_size);
    std.base64.standard.Decoder.decode(data, encoded) catch return .{
        .payload = try errorPayload(arena, "invalid_base64", "content_base64 is not valid base64."),
        .is_error = true,
    };
    const note = try app.database.getNote(arena, note_id, false) orelse {
        return .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true };
    };
    const filename = try media.sanitizeFilename(arena, raw_name);
    const mime = media.sniffMime(data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const attachment_id = try app.database.insertAttachment(.{
        .note_id = note_id,
        .filename = filename,
        .mime = mime,
        .sha256 = hex[0..],
        .data = data,
    }, nowSeconds(app.io));
    const new_body = try media.appendFileLink(arena, note.body, attachment_id, filename, mime);
    if (new_body.len > util.max_body_bytes) {
        _ = app.database.deleteAttachment(attachment_id, note_id) catch {};
        return .{ .payload = try errorPayload(arena, "note_full", "The note is at its 256 KiB limit."), .is_error = true };
    }
    const updated = try app.database.updateNote(note_id, version, note.title, new_body, nowSeconds(app.io));
    if (updated != .ok) {
        _ = app.database.deleteAttachment(attachment_id, note_id) catch {};
        if (updated == .conflict) return conflictResult(app, arena, note_id, "The note changed since that version was read.");
        return .{ .payload = try errorPayload(arena, "write_failed", "The attachment could not be linked."), .is_error = true };
    }
    const meta = db.Attachment{
        .id = attachment_id,
        .note_id = note_id,
        .filename = filename,
        .mime = mime,
        .size = @intCast(data.len),
        .sha256 = hex[0..],
        .created_at = nowSeconds(app.io),
    };
    const fresh = (try app.database.getNote(arena, note_id, false)).?;
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("attachment");
    try writeAttachmentMeta(&jw, meta);
    try jw.objectField("note");
    try writeNote(&jw, fresh, true);
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn toolDeleteAttachment(app: *App, arena: Allocator, args: Object) !ToolResult {
    const note_id = try reqInt(args, "note_id");
    const attachment_id = try reqInt(args, "attachment_id");
    const removed = try app.database.deleteAttachment(attachment_id, note_id);
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("deleted");
    try jw.write(removed);
    try jw.objectField("note_id");
    try jw.write(note_id);
    try jw.objectField("attachment_id");
    try jw.write(attachment_id);
    try jw.endObject();
    if (!removed) {
        return .{ .payload = aw.written(), .is_error = true };
    }
    return .{ .payload = aw.written() };
}

fn toolSetTheme(app: *App, arena: Allocator, args: Object) !ToolResult {
    const theme = try reqString(args, "theme");
    if (!themes.isValid(theme)) {
        return .{ .payload = try errorPayload(arena, "unknown_theme", "Unknown theme id. Use get_theme to list them."), .is_error = true };
    }
    try app.database.setTheme(theme);
    if (!std.mem.eql(u8, themes.canonical(try app.database.theme(arena)), theme)) {
        return .{ .payload = try errorPayload(arena, "no_owner", "No owner account exists yet. Run feathernote admin set-password first."), .is_error = true };
    }
    return toolGetTheme(app, arena, args);
}

// ---- resources ----

fn resourcesPayload(app: *App, arena: Allocator) ![]const u8 {
    const rows = try app.database.listNotes(arena, null, 0, 50);
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("resources");
    try jw.beginArray();
    for (rows) |row| {
        var uri_buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&uri_buf, "feathernote://notes/{d}", .{row.id});
        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(uri);
        try jw.objectField("name");
        try jw.write(if (row.title.len == 0) "Untitled" else row.title);
        try jw.objectField("description");
        try jw.write("Markdown note");
        try jw.objectField("mimeType");
        try jw.write("text/markdown");
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    return aw.written();
}

fn resourceTemplatesPayload(arena: Allocator) ![]const u8 {
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("resourceTemplates");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("uriTemplate");
    try jw.write("feathernote://notes/{id}");
    try jw.objectField("name");
    try jw.write("Note");
    try jw.objectField("description");
    try jw.write("A FeatherNote Markdown note by numeric id.");
    try jw.objectField("mimeType");
    try jw.write("text/markdown");
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    return aw.written();
}

fn handleResourceRead(app: *App, out: *Writer, arena: Allocator, id: ?Value, params: ?Value) !void {
    const object = switch (params orelse return sendError(out, arena, id, -32602, "Missing params")) {
        .object => |obj| obj,
        else => return sendError(out, arena, id, -32602, "params must be an object"),
    };
    const uri = valueString(object.get("uri")) orelse {
        return sendError(out, arena, id, -32602, "uri is required");
    };
    const prefix = "feathernote://notes/";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        return sendError(out, arena, id, -32002, "Resource not found");
    }
    const id_text = uri[prefix.len..];
    const note_id = std.fmt.parseInt(i64, id_text, 10) catch {
        return sendError(out, arena, id, -32002, "Resource not found");
    };
    const note = (try app.database.getNote(arena, note_id, false)) orelse {
        return sendError(out, arena, id, -32002, "Resource not found");
    };
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("contents");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("uri");
    try jw.write(uri);
    try jw.objectField("mimeType");
    try jw.write("text/markdown");
    try jw.objectField("text");
    try jw.write(note.body);
    try jw.objectField("_meta");
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(note.id);
    try jw.objectField("title");
    try jw.write(note.title);
    try jw.objectField("version");
    try jw.write(note.version);
    try jw.objectField("updated_at");
    try jw.write(note.updated_at);
    try jw.objectField("pinned");
    try jw.write(note.is_pinned);
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try sendResult(out, arena, id, aw.written());
}

// ---- JSON output helpers ----

fn noteResult(app: *App, arena: Allocator, id: i64, include_trash: bool) !ToolResult {
    const note = try app.database.getNote(arena, id, include_trash) orelse {
        return .{ .payload = try errorPayload(arena, "not_found", "No note with that id."), .is_error = true };
    };
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("note");
    try writeNote(&jw, note, true);
    try jw.endObject();
    return .{ .payload = aw.written() };
}

fn conflictResult(app: *App, arena: Allocator, id: i64, message: []const u8) !ToolResult {
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("error");
    try jw.write("conflict");
    try jw.objectField("message");
    try jw.write(message);
    if (try app.database.getNote(arena, id, true)) |latest| {
        try jw.objectField("latest");
        try writeNote(&jw, latest, true);
    }
    try jw.endObject();
    return .{ .payload = aw.written(), .is_error = true };
}

fn writeNote(jw: *std.json.Stringify, note: db.Note, include_body: bool) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(note.id);
    try jw.objectField("title");
    try jw.write(note.title);
    if (include_body) {
        try jw.objectField("body");
        try jw.write(note.body);
    }
    try jw.objectField("created_at");
    try jw.write(note.created_at);
    try jw.objectField("updated_at");
    try jw.write(note.updated_at);
    try jw.objectField("updated_utc");
    try writeTimestamp(jw, note.updated_at);
    try jw.objectField("version");
    try jw.write(note.version);
    try jw.objectField("pinned");
    try jw.write(note.is_pinned);
    try jw.objectField("deleted_at");
    if (note.deleted_at) |ts| try jw.write(ts) else try jw.write(null);
    try jw.objectField("uri");
    var buf: [64]u8 = undefined;
    try jw.write(try std.fmt.bufPrint(&buf, "feathernote://notes/{d}", .{note.id}));
    try jw.endObject();
}

fn writeNoteRow(jw: *std.json.Stringify, row: db.NoteRow) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(row.id);
    try jw.objectField("title");
    try jw.write(row.title);
    try jw.objectField("updated_at");
    try jw.write(row.updated_at);
    try jw.objectField("updated_utc");
    try writeTimestamp(jw, row.updated_at);
    try jw.objectField("version");
    try jw.write(row.version);
    try jw.objectField("pinned");
    try jw.write(row.is_pinned);
    try jw.objectField("uri");
    var buf: [64]u8 = undefined;
    try jw.write(try std.fmt.bufPrint(&buf, "feathernote://notes/{d}", .{row.id}));
    try jw.endObject();
}

fn writeAttachmentMeta(jw: *std.json.Stringify, file: db.Attachment) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(file.id);
    try jw.objectField("note_id");
    try jw.write(file.note_id);
    try jw.objectField("filename");
    try jw.write(file.filename);
    try jw.objectField("mime");
    try jw.write(file.mime);
    try jw.objectField("size");
    try jw.write(file.size);
    try jw.objectField("sha256");
    try jw.write(file.sha256);
    try jw.objectField("created_at");
    try jw.write(file.created_at);
    try jw.endObject();
}

fn writeTimestamp(jw: *std.json.Stringify, ts: i64) !void {
    var buf: [48]u8 = undefined;
    var w = Writer.fixed(&buf);
    try util.formatDateFull(&w, ts);
    try jw.write(w.buffered());
}

fn errorPayload(arena: Allocator, code: []const u8, message: []const u8) ![]const u8 {
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("error");
    try jw.write(code);
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    return aw.written();
}

fn sendResult(out: *Writer, arena: Allocator, id: ?Value, payload: []const u8) !void {
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    if (id) |v| try writeValue(&jw, v) else try jw.write(null);
    try jw.objectField("result");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(payload);
    jw.endWriteRaw();
    try jw.endObject();
    try out.writeAll(aw.written());
    try out.writeByte('\n');
}

fn sendError(out: *Writer, arena: Allocator, id: ?Value, code: i64, message: []const u8) !void {
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    if (id) |v| try writeValue(&jw, v) else try jw.write(null);
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(code);
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    try jw.endObject();
    try out.writeAll(aw.written());
    try out.writeByte('\n');
}

fn sendToolResult(out: *Writer, arena: Allocator, id: ?Value, result: ToolResult) !void {
    var aw = Writer.Allocating.init(arena);
    var jw = std.json.Stringify{ .writer = &aw.writer };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    if (id) |v| try writeValue(&jw, v) else try jw.write(null);
    try jw.objectField("result");
    try jw.beginObject();
    try jw.objectField("content");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("text");
    try jw.objectField("text");
    try jw.write(result.payload);
    try jw.endObject();
    try jw.endArray();
    try jw.objectField("structuredContent");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(result.payload);
    jw.endWriteRaw();
    if (result.is_error) {
        try jw.objectField("isError");
        try jw.write(true);
    }
    try jw.endObject();
    try jw.endObject();
    try out.writeAll(aw.written());
    try out.writeByte('\n');
}

fn writeValue(jw: *std.json.Stringify, value: Value) !void {
    switch (value) {
        .null => try jw.write(null),
        .bool => |v| try jw.write(v),
        .integer => |v| try jw.write(v),
        .float => |v| try jw.write(v),
        .number_string => |v| {
            try jw.beginWriteRaw();
            try jw.writer.writeAll(v);
            jw.endWriteRaw();
        },
        .string => |v| try jw.write(v),
        .array => |arr| {
            try jw.beginArray();
            for (arr.items) |item| try writeValue(jw, item);
            try jw.endArray();
        },
        .object => |obj| {
            try jw.beginObject();
            for (obj.keys()) |key| {
                try jw.objectField(key);
                try writeValue(jw, obj.get(key).?);
            }
            try jw.endObject();
        },
    }
}

// ---- argument helpers ----

fn valueString(value: ?Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn reqString(obj: Object, key: []const u8) ![]const u8 {
    return valueString(obj.get(key)) orelse error.InvalidArguments;
}

fn reqInt(obj: Object, key: []const u8) !i64 {
    return intValue(obj.get(key)) orelse error.InvalidArguments;
}

fn optInt(obj: Object, key: []const u8, default: i64) !i64 {
    if (obj.get(key) == null) return default;
    return intValue(obj.get(key)) orelse error.InvalidArguments;
}

fn reqBool(obj: Object, key: []const u8) !bool {
    return boolValue(obj.get(key)) orelse error.InvalidArguments;
}

fn optBool(obj: Object, key: []const u8, default: bool) !bool {
    if (obj.get(key) == null) return default;
    return boolValue(obj.get(key)) orelse error.InvalidArguments;
}

fn intValue(value: ?Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn boolValue(value: ?Value) ?bool {
    const v = value orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn validateDraft(title: []const u8, body: []const u8) !void {
    try util.validateTitle(title);
    try util.validateBody(body);
}

fn nowSeconds(io: Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

test "mcp argument helpers reject the wrong shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSlice(Value, arena_state.allocator(),
        \\{"s":"x","i":3,"b":true}
    , .{});
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("x", try reqString(obj, "s"));
    try std.testing.expectEqual(@as(i64, 3), try reqInt(obj, "i"));
    try std.testing.expect(try reqBool(obj, "b"));
    try std.testing.expectError(error.InvalidArguments, reqString(obj, "i"));
    try std.testing.expectError(error.InvalidArguments, reqInt(obj, "s"));
}
