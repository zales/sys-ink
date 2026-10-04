//! Optional HTTP view of what is currently on the panel.
//!
//! Off unless `WEB_PREVIEW=true`. For a headless machine it answers the question
//! the panel cannot when you are not standing in front of it — and unlike the
//! BMP export it needs nothing copied off the box.
//!
//! What it serves is the frame the daemon actually drew, not a re-render: the
//! render loop hands each finished frame over, and the server sends back the
//! latest one it was given. So it agrees with the glass by construction, fault
//! overlay included.
//!
//! ## Exposure
//!
//! There is no authentication, and the frame shows host name, addresses, load
//! and disk figures. It binds loopback unless told otherwise, so reaching it
//! from another machine means an SSH tunnel:
//!
//!     ssh -L 8390:127.0.0.1:8390 user@host
//!
//! `WEB_PREVIEW_ADDR=0.0.0.0` puts it on the network for anyone who can route to
//! the port. That is a decision, not a default.
//!
//! ## The API
//!
//! The same server answers `/api/status` and `/api/notice`; what they do and
//! who may use them is in `api.zig`. Status is handed over like the frame: the
//! render loop publishes the readings it drew, already as JSON. A notice goes
//! the other way — into a one-slot mailbox, newest wins as on the pipe, with an
//! eventfd the main loop polls so it goes up at once rather than at the next
//! tick.

const std = @import("std");
const linux = std.os.linux;
const net = std.Io.net;
const api = @import("api.zig");
const bmp = @import("bmp.zig");
const display_config = @import("display_config.zig");
const frame_server = @import("frame_server.zig");
const http_request = @import("http_request.zig");
const syscall = @import("syscall.zig");

const log = std.log.scoped(.preview);

const width = display_config.DISPLAY_WIDTH;
const height = display_config.DISPLAY_HEIGHT;
const frame_bytes = @divCeil(width, 8) * height;

pub const WebPreview = struct {
    io: std.Io,
    address: net.IpAddress,
    server: net.Server,
    task: ?std.Io.Future(void) = null,

    options: api.Options,

    /// Guards everything below it, shared between the main loop and the server.
    mutex: std.Io.Mutex = .init,
    frame: [frame_bytes]u8 = @splat(0xFF),
    have_frame: bool = false,
    /// The latest status as JSON; empty until the first is published.
    status_json: [api.status_json_max]u8 = undefined,
    status_len: usize = 0,
    /// The latest notice received and not yet taken.
    notice: [api.max_notice_body]u8 = undefined,
    notice_len: ?usize = null,

    /// Readable while a notice waits in the mailbox. -1 when the API takes none.
    notice_fd: linux.fd_t = -1,

    /// Cleared to make the accept loop stop at its next time around.
    running: std.atomic.Value(bool) = .init(true),

    /// Bind the port. Serving does not begin until `start`.
    ///
    /// Split in two because `start` hands the runtime a pointer to this struct,
    /// which therefore must already be at its final address — the same
    /// constraint the renderer has with its transport.
    pub fn init(io: std.Io, addr: []const u8, port: u16, options: api.Options) !WebPreview {
        const address = net.IpAddress.parse(addr, port) catch {
            log.err("WEB_PREVIEW_ADDR is not an address: {s}", .{addr});
            return error.InvalidAddress;
        };

        var server = try address.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);

        var notice_fd: linux.fd_t = -1;
        if (options.acceptsNotices()) {
            const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (!syscall.ok(rc)) {
                log.err("Cannot create the API's notice eventfd: {t}", .{syscall.errno(rc)});
                return error.EventFdFailed;
            }
            notice_fd = @intCast(rc);
        }

        return .{
            .io = io,
            // Where it is listening, not where it was asked to: with port 0
            // these differ, and `deinit` has to connect to the former.
            .address = server.socket.address,
            .server = server,
            .options = options,
            .notice_fd = notice_fd,
        };
    }

    /// Begin answering requests on a task of its own.
    ///
    /// Concurrency is required, not preferred: `accept` blocks, and this shares a
    /// thread with the render loop. If the runtime cannot give us a task the
    /// preview stays off rather than stalling the display.
    pub fn start(self: *WebPreview) void {
        self.task = self.io.concurrent(serveLoop, .{self}) catch |err| {
            log.warn("Cannot serve the preview concurrently: {t}; disabled", .{err});
            self.running.store(false, .release);
            return;
        };
        log.info("Panel preview on http://{f}", .{self.address});
        if (self.notice_fd >= 0) log.info("Accepting notices on http://{f}/api/notice", .{self.address});
    }

    /// Hand over a finished frame. Called from the render loop.
    ///
    /// Copied rather than borrowed: the renderer reuses its buffer for the next
    /// frame, and the server must not read one being rewritten.
    pub fn publish(self: *WebPreview, packed_frame: []const u8) void {
        if (packed_frame.len != frame_bytes) return;

        // Uncancelable: a memcpy of a few kilobytes, and dropping a frame here
        // would leave the preview showing something older for no good reason.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        @memcpy(&self.frame, packed_frame);
        self.have_frame = true;
    }

    /// Hand over the readings the frame just published was drawn from.
    /// Called from the render loop.
    pub fn publishStatus(self: *WebPreview, status: api.Status) void {
        // Serialised outside the lock: the server only ever needs the bytes.
        var buf: [api.status_json_max]u8 = undefined;
        const json = api.writeStatus(&buf, status) catch |err| {
            log.warn("Cannot serialise the status: {t}", .{err});
            return;
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        @memcpy(self.status_json[0..json.len], json);
        self.status_len = json.len;
    }

    /// The descriptor to poll for an arriving notice, if the API takes them.
    pub fn noticeFd(self: *const WebPreview) ?linux.fd_t {
        return if (self.notice_fd >= 0) self.notice_fd else null;
    }

    /// Take the notice waiting in the mailbox, copied into `out`. Called from
    /// the main loop once `noticeFd` is readable.
    pub fn takeNotice(self: *WebPreview, out: *[api.max_notice_body]u8) ?[]const u8 {
        // Drain the counter first: a notice delivered between this and the
        // lock below is then taken now, and its wake-up is a harmless extra.
        var counter: u64 = undefined;
        _ = linux.read(self.notice_fd, std.mem.asBytes(&counter), @sizeOf(u64));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const len = self.notice_len orelse return null;
        self.notice_len = null;
        @memcpy(out[0..len], self.notice[0..len]);
        return out[0..len];
    }

    /// Put a notice in the mailbox and wake the main loop. Server side.
    fn deliverNotice(self: *WebPreview, raw: []const u8) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            @memcpy(self.notice[0..raw.len], raw);
            self.notice_len = raw.len;
        }
        const one: u64 = 1;
        _ = linux.write(self.notice_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// Stop serving and release the task.
    pub fn deinit(self: *WebPreview) void {
        self.running.store(false, .release);

        // `accept` is blocking and there is no way to cancel it, so wake it with
        // a connection of our own. The loop then sees the cleared flag and
        // returns instead of waiting for a real client. Same shape as the wake
        // pipe the signal handler uses.
        if (self.task != null) {
            // `.timeout` left at `.none` deliberately: it is unimplemented in Zig
            // 0.16 and panics if set — the reason `bounded_connect.zig` exists.
            // Connecting to our own listening socket needs no deadline anyway.
            if (net.IpAddress.connect(&self.address, self.io, .{ .mode = .stream })) |stream| {
                stream.close(self.io);
            } else |err| {
                log.debug("Could not wake the preview to stop it: {t}", .{err});
            }
        }

        if (self.task) |*task| {
            task.await(self.io);
            self.task = null;
        }
        self.server.deinit(self.io);
        if (self.notice_fd >= 0) _ = linux.close(self.notice_fd);
    }

    fn serveLoop(self: *WebPreview) void {
        var request_buf: [http_request.max_header_len + api.max_notice_body]u8 = undefined;
        var image: [bmp.byteSize(width, height)]u8 = undefined;
        var snapshot: [frame_bytes]u8 = undefined;
        var status: [api.status_json_max]u8 = undefined;

        while (self.running.load(.acquire)) {
            const stream = frame_server.accept(&self.server, self.io) orelse continue;
            defer stream.close(self.io);

            if (!self.running.load(.acquire)) return;

            const request = switch (frame_server.receiveRequest(stream, self.io, &request_buf, api.max_notice_body)) {
                .request => |r| r,
                .refuse => |why| {
                    frame_server.respond(stream, self.io, why, "text/plain", "");
                    continue;
                },
                .drop => continue,
            };

            switch (api.route(request.method, request.path)) {
                .page => frame_server.respondPage(stream, self.io, "Live panel"),
                .frame => {
                    // Copied out under the lock, so serialising and writing —
                    // which can block on a slow client — hold nothing.
                    const ready = blk: {
                        self.mutex.lockUncancelable(self.io);
                        defer self.mutex.unlock(self.io);
                        if (!self.have_frame) break :blk false;
                        @memcpy(&snapshot, &self.frame);
                        break :blk true;
                    };

                    if (!ready) {
                        frame_server.respond(stream, self.io, "503 Service Unavailable", "text/plain", "no frame yet\n");
                        continue;
                    }
                    frame_server.respondFrame(stream, self.io, &image, &snapshot, width, height);
                },
                .status => {
                    const len = blk: {
                        self.mutex.lockUncancelable(self.io);
                        defer self.mutex.unlock(self.io);
                        @memcpy(status[0..self.status_len], self.status_json[0..self.status_len]);
                        break :blk self.status_len;
                    };

                    if (len == 0) {
                        respondJson(stream, self.io, "503 Service Unavailable", "", "{\"error\":\"no readings yet\"}");
                        continue;
                    }
                    respondJson(stream, self.io, "200 OK", "", status[0..len]);
                },
                .post_notice, .delete_notice => |which| switch (api.noticeRequest(self.options, which, request)) {
                    .accepted => |raw| {
                        self.deliverNotice(raw);
                        respondJson(stream, self.io, "202 Accepted", "", "{\"status\":\"accepted\"}");
                    },
                    .disabled => respondJson(stream, self.io, "403 Forbidden", "", "{\"error\":\"notices over HTTP are off; set WEB_API_TOKEN\"}"),
                    .unauthorized => {
                        log.info("Refused a notice: missing or wrong token", .{});
                        respondJson(stream, self.io, "401 Unauthorized", "WWW-Authenticate: Bearer\r\n", "{\"error\":\"unauthorized\"}");
                    },
                    .empty => respondJson(stream, self.io, "400 Bad Request", "", "{\"error\":\"nothing to show\"}"),
                },
                .method_not_allowed => {
                    var allow_buf: [64]u8 = undefined;
                    const allow = std.mem.print(&allow_buf, "Allow: {s}\r\n", .{api.allowedMethods(request.path)}) catch "";
                    respondJson(stream, self.io, "405 Method Not Allowed", allow, "{\"error\":\"method not allowed\"}");
                },
                .not_found => frame_server.respondNotFound(stream, self.io),
            }
        }
    }
};

fn respondJson(stream: net.Stream, io: std.Io, status: []const u8, extra_headers: []const u8, body: []const u8) void {
    frame_server.respondWith(stream, io, status, extra_headers, "application/json", body);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
//
// Linux only, as the module is: `tests.zig` leaves it out anywhere else. They
// run the real server on a loopback port of the kernel's choosing and talk to
// it as a client would, so they cover what the I/O-free halves cannot: the
// accept loop, the handover to and from the main loop, and shutting down.

const testing = std.testing;
const notice = @import("notice.zig");

/// Longest a test waits on the server before failing instead of hanging.
const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } };

/// Start serving at `preview`'s address, which must be its final one.
fn serve(preview: *WebPreview, options: api.Options) !void {
    preview.* = try WebPreview.init(testing.io, "127.0.0.1", 0, options);
    preview.start();
    if (preview.task == null) {
        preview.deinit();
        return error.SkipZigTest;
    }
}

/// Send `request` and return everything the server answers before closing.
fn exchange(preview: *WebPreview, request: []const u8, buf: []u8) ![]const u8 {
    const io = testing.io;
    const stream = try net.IpAddress.connect(&preview.address, io, .{ .mode = .stream });
    defer stream.close(io);

    var out: [256]u8 = undefined;
    var writer = stream.writer(io, &out);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var len: usize = 0;
    while (len < buf.len) {
        const message = try stream.socket.receiveTimeout(io, buf[len..], patience);
        if (message.data.len == 0) break;
        len += message.data.len;
    }
    return buf[0..len];
}

fn expectStatus(expected: []const u8, response: []const u8) !void {
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&buf, "HTTP/1.1 {s}", .{expected}), response[0..line_end]);
}

fn bodyOf(response: []const u8) []const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[head_end + 4 ..];
}

fn hasHeader(response: []const u8, comptime line: []const u8) bool {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return false;
    return std.mem.indexOf(u8, response[0 .. head_end + 2], "\r\n" ++ line ++ "\r\n") != null;
}

/// Whether a notice is waiting, as the main loop's poll would see it.
fn noticeWaiting(preview: *const WebPreview) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = preview.noticeFd().?, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, 0) catch return false;
    return n == 1 and fds[0].revents & std.posix.POLL.IN != 0;
}

const post_notice = "POST /api/notice HTTP/1.1\r\nAuthorization: Bearer s3cret\r\n";

const readings: api.Status = .{
    .cpu_load = 12,
    .cpu_temp = 48,
    .memory = 31,
    .disk_usage = 67,
    .disk_temp = null,
    .fan_speed = 2100,
    .uptime_minutes = 4445,
    .ip_address = "192.168.1.20",
    .wired = true,
    .signal_strength = null,
    .internet = true,
    .download_bytes_per_second = 1_250_000,
    .upload_bytes_per_second = 0,
    .apt_updates = 3,
    .undervoltage = false,
    .nvme_fault = null,
    .ssd_wear = 3,
};

test "the frame and the readings are served as published, and not before" {
    var preview: WebPreview = undefined;
    try serve(&preview, .{});
    defer preview.deinit();

    var buf: [8192]u8 = undefined;

    try expectStatus("503 Service Unavailable", try exchange(&preview, "GET /frame.bmp HTTP/1.1\r\n\r\n", &buf));
    const early = try exchange(&preview, "GET /api/status HTTP/1.1\r\n\r\n", &buf);
    try expectStatus("503 Service Unavailable", early);
    try testing.expectEqualStrings("{\"error\":\"no readings yet\"}", bodyOf(early));

    // A frame of the wrong size is not one, and changes nothing.
    preview.publish(&@as([16]u8, @splat(0x00)));
    try expectStatus("503 Service Unavailable", try exchange(&preview, "GET /frame.bmp HTTP/1.1\r\n\r\n", &buf));

    var frame: [frame_bytes]u8 = @splat(0xFF);
    frame[0] = 0x0F;
    preview.publish(&frame);
    preview.publishStatus(readings);

    const image = try exchange(&preview, "GET /frame.bmp?t=1 HTTP/1.1\r\nHost: pi\r\n\r\n", &buf);
    try expectStatus("200 OK", image);
    try testing.expect(hasHeader(image, "Content-Type: image/bmp"));
    try testing.expect(hasHeader(image, "Cache-Control: no-store"));
    const pixels = bodyOf(image);
    try testing.expectEqual(bmp.byteSize(width, height), pixels.len);
    try testing.expectEqualStrings("BM", pixels[0..2]);
    // The first byte of the frame, inverted as a BMP has it.
    try testing.expectEqual(@as(u8, 0xF0), pixels[bmp.header_len]);

    const status = try exchange(&preview, "GET /api/status HTTP/1.1\r\n\r\n", &buf);
    try expectStatus("200 OK", status);
    try testing.expect(hasHeader(status, "Content-Type: application/json"));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bodyOf(status), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 12), parsed.value.object.get("cpu_load").?.integer);
    try testing.expectEqualStrings("192.168.1.20", parsed.value.object.get("ip_address").?.string);
    try testing.expect(parsed.value.object.get("disk_temp").? == .null);

    const page = try exchange(&preview, "GET / HTTP/1.1\r\n\r\n", &buf);
    try expectStatus("200 OK", page);
    try testing.expect(std.mem.indexOf(u8, bodyOf(page), "Live panel") != null);
}

test "a notice needs the token, and then reaches the main loop at once" {
    var preview: WebPreview = undefined;
    try serve(&preview, .{ .token = "s3cret" });
    defer preview.deinit();

    var buf: [2048]u8 = undefined;
    var taken: [api.max_notice_body]u8 = undefined;

    try testing.expect(!noticeWaiting(&preview));

    const anonymous = try exchange(&preview, "POST /api/notice HTTP/1.1\r\nContent-Length: 2\r\n\r\nHi", &buf);
    try expectStatus("401 Unauthorized", anonymous);
    try testing.expect(hasHeader(anonymous, "WWW-Authenticate: Bearer"));
    try expectStatus("401 Unauthorized", try exchange(
        &preview,
        "POST /api/notice HTTP/1.1\r\nAuthorization: Bearer nope\r\nContent-Length: 2\r\n\r\nHi",
        &buf,
    ));
    try expectStatus("401 Unauthorized", try exchange(&preview, "DELETE /api/notice HTTP/1.1\r\n\r\n", &buf));
    try testing.expect(!noticeWaiting(&preview));
    try testing.expect(preview.takeNotice(&taken) == null);

    const accepted = try exchange(&preview, post_notice ++ "Content-Length: 15\r\n\r\nBackup finished", &buf);
    try expectStatus("202 Accepted", accepted);
    try testing.expectEqualStrings("{\"status\":\"accepted\"}", bodyOf(accepted));

    // Delivered before the answer was sent, so it is there by now.
    try testing.expect(noticeWaiting(&preview));
    try testing.expectEqualStrings("Backup finished", preview.takeNotice(&taken).?);
    try testing.expect(!noticeWaiting(&preview));
    try testing.expect(preview.takeNotice(&taken) == null);

    // Not queued: of two that arrive before the main loop looks, the newer.
    try expectStatus("202 Accepted", try exchange(&preview, post_notice ++ "Content-Length: 5\r\n\r\nfirst", &buf));
    try expectStatus("202 Accepted", try exchange(&preview, post_notice ++ "Content-Length: 6\r\n\r\nsecond", &buf));
    try testing.expectEqualStrings("second", preview.takeNotice(&taken).?);
    try testing.expect(!noticeWaiting(&preview));

    // Nothing visible in it: refused, and nothing handed over.
    const blank = try exchange(&preview, post_notice ++ "Content-Length: 3\r\n\r\n \n ", &buf);
    try expectStatus("400 Bad Request", blank);
    try testing.expectEqualStrings("{\"error\":\"nothing to show\"}", bodyOf(blank));
    try testing.expect(!noticeWaiting(&preview));

    // DELETE hands over the dismissal every other source understands.
    try expectStatus("202 Accepted", try exchange(
        &preview,
        "DELETE /api/notice HTTP/1.1\r\nAuthorization: Bearer s3cret\r\n\r\n",
        &buf,
    ));
    var scratch: [8192]u8 = undefined;
    try testing.expectEqualStrings("", notice.parse(&scratch, preview.takeNotice(&taken).?).?.text);
}

test "the largest notice the API takes arrives whole" {
    var preview: WebPreview = undefined;
    try serve(&preview, .{ .token = "s3cret" });
    defer preview.deinit();

    const body: [api.max_notice_body]u8 = @splat('x');
    var buf: [1024]u8 = undefined;
    try expectStatus("202 Accepted", try exchange(
        &preview,
        post_notice ++ std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len}) ++ body,
        &buf,
    ));

    var taken: [api.max_notice_body]u8 = undefined;
    try testing.expectEqualStrings(&body, preview.takeNotice(&taken).?);

    // One byte more is refused on its length alone, with nothing delivered.
    try expectStatus("413 Content Too Large", try exchange(
        &preview,
        post_notice ++ std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body.len + 1}),
        &buf,
    ));
    try testing.expect(!noticeWaiting(&preview));
}

test "without a token the notice routes are shut" {
    var preview: WebPreview = undefined;
    try serve(&preview, .{});
    defer preview.deinit();

    try testing.expect(preview.noticeFd() == null);

    var buf: [2048]u8 = undefined;
    const refused = try exchange(&preview, "POST /api/notice HTTP/1.1\r\nAuthorization: Bearer s3cret\r\nContent-Length: 2\r\n\r\nHi", &buf);
    try expectStatus("403 Forbidden", refused);
    try expectStatus("403 Forbidden", try exchange(&preview, "DELETE /api/notice HTTP/1.1\r\n\r\n", &buf));
}

test "a token is not enough while notices are turned off" {
    var preview: WebPreview = undefined;
    try serve(&preview, .{ .token = "s3cret", .notices_enabled = false });
    defer preview.deinit();

    try testing.expect(preview.noticeFd() == null);

    var buf: [2048]u8 = undefined;
    try expectStatus("403 Forbidden", try exchange(&preview, post_notice ++ "Content-Length: 2\r\n\r\nHi", &buf));
}

test "what is not served is told so, and the server carries on" {
    var preview: WebPreview = undefined;
    try serve(&preview, .{ .token = "s3cret" });
    defer preview.deinit();

    var buf: [2048]u8 = undefined;

    try expectStatus("404 Not Found", try exchange(&preview, "GET /etc/passwd HTTP/1.1\r\n\r\n", &buf));
    try expectStatus("404 Not Found", try exchange(&preview, "GET /api/status/ HTTP/1.1\r\n\r\n", &buf));

    const on_page = try exchange(&preview, "DELETE / HTTP/1.1\r\n\r\n", &buf);
    try expectStatus("405 Method Not Allowed", on_page);
    try testing.expect(hasHeader(on_page, "Allow: GET"));

    const on_notice = try exchange(&preview, "GET /api/notice HTTP/1.1\r\n\r\n", &buf);
    try expectStatus("405 Method Not Allowed", on_notice);
    try testing.expect(hasHeader(on_notice, "Allow: POST, DELETE"));

    try expectStatus("400 Bad Request", try exchange(&preview, "nonsense\r\n\r\n", &buf));
    try expectStatus("411 Length Required", try exchange(
        &preview,
        post_notice ++ "Transfer-Encoding: chunked\r\n\r\n",
        &buf,
    ));

    // A client that connects and leaves without a word is not answered.
    {
        const stream = try net.IpAddress.connect(&preview.address, testing.io, .{ .mode = .stream });
        stream.close(testing.io);
    }

    // After all of that it still answers.
    try expectStatus("503 Service Unavailable", try exchange(&preview, "GET /api/status HTTP/1.1\r\n\r\n", &buf));
}

test "the address is the one being listened on, and stopping does not hang" {
    var preview: WebPreview = undefined;
    try serve(&preview, .{});

    // Asked for port 0, given a real one: `deinit` wakes the accept loop by
    // connecting to it, and would wait for ever on a connection to port 0.
    try testing.expect(preview.address.ip4.port != 0);
    preview.deinit();
}
