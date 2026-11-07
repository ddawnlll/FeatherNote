//! FeatherNote: a single-owner, server-rendered notes service.
const std = @import("std");
const http = std.http;
const net = std.Io.net;
const db = @import("db.zig");
const auth = @import("auth.zig");
const util = @import("http_util.zig");
const views = @import("views.zig");
const assets = @import("assets");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const css = assets.css;
const csp = "default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

const Config = struct {
    db_path: []const u8,
    listen: []const u8,
    secure_cookies: bool = true,
    trust_proxy: bool = false,
    session_days: u32 = 30,
    allow_public_bind: bool = false,

    fn cookieName(self: Config) []const u8 {
        return if (self.secure_cookies) "__Host-feather_session" else "feather_session";
    }
};

const App = struct {
    gpa: Allocator,
    io: Io,
    config: Config,
    database: *db.Db,
    limiter: auth.LoginLimiter = .{},
    active_connections: std.atomic.Value(u32) = .init(0),
    max_connections: u32 = 64,
};

const Response = struct {
    status: http.Status,
    body: []const u8 = "",
    content_type: []const u8 = "text/html; charset=utf-8",
    location: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    retry_after: ?[]const u8 = null,
    cache: []const u8 = "no-store",
};

const Auth = struct {
    csrf: []const u8,
    token_hash: [64]u8,
};

const Query = struct {
    q: ?[]const u8 = null,
    page: usize = 1,
    saved: bool = false,
};

const BodyError = error{ TooLarge, ExpectationFailed, ReadFailed } || Allocator.Error;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const command = it.next() orelse "serve";

    if (std.mem.eql(u8, command, "serve")) {
        const cfg = parseConfig(init.environ_map.*, &it);
        try serve(gpa, io, cfg);
    } else if (std.mem.eql(u8, command, "admin")) {
        const sub = it.next() orelse {
            std.debug.print("usage: feathernote admin set-password|backup|integrity [--db PATH] [--out PATH]\n", .{});
            std.process.exit(2);
        };
        if (std.mem.eql(u8, sub, "set-password")) {
            const cfg = parseConfig(init.environ_map.*, &it);
            try adminSetPassword(gpa, io, cfg.db_path);
        } else if (std.mem.eql(u8, sub, "backup")) {
            var out: ?[]const u8 = null;
            const cfg = parseConfigWithOut(init.environ_map.*, &it, &out);
            try adminBackup(gpa, io, cfg.db_path, out orelse {
                std.debug.print("admin backup requires --out PATH\n", .{});
                std.process.exit(2);
            });
        } else if (std.mem.eql(u8, sub, "integrity")) {
            const cfg = parseConfig(init.environ_map.*, &it);
            try adminIntegrity(gpa, io, cfg.db_path);
        } else {
            std.debug.print("unknown admin command: {s}\n", .{sub});
            std.process.exit(2);
        }
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        printUsage();
    } else {
        std.debug.print("unknown command: {s}\n", .{command});
        printUsage();
        std.process.exit(2);
    }
}

fn printUsage() void {
    std.debug.print(
        \\FeatherNote
        \\  feathernote serve [--db PATH] [--listen 127.0.0.1:8080]
        \\                   [--insecure-cookies] [--trust-proxy] [--allow-public-bind]
        \\  feathernote admin set-password [--db PATH]   (reads one line from stdin)
        \\  feathernote admin backup [--db PATH] --out PATH
        \\  feathernote admin integrity [--db PATH]
        \\
    , .{});
}

fn parseConfig(env: std.process.Environ.Map, it: *std.process.Args.Iterator) Config {
    var out_ignored: ?[]const u8 = null;
    return parseConfigWithOut(env, it, &out_ignored);
}

fn parseConfigWithOut(env: std.process.Environ.Map, it: *std.process.Args.Iterator, out: *?[]const u8) Config {
    var cfg = Config{
        .db_path = env.get("FEATHERNOTE_DB") orelse "data/feathernote.db",
        .listen = env.get("FEATHERNOTE_LISTEN") orelse "127.0.0.1:8080",
        .secure_cookies = !std.mem.eql(u8, env.get("FEATHERNOTE_INSECURE_COOKIES") orelse "0", "1"),
        .trust_proxy = std.mem.eql(u8, env.get("FEATHERNOTE_TRUST_PROXY") orelse "0", "1"),
        .allow_public_bind = std.mem.eql(u8, env.get("FEATHERNOTE_ALLOW_PUBLIC_BIND") orelse "0", "1"),
    };
    if (env.get("FEATHERNOTE_SESSION_DAYS")) |days| {
        cfg.session_days = std.fmt.parseInt(u32, days, 10) catch cfg.session_days;
        if (cfg.session_days == 0 or cfg.session_days > 365) cfg.session_days = 30;
    }
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--db")) {
            cfg.db_path = it.next() orelse fatal("--db requires a path");
        } else if (std.mem.eql(u8, arg, "--listen")) {
            cfg.listen = it.next() orelse fatal("--listen requires host:port");
        } else if (std.mem.eql(u8, arg, "--out")) {
            out.* = it.next() orelse fatal("--out requires a path");
        } else if (std.mem.eql(u8, arg, "--insecure-cookies")) {
            cfg.secure_cookies = false;
        } else if (std.mem.eql(u8, arg, "--trust-proxy")) {
            cfg.trust_proxy = true;
        } else if (std.mem.eql(u8, arg, "--allow-public-bind")) {
            cfg.allow_public_bind = true;
        } else {
            std.debug.print("unknown option: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    return cfg;
}

fn fatal(comptime message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(2);
}

fn ensureParent(io: Io, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn nowSeconds(io: Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn serve(gpa: Allocator, io: Io, cfg: Config) !void {
    try ensureParent(io, cfg.db_path);
    const database = db.Db.open(gpa, io, cfg.db_path) catch |err| {
        std.log.err("cannot open database {s}: {t}", .{ cfg.db_path, err });
        return err;
    };
    defer database.close(gpa);

    var app = App{ .gpa = gpa, .io = io, .config = cfg, .database = database };
    const address = parseListen(cfg.listen) catch {
        std.log.err("invalid --listen value: {s}", .{cfg.listen});
        return error.InvalidListen;
    };
    if (!cfg.allow_public_bind and !isLoopbackText(cfg.listen)) {
        std.log.err("refusing non-loopback bind {s}; use --allow-public-bind only if a firewall protects it", .{cfg.listen});
        return error.PublicBindRefused;
    }

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.log.info("FeatherNote listening on {s} (db={s}, sqlite={s})", .{ cfg.listen, cfg.db_path, database.version() });

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                std.log.warn("accept failed: {t}", .{err});
                continue;
            },
        };
        if (app.active_connections.fetchAdd(1, .monotonic) >= app.max_connections) {
            _ = app.active_connections.fetchSub(1, .monotonic);
            stream.close(io);
            continue;
        }
        group.async(io, handleConnection, .{ &app, stream });
    }
}

fn parseListen(text: []const u8) !net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidListen;
    if (colon == 0 or colon + 1 >= text.len) return error.InvalidListen;
    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    const port_text = text[colon + 1 ..];
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidListen;
    return net.IpAddress.parse(host, port);
}

fn isLoopbackText(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "127.") or
        std.mem.startsWith(u8, text, "[::1]") or
        std.mem.startsWith(u8, text, "::1:");
}

fn handleConnection(app: *App, stream: net.Stream) Io.Cancelable!void {
    const io = app.io;
    defer _ = app.active_connections.fetchSub(1, .monotonic);
    defer stream.close(io);
    var recv_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var server = http.Server.init(&conn_reader.interface, &conn_writer.interface);

    var peer_buffer: [80]u8 = undefined;
    var peer_address = stream.socket.address;
    peer_address.setPort(0);
    const peer = std.fmt.bufPrint(&peer_buffer, "{f}", .{peer_address}) catch "unknown";

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.warn("closing connection after bad request head: {t}", .{err});
                return;
            },
        };
        var arena_state = std.heap.ArenaAllocator.init(app.gpa);
        defer arena_state.deinit();
        handleRequest(app, &request, arena_state.allocator(), peer) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.err("request failed: {t}", .{err});
            return;
        };
    }
}

fn handleRequest(
    app: *App,
    request: *http.Server.Request,
    arena: Allocator,
    peer: []const u8,
) !void {
    const target = try arena.dupe(u8, request.head.target);
    const method = request.head.method;

    var cookie_buffer: [512]u8 = undefined;
    var content_type_buffer: [128]u8 = undefined;
    var xreal_buffer: [80]u8 = undefined;
    const cookie = util.findHeaderCookie(request, app.config.cookieName(), &cookie_buffer);
    const content_type = util.findHeader(request, "content-type", &content_type_buffer);
    const x_real_ip = util.findHeader(request, "x-real-ip", &xreal_buffer);
    const client_ip = if (app.config.trust_proxy) (x_real_ip orelse peer) else peer;

    const response = dispatch(app, request, arena, target, method, cookie, content_type, client_ip) catch |err| blk: {
        if (err == error.Canceled) return err;
        std.log.err("dispatch error for {s}: {t}", .{ requestPath(target), err });
        break :blk try htmlError(arena, .{ .authed = false }, .internal_server_error, "Internal error", "The request could not be completed. No changes were made.");
    };
    try sendResponse(app, request, response);
}

fn requestPath(target: []const u8) []const u8 {
    const q = std.mem.findScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

fn sendResponse(app: *App, request: *http.Server.Request, response: Response) !void {
    var headers: [12]http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "content-type", .value = response.content_type };
    n += 1;
    headers[n] = .{ .name = "cache-control", .value = response.cache };
    n += 1;
    headers[n] = .{ .name = "content-security-policy", .value = csp };
    n += 1;
    headers[n] = .{ .name = "x-content-type-options", .value = "nosniff" };
    n += 1;
    headers[n] = .{ .name = "referrer-policy", .value = "no-referrer" };
    n += 1;
    headers[n] = .{ .name = "x-frame-options", .value = "DENY" };
    n += 1;
    headers[n] = .{ .name = "permissions-policy", .value = "geolocation=(), camera=(), microphone=()" };
    n += 1;
    if (app.config.secure_cookies) {
        headers[n] = .{ .name = "strict-transport-security", .value = "max-age=31536000; includeSubDomains" };
        n += 1;
    }
    if (response.location) |location| {
        headers[n] = .{ .name = "location", .value = location };
        n += 1;
    }
    if (response.cookie) |cookie| {
        headers[n] = .{ .name = "set-cookie", .value = cookie };
        n += 1;
    }
    if (response.allow) |allow| {
        headers[n] = .{ .name = "allow", .value = allow };
        n += 1;
    }
    if (response.retry_after) |retry| {
        headers[n] = .{ .name = "retry-after", .value = retry };
        n += 1;
    }
    try request.respond(response.body, .{
        .status = response.status,
        .extra_headers = headers[0..n],
    });
}

fn isReadMethod(method: http.Method) bool {
    return method == .GET or method == .HEAD;
}

fn parseQuery(arena: Allocator, raw: ?[]const u8) !Query {
    var query = Query{};
    const text = raw orelse return query;
    var it = std.mem.splitScalar(u8, text, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        const name = try util.percentDecode(arena, pair[0..eq], true);
        const value = try util.percentDecode(arena, pair[eq + 1 ..], true);
        if (std.mem.eql(u8, name, "q")) {
            if (query.q != null) return error.DuplicateField;
            if (value.len > 0) {
                try util.validateSearch(value);
                query.q = value;
            }
        } else if (std.mem.eql(u8, name, "page")) {
            query.page = util.parsePage(value);
        } else if (std.mem.eql(u8, name, "saved")) {
            query.saved = std.mem.eql(u8, value, "1");
        }
    }
    return query;
}

fn readBody(request: *http.Server.Request, arena: Allocator) BodyError![]const u8 {
    if (request.head.content_length) |len| {
        if (len > util.max_request_body) return error.TooLarge;
    }
    var body_buffer: [16 * 1024]u8 = undefined;
    const reader = request.readerExpectContinue(&body_buffer) catch |err| switch (err) {
        error.HttpExpectationFailed => return error.ExpectationFailed,
        error.WriteFailed => return error.ReadFailed,
    };
    return reader.allocRemaining(arena, .limited(util.max_request_body)) catch |err| switch (err) {
        error.StreamTooLong => error.TooLarge,
        else => error.ReadFailed,
    };
}

fn isFormContentType(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    const semi = std.mem.findScalar(u8, ct, ';') orelse ct.len;
    const media = std.mem.trim(u8, ct[0..semi], " \t");
    return std.ascii.eqlIgnoreCase(media, "application/x-www-form-urlencoded");
}

fn authenticate(app: *App, arena: Allocator, cookie: ?[]const u8, now: i64) !?Auth {
    const token = cookie orelse return null;
    const hash = auth.tokenHashFromHex(token) orelse return null;
    const session = try app.database.findSession(arena, &hash, now) orelse return null;
    return .{ .csrf = session.csrf_token, .token_hash = hash };
}

fn csrfOk(expected: []const u8, form: util.Form) bool {
    const supplied = form.get("csrf") orelse return false;
    return auth.csrfMatches(expected, supplied);
}

fn formVersion(form: util.Form) !i64 {
    const raw = form.get("version") orelse return error.InvalidForm;
    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidForm;
    if (value < 1) return error.InvalidForm;
    return value;
}

fn sessionCookie(arena: Allocator, cfg: Config, token: []const u8, max_age: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age={d}{s}", .{
        cfg.cookieName(),
        token,
        max_age,
        if (cfg.secure_cookies) "; Secure" else "",
    });
}

fn htmlError(arena: Allocator, ctx: views.Ctx, status: http.Status, heading: []const u8, message: []const u8) !Response {
    var aw = std.Io.Writer.Allocating.init(arena);
    try views.errorPage(&aw.writer, ctx, heading, message);
    return .{ .status = status, .body = aw.written() };
}

fn dispatch(
    app: *App,
    request: *http.Server.Request,
    arena: Allocator,
    target: []const u8,
    method: http.Method,
    cookie: ?[]const u8,
    content_type: ?[]const u8,
    client_ip: []const u8,
) !Response {
    const qmark = std.mem.findScalar(u8, target, '?');
    const path = if (qmark) |i| target[0..i] else target;
    const raw_query: ?[]const u8 = if (qmark) |i| target[i + 1 ..] else null;
    if (std.mem.findScalar(u8, path, '#')) |_| {
        return htmlError(arena, .{ .authed = false }, .bad_request, "Bad request", "Malformed request target.");
    }

    if (std.mem.eql(u8, path, "/healthz")) {
        if (!isReadMethod(method)) return methodNotAllowed(arena, .{ .authed = false }, "GET, HEAD");
        return .{ .status = .ok, .body = "ok\n", .content_type = "text/plain; charset=utf-8" };
    }
    if (std.mem.eql(u8, path, "/style.css")) {
        if (!isReadMethod(method)) return methodNotAllowed(arena, .{ .authed = false }, "GET, HEAD");
        return .{ .status = .ok, .body = css, .content_type = "text/css; charset=utf-8", .cache = "public, max-age=86400" };
    }
    if (std.mem.eql(u8, path, "/login")) {
        if (isReadMethod(method)) {
            const no_owner = !(app.database.hasOwner(arena) catch false);
            return loginPage(arena, .ok, null, no_owner, false);
        }
        if (method != .POST) return methodNotAllowed(arena, .{ .authed = false }, "GET, HEAD, POST");
        return handleLogin(app, request, arena, content_type, client_ip);
    }
    if (std.mem.eql(u8, path, "/favicon.ico")) {
        return htmlError(arena, .{ .authed = false }, .not_found, "Not found", "No such resource.");
    }

    const now = nowSeconds(app.io);
    const maybe_auth = authenticate(app, arena, cookie, now) catch |err| {
        std.log.warn("session lookup failed: {t}", .{err});
        return htmlError(arena, .{ .authed = false }, .internal_server_error, "Internal error", "Session storage is unavailable.");
    };
    if (maybe_auth == null) {
        if (isReadMethod(method)) {
            return .{ .status = .see_other, .location = "/login" };
        }
        return htmlError(arena, .{ .authed = false }, .unauthorized, "Log in required", "Your session is missing or expired. Log in and try again.");
    }
    const a = maybe_auth.?;
    const ctx = views.Ctx{ .authed = true, .csrf = a.csrf };

    if (std.mem.eql(u8, path, "/logout")) {
        if (method != .POST) return methodNotAllowed(arena, ctx, "POST");
        const body = readBody(request, arena) catch return bodyErrorResponse(arena, ctx, request, content_type);
        const form = util.parseForm(arena, body) catch {
            return htmlError(arena, ctx, .bad_request, "Bad request", "Malformed form data.");
        };
        if (!csrfOk(a.csrf, form)) return csrfFailure(arena, ctx);
        try app.database.revokeSession(&a.token_hash);
        const expired = try sessionCookie(arena, app.config, "", 0);
        return .{ .status = .see_other, .location = "/login", .cookie = expired };
    }

    if (std.mem.eql(u8, path, "/")) {
        if (!isReadMethod(method)) return methodNotAllowed(arena, ctx, "GET, HEAD");
        return .{ .status = .see_other, .location = "/notes" };
    }

    const query = parseQuery(arena, raw_query) catch |err| switch (err) {
        error.DuplicateField => return htmlError(arena, ctx, .bad_request, "Bad request", "The query string contains duplicate parameters."),
        error.FieldTooLong => return htmlError(arena, ctx, .bad_request, "Search too long", "Search queries are limited to 100 characters."),
        error.InvalidEncoding => return htmlError(arena, ctx, .bad_request, "Bad request", "The query string is not valid UTF-8."),
        else => return err,
    };

    if (std.mem.eql(u8, path, "/notes")) {
        if (isReadMethod(method)) return handleList(app, arena, ctx, query);
        if (method != .POST) return methodNotAllowed(arena, ctx, "GET, HEAD, POST");
        return handleCreate(app, request, arena, ctx, content_type);
    }
    if (std.mem.eql(u8, path, "/notes/new")) {
        if (!isReadMethod(method)) return methodNotAllowed(arena, ctx, "GET, HEAD");
        var aw = std.Io.Writer.Allocating.init(arena);
        try views.newNote(&aw.writer, ctx, "", "", null);
        return .{ .status = .ok, .body = aw.written() };
    }
    if (std.mem.eql(u8, path, "/trash")) {
        if (!isReadMethod(method)) return methodNotAllowed(arena, ctx, "GET, HEAD");
        const rows = try app.database.listTrash(arena, (query.page - 1) * util.page_size, util.page_size);
        const total = try app.database.countTrash();
        var aw = std.Io.Writer.Allocating.init(arena);
        try views.trash(&aw.writer, ctx, rows, total, query.page);
        return .{ .status = .ok, .body = aw.written() };
    }

    if (std.mem.startsWith(u8, path, "/notes/")) {
        const rest = path["/notes/".len..];
        var segments = std.mem.splitScalar(u8, rest, '/');
        const id_text = segments.next() orelse return notFound(arena, ctx);
        const action = segments.next();
        if (segments.next() != null) return notFound(arena, ctx);
        const id = std.fmt.parseInt(i64, id_text, 10) catch return notFound(arena, ctx);
        if (id < 1) return notFound(arena, ctx);
        const act = action orelse "";
        if (std.mem.eql(u8, act, "")) {
            if (isReadMethod(method)) return handleEditor(app, arena, ctx, id, query.saved);
            if (method == .POST) return handleUpdate(app, request, arena, ctx, id, content_type);
            return methodNotAllowed(arena, ctx, "GET, HEAD, POST");
        } else if (std.mem.eql(u8, act, "pin")) {
            if (method != .POST) return methodNotAllowed(arena, ctx, "POST");
            return handlePin(app, request, arena, ctx, id, content_type);
        } else if (std.mem.eql(u8, act, "delete")) {
            if (isReadMethod(method)) return handleDeleteConfirm(app, arena, ctx, id);
            if (method == .POST) return handleDelete(app, request, arena, ctx, id, content_type);
            return methodNotAllowed(arena, ctx, "GET, HEAD, POST");
        } else if (std.mem.eql(u8, act, "restore")) {
            if (method != .POST) return methodNotAllowed(arena, ctx, "POST");
            return handleRestore(app, request, arena, ctx, id, content_type);
        }
        return notFound(arena, ctx);
    }

    return notFound(arena, ctx);
}

fn methodNotAllowed(arena: Allocator, ctx: views.Ctx, allow: []const u8) !Response {
    var aw = std.Io.Writer.Allocating.init(arena);
    try views.errorPage(&aw.writer, ctx, "Method not allowed", "That HTTP method is not supported for this route.");
    return .{ .status = .method_not_allowed, .body = aw.written(), .allow = allow };
}

fn notFound(arena: Allocator, ctx: views.Ctx) !Response {
    return htmlError(arena, ctx, .not_found, "Not found", "The requested note or page does not exist.");
}

fn csrfFailure(arena: Allocator, ctx: views.Ctx) !Response {
    return htmlError(arena, ctx, .forbidden, "Request rejected", "The form security token was missing or invalid. Reload the page and try again.");
}

fn bodyErrorResponse(arena: Allocator, ctx: views.Ctx, request: *http.Server.Request, content_type: ?[]const u8) Response {
    _ = content_type;
    _ = request;
    return htmlError(arena, ctx, .payload_too_large, "Request too large", "The submitted form exceeded the 320 KiB request limit.") catch .{
        .status = .payload_too_large,
        .body = "<!doctype html><title>Request too large</title><h1>Request too large</h1>",
    };
}

fn loginPage(arena: Allocator, status: http.Status, error_message: ?[]const u8, no_owner: bool, changed: bool) !Response {
    var aw = std.Io.Writer.Allocating.init(arena);
    try views.login(&aw.writer, error_message, no_owner, changed);
    return .{ .status = status, .body = aw.written() };
}

fn handleLogin(app: *App, request: *http.Server.Request, arena: Allocator, content_type: ?[]const u8, client_ip: []const u8) !Response {
    if (!isFormContentType(content_type)) {
        return loginPage(arena, .unsupported_media_type, "Use the HTML login form.", false, false);
    }
    const body = readBody(request, arena) catch return loginPage(arena, .payload_too_large, "Login request is too large.", false, false);
    const form = util.parseForm(arena, body) catch {
        return loginPage(arena, .bad_request, "Malformed login form.", false, false);
    };
    const password = form.get("password") orelse {
        return loginPage(arena, .bad_request, "Password is required.", false, false);
    };
    if (password.len > auth.max_password_len) {
        return loginPage(arena, .bad_request, "Password is too long.", false, false);
    }

    const now = nowSeconds(app.io);
    const decision = app.limiter.begin(app.io, client_ip, now);
    if (decision.limited) {
        return loginPage(arena, .too_many_requests, "Too many failed login attempts. Wait 15 minutes and try again.", false, false);
    }
    if (decision.busy) {
        return loginPage(arena, .too_many_requests, "Another login is being processed. Try again shortly.", false, false);
    }

    const stored = app.database.ownerHash(arena) catch |err| {
        app.limiter.finish(app.io, decision.ticket.?, false, now);
        return err;
    };
    const hash = stored orelse {
        app.limiter.finish(app.io, decision.ticket.?, false, now);
        return loginPage(arena, .unauthorized, "No owner password is configured.", true, false);
    };

    const ok = auth.verifyPassword(app.gpa, app.io, hash, password);
    app.limiter.finish(app.io, decision.ticket.?, ok, now);
    if (!ok) {
        return loginPage(arena, .unauthorized, "Incorrect password.", false, false);
    }

    const session = auth.newSession(app.io);
    const expires = now + @as(i64, app.config.session_days) * 86400;
    try app.database.createSession(&session.token_hash_hex, &session.csrf_hex, now, expires);
    const cookie = try sessionCookie(arena, app.config, &session.token_hex, app.config.session_days * 86400);
    return .{ .status = .see_other, .location = "/notes", .cookie = cookie };
}

fn handleList(app: *App, arena: Allocator, ctx: views.Ctx, query: Query) !Response {
    const total = try app.database.countNotes(query.q);
    const offset = (query.page - 1) * util.page_size;
    const rows = try app.database.listNotes(arena, query.q, offset, util.page_size);
    var aw = std.Io.Writer.Allocating.init(arena);
    try views.noteList(&aw.writer, ctx, rows, total, query.page, query.q);
    return .{ .status = .ok, .body = aw.written() };
}

fn handleEditor(app: *App, arena: Allocator, ctx: views.Ctx, id: i64, saved: bool) !Response {
    const note = try app.database.getNote(arena, id, false) orelse {
        const trashed = try app.database.getNote(arena, id, true);
        if (trashed != null) return .{ .status = .see_other, .location = "/trash" };
        return notFound(arena, ctx);
    };
    const sidebar_rows = try app.database.listNotes(arena, null, 0, 30);
    var aw = std.Io.Writer.Allocating.init(arena);
    try views.editor(&aw.writer, ctx, .{ .note = note, .sidebar_rows = sidebar_rows, .saved = saved });
    return .{ .status = .ok, .body = aw.written() };
}

fn handleCreate(app: *App, request: *http.Server.Request, arena: Allocator, ctx: views.Ctx, content_type: ?[]const u8) !Response {
    if (!isFormContentType(content_type)) {
        return htmlError(arena, ctx, .unsupported_media_type, "Unsupported form", "Submit the HTML note form.");
    }
    const body = readBody(request, arena) catch return bodyErrorResponse(arena, ctx, request, content_type);
    const form = util.parseForm(arena, body) catch {
        return htmlError(arena, ctx, .bad_request, "Malformed form", "The note form could not be parsed.");
    };
    if (!csrfOk(ctx.csrf, form)) return csrfFailure(arena, ctx);
    const title = form.get("title") orelse "";
    const note_body = form.get("body") orelse "";
    validateDraft(title, note_body) catch |err| {
        var aw = std.Io.Writer.Allocating.init(arena);
        try views.newNote(&aw.writer, ctx, title, note_body, validationMessage(err));
        return .{ .status = .bad_request, .body = aw.written() };
    };
    const id = try app.database.createNote(arena, title, note_body, nowSeconds(app.io));
    const location = try std.fmt.allocPrint(arena, "/notes/{d}?saved=1", .{id});
    return .{ .status = .see_other, .location = location };
}

fn validateDraft(title: []const u8, body: []const u8) !void {
    try util.validateTitle(title);
    try util.validateBody(body);
}

fn validationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FieldTooLong => "The title or note is too long. Titles are limited to 200 characters and notes to 256 KiB.",
        error.InvalidEncoding => "The submitted text is not valid UTF-8.",
        else => "The note could not be validated.",
    };
}

fn handleUpdate(app: *App, request: *http.Server.Request, arena: Allocator, ctx: views.Ctx, id: i64, content_type: ?[]const u8) !Response {
    if (!isFormContentType(content_type)) {
        return htmlError(arena, ctx, .unsupported_media_type, "Unsupported form", "Submit the HTML note form.");
    }
    const note = try app.database.getNote(arena, id, false) orelse {
        const trashed = try app.database.getNote(arena, id, true);
        if (trashed != null) return htmlError(arena, ctx, .conflict, "Note is in Trash", "Restore the note before editing it.");
        return notFound(arena, ctx);
    };
    const body = readBody(request, arena) catch return bodyErrorResponse(arena, ctx, request, content_type);
    const form = util.parseForm(arena, body) catch {
        return htmlError(arena, ctx, .bad_request, "Malformed form", "The note form could not be parsed.");
    };
    if (!csrfOk(ctx.csrf, form)) return csrfFailure(arena, ctx);
    const title = form.get("title") orelse "";
    const note_body = form.get("body") orelse "";
    const version = formVersion(form) catch {
        return renderEditorError(app, arena, ctx, note, title, note_body, "The form version was missing or invalid. Reload and try again.");
    };
    validateDraft(title, note_body) catch |err| {
        return renderEditorError(app, arena, ctx, note, title, note_body, validationMessage(err));
    };

    const result = try app.database.updateNote(id, version, title, note_body, nowSeconds(app.io));
    switch (result) {
        .ok => {
            const location = try std.fmt.allocPrint(arena, "/notes/{d}?saved=1", .{id});
            return .{ .status = .see_other, .location = location };
        },
        .conflict => {
            const latest = (try app.database.getNote(arena, id, false)) orelse return notFound(arena, ctx);
            var aw = std.Io.Writer.Allocating.init(arena);
            try views.conflict(&aw.writer, ctx, latest, title, note_body);
            return .{ .status = .conflict, .body = aw.written() };
        },
        .deleted => return htmlError(arena, ctx, .conflict, "Note is in Trash", "This note was moved to Trash. Restore it before saving."),
        .not_found => return notFound(arena, ctx),
    }
}

fn renderEditorError(app: *App, arena: Allocator, ctx: views.Ctx, note: db.Note, title: []const u8, body: []const u8, message: []const u8) !Response {
    const sidebar_rows = try app.database.listNotes(arena, null, 0, 30);
    var aw = std.Io.Writer.Allocating.init(arena);
    try views.editor(&aw.writer, ctx, .{
        .note = note,
        .sidebar_rows = sidebar_rows,
        .saved = false,
        .draft_title = title,
        .draft_body = body,
        .error_message = message,
    });
    return .{ .status = .bad_request, .body = aw.written() };
}

fn handlePin(app: *App, request: *http.Server.Request, arena: Allocator, ctx: views.Ctx, id: i64, content_type: ?[]const u8) !Response {
    if (!isFormContentType(content_type)) return htmlError(arena, ctx, .unsupported_media_type, "Unsupported form", "Submit the HTML form.");
    const body = readBody(request, arena) catch return bodyErrorResponse(arena, ctx, request, content_type);
    const form = util.parseForm(arena, body) catch return htmlError(arena, ctx, .bad_request, "Malformed form", "The form could not be parsed.");
    if (!csrfOk(ctx.csrf, form)) return csrfFailure(arena, ctx);
    const version = formVersion(form) catch return htmlError(arena, ctx, .bad_request, "Bad request", "Missing or invalid note version.");
    const result = try app.database.togglePin(id, version, nowSeconds(app.io));
    return switch (result) {
        .ok => .{ .status = .see_other, .location = try std.fmt.allocPrint(arena, "/notes/{d}", .{id}) },
        .conflict => htmlError(arena, ctx, .conflict, "Conflict", "The note changed elsewhere. Reload it and try again."),
        .deleted => htmlError(arena, ctx, .conflict, "Note is in Trash", "Restore the note before pinning it."),
        .not_found => notFound(arena, ctx),
    };
}

fn handleDeleteConfirm(app: *App, arena: Allocator, ctx: views.Ctx, id: i64) !Response {
    const note = try app.database.getNote(arena, id, false) orelse return notFound(arena, ctx);
    var aw = std.Io.Writer.Allocating.init(arena);
    try views.deleteConfirm(&aw.writer, ctx, note);
    return .{ .status = .ok, .body = aw.written() };
}

fn handleDelete(app: *App, request: *http.Server.Request, arena: Allocator, ctx: views.Ctx, id: i64, content_type: ?[]const u8) !Response {
    if (!isFormContentType(content_type)) return htmlError(arena, ctx, .unsupported_media_type, "Unsupported form", "Submit the HTML form.");
    const body = readBody(request, arena) catch return bodyErrorResponse(arena, ctx, request, content_type);
    const form = util.parseForm(arena, body) catch return htmlError(arena, ctx, .bad_request, "Malformed form", "The form could not be parsed.");
    if (!csrfOk(ctx.csrf, form)) return csrfFailure(arena, ctx);
    const version = formVersion(form) catch return htmlError(arena, ctx, .bad_request, "Bad request", "Missing or invalid note version.");
    const result = try app.database.softDelete(id, version, nowSeconds(app.io));
    return switch (result) {
        .ok => .{ .status = .see_other, .location = "/notes" },
        .conflict => htmlError(arena, ctx, .conflict, "Conflict", "The note changed elsewhere. Reload it and try again."),
        .deleted => htmlError(arena, ctx, .conflict, "Already in Trash", "This note is already in Trash."),
        .not_found => notFound(arena, ctx),
    };
}

fn handleRestore(app: *App, request: *http.Server.Request, arena: Allocator, ctx: views.Ctx, id: i64, content_type: ?[]const u8) !Response {
    if (!isFormContentType(content_type)) return htmlError(arena, ctx, .unsupported_media_type, "Unsupported form", "Submit the HTML form.");
    const body = readBody(request, arena) catch return bodyErrorResponse(arena, ctx, request, content_type);
    const form = util.parseForm(arena, body) catch return htmlError(arena, ctx, .bad_request, "Malformed form", "The form could not be parsed.");
    if (!csrfOk(ctx.csrf, form)) return csrfFailure(arena, ctx);
    const version = formVersion(form) catch return htmlError(arena, ctx, .bad_request, "Bad request", "Missing or invalid note version.");
    const result = try app.database.restore(id, version, nowSeconds(app.io));
    return switch (result) {
        .ok => .{ .status = .see_other, .location = "/trash" },
        .conflict => htmlError(arena, ctx, .conflict, "Conflict", "The note changed elsewhere. Reload Trash and try again."),
        .deleted => htmlError(arena, ctx, .conflict, "Conflict", "The note changed elsewhere. Reload Trash and try again."),
        .not_found => notFound(arena, ctx),
    };
}

// ---- admin commands ----

fn adminSetPassword(gpa: Allocator, io: Io, db_path: []const u8) !void {
    try ensureParent(io, db_path);
    var in_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    const raw = stdin_reader.interface.allocRemaining(gpa, .limited(2048)) catch {
        std.debug.print("could not read password from stdin\n", .{});
        return error.PasswordReadFailed;
    };
    defer gpa.free(raw);
    const password = std.mem.trimEnd(u8, raw, "\r\n");
    if (std.mem.findScalar(u8, password, '\n') != null or std.mem.findScalar(u8, password, '\r') != null) {
        std.debug.print("password must be exactly one line\n", .{});
        return error.PasswordTooLong;
    }
    auth.validatePassword(password) catch |err| {
        std.debug.print("password rejected: {t}. Use at least {d} UTF-8 bytes and at most {d}.\n", .{ err, auth.min_password_len, auth.max_password_len });
        return err;
    };
    const database = try db.Db.open(gpa, io, db_path);
    defer database.close(gpa);
    var hash_buffer: [256]u8 = undefined;
    const hash = try auth.hashPassword(gpa, io, password, &hash_buffer);
    try database.setOwnerPassword(hash, nowSeconds(io));
    std.debug.print("Owner password set. All existing sessions were revoked.\n", .{});
}

fn adminBackup(gpa: Allocator, io: Io, db_path: []const u8, out_path: []const u8) !void {
    try ensureParent(io, out_path);
    db.backupTo(gpa, io, db_path, out_path) catch |err| {
        std.debug.print("backup failed: {t}\n", .{err});
        return err;
    };
    std.debug.print("Backup written to {s}; PRAGMA integrity_check = ok.\n", .{out_path});
}

fn adminIntegrity(gpa: Allocator, io: Io, db_path: []const u8) !void {
    const database = db.Db.open(gpa, io, db_path) catch |err| {
        std.debug.print("cannot open database: {t}\n", .{err});
        return err;
    };
    defer database.close(gpa);
    const ok = try database.integrityCheck();
    if (ok) {
        std.debug.print("integrity_check: ok\n", .{});
    } else {
        std.debug.print("integrity_check: FAILED\n", .{});
        return error.IntegrityCheckFailed;
    }
}

test {
    _ = db;
    _ = auth;
    _ = util;
    _ = views;
}
