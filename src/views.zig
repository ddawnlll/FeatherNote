//! Server-rendered HTML. No browser JavaScript is required for any page.
const std = @import("std");
const util = @import("http_util.zig");
const db = @import("db.zig");

const Writer = std.Io.Writer;

pub const Ctx = struct {
    authed: bool,
    csrf: []const u8 = "",
};

fn documentStart(w: *Writer, title: []const u8, ctx: Ctx, search: ?[]const u8) !void {
    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
    );
    try w.writeAll("<title>");
    try util.escapeHtml(w, title);
    try w.writeAll(" · FeatherNote</title>\n<link rel=\"stylesheet\" href=\"/style.css\">\n</head>\n<body>\n");
    try w.writeAll("<header class=\"top\"><a class=\"brand\" href=\"/notes\">FeatherNote</a>");
    if (ctx.authed) {
        try w.writeAll("<form class=\"search\" method=\"get\" action=\"/notes\" role=\"search\"><input id=\"q\" type=\"search\" name=\"q\" maxlength=\"100\" placeholder=\"Search\" aria-label=\"Search notes\"");
        if (search) |q| {
            try w.writeAll(" value=\"");
            try util.escapeHtml(w, q);
            try w.writeAll("\"");
        }
        try w.writeAll("><button type=\"submit\">Search</button></form>");
        try w.writeAll("<nav class=\"nav\"><a href=\"/notes/new\">New note</a><a href=\"/trash\">Trash</a><form method=\"post\" action=\"/logout\">");
        try csrfField(w, ctx.csrf);
        try w.writeAll("<button class=\"link\" type=\"submit\">Log out</button></form></nav>");
    }
    try w.writeAll("</header>\n<main>\n");
}

fn documentEnd(w: *Writer) !void {
    try w.writeAll("</main>\n<footer>FeatherNote · plain text · no tracking</footer>\n</body>\n</html>\n");
}

fn csrfField(w: *Writer, csrf: []const u8) !void {
    try w.writeAll("<input type=\"hidden\" name=\"csrf\" value=\"");
    try util.escapeHtml(w, csrf);
    try w.writeAll("\">");
}

fn versionField(w: *Writer, version: i64) !void {
    try w.print("<input type=\"hidden\" name=\"version\" value=\"{d}\">", .{version});
}

fn displayTitle(title: []const u8) []const u8 {
    return if (title.len == 0) "Untitled" else title;
}

fn statusMessage(w: *Writer, message: []const u8) !void {
    try w.writeAll("<p class=\"status\" role=\"status\">");
    try util.escapeHtml(w, message);
    try w.writeAll("</p>\n");
}

fn errorBanner(w: *Writer, message: []const u8) !void {
    try w.writeAll("<p class=\"error\" role=\"alert\">");
    try util.escapeHtml(w, message);
    try w.writeAll("</p>\n");
}

pub fn login(
    w: *Writer,
    error_message: ?[]const u8,
    no_owner: bool,
    password_changed: bool,
) !void {
    try documentStart(w, "Log in", .{ .authed = false }, null);
    try w.writeAll("<h1>Log in</h1>\n");
    if (no_owner) {
        try errorBanner(w, "No owner account is configured yet. Run: feathernote admin set-password --db PATH");
    }
    if (password_changed) try statusMessage(w, "Password updated. Log in with the new password.");
    if (error_message) |message| try errorBanner(w, message);
    try w.writeAll(
        \\<form class="stack" method="post" action="/login">
        \\<label for="password">Owner password</label>
        \\<input id="password" name="password" type="password" autocomplete="current-password" required autofocus>
        \\<button type="submit">Log in</button>
        \\</form>
        \\<p class="muted">Single-owner instance. There is no public registration.</p>
        \\
    );
    try documentEnd(w);
}

fn pagination(w: *Writer, q: ?[]const u8, page: usize, total: i64) !void {
    const page_size: usize = util.page_size;
    const total_pages: usize = if (total <= 0) 1 else (@as(usize, @intCast(total)) + page_size - 1) / page_size;
    if (total_pages <= 1) return;
    try w.writeAll("<nav class=\"pager\" aria-label=\"Pagination\">");
    if (page > 1) {
        try w.writeAll("<a rel=\"prev\" href=\"");
        try listHref(w, q, page - 1);
        try w.writeAll("\">Previous</a>");
    } else {
        try w.writeAll("<span></span>");
    }
    try w.print("<span class=\"muted\">Page {d} of {d}</span>", .{ page, total_pages });
    if (page < total_pages) {
        try w.writeAll("<a rel=\"next\" href=\"");
        try listHref(w, q, page + 1);
        try w.writeAll("\">Next</a>");
    } else {
        try w.writeAll("<span></span>");
    }
    try w.writeAll("</nav>\n");
}

fn listHref(w: *Writer, q: ?[]const u8, page: usize) !void {
    try w.writeAll("/notes?");
    if (q) |query| {
        if (query.len != 0) {
            try w.writeAll("q=");
            try util.urlEncode(w, query);
            try w.writeAll("&amp;");
        }
    }
    try w.print("page={d}", .{page});
}

pub fn noteList(
    w: *Writer,
    ctx: Ctx,
    rows: []const db.NoteRow,
    total: i64,
    page: usize,
    q: ?[]const u8,
) !void {
    try documentStart(w, "Notes", ctx, q);
    if (q) |query| {
        if (query.len != 0) {
            try w.writeAll("<h1>Search</h1>\n");
            try w.print("<p class=\"muted\">{d} result(s) for “", .{total});
            try util.escapeHtml(w, query);
            try w.writeAll("”. <a href=\"/notes\">Clear search</a></p>\n");
        } else {
            try w.writeAll("<h1>Notes</h1>\n");
        }
    } else {
        try w.writeAll("<h1>Notes</h1>\n");
    }

    if (rows.len == 0) {
        if (q != null and q.?.len != 0) {
            try w.writeAll("<p class=\"empty\">No notes matched. Try a different word, or <a href=\"/notes\">view all notes</a>.</p>\n");
        } else {
            try w.writeAll("<p class=\"empty\">No notes yet. <a href=\"/notes/new\">Create your first note</a>.</p>\n");
        }
    } else {
        try w.writeAll("<ul class=\"notes\">\n");
        for (rows) |row| {
            try w.writeAll("<li class=\"note-row\"><a class=\"note-link\" href=\"/notes/");
            try w.print("{d}", .{row.id});
            try w.writeAll("\"><span class=\"note-title\">");
            try util.escapeHtml(w, displayTitle(row.title));
            try w.writeAll("</span><span class=\"note-meta\">");
            if (row.is_pinned) try w.writeAll("Pinned · ");
            try util.formatDateShort(w, row.updated_at);
            try w.writeAll("</span></a></li>\n");
        }
        try w.writeAll("</ul>\n");
        try pagination(w, q, page, total);
    }
    try documentEnd(w);
}

fn sidebar(w: *Writer, rows: []const db.NoteRow, current_id: i64) !void {
    if (rows.len == 0) return;
    try w.writeAll("<aside class=\"sidebar\" aria-label=\"Recent notes\"><h2>Recent</h2><ul class=\"notes compact\">\n");
    for (rows) |row| {
        try w.writeAll("<li class=\"note-row");
        if (row.id == current_id) try w.writeAll(" current");
        try w.writeAll("\"><a class=\"note-link\" href=\"/notes/");
        try w.print("{d}", .{row.id});
        try w.writeAll("\"><span class=\"note-title\">");
        try util.escapeHtml(w, displayTitle(row.title));
        try w.writeAll("</span></a></li>\n");
    }
    try w.writeAll("</ul></aside>\n");
}

pub const EditorArgs = struct {
    note: ?db.Note,
    sidebar_rows: []const db.NoteRow,
    saved: bool,
    draft_title: []const u8 = "",
    draft_body: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub fn editor(w: *Writer, ctx: Ctx, args: EditorArgs) !void {
    const is_new = args.note == null;
    const title = if (is_new) "New note" else displayTitle(args.note.?.title);
    try documentStart(w, title, ctx, null);
    // Only wrap in the two-column grid when there is a sidebar to sit beside.
    if (!is_new) try w.writeAll("<div class=\"layout\">\n");
    if (!is_new) try sidebar(w, args.sidebar_rows, args.note.?.id);
    try w.writeAll("<article class=\"editor\">\n");
    if (is_new) {
        try w.writeAll("<h1>New note</h1>\n");
    } else {
        try w.writeAll("<div class=\"editor-head\"><h1>");
        try util.escapeHtml(w, displayTitle(args.note.?.title));
        try w.writeAll("</h1><p class=\"muted\">");
        try util.formatDateFull(w, args.note.?.updated_at);
        try w.print(" · version {d}", .{args.note.?.version});
        try w.writeAll("</p></div>\n");
    }
    if (args.saved) try statusMessage(w, "Saved.");
    if (args.error_message) |message| try errorBanner(w, message);

    const value_title = if (args.error_message != null or is_new) args.draft_title else args.note.?.title;
    const value_body = if (args.error_message != null or is_new) args.draft_body else args.note.?.body;

    try w.writeAll("<form class=\"editor-form\" method=\"post\" action=\"");
    if (is_new) {
        try w.writeAll("/notes");
    } else {
        try w.print("/notes/{d}", .{args.note.?.id});
    }
    try w.writeAll("\">");
    try csrfField(w, ctx.csrf);
    if (!is_new) try versionField(w, args.note.?.version);
    try w.writeAll("<label for=\"title\">Title</label><input id=\"title\" name=\"title\" type=\"text\" maxlength=\"200\" value=\"");
    try util.escapeHtml(w, value_title);
    try w.writeAll("\" autocomplete=\"off\">");
    try w.writeAll("<label for=\"body\">Note</label><textarea id=\"body\" name=\"body\" rows=\"18\" spellcheck=\"true\">");
    try util.escapeHtml(w, value_body);
    try w.writeAll("</textarea><div class=\"actions\"><button type=\"submit\">Save</button><a class=\"button secondary\" href=\"");
    if (is_new) {
        try w.writeAll("/notes");
    } else {
        try w.print("/notes/{d}", .{args.note.?.id});
    }
    try w.writeAll("\">Cancel</a></div></form>\n");

    if (!is_new) {
        try w.writeAll("<div class=\"secondary-actions\">");
        try w.writeAll("<form method=\"post\" action=\"/notes/");
        try w.print("{d}", .{args.note.?.id});
        try w.writeAll("/pin\">");
        try csrfField(w, ctx.csrf);
        try versionField(w, args.note.?.version);
        if (args.note.?.is_pinned) {
            try w.writeAll("<button type=\"submit\" class=\"secondary\">Unpin</button>");
        } else {
            try w.writeAll("<button type=\"submit\" class=\"secondary\">Pin</button>");
        }
        try w.writeAll("</form><a class=\"button danger-link\" href=\"/notes/");
        try w.print("{d}", .{args.note.?.id});
        try w.writeAll("/delete\">Delete…</a></div>\n");
    }
    try w.writeAll("</article>\n");
    if (!is_new) try w.writeAll("</div>\n");
    try documentEnd(w);
}

pub fn conflict(
    w: *Writer,
    ctx: Ctx,
    latest: db.Note,
    draft_title: []const u8,
    draft_body: []const u8,
) !void {
    try documentStart(w, "Edit conflict", ctx, null);
    try w.writeAll("<h1>Edit conflict</h1>\n");
    try errorBanner(w, "This note changed elsewhere after you opened it. Nothing was overwritten. Your draft is preserved below.");
    try w.writeAll("<section class=\"conflict\"><h2>Your draft (not saved)</h2>");
    try w.writeAll("<form method=\"post\" action=\"/notes/");
    try w.print("{d}", .{latest.id});
    try w.writeAll("\">");
    try csrfField(w, ctx.csrf);
    try versionField(w, latest.version);
    try w.writeAll("<label for=\"draft-title\">Title</label><input id=\"draft-title\" name=\"title\" type=\"text\" maxlength=\"200\" value=\"");
    try util.escapeHtml(w, draft_title);
    try w.writeAll("\"><label for=\"draft-body\">Draft</label><textarea id=\"draft-body\" name=\"body\" rows=\"12\">");
    try util.escapeHtml(w, draft_body);
    try w.writeAll("</textarea><p class=\"muted\">Saving this form explicitly replaces the latest version shown below. Copy and merge manually first if you prefer.</p><button type=\"submit\" class=\"danger\">Save my draft over the latest version</button></form></section>\n");

    try w.writeAll("<section class=\"latest\"><h2>Latest saved version (version ");
    try w.print("{d}", .{latest.version});
    try w.writeAll(")</h2><label for=\"latest-title\">Title</label><input id=\"latest-title\" type=\"text\" value=\"");
    try util.escapeHtml(w, latest.title);
    try w.writeAll("\" readonly><label for=\"latest-body\">Note</label><textarea id=\"latest-body\" rows=\"12\" readonly>");
    try util.escapeHtml(w, latest.body);
    try w.writeAll("</textarea><p><a href=\"/notes/");
    try w.print("{d}", .{latest.id});
    try w.writeAll("\">Open the latest version</a> · <a href=\"/notes\">All notes</a></p></section>\n");
    try documentEnd(w);
}

pub fn newNote(
    w: *Writer,
    ctx: Ctx,
    draft_title: []const u8,
    draft_body: []const u8,
    error_message: ?[]const u8,
) !void {
    try editor(w, ctx, .{
        .note = null,
        .sidebar_rows = &.{},
        .saved = false,
        .draft_title = draft_title,
        .draft_body = draft_body,
        .error_message = error_message,
    });
}

pub fn trash(w: *Writer, ctx: Ctx, rows: []const db.TrashRow, total: i64, page: usize) !void {
    try documentStart(w, "Trash", ctx, null);
    try w.writeAll("<h1>Trash</h1>\n<p class=\"muted\">Deleted notes stay recoverable until an operator removes them.</p>\n");
    if (rows.len == 0) {
        try w.writeAll("<p class=\"empty\">Trash is empty.</p>\n");
    } else {
        try w.writeAll("<ul class=\"notes trash-list\">\n");
        for (rows) |row| {
            try w.writeAll("<li class=\"note-row\"><div class=\"note-link\"><span class=\"note-title\">");
            try util.escapeHtml(w, displayTitle(row.title));
            try w.writeAll("</span><span class=\"note-meta\">Deleted ");
            try util.formatDateShort(w, row.deleted_at);
            try w.writeAll("</span></div><form method=\"post\" action=\"/notes/");
            try w.print("{d}", .{row.id});
            try w.writeAll("/restore\">");
            try csrfField(w, ctx.csrf);
            try versionField(w, row.version);
            try w.writeAll("<button type=\"submit\" class=\"secondary\">Restore</button></form></li>\n");
        }
        try w.writeAll("</ul>\n");
        if (total > @as(i64, @intCast(util.page_size))) {
            try w.writeAll("<nav class=\"pager\"><span></span><span class=\"muted\">Page ");
            try w.print("{d}", .{page});
            try w.writeAll("</span>");
            if (@as(usize, @intCast(total)) > page * util.page_size) {
                try w.print("<a href=\"/trash?page={d}\">Next</a>", .{page + 1});
            } else {
                try w.writeAll("<span></span>");
            }
            try w.writeAll("</nav>\n");
        }
    }
    try documentEnd(w);
}

pub fn deleteConfirm(w: *Writer, ctx: Ctx, note: db.Note) !void {
    try documentStart(w, "Delete note", ctx, null);
    try w.writeAll("<h1>Delete this note?</h1>\n<p>“");
    try util.escapeHtml(w, displayTitle(note.title));
    try w.writeAll("” will move to Trash and can be restored later.</p>\n<form class=\"stack\" method=\"post\" action=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("/delete\">");
    try csrfField(w, ctx.csrf);
    try versionField(w, note.version);
    try w.writeAll("<div class=\"actions\"><button type=\"submit\" class=\"danger\">Delete note</button><a class=\"button secondary\" href=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("\">Cancel</a></div></form>\n");
    try documentEnd(w);
}

pub fn errorPage(w: *Writer, ctx: Ctx, heading: []const u8, message: []const u8) !void {
    try documentStart(w, heading, ctx, null);
    try w.writeAll("<h1>");
    try util.escapeHtml(w, heading);
    try w.writeAll("</h1>\n");
    try errorBanner(w, message);
    try w.writeAll("<p><a href=\"/notes\">Back to notes</a></p>\n");
    try documentEnd(w);
}

pub fn simpleMessage(w: *Writer, ctx: Ctx, heading: []const u8, message: []const u8) !void {
    try documentStart(w, heading, ctx, null);
    try w.writeAll("<h1>");
    try util.escapeHtml(w, heading);
    try w.writeAll("</h1>\n");
    try statusMessage(w, message);
    try w.writeAll("<p><a href=\"/notes\">Back to notes</a></p>\n");
    try documentEnd(w);
}
