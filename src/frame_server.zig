//! The HTTP side of showing a panel frame in a browser.
//!
//! Shared by the simulator and by the daemon's optional preview, which differ
//! only in where the frame comes from — one synthesizes it, the other shows what
//! is on the glass — and so each keeps its own accept loop. The daemon's loop
//! answers the API as well (`api.zig`), which is what `receiveRequest` is for.
//!
//! Deliberately small: one request per connection, no keep-alive, no
//! concurrency. A page that reloads one image a second needs nothing more, and
//! in the daemon it has to stay cheap enough to be beside the point.

const std = @import("std");
const net = std.Io.net;
const bmp = @import("bmp.zig");
const http_request = @import("http_request.zig");

const log = std.log.scoped(.preview);

/// How long a client gets to send its request.
///
/// Short on purpose. A stalled peer costs at most this much, and the page asks
/// for a frame once a second, so nothing legitimate comes near it.
pub const io_timeout_ms = 2000;

/// After a failed `accept`, wait this long before trying again.
///
/// Without it, a persistent failure — descriptor exhaustion is the realistic one
/// — turns the loop into a busy spin competing with the render loop for the CPU.
pub const accept_backoff_ms = 250;

/// Accept a connection.
///
/// Returns null when nothing usable arrived, having already waited out the
/// backoff; the caller should simply go round again. `running` is checked by the
/// caller, not here.
///
/// Null at once when the task was cancelled: that is the caller being stopped,
/// not a failure, and the backoff would only hold its shutdown up.
///
/// The deadline that keeps a stalled peer from taking the loop down lives in
/// `readRequest`, not here — see the note there for why it cannot be a socket
/// option.
pub fn accept(server: *net.Server, io: std.Io) ?net.Stream {
    return server.accept(io) catch |err| {
        if (err == error.Canceled) return null;
        log.debug("Preview accept failed: {t}", .{err});
        std.Io.sleep(io, .fromMilliseconds(accept_backoff_ms), .awake) catch {};
        return null;
    };
}

/// The viewer page, with `{{LABEL}}` still in it. Render it with `renderPage`.
const page_template = @embedFile("viewer_page.html");

const label_token = "{{LABEL}}";

/// Longest label `renderPage` will take. Enough for the two in use, with room.
pub const label_max = 48;

/// Buffer size `renderPage` needs.
pub const page_buffer_size = blk: {
    // Counting occurrences at comptime walks the whole template.
    @setEvalBranchQuota(page_template.len * 4);
    break :blk page_template.len + label_max * std.mem.count(u8, page_template, label_token);
};

/// The viewer page with `label` substituted for every `{{LABEL}}`.
///
/// A template rather than two files: the daemon's preview and the simulator show
/// the same panel through the same markup, and only the caption differs — one is
/// the glass, the other is made up. Getting that label wrong makes a live reading
/// look like a mock-up, which is worse than no caption at all.
pub fn renderPage(dest: []u8, label: []const u8) []const u8 {
    std.debug.assert(label.len <= label_max);
    std.debug.assert(dest.len >= page_buffer_size);

    _ = std.mem.replace(u8, page_template, label_token, label, dest);
    return dest[0..std.mem.replacementSize(u8, page_template, label_token, label)];
}

pub const Request = enum {
    /// `GET /` — the page itself.
    index,
    /// `GET /frame.bmp` — the current frame.
    frame,
    other,
};

/// Read the request line, ignoring headers.
///
/// Through `receiveTimeout` rather than a `Stream.Reader`, because the reader
/// has no deadline and the obvious way to give it one is a trap: `SO_RCVTIMEO`
/// makes a stalled read report `EAGAIN`, and `Io.Threaded` classifies `EAGAIN`
/// on a blocking socket as a programmer bug — `std.debug.panic` in a Debug
/// build, `error.Unexpected` in a release one. A deadline that crashes the
/// daemon is worse than the hang it replaces, so the runtime supplies it here
/// instead.
///
/// One receive, not a loop: the request line arrives in the first segment of
/// any real client. A peer that dribbles its line one byte at a time gets a
/// short read and a 404 rather than being waited on, which is the right answer
/// for a preview server that owes nobody anything.
pub fn readRequest(stream: net.Stream, io: std.Io, buf: []u8) ?Request {
    const message = stream.socket.receiveTimeout(io, buf, .{
        .duration = .{ .raw = .fromMilliseconds(io_timeout_ms), .clock = .awake },
    }) catch |err| {
        log.debug("Preview request read failed: {t}", .{err});
        return null;
    };

    const line = message.data;
    if (std.mem.startsWith(u8, line, "GET /frame.bmp")) return .frame;
    if (std.mem.startsWith(u8, line, "GET / ")) return .index;
    return .other;
}

/// What `receiveRequest` makes of a connection.
pub const Received = union(enum) {
    request: http_request.Request,
    /// Answer with this status, then close.
    refuse: []const u8,
    /// Nothing worth answering: the peer went away or never finished.
    drop,
};

/// Read a whole request, body included, for the API.
///
/// Unlike `readRequest` this has to loop: a body can arrive in a segment of
/// its own, and a client sending `Expect: 100-continue` waits to be told
/// before it sends one at all. The loop runs against a single deadline for the
/// whole request, not one per receive, so a peer dribbling a byte at a time
/// still costs no more than `io_timeout_ms`.
///
/// The request borrows from `buf`, which bounds headers and body together.
pub fn receiveRequest(stream: net.Stream, io: std.Io, buf: []u8, max_body: usize) Received {
    return receiveRequestWithin(stream, io, buf, max_body, io_timeout_ms);
}

/// `receiveRequest` with the deadline given, so that a test of what a stalled
/// peer costs does not have to wait the real one out.
fn receiveRequestWithin(stream: net.Stream, io: std.Io, buf: []u8, max_body: usize, timeout_ms: i64) Received {
    const deadline: std.Io.Timeout = (std.Io.Timeout{
        .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake },
    }).toDeadline(io);

    var len: usize = 0;
    var continued = false;

    while (true) {
        if (len == buf.len) return .{ .refuse = "413 Content Too Large" };

        const message = stream.socket.receiveTimeout(io, buf[len..], deadline) catch |err| {
            log.debug("API request read failed: {t}", .{err});
            return .drop;
        };
        if (message.data.len == 0) return .drop;
        len += message.data.len;

        switch (http_request.parse(buf[0..len], max_body)) {
            .complete => |request| return .{ .request = request },
            .need_headers => {},
            .need_body => |wait| if (wait.expect_continue and !continued) {
                continued = true;
                writeAll(stream, io, "HTTP/1.1 100 Continue\r\n\r\n");
            },
            .bad_request => return .{ .refuse = "400 Bad Request" },
            .length_required => return .{ .refuse = "411 Length Required" },
            .too_large => return .{ .refuse = "413 Content Too Large" },
        }
    }
}

fn writeAll(stream: net.Stream, io: std.Io, bytes: []const u8) void {
    var out_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch return;
}

/// Send a complete response. Errors are dropped: a client that goes away
/// mid-write is ordinary, and there is nothing useful to do about it.
pub fn respond(
    stream: net.Stream,
    io: std.Io,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) void {
    respondWith(stream, io, status, "", content_type, body);
}

/// `respond` with extra header lines, each ending in CRLF.
pub fn respondWith(
    stream: net.Stream,
    io: std.Io,
    status: []const u8,
    extra_headers: []const u8,
    content_type: []const u8,
    body: []const u8,
) void {
    var out_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const w = &writer.interface;

    w.print("HTTP/1.1 {s}\r\n" ++
        "{s}" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "Connection: close\r\n\r\n", .{ status, extra_headers, content_type, body.len }) catch return;
    w.writeAll(body) catch return;
    w.flush() catch return;
}

pub fn respondPage(stream: net.Stream, io: std.Io, label: []const u8) void {
    var buf: [page_buffer_size]u8 = undefined;
    respond(stream, io, "200 OK", "text/html; charset=utf-8", renderPage(&buf, label));
}

pub fn respondNotFound(stream: net.Stream, io: std.Io) void {
    respond(stream, io, "404 Not Found", "text/plain", "not found\n");
}

/// Send a packed 1-bit frame as a BMP, serialised into `scratch`.
pub fn respondFrame(
    stream: net.Stream,
    io: std.Io,
    scratch: []u8,
    packed_frame: []const u8,
    width: u32,
    height: u32,
) void {
    const bytes = bmp.serialize(scratch, packed_frame, width, height) catch {
        respond(stream, io, "500 Internal Server Error", "text/plain", "serialize failed\n");
        return;
    };
    respond(stream, io, "200 OK", "image/bmp", bytes);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "renderPage substitutes every occurrence of the label" {
    var buf: [page_buffer_size]u8 = undefined;
    const rendered = renderPage(&buf, "Live panel");

    // The token appears in the title and the caption; neither may survive, or a
    // live reading is captioned as something it is not.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, rendered, label_token));
    try testing.expectEqual(
        std.mem.count(u8, page_template, label_token),
        std.mem.count(u8, rendered, "Live panel"),
    );
    try testing.expect(std.mem.indexOf(u8, rendered, "<title>") != null);
}

test "the buffer is large enough for the longest label" {
    var buf: [page_buffer_size]u8 = undefined;
    const label: [label_max]u8 = @splat('x');
    const rendered = renderPage(&buf, &label);
    try testing.expect(rendered.len <= buf.len);
}

/// Longest a test waits on the other side before failing instead of hanging.
const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } };

/// A TCP connection over loopback. `server` is the end `accept` hands the
/// daemon; `client` is the peer, which the test plays.
const Connection = struct {
    listener: net.Server,
    server: net.Stream,
    client: net.Stream,
    client_open: bool = true,
    server_open: bool = true,

    fn open() !Connection {
        const io = testing.io;
        const any_port: net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try any_port.listen(io, .{});
        errdefer listener.deinit(io);

        const client = try net.IpAddress.connect(&listener.socket.address, io, .{ .mode = .stream });
        errdefer client.close(io);
        const server = try listener.accept(io);

        return .{ .listener = listener, .server = server, .client = client };
    }

    fn close(self: *Connection) void {
        self.hangUp();
        self.finish();
        self.listener.deinit(testing.io);
    }

    /// The client goes away.
    fn hangUp(self: *Connection) void {
        if (self.client_open) self.client.close(testing.io);
        self.client_open = false;
    }

    /// The server closes its end, as an accept loop does once it has answered.
    fn finish(self: *Connection) void {
        if (self.server_open) self.server.close(testing.io);
        self.server_open = false;
    }

    fn send(self: *Connection, bytes: []const u8) !void {
        var out: [64]u8 = undefined;
        var writer = self.client.writer(testing.io, &out);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    /// Everything the server sent before it closed its end.
    fn readAll(self: *Connection, buf: []u8) ![]const u8 {
        var len: usize = 0;
        while (len < buf.len) {
            const message = try self.client.socket.receiveTimeout(testing.io, buf[len..], patience);
            if (message.data.len == 0) break;
            len += message.data.len;
        }
        return buf[0..len];
    }
};

fn expectRequest(received: Received) !http_request.Request {
    return switch (received) {
        .request => |request| request,
        else => |other| {
            std.debug.print("expected a request, got {t}\n", .{other});
            return error.TestUnexpectedResult;
        },
    };
}

test "a request that arrives whole is read as it stands" {
    var conn = try Connection.open();
    defer conn.close();

    try conn.send("POST /api/notice HTTP/1.1\r\nAuthorization: Bearer s3cret\r\nContent-Length: 2\r\n\r\nhi");

    var buf: [1024]u8 = undefined;
    const request = try expectRequest(receiveRequest(conn.server, testing.io, &buf, 512));
    try testing.expectEqual(http_request.Method.post, request.method);
    try testing.expectEqualStrings("/api/notice", request.path);
    try testing.expectEqualStrings("Bearer s3cret", request.authorization.?);
    try testing.expectEqualStrings("hi", request.body);
}

test "a client holding its body back is told to send it, once, and then heard" {
    var conn = try Connection.open();
    defer conn.close();

    const Client = struct {
        told: bool = false,

        fn run(self: *@This(), c: *Connection) void {
            c.send("POST /api/notice HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 15\r\n\r\n") catch return;
            // Nothing more until the server asks, so it has to go round again
            // for the body whatever the timing.
            var answer: [64]u8 = undefined;
            const message = c.client.socket.receiveTimeout(testing.io, &answer, patience) catch return;
            self.told = std.mem.eql(u8, message.data, "HTTP/1.1 100 Continue\r\n\r\n");
            c.send("Backup finished") catch return;
        }
    };
    var client: Client = .{};
    const thread = try std.Thread.spawn(.{}, Client.run, .{ &client, &conn });

    var buf: [1024]u8 = undefined;
    const received = receiveRequest(conn.server, testing.io, &buf, 512);
    thread.join();

    try testing.expect(client.told);
    try testing.expectEqualStrings("Backup finished", (try expectRequest(received)).body);
}

test "a request that arrives in pieces is put back together" {
    var conn = try Connection.open();
    defer conn.close();

    const Client = struct {
        fn run(c: *Connection) void {
            for ([_][]const u8{ "GET /api/st", "atus HTTP/1.1\r\nHo", "st: pi\r\n\r\n" }) |piece| {
                c.send(piece) catch return;
                std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch return;
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&conn});

    var buf: [1024]u8 = undefined;
    const received = receiveRequest(conn.server, testing.io, &buf, 512);
    thread.join();

    try testing.expectEqualStrings("/api/status", (try expectRequest(received)).path);
}

test "a peer that hangs up mid-request is dropped" {
    var conn = try Connection.open();
    defer conn.close();

    try conn.send("GET /api/status HTTP/1.1\r\nHost:");
    conn.hangUp();

    var buf: [1024]u8 = undefined;
    try testing.expect(receiveRequest(conn.server, testing.io, &buf, 512) == .drop);
}

test "a peer that dribbles costs one deadline, not one per byte" {
    var conn = try Connection.open();
    defer conn.close();

    // A byte every 20 ms for two seconds: each arrives well inside the
    // deadline, so one that restarted with every receive would never fire.
    const Client = struct {
        stop: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This(), c: *Connection) void {
            for (0..100) |_| {
                if (self.stop.load(.acquire)) return;
                c.send("X") catch return;
                std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch return;
            }
        }
    };
    var client: Client = .{};
    const thread = try std.Thread.spawn(.{}, Client.run, .{ &client, &conn });

    const started = std.Io.Timestamp.now(testing.io, .awake);
    var buf: [1024]u8 = undefined;
    const received = receiveRequestWithin(conn.server, testing.io, &buf, 512, 150);
    const took_ms = started.untilNow(testing.io, .awake).toMilliseconds();

    client.stop.store(true, .release);
    thread.join();

    try testing.expect(received == .drop);
    try testing.expect(took_ms >= 100);
    try testing.expect(took_ms < 1500);
}

test "what cannot be taken is refused with the status that says why" {
    const cases = [_]struct { request: []const u8, status: []const u8 }{
        .{ .request = "GET\r\n\r\n", .status = "400 Bad Request" },
        .{ .request = "POST /api/notice HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", .status = "411 Length Required" },
        // A body over the limit, refused on its length before any of it is read.
        .{ .request = "POST /api/notice HTTP/1.1\r\nContent-Length: 513\r\n\r\n", .status = "413 Content Too Large" },
        // Headers that have not ended by the time the buffer is full.
        .{ .request = "GET / HTTP/1.1\r\nX: " ++ @as([300]u8, @splat('a')), .status = "413 Content Too Large" },
    };

    for (cases) |case| {
        var conn = try Connection.open();
        defer conn.close();
        try conn.send(case.request);

        var buf: [256]u8 = undefined;
        switch (receiveRequest(conn.server, testing.io, &buf, 512)) {
            .refuse => |status| try testing.expectEqualStrings(case.status, status),
            else => |other| {
                std.debug.print("expected {s}, got {t}\n", .{ case.status, other });
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "a response is whole, and says the connection ends with it" {
    var conn = try Connection.open();
    defer conn.close();

    respondWith(conn.server, testing.io, "405 Method Not Allowed", "Allow: GET\r\n", "application/json", "{\"error\":\"method not allowed\"}");
    conn.finish();

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("HTTP/1.1 405 Method Not Allowed\r\n" ++
        "Allow: GET\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 30\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "Connection: close\r\n\r\n" ++
        "{\"error\":\"method not allowed\"}", try conn.readAll(&buf));
}

test "a frame is served as a BMP of the length its headers give" {
    var conn = try Connection.open();
    defer conn.close();

    const width = 16;
    const height = 2;
    const frame = [_]u8{ 0xFF, 0x00, 0xAA, 0x55 };
    var scratch: [bmp.byteSize(width, height)]u8 = undefined;
    respondFrame(conn.server, testing.io, &scratch, &frame, width, height);
    conn.finish();

    var buf: [512]u8 = undefined;
    const response = try conn.readAll(&buf);
    const body = response[std.mem.indexOf(u8, response, "\r\n\r\n").? + 4 ..];

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, response, "Content-Type: image/bmp\r\n") != null);
    var length_buf: [32]u8 = undefined;
    const length = try std.mem.print(&length_buf, "Content-Length: {d}\r\n", .{bmp.byteSize(width, height)});
    try testing.expect(std.mem.indexOf(u8, response, length) != null);
    try testing.expectEqual(bmp.byteSize(width, height), body.len);
    try testing.expectEqualStrings("BM", body[0..2]);
}
