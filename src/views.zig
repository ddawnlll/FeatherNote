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
    theme: []const u8 = "paper",
};

fn themeId(ctx: Ctx) []const u8 {
    return themes.canonical(ctx.theme);
}

const logo_svg =
    \\<svg class="logo" viewBox="0 0 32 32" aria-hidden="true" focusable="false">
    \\<path d="M25 4C17 5 10 10 8 18l-2 6 4-2c2 2 5 3 8 2 6-2 9-9 7-20Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/>
    \\<path d="M9 25c3-7 8-11 14-14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
    \\</svg>
;

fn documentStart(w: *Writer, title: []const u8, ctx: Ctx, search: ?[]const u8) !void {
    try w.writeAll("<!doctype html>\n<html lang=\"en\" data-theme=\"");
    try w.writeAll(themeId(ctx));
    try w.writeAll("\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try util.escapeHtml(w, title);
    try w.writeAll(" · FeatherNote</title>\n<link rel=\"stylesheet\" href=\"/style.css\">\n</head>\n<body>\n");
    try w.writeAll("<a class=\"skip\" href=\"#main\">Skip to content</a>\n<header class=\"top\"><div class=\"top-inner\"><a class=\"brand\" href=\"/notes\">");
    try w.writeAll(logo_svg);
    try w.writeAll("<span>FeatherNote</span></a>");
    if (ctx.authed) {
        try w.writeAll("<form class=\"search\" method=\"get\" action=\"/notes\" role=\"search\"><input id=\"q\" type=\"search\" name=\"q\" maxlength=\"100\" placeholder=\"Search notes\" aria-label=\"Search notes\"");
        if (search) |q| {
            try w.writeAll(" value=\"");
            try util.escapeHtml(w, q);
            try w.writeAll("\"");
        }
        try w.writeAll("><button type=\"submit\" class=\"button secondary\">Search</button></form>");
        try w.writeAll("<nav class=\"nav\" aria-label=\"Main\"><a href=\"/notes/new\">New note</a><a href=\"/trash\">Trash</a><a href=\"/settings\">Themes</a><form method=\"post\" action=\"/logout\">");
        try csrfField(w, ctx.csrf);
        try w.writeAll("<button class=\"link\" type=\"submit\">Log out</button></form></nav>");
    }
    try w.writeAll("</div></header>\n<main id=\"main\">\n");
}

fn documentEnd(w: *Writer) !void {
    try w.writeAll("</main>\n<footer class=\"foot\"><span>FeatherNote</span><span>No scripts. No tracking.</span></footer>\n</body>\n</html>\n");
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

fn pageHead(w: *Writer, title: []const u8, meta: []const u8) !void {
    try w.writeAll("<section class=\"page-head\"><h1>");
    try util.escapeHtml(w, title);
    try w.writeAll("</h1><p class=\"page-meta\">");
    try util.escapeHtml(w, meta);
    try w.writeAll("</p></section>\n");
}

pub fn login(w: *Writer, ctx: Ctx, error_message: ?[]const u8, no_owner: bool, password_changed: bool) !void {
    try documentStart(w, "Log in", ctx, null);
    try w.writeAll("<div class=\"auth-shell\"><section class=\"auth-intro\"><h1>Private notes, kept on your own machine.</h1><p class=\"lede\">One owner, one SQLite file, no scripts. Everything you write stays here.</p></section><section class=\"auth-form\"><h2>Unlock</h2>\n");
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
    try documentStart(w, if (searching) "Search" else "Notes", ctx, q);
    if (searching) {
        var lede: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&lede, "{d} result{s} for “{s}”", .{
            total,
            if (total == 1) "" else "s",
            q.?,
        }) catch "Matching notes";
        try pageHead(w, "Search", text);
        try w.writeAll("<p class=\"page-note\"><a href=\"/notes\">Clear search</a></p>\n");
    } else {
        var lede: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&lede, "{d} note{s}, pinned first, then most recent", .{
            total,
            if (total == 1) "" else "s",
        }) catch "Your library";
        try pageHead(w, "Notes", text);
    }

    if (rows.len == 0) {
        if (searching) {
            try w.writeAll("<p class=\"empty\">No notes matched. Try a different word, or <a href=\"/notes\">view all notes</a>.</p>\n");
        } else {
            try w.writeAll("<p class=\"empty\">No notes yet. <a href=\"/notes/new\">Create the first one</a>.</p>\n");
        }
    } else {
        try w.writeAll("<ul class=\"index\">\n");
        for (rows) |row| {
            try w.writeAll("<li><a class=\"index-row\" href=\"/notes/");
            try w.print("{d}", .{row.id});
            try w.writeAll("\"><time class=\"index-date\" datetime=\"");
            try util.formatDateShort(w, row.updated_at);
            try w.writeAll("\">");
            try util.formatDateShort(w, row.updated_at);
            try w.writeAll("</time><span class=\"index-title\">");
            try util.escapeHtml(w, displayTitle(row.title));
            try w.writeAll("</span><span class=\"index-flag\">");
            if (row.is_pinned) try w.writeAll("Pinned");
            try w.writeAll("</span></a></li>\n");
        }
        try w.writeAll("</ul>\n");
        try pagination(w, q, page, total);
    }
    try documentEnd(w);
}

fn recentRail(w: *Writer, rows: []const db.NoteRow, current_id: ?i64) !void {
    if (rows.len == 0) return;
    try w.writeAll("<h2 class=\"rail-title\">Recent</h2><ul class=\"rail-list\">\n");
    for (rows) |row| {
        try w.writeAll("<li");
        if (current_id != null and row.id == current_id.?) try w.writeAll(" class=\"current\"");
        try w.writeAll("><a href=\"/notes/");
        try w.print("{d}", .{row.id});
        try w.writeAll("\">");
        try util.escapeHtml(w, displayTitle(row.title));
        try w.writeAll("</a></li>\n");
    }
    try w.writeAll("</ul>\n");
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
    try w.writeAll("<div class=\"sheet\"><aside class=\"rail\"><dl class=\"meta-list\"><dt>Updated</dt><dd>");
    try util.formatDateFull(w, note.updated_at);
    try w.writeAll("</dd><dt>Version</dt><dd>");
    try w.print("{d}", .{note.version});
    try w.writeAll("</dd>");
    if (note.is_pinned) try w.writeAll("<dt>Status</dt><dd>Pinned</dd>");
    try w.writeAll("</dl><div class=\"rail-actions\"><a class=\"button primary\" href=\"/notes/");
    try w.print("{d}/edit", .{note.id});
    try w.writeAll("\">Edit note</a><form method=\"post\" action=\"/notes/");
    try w.print("{d}/pin", .{note.id});
    try w.writeAll("\">");
    try csrfField(w, ctx.csrf);
    try versionField(w, note.version);
    if (note.is_pinned) {
        try w.writeAll("<button type=\"submit\" class=\"button secondary\">Unpin</button>");
    } else {
        try w.writeAll("<button type=\"submit\" class=\"button secondary\">Pin</button>");
    }
    try w.writeAll("</form><a class=\"text-link danger-text\" href=\"/notes/");
    try w.print("{d}/delete", .{note.id});
    try w.writeAll("\">Delete</a></div>");
    try recentRail(w, sidebar_rows, note.id);
    try w.writeAll("</aside><article class=\"sheet-main\"><header class=\"sheet-head\"><h1>");
    try util.escapeHtml(w, displayTitle(note.title));
    try w.writeAll("</h1><div class=\"tabs\"><span class=\"tab active\">Read</span><a class=\"tab\" href=\"/notes/");
    try w.print("{d}/edit", .{note.id});
    try w.writeAll("\">Edit</a></div></header>\n");
    if (saved) try statusMessage(w, "Saved.");
    try w.writeAll("<div class=\"prose\">");
    if (note.body.len == 0) {
        try w.writeAll("<p class=\"muted\">This note is empty.</p>");
    } else {
        try markdown.render(w, note.body);
    }
    try w.writeAll("</div>\n");
    try attachmentSection(w, ctx, note.id, attachments, false);
    try w.writeAll("</article></div>\n");
    try documentEnd(w);
}

fn attachmentSection(w: *Writer, ctx: Ctx, note_id: i64, attachments: []const db.Attachment, include_delete: bool) !void {
    if (attachments.len == 0) return;
    try w.writeAll("<section class=\"files\"><h2 class=\"rail-title\">Attachments</h2><ul class=\"file-list\">\n");
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
    if (is_new) {
        try w.writeAll("<article class=\"sheet sheet-single\"><div class=\"sheet-main\">");
    } else {
        try w.writeAll("<div class=\"sheet\"><aside class=\"rail\"><dl class=\"meta-list\"><dt>Updated</dt><dd>");
        try util.formatDateFull(w, args.note.?.updated_at);
        try w.writeAll("</dd><dt>Version</dt><dd>");
        try w.print("{d}", .{args.note.?.version});
        try w.writeAll("</dd></dl>");
        try recentRail(w, args.sidebar_rows, args.note.?.id);
        try w.writeAll("</aside><div class=\"sheet-main\">");
    }
    try w.writeAll("<header class=\"sheet-head\"><h1>");
    if (is_new) {
        try w.writeAll("New note");
    } else {
        try util.escapeHtml(w, displayTitle(args.note.?.title));
    }
    try w.writeAll("</h1>");
    if (!is_new) {
        try w.writeAll("<div class=\"tabs\"><span class=\"tab active\">Write</span><a class=\"tab\" href=\"/notes/");
        try w.print("{d}", .{args.note.?.id});
        try w.writeAll("\">Read</a></div>");
    }
    try w.writeAll("</header>\n");
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
    try w.writeAll("<label for=\"body\">Note</label><textarea id=\"body\" name=\"body\" rows=\"18\" spellcheck=\"true\" placeholder=\"Write in Markdown. # heading, **bold**, - list, [link](https://…), ![image](/files/…)\">");
    try util.escapeHtml(w, value_body);
    try w.writeAll("</textarea><div class=\"actions\"><button type=\"submit\" class=\"primary\">Save note</button><a class=\"button secondary\" href=\"");
    if (is_new) {
        try w.writeAll("/notes");
    } else {
        try w.print("/notes/{d}", .{args.note.?.id});
    }
    try w.writeAll("\">Cancel</a></div></form>\n");
    if (is_new) try w.writeAll("<p class=\"muted small\">Save once to attach files. Images are uploaded, not pasted, because paste needs JavaScript.</p>\n");

    try w.writeAll("<details class=\"help\"><summary>Markdown cheatsheet</summary><pre># Heading\n**bold** *italic* ~~strike~~\n`inline code`\n- list item\n1. ordered item\n> quote\n[link](https://example.com)\n![alt](/files/ID/name.png)\n```zig\ncode block\n```</pre><p class=\"muted small\">Raw HTML is escaped, never executed. Links allow http, https, mailto, and same-site paths. Images must use a same-site path such as /files/.</p></details>\n");

    if (!is_new) {
        try w.writeAll("<section class=\"upload\"><h2 class=\"rail-title\">Add a file</h2>");
        try w.writeAll("<p class=\"muted small\">Images, PDF, text, and archives up to 8 MiB. The Markdown link is appended to the end of this note. Pasting an image needs JavaScript, so use the file picker.</p>");
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
            try w.writeAll("<button type=\"submit\" class=\"button secondary\">Unpin</button>");
        } else {
            try w.writeAll("<button type=\"submit\" class=\"button secondary\">Pin</button>");
        }
        try w.writeAll("</form><a class=\"text-link danger-text\" href=\"/notes/");
        try w.print("{d}/delete", .{args.note.?.id});
        try w.writeAll("\">Delete note</a></div>\n");
    }
    try w.writeAll("</div>");
    if (is_new) try w.writeAll("</article>");
    try w.writeAll("\n");
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
    try pageHead(w, "Edit conflict", "This note changed in another tab. Your draft is preserved.");
    try errorBanner(w, "Nothing was overwritten. Compare both versions before choosing.");
    try w.writeAll("<div class=\"diff-grid\"><section class=\"diff-col\"><h2>Your draft</h2>");
    try w.writeAll("<form method=\"post\" action=\"/notes/");
    try w.print("{d}", .{latest.id});
    try w.writeAll("\">");
    try csrfField(w, ctx.csrf);
    try versionField(w, latest.version);
    try w.writeAll("<label for=\"draft-title\">Title</label><input id=\"draft-title\" name=\"title\" type=\"text\" maxlength=\"200\" value=\"");
    try util.escapeHtml(w, draft_title);
    try w.writeAll("\"><label for=\"draft-body\">Draft</label><textarea id=\"draft-body\" name=\"body\" rows=\"14\">");
    try util.escapeHtml(w, draft_body);
    try w.writeAll("</textarea><p class=\"muted small\">Saving replaces the latest version with this draft.</p><button type=\"submit\" class=\"danger\">Save draft over latest</button></form></section>");

    try w.writeAll("<section class=\"diff-col\"><h2>Latest saved version ");
    try w.print("{d}", .{latest.version});
    try w.writeAll("</h2><label for=\"latest-title\">Title</label><input id=\"latest-title\" type=\"text\" value=\"");
    try util.escapeHtml(w, latest.title);
    try w.writeAll("\" readonly><label for=\"latest-body\">Note</label><textarea id=\"latest-body\" rows=\"14\" readonly>");
    try util.escapeHtml(w, latest.body);
    try w.writeAll("</textarea><p><a class=\"text-link\" href=\"/notes/");
    try w.print("{d}", .{latest.id});
    try w.writeAll("\">Open the latest version</a></p></section></div>\n");
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
    var meta: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&meta, "{d} deleted note{s}", .{
        total,
        if (total == 1) "" else "s",
    }) catch "Deleted notes";
    try pageHead(w, "Trash", text);
    if (rows.len == 0) {
        try w.writeAll("<p class=\"empty\">Trash is empty.</p>\n");
    } else {
        try w.writeAll("<ul class=\"index\">\n");
        for (rows) |row| {
            try w.writeAll("<li class=\"index-static\"><time class=\"index-date\" datetime=\"");
            try util.formatDateShort(w, row.deleted_at);
            try w.writeAll("\">");
            try util.formatDateShort(w, row.deleted_at);
            try w.writeAll("</time><span class=\"index-title\">");
            try util.escapeHtml(w, displayTitle(row.title));
            try w.writeAll("</span><form method=\"post\" action=\"/notes/");
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
    try w.writeAll("<div class=\"narrow\"><h1>Delete this note?</h1>\n<p>“");
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
    try pageHead(w, "Themes", "Twelve palettes, stored in your database, applied on the server.");
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
    try w.writeAll("<p class=\"muted small\">The choice lives in the owner row, so backups carry it too.</p>\n");
    try documentEnd(w);
}

pub fn errorPage(w: *Writer, ctx: Ctx, heading: []const u8, message: []const u8) !void {
    try documentStart(w, heading, ctx, null);
    try w.writeAll("<div class=\"narrow\"><h1>");
    try util.escapeHtml(w, heading);
    try w.writeAll("</h1>\n");
    try errorBanner(w, message);
    try w.writeAll("<p><a class=\"button secondary\" href=\"/notes\">Back to notes</a></p></div>\n");
    try documentEnd(w);
}

pub fn simpleMessage(w: *Writer, ctx: Ctx, heading: []const u8, message: []const u8) !void {
    try documentStart(w, heading, ctx, null);
    try w.writeAll("<div class=\"narrow\"><h1>");
    try util.escapeHtml(w, heading);
    try w.writeAll("</h1>\n");
    try statusMessage(w, message);
    try w.writeAll("<p><a class=\"button secondary\" href=\"/notes\">Back to notes</a></p></div>\n");
    try documentEnd(w);
}
