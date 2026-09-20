//! The HTTP side of showing a panel frame in a browser.
//!
//! Shared by the simulator and by the daemon's optional preview, which differ
//! only in where the frame comes from — one synthesizes it, the other shows what
//! is on the glass — and so each keeps its own accept loop.
//!
//! Deliberately small: one request per connection, no keep-alive, no
//! concurrency. A page that reloads one image a second needs nothing more, and
//! in the daemon it has to stay cheap enough to be beside the point.

const std = @import("std");
const net = std.Io.net;
const bmp = @import("bmp.zig");

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
/// The deadline that keeps a stalled peer from taking the loop down lives in
/// `readRequest`, not here — see the note there for why it cannot be a socket
/// option.
pub fn accept(server: *net.Server, io: std.Io) ?net.Stream {
    return server.accept(io) catch |err| {
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

/// Send a complete response. Errors are dropped: a client that goes away
/// mid-write is ordinary, and there is nothing useful to do about it.
pub fn respond(
    stream: net.Stream,
    io: std.Io,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) void {
    var out_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const w = &writer.interface;

    w.print("HTTP/1.1 {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "Connection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
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
