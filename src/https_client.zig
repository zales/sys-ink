//! HTTPS requests for the clients that run on tasks of their own, Spotify's
//! and Kodi's, with every wait bounded.
//!
//! Each read has a deadline and watches the owner's `stop_fd` as well, so the
//! daemon stops promptly and a server that goes quiet costs a request, not a
//! task stuck for good. The exceptions are the name lookup, which has libc's
//! timeouts, and the connect, which has its own. Linux-only like the rest of
//! the daemon's networking, and left to the device.

const std = @import("std");
const linux = std.os.linux;
const bounded_connect = @import("bounded_connect.zig");
const lookup = @import("mqtt.zig").lookup;

const log = std.log.scoped(.https);

/// A TCP connect, as the broker's has.
pub const connect_timeout_ms = 5000;
/// A whole request, from connecting to the last byte of the reply.
pub const request_timeout_ms = 15_000;
/// Waiting for room to send; see `bounded_connect.waitWritable`.
pub const send_timeout_ms = 5000;
/// Longest reply body taken: a cover is some 30 kB, a poster 40, JSON less.
const max_body = 1024 * 1024;

pub const WaitError = error{
    /// `stop_fd` was written: the daemon is going.
    Stopped,
    /// Waited past a deadline.
    Timeout,
};

pub const Request = struct {
    method: []const u8,
    host: []const u8,
    port: u16 = 443,
    path: []const u8,
    /// Whole header lines, each ending in CRLF.
    headers: []const u8 = "",
    body: ?[]const u8 = null,
    content_type: []const u8 = "",
};

pub const Reply = struct {
    status: std.http.Status,
    body: []u8,
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// The owner's: readable once the daemon is going. Every wait watches it.
    stop_fd: linux.fd_t,
    ca: std.crypto.Certificate.Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,
    ca_loaded: bool = false,
    /// Connections kept open after a GET, one a host, so that the next
    /// request there needs no handshake: each track asks the metadata service
    /// and the image host, and some the embed player.
    pooled: [pool_size]?*Tls = @splat(null),

    const pool_size = 3;

    pub fn init(io: std.Io, gpa: std.mem.Allocator, stop_fd: linux.fd_t) Client {
        return .{ .io = io, .gpa = gpa, .stop_fd = stop_fd };
    }

    /// Only once the task that makes the requests has stopped.
    pub fn deinit(self: *Client) void {
        for (&self.pooled) |*slot| {
            if (slot.*) |conn| self.discard(conn);
            slot.* = null;
        }
        self.ca.deinit(self.gpa);
    }

    /// The system's CA certificates, read the first time they are needed.
    /// `what` names the owner in the log.
    pub fn loadCertificates(self: *Client, what: []const u8) !void {
        if (self.ca_loaded) return;
        self.ca.rescan(self.gpa, self.io, std.Io.Clock.real.now(self.io)) catch |err| {
            log.err("{s}: cannot load the system's CA certificates: {t}", .{ what, err });
            return err;
        };
        self.ca_loaded = true;
    }

    /// One request. A GET goes on a connection kept from the last one to the
    /// same host if there is one, and its connection is kept for the next if
    /// the server allows; anything else goes on a connection of its own,
    /// closed after the reply, so that a POST is never sent twice.
    pub fn request(self: *Client, arena: std.mem.Allocator, req: Request) !Reply {
        const reusable = std.mem.eql(u8, req.method, "GET");
        if (reusable) {
            if (self.takePooled(req.host, req.port)) |conn| {
                if (self.exchange(arena, conn, req, true)) |done| {
                    self.keepOrDiscard(conn, done.keep);
                    return done.reply;
                } else |err| {
                    self.discard(conn);
                    if (err == error.Stopped) return err;
                    // The server closed it since, most likely: once more on a
                    // fresh one, which a GET can safely be.
                    log.debug("a kept connection to {s} failed: {t}; opening another", .{ req.host, err });
                }
            }
        }

        const conn = try self.gpa.create(Tls);
        conn.open(self, req.host, req.port, nowMs(self.io) + request_timeout_ms) catch |err| {
            self.gpa.destroy(conn);
            return err;
        };
        const done = self.exchange(arena, conn, req, reusable) catch |err| {
            self.discard(conn);
            return err;
        };
        self.keepOrDiscard(conn, reusable and done.keep);
        return done.reply;
    }

    const Exchanged = struct {
        reply: Reply,
        /// The server will take another request on the connection.
        keep: bool,
    };

    fn exchange(self: *Client, arena: std.mem.Allocator, conn: *Tls, req: Request, keep_alive: bool) !Exchanged {
        conn.input.deadline_ms = nowMs(self.io) + request_timeout_ms;

        const w = &conn.client.writer;
        try w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: sys-ink\r\nAccept-Encoding: identity\r\nConnection: {s}\r\n{s}", .{
            req.method, req.path, req.host, if (keep_alive) "keep-alive" else "close", req.headers,
        });
        if (req.body) |body| {
            try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ req.content_type, body.len });
            try w.writeAll(body);
        } else {
            try w.writeAll("\r\n");
        }
        try conn.flush();

        var http_reader: std.http.Reader = .{
            .in = &conn.client.reader,
            .interface = undefined,
            .state = .ready,
            .max_head_len = 16 * 1024,
        };
        const head = std.http.Client.Response.Head.parse(try conn.mapRead(http_reader.receiveHead())) catch return error.UnexpectedReply;
        const status = head.status;
        // A body that runs to the end of the connection leaves nothing to
        // reuse.
        const delimited = head.transfer_encoding == .chunked or head.content_length != null;
        const keep = keep_alive and head.keep_alive and delimited;
        var transfer: [4096]u8 = undefined;
        const body_reader = http_reader.bodyReader(&transfer, head.transfer_encoding, head.content_length);
        const body = body_reader.allocRemaining(arena, .limited(max_body)) catch |err| switch (err) {
            error.ReadFailed => return conn.readError(),
            else => |e| return e,
        };
        return .{ .reply = .{ .status = status, .body = body }, .keep = keep };
    }

    /// The connection kept to `host`, if there is one still worth using: one
    /// the server has said anything on since is closing, and is dropped.
    fn takePooled(self: *Client, host: []const u8, port: u16) ?*Tls {
        for (&self.pooled) |*slot| {
            const conn = slot.* orelse continue;
            if (!conn.isTo(host, port)) continue;
            slot.* = null;
            if (conn.hasBuffered() or conn.readableNow()) {
                self.discard(conn);
                return null;
            }
            return conn;
        }
        return null;
    }

    fn keepOrDiscard(self: *Client, conn: *Tls, keep: bool) void {
        if (!keep) return self.discard(conn);
        for (&self.pooled) |*slot| {
            if (slot.* == null) {
                slot.* = conn;
                return;
            }
        }
        // Full: the oldest makes room.
        self.discard(self.pooled[0].?);
        std.mem.copyForwards(?*Tls, self.pooled[0 .. pool_size - 1], self.pooled[1..]);
        self.pooled[pool_size - 1] = conn;
    }

    fn discard(self: *Client, conn: *Tls) void {
        conn.close(self);
        self.gpa.destroy(conn);
    }
};

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// A TLS connection whose every read has a deadline.
///
/// Its buffers, and the pointers the TLS client keeps into it, pin it in
/// place: it is opened where it is to stay.
pub const Tls = struct {
    stream: std.Io.net.Stream,
    input: SocketReader,
    output: std.Io.net.Stream.Writer,
    client: std.crypto.tls.Client,
    buffers: []u8,
    /// Where it goes, for a kept connection to be found by.
    host: [256]u8,
    host_len: usize,
    port: u16,

    const tls_len = std.crypto.tls.Client.min_buffer_len;
    /// The socket's buffer, the TLS record buffer both ways, and room for an
    /// HTTP head in the plaintext one.
    const buffers_len = 3 * tls_len + (tls_len + 16 * 1024);

    pub fn open(self: *Tls, owner: *Client, host: []const u8, port: u16, deadline_ms: i64) !void {
        var name: [256:0]u8 = undefined;
        const host_z = std.mem.printSentinel(&name, "{s}", .{host}, 0) catch return error.HostTooLong;
        @memcpy(self.host[0..host.len], host);
        self.host_len = host.len;
        self.port = port;
        const address = lookup(null, host_z.ptr) catch return error.DnsResolutionFailed;
        self.stream = try bounded_connect.connectStream(address, port, connect_timeout_ms);
        errdefer self.stream.close(owner.io);

        self.buffers = try owner.gpa.alloc(u8, buffers_len);
        errdefer owner.gpa.free(self.buffers);
        const socket_in = self.buffers[0..tls_len];
        const socket_out = self.buffers[tls_len..][0..tls_len];
        const plain_out = self.buffers[2 * tls_len ..][0..tls_len];
        const plain_in = self.buffers[3 * tls_len ..];

        self.input = .init(self.stream.socket.handle, owner.stop_fd, owner.io, socket_in, deadline_ms);
        self.output = self.stream.writer(owner.io, socket_out);

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        owner.io.random(&entropy);
        self.client = std.crypto.tls.Client.init(&self.input.interface, &self.output.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{
                .gpa = owner.gpa,
                .io = owner.io,
                .lock = &owner.ca_lock,
                .bundle = &owner.ca,
            } },
            .read_buffer = plain_in,
            .write_buffer = plain_out,
            .entropy = &entropy,
            .realtime_now = std.Io.Clock.real.now(owner.io),
            // HTTP says how long its body is, and WebSocket how long its
            // frames are, so a cut-off reply is caught above this.
            .allow_truncation_attacks = true,
        }) catch |err| switch (err) {
            error.ReadFailed => return self.input.failure(),
            error.WriteFailed => return self.output.err orelse error.WriteFailed,
            else => |e| return e,
        };
    }

    pub fn close(self: *Tls, owner: *Client) void {
        self.stream.close(owner.io);
        owner.gpa.free(self.buffers);
    }

    /// Send what has been written, waiting a bounded time for room.
    pub fn flush(self: *Tls) !void {
        try self.client.writer.flush();
        try bounded_connect.waitWritable(self.stream.socket.handle, send_timeout_ms);
        self.output.interface.flush() catch return self.output.err orelse error.WriteFailed;
    }

    fn isTo(self: *const Tls, host: []const u8, port: u16) bool {
        return self.port == port and std.mem.eql(u8, self.host[0..self.host_len], host);
    }

    /// Whether the socket has something to read this moment: on a connection
    /// with no request out, the server closing it.
    fn readableNow(self: *Tls) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = self.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return true;
        return ready > 0;
    }

    /// Whether a read can go ahead without waiting for the network.
    pub fn hasBuffered(self: *Tls) bool {
        return self.client.reader.bufferedLen() > 0 or self.input.interface.bufferedLen() > 0;
    }

    /// Why a read failed: the socket's reason if it had one, else TLS's.
    pub fn readError(self: *Tls) anyerror {
        if (self.input.err != null) return self.input.failure();
        return self.client.read_err orelse error.ReadFailed;
    }

    pub fn mapRead(self: *Tls, result: anytype) !@typeInfo(@TypeOf(result)).error_union.payload {
        return result catch |err| switch (err) {
            error.ReadFailed => self.readError(),
            else => |e| e,
        };
    }
};

/// Reads a socket the way `std.Io.net.Stream.Reader` does, but waits for each
/// read no later than `deadline_ms`, and gives up at once when `stop_fd`
/// becomes readable.
pub const SocketReader = struct {
    interface: std.Io.Reader,
    fd: linux.fd_t,
    stop_fd: linux.fd_t,
    io: std.Io,
    deadline_ms: i64,
    err: ?anyerror = null,

    pub fn init(fd: linux.fd_t, stop_fd: linux.fd_t, io: std.Io, buffer: []u8, deadline_ms: i64) SocketReader {
        return .{
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .fd = fd,
            .stop_fd = stop_fd,
            .io = io,
            .deadline_ms = deadline_ms,
        };
    }

    pub fn failure(self: *const SocketReader) anyerror {
        return self.err orelse error.ReadFailed;
    }

    /// Wait until the socket has something to read: true when it has, false
    /// at `deadline_ms`.
    pub fn waitUntil(self: *SocketReader, deadline_ms: i64) WaitError!bool {
        const left = deadline_ms - nowMs(self.io);
        if (left <= 0) return false;
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.stop_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, @intCast(@min(left, std.math.maxInt(i32)))) catch return error.Timeout;
        if (fds[1].revents != 0) return error.Stopped;
        // A hangup or an error is readable too: the read says which.
        return ready > 0;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SocketReader = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const readable = self.waitUntil(self.deadline_ms) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (!readable) {
            self.err = error.Timeout;
            return error.ReadFailed;
        }
        const n = std.posix.read(self.fd, dest) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }
};
