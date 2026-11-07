//! Server-rendered HTML. No browser JavaScript is required for any page.
const std = @import("std");
const util = @import("http_util.zig");
const db = @import("db.zig");
const markdown = @import("markdown.zig");
const themes = @import("themes.zig");

const Writer = std.Io.Writer;

pub const Ctx = struct {
    authed: bool,
    csrf: []const u8 = "",
    theme: []const u8 = "feather",
};

fn themeId(ctx: Ctx) []const u8 {
    return if (themes.isValid(ctx.theme)) ctx.theme else "feather";
}

const logo_svg =
    \\<svg class="logo" viewBox="0 0 32 32" aria-hidden="true" focusable="false">
    \\<path d="M25 4C17 5 10 10 8 18l-2 6 4-2c2 2 5 3 8 2 6-2 9-9 7-20Z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/>
    \\<path d="M9 25c3-7 8-11 14-14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
    \\</svg>
;

fn documentStart(w: *Writer, title: []const u8, ctx: Ctx, search: ?[]const u8) !void {
    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en" data-theme="
    );
    try w.writeAll(themeId(ctx));
    try w.writeAll("\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try util.escapeHtml(w, title);
    try w.writeAll(" · FeatherNote</title>\n<link rel=\"stylesheet\" href=\"/style.css\">\n</head>\n<body>\n");
    try w.writeAll("<a class=\"skip\" href=\"#main\">Skip to content</a>\n<header class=\"top\"><a class=\"brand\" href=\"/notes\">");
    try w.writeAll(logo_svg);
    try w.writeAll("<span>FeatherNote</span></a>");
    if (ctx.authed) {
        try w.writeAll("<form class=\"search\" method=\"get\" action=\"/notes\" role=\"search\"><input id=\"q\" type=\"search\" name=\"q\" maxlength=\"100\" placeholder=\"Search notes\" aria-label=\"Search notes\"");
        if (search) |q| {
            try w.writeAll(" value=\"");
            try util.escapeHtml(w, q);
            try w.writeAll("\"");
        }
        try w.writeAll("><button type=\"submit\" class=\"secondary\">Search</button></form>");
        try w.writeAll("<nav class=\"nav\" aria-label=\"Main\"><a href=\"/notes/new\">New note</a><a href=\"/trash\">Trash</a><a href=\"/settings\">Themes</a><form method=\"post\" action=\"/logout\">");
        try csrfField(w, ctx.csrf);
        try w.writeAll("<button class=\"link\" type=\"submit\">Log out</button></form></nav>");
    }
    try w.writeAll("</header>\n<main id=\"main\">\n");
}

fn documentEnd(w: *Writer) !void {
    try w.writeAll("</main>\n<footer class=\"foot\"><span>FeatherNote</span><span>markdown · no tracking · no JavaScript</span></footer>\n</body>\n</html>\n");
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

fn hero(w: *Writer, eyebrow: []const u8, heading: []const u8, lede: []const u8) !void {
    try w.writeAll("<section class=\"hero\"><p class=\"eyebrow\">");
    try util.escapeHtml(w, eyebrow);
    try w.writeAll("</p><h1>");
    try util.escapeHtml(w, heading);
    try w.writeAll("</h1><p class=\"lede\">");
    try util.escapeHtml(w, lede);
    try w.writeAll("</p></section>\n");
}

pub fn login(w: *Writer, ctx: Ctx, error_message: ?[]const u8, no_owner: bool, password_changed: bool) !void {
    try documentStart(w, "Log in", ctx, null);
    try w.writeAll("<div class=\"auth-shell\"><section class=\"auth-card\">\n<p class=\"eyebrow\">Private notebook</p>\n<h1>Welcome back</h1>\n<p class=\"lede\">One password. Your notes never leave this server.</p>\n");
    if (no_owner) {
        try errorBanner(w, "No owner account is configured yet. Run: feathernote admin set-password --db PATH");
    }
    if (password_changed) try statusMessage(w, "Password updated. Log in with the new password.");
    if (error_message) |message| try errorBanner(w, message);
    try w.writeAll(
        \\<form class="stack" method="post" action="/login">
        \\<label for="password">Owner password</label>
        \\<input id="password" name="password" type="password" autocomplete="current-password" required autofocus>
        \\<button type="submit" class="primary">Unlock notes</button>
        \\</form>
        \\<p class="muted small">Single-owner instance. There is no public registration.</p>
        \\</section></div>
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
    const searching = q != null and q.?.len != 0;
    try documentStart(w, "Notes", ctx, q);
    if (searching) {
        var lede: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&lede, "{d} result{s} for “{s}”", .{
            total,
            if (total == 1) "" else "s",
            q.?,
        }) catch "Search results";
        try hero(w, "Search", "Found", text);
        try w.writeAll("<p class=\"hero-actions\"><a class=\"button secondary\" href=\"/notes\">Clear search</a></p>\n");
    } else {
        var lede: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&lede, "{d} note{s}, newest first. Pinned notes stay on top.", .{
            total,
            if (total == 1) "" else "s",
        }) catch "Your library";
        try hero(w, "Library", "Your notes", text);
    }

    if (rows.len == 0) {
        if (searching) {
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
            if (row.is_pinned) try w.writeAll("<span class=\"badge\">Pinned</span>");
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
    try w.writeAll("<aside class=\"sidebar\" aria-label=\"Recent notes\"><p class=\"eyebrow\">Recent</p><ul class=\"notes compact\">\n");
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

pub fn readNote(
    w: *Writer,
    ctx: Ctx,
    note: db.Note,
    sidebar_rows: []const db.NoteRow,
    attachments: []const db.Attachment,
    saved: bool,
) !void {
    try documentStart(w, displayTitle(note.title), ctx, null);
    try w.writeAll("<div class=\"layout reader-layout\">\n");
    try sidebar(w, sidebar_rows, note.id);
    try w.writeAll("<article class=\"reader\">\n<header class=\"reader-head\"><p class=\"eyebrow\">Note · version ");
    try w.print("{d}", .{note.version});
    try w.writeAll("</p><h1>");
    try util.escapeHtml(w, displayTitle(note.title));
    try w.writeAll("</h1><p class=\"meta\">Updated ");
    try util.formatDateFull(w, note.updated_at);
    if (note.is_pinned) try w.writeAll(" · pinned");
    try w.writeAll("</p></header>\n");
    if (saved) try statusMessage(w, "Saved.");
    try w.writeAll("<div class=\"tabs\"><span class=\"tab active\">Read</span><a class=\"tab\" href=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("/edit\">Edit</a></div>\n");
    try w.writeAll("<div class=\"prose\">");
    if (note.body.len == 0) {
        try w.writeAll("<p class=\"muted\">This note is empty.</p>");
    } else {
        try markdown.render(w, note.body);
    }
    try w.writeAll("</div>\n");
    try attachmentSection(w, ctx, note.id, attachments, true);
    try w.writeAll("<div class=\"reader-actions\">");
    try w.writeAll("<a class=\"button primary\" href=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("/edit\">Edit note</a>");
    try w.writeAll("<form method=\"post\" action=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("/pin\">");
    try csrfField(w, ctx.csrf);
    try versionField(w, note.version);
    if (note.is_pinned) {
        try w.writeAll("<button type=\"submit\" class=\"secondary\">Unpin</button>");
    } else {
        try w.writeAll("<button type=\"submit\" class=\"secondary\">Pin</button>");
    }
    try w.writeAll("</form><a class=\"button danger-link\" href=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("/delete\">Delete…</a></div>\n");
    try w.writeAll("</article>\n</div>\n");
    try documentEnd(w);
}

fn attachmentSection(w: *Writer, ctx: Ctx, note_id: i64, attachments: []const db.Attachment, include_delete: bool) !void {
    if (attachments.len == 0) return;
    try w.writeAll("<section class=\"files\"><p class=\"eyebrow\">Attachments</p><ul class=\"file-list\">\n");
    for (attachments) |file| {
        try w.writeAll("<li class=\"file-row\"><a class=\"file-link\" href=\"/files/");
        try w.print("{d}", .{file.id});
        try w.writeAll("/");
        try util.urlEncode(w, file.filename);
        try w.writeAll("\">");
        try util.escapeHtml(w, file.filename);
        try w.writeAll("</a><span class=\"muted small\">");
        try formatBytes(w, file.size);
        try w.writeAll(" · ");
        try util.escapeHtml(w, file.mime);
        try w.writeAll("</span>");
        if (include_delete) {
            try w.writeAll("<form method=\"post\" action=\"/notes/");
            try w.print("{d}/files/{d}/delete", .{ note_id, file.id });
            try w.writeAll("\">");
            try csrfField(w, ctx.csrf);
            try w.writeAll("<button type=\"submit\" class=\"link danger-text\">Remove</button></form>");
        }
        try w.writeAll("</li>\n");
    }
    try w.writeAll("</ul></section>\n");
}

fn formatBytes(w: *Writer, bytes: i64) !void {
    if (bytes < 1024) {
        try w.print("{d} B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        try w.print("{d}.{d} KiB", .{ @divTrunc(bytes, 1024), @divTrunc(@mod(bytes, 1024) * 10, 1024) });
    } else {
        try w.print("{d}.{d} MiB", .{ @divTrunc(bytes, 1024 * 1024), @divTrunc(@mod(bytes, 1024 * 1024) * 10, 1024 * 1024) });
    }
}

pub const EditorArgs = struct {
    note: ?db.Note,
    sidebar_rows: []const db.NoteRow,
    saved: bool,
    notice: ?[]const u8 = null,
    attachments: []const db.Attachment = &.{},
    draft_title: []const u8 = "",
    draft_body: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub fn editor(w: *Writer, ctx: Ctx, args: EditorArgs) !void {
    const is_new = args.note == null;
    const title = if (is_new) "New note" else displayTitle(args.note.?.title);
    try documentStart(w, title, ctx, null);
    if (!is_new) try w.writeAll("<div class=\"layout\">\n");
    if (!is_new) try sidebar(w, args.sidebar_rows, args.note.?.id);
    try w.writeAll("<article class=\"editor\">\n");
    if (is_new) {
        try w.writeAll("<header class=\"editor-head\"><p class=\"eyebrow\">Compose</p><h1>New note</h1><p class=\"meta\">Markdown: headings, lists, code, links, images.</p></header>\n");
    } else {
        try w.writeAll("<header class=\"editor-head\"><p class=\"eyebrow\">Editing · version ");
        try w.print("{d}", .{args.note.?.version});
        try w.writeAll("</p><h1>");
        try util.escapeHtml(w, displayTitle(args.note.?.title));
        try w.writeAll("</h1><p class=\"meta\">Updated ");
        try util.formatDateFull(w, args.note.?.updated_at);
        try w.writeAll("</p></header>\n");
        try w.writeAll("<div class=\"tabs\"><span class=\"tab active\">Write</span><a class=\"tab\" href=\"/notes/");
        try w.print("{d}", .{args.note.?.id});
        try w.writeAll("\">Read</a></div>\n");
    }
    if (args.saved) try statusMessage(w, "Saved.");
    if (args.notice) |message| try statusMessage(w, message);
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
    try w.writeAll("\" autocomplete=\"off\" placeholder=\"A clear title\">");
    try w.writeAll("<label for=\"body\">Note</label><textarea id=\"body\" name=\"body\" rows=\"18\" spellcheck=\"true\" placeholder=\"Write in Markdown. **bold**, *italic*, `code`, # heading, - list, > quote, [link](https://…), ![image](/files/…)\">");
    try util.escapeHtml(w, value_body);
    try w.writeAll("</textarea><div class=\"actions\"><button type=\"submit\" class=\"primary\">Save note</button><a class=\"button secondary\" href=\"");
    if (is_new) {
        try w.writeAll("/notes");
    } else {
        try w.print("/notes/{d}", .{args.note.?.id});
    }
    try w.writeAll("\">Cancel</a></div></form>\n");
    if (is_new) try w.writeAll("<p class=\"muted small\">Save the note once to attach files. Images can be uploaded from the editor, not pasted, because pasting needs JavaScript.</p>\n");

    try w.writeAll("<details class=\"help\"><summary>Markdown cheatsheet</summary><div class=\"help-grid\"><pre># Heading\n**bold** *italic* ~~strike~~\n`inline code`\n- list item\n1. ordered item\n> quote\n[link](https://example.com)\n![alt](/files/ID/name.png)\n```zig\ncode block\n```</pre><p class=\"muted small\">Raw HTML is escaped, never executed. Links allow http, https, mailto, and same-site paths. Images must use a same-site path such as /files/.</p></div></details>\n");

    if (!is_new) {
        try w.writeAll("<section class=\"upload\"><p class=\"eyebrow\">Add a file</p>");
        try w.writeAll("<p class=\"muted small\">Images, PDF, text, and archives up to 8 MiB. The Markdown link is appended to the end of this note. Pasting an image needs JavaScript, so use the file picker instead.</p>");
        try w.writeAll("<form method=\"post\" enctype=\"multipart/form-data\" action=\"/notes/");
        try w.print("{d}", .{args.note.?.id});
        try w.writeAll("/files\">");
        try csrfField(w, ctx.csrf);
        try w.writeAll("<input id=\"file\" type=\"file\" name=\"file\" required><button type=\"submit\" class=\"secondary\">Upload and link</button></form></section>\n");
        try attachmentSection(w, ctx, args.note.?.id, args.attachments, true);
    }

    if (!is_new) {
        try w.writeAll("<div class=\"secondary-actions\"><form method=\"post\" action=\"/notes/");
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
    try w.writeAll("<div class=\"narrow\"><p class=\"eyebrow\">Conflict</p><h1>Two versions, no silent overwrite</h1>\n");
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
    try w.writeAll("</textarea><p class=\"muted small\">Saving this form explicitly replaces the latest version shown below. Copy and merge manually first if you prefer.</p><button type=\"submit\" class=\"danger\">Save my draft over the latest version</button></form></section>\n");

    try w.writeAll("<section class=\"latest\"><h2>Latest saved version (version ");
    try w.print("{d}", .{latest.version});
    try w.writeAll(")</h2><label for=\"latest-title\">Title</label><input id=\"latest-title\" type=\"text\" value=\"");
    try util.escapeHtml(w, latest.title);
    try w.writeAll("\" readonly><label for=\"latest-body\">Note</label><textarea id=\"latest-body\" rows=\"12\" readonly>");
    try util.escapeHtml(w, latest.body);
    try w.writeAll("</textarea><p><a href=\"/notes/");
    try w.print("{d}", .{latest.id});
    try w.writeAll("\">Open the latest version</a> · <a href=\"/notes\">All notes</a></p></section></div>\n");
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
    try hero(w, "Trash", "Deleted notes", "Deleted notes stay recoverable until an operator removes them.");
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
    try w.writeAll("<div class=\"narrow\"><p class=\"eyebrow\">Delete</p><h1>Delete this note?</h1>\n<p>“");
    try util.escapeHtml(w, displayTitle(note.title));
    try w.writeAll("” will move to Trash and can be restored later.</p>\n<form class=\"stack\" method=\"post\" action=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("/delete\">");
    try csrfField(w, ctx.csrf);
    try versionField(w, note.version);
    try w.writeAll("<div class=\"actions\"><button type=\"submit\" class=\"danger\">Delete note</button><a class=\"button secondary\" href=\"/notes/");
    try w.print("{d}", .{note.id});
    try w.writeAll("\">Cancel</a></div></form></div>\n");
    try documentEnd(w);
}

pub fn settings(w: *Writer, ctx: Ctx, saved: bool) !void {
    try documentStart(w, "Themes", ctx, null);
    try hero(w, "Appearance", "Choose a mood", "Twelve themes, stored on the server. Every device sees the same choice, and it costs no JavaScript.");
    if (saved) try statusMessage(w, "Theme updated.");
    try w.writeAll("<form method=\"post\" action=\"/settings/theme\" class=\"theme-form\">");
    try csrfField(w, ctx.csrf);
    try w.writeAll("<div class=\"theme-grid\">\n");
    const current = themeId(ctx);
    for (themes.all) |theme| {
        try w.writeAll("<label class=\"theme-card\"><input type=\"radio\" name=\"theme\" value=\"");
        try w.writeAll(theme.id);
        try w.writeAll("\"");
        if (std.mem.eql(u8, theme.id, current)) try w.writeAll(" checked");
        try w.writeAll("><span class=\"swatch\" data-theme=\"");
        try w.writeAll(theme.id);
        try w.writeAll("\" aria-hidden=\"true\"><i></i><i></i><i></i></span><span class=\"theme-name\">");
        try util.escapeHtml(w, theme.name);
        try w.writeAll("</span><span class=\"theme-mode\">");
        try util.escapeHtml(w, theme.mode);
        try w.writeAll("</span></label>\n");
    }
    try w.writeAll("</div><div class=\"actions\"><button type=\"submit\" class=\"primary\">Apply theme</button></div></form>\n");
    try w.writeAll("<p class=\"muted small\">Theme preference lives in your SQLite file, so backups carry it too.</p>\n");
    try documentEnd(w);
}

pub fn errorPage(w: *Writer, ctx: Ctx, heading: []const u8, message: []const u8) !void {
    try documentStart(w, heading, ctx, null);
    try w.writeAll("<div class=\"narrow\"><p class=\"eyebrow\">Error</p><h1>");
    try util.escapeHtml(w, heading);
    try w.writeAll("</h1>\n");
    try errorBanner(w, message);
    try w.writeAll("<p><a class=\"button secondary\" href=\"/notes\">Back to notes</a></p></div>\n");
    try documentEnd(w);
}

pub fn simpleMessage(w: *Writer, ctx: Ctx, heading: []const u8, message: []const u8) !void {
    try documentStart(w, heading, ctx, null);
    try w.writeAll("<div class=\"narrow\"><p class=\"eyebrow\">Done</p><h1>");
    try util.escapeHtml(w, heading);
    try w.writeAll("</h1>\n");
    try statusMessage(w, message);
    try w.writeAll("<p><a class=\"button secondary\" href=\"/notes\">Back to notes</a></p></div>\n");
    try documentEnd(w);
}
