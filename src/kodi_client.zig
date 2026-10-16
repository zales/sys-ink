//! The connection to Kodi, on a task of its own: holding its JSON-RPC port
//! open, asking what plays whenever Kodi says playback has changed, and
//! fetching the picture of it.
//!
//! What is said over it is `kodi.zig`, free of I/O and tested; this is the
//! part that talks, Linux-only like the rest of the daemon's networking, and
//! left to the device. It hands the main loop what it learns as the Spotify
//! client does, through a one-slot mailbox and an eventfd, and every wait it
//! makes has a deadline and watches `stop_fd`; pictures come through
//! `https_client.zig`, which bounds its waits the same way. The exceptions
//! are the name lookups, which have libc's timeouts.
//!
//! Kodi is often away, on a TV that is off or with the app closed. That is
//! no fault: it is said once in the log, and Kodi is looked for again every
//! half a minute or sooner.

const std = @import("std");
const linux = std.os.linux;
const kodi = @import("kodi.zig");
const now_playing = @import("now_playing.zig");
const jpeg = @import("jpeg.zig");
const graphics = @import("graphics.zig");
const bounded_connect = @import("bounded_connect.zig");
const syscall = @import("syscall.zig");
const https = @import("https_client.zig");
const notice = @import("notice.zig");
const lookup = @import("mqtt.zig").lookup;

const Value = std.json.Value;
const nowMs = https.nowMs;

const log = std.log.scoped(.kodi);

pub const Options = struct {
    host: []const u8,
    port: u16 = kodi.default_port,
};

/// The rest of a message, once its first byte has arrived.
const message_timeout_ms = 10_000;
/// Longest message taken. Kodi's add-ons tell each other things through it,
/// some of them kilobytes long.
const max_message = 256 * 1024;
/// Heard nothing for this long, despite pinging: Kodi is gone.
const silence_limit_ms = (2 * kodi.ping_interval_s + 15) * 1000;
/// Longest picture address kept; longer ones are not fetched.
const max_picture_url = 2048;

pub const Error = error{
    /// `stop_fd` was written: the daemon is going.
    Stopped,
    Timeout,
    KodiClosed,
    KodiSilent,
    MessageTooLong,
    NotJson,
};

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    task: ?std.Io.Future(void) = null,

    /// Readable while a snapshot waits to be taken.
    ready_fd: linux.fd_t,
    /// Written once, to stop the task. Every wait it makes watches this.
    stop_fd: linux.fd_t,
    stopping: std.atomic.Value(bool) = .init(false),

    /// Guards `shared` and `fresh`, the mailbox.
    mutex: std.Io.Mutex = .init,
    shared: now_playing.Snapshot = .{},
    fresh: bool = false,

    // The task's own. Nothing else touches these.
    mine: now_playing.Snapshot = .{},
    https: https.Client,
    /// The player that plays, as Kodi last said.
    player: ?kodi.Player = null,
    /// When what plays now was first seen, which a live stream's time counts
    /// from.
    watched_since: i64 = 0,
    /// The address of the picture held, so the same one is not fetched again
    /// for each change of playback.
    picture_url: [max_picture_url]u8 = undefined,
    picture_url_len: usize = 0,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, options: Options) !Client {
        const ready = try syscall.eventFd();
        errdefer bounded_connect.closeFd(ready);
        const stop = try syscall.eventFd();
        return .{
            .io = io,
            .gpa = gpa,
            .options = options,
            .ready_fd = ready,
            .stop_fd = stop,
            .https = .init(io, gpa, stop),
        };
    }

    /// Begin on a task of its own. Like `WebPreview.start`, it needs this at
    /// its final address, and it stays off rather than share the main loop.
    pub fn start(self: *Client) void {
        self.task = self.io.concurrent(run, .{self}) catch |err| {
            log.warn("Cannot run the Kodi client concurrently: {t}; disabled", .{err});
            return;
        };
    }

    pub fn readyFd(self: *const Client) linux.fd_t {
        return self.ready_fd;
    }

    /// Copy the snapshot waiting in the mailbox into `out`. False when none
    /// has come since the last.
    pub fn take(self: *Client, out: *now_playing.Snapshot) bool {
        var count: u64 = 0;
        _ = linux.read(self.ready_fd, std.mem.asBytes(&count), @sizeOf(u64));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.fresh) return false;
        out.* = self.shared;
        self.fresh = false;
        return true;
    }

    /// Stop the task and wait for it. Its waits all watch `stop_fd`, so this
    /// takes at most a name lookup or a connect already under way.
    pub fn deinit(self: *Client) void {
        self.stopping.store(true, .release);
        const one: u64 = 1;
        _ = linux.write(self.stop_fd, std.mem.asBytes(&one), @sizeOf(u64));
        if (self.task) |*task| task.await(self.io);
        self.https.deinit();
        bounded_connect.closeFd(self.ready_fd);
        bounded_connect.closeFd(self.stop_fd);
    }

    fn publish(self: *Client) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.shared = self.mine;
            self.fresh = true;
        }
        const one: u64 = 1;
        _ = linux.write(self.ready_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    // ------------------------------------------------------------------------
    // The task
    // ------------------------------------------------------------------------

    fn run(self: *Client) void {
        var failures: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            self.session(&failures) catch |err| switch (err) {
                error.Stopped => break,
                else => {
                    failures += 1;
                    const wait = kodi.backoffSeconds(failures);
                    // What was on show is no longer known to be so.
                    self.forgetPlayback();
                    if (failures == 1) {
                        log.info("Kodi at {s}:{d}: {t}; looking for it again every {d}s or sooner", .{
                            self.options.host, self.options.port, err, kodi.backoffSeconds(std.math.maxInt(u32)),
                        });
                    } else {
                        log.debug("Kodi: {t} (attempt {d}); trying again in {d}s", .{ err, failures, wait });
                    }
                    self.pause(@intCast(wait * 1000)) catch break;
                },
            };
        }
    }

    fn forgetPlayback(self: *Client) void {
        self.player = null;
        if (self.mine.playback == null) return;
        self.mine.playback = null;
        self.publish();
    }

    /// One connection to Kodi, for as long as it lasts.
    fn session(self: *Client, failures: *u32) !void {
        var conn: Connection = undefined;
        try conn.open(self);
        defer conn.close(self);

        log.info("Kodi: connected to {s}:{d}", .{ self.options.host, self.options.port });
        failures.* = 0;

        // How playback stands now; from here on Kodi says when it changes.
        try conn.send(kodi.players_request);
        var last_heard = nowMs(self.io);
        var last_ping = last_heard;

        // Each message is parsed into this, and it is emptied after each.
        var message_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer message_arena.deinit();

        while (true) {
            _ = message_arena.reset(.retain_capacity);
            const now = nowMs(self.io);
            // Judged only after a wait that brought nothing: after a long
            // picture fetch, what came meanwhile is still to be read.
            const ping_at = last_ping + kodi.ping_interval_s * 1000;
            if (now >= ping_at) {
                try conn.send(kodi.ping_request);
                last_ping = now;
                continue;
            }

            const text = (try conn.next(self, ping_at)) orelse {
                if (nowMs(self.io) - last_heard > silence_limit_ms) return error.KodiSilent;
                continue;
            };
            last_heard = nowMs(self.io);

            const arena = message_arena.allocator();
            const root = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch {
                log.debug("Kodi: a message that is not JSON", .{});
                continue;
            };
            switch (kodi.parse(root)) {
                .changed => try conn.send(kodi.players_request),
                .stopped => self.setNothing(),
                .players => |player| {
                    self.player = player;
                    const p = player orelse {
                        self.setNothing();
                        continue;
                    };
                    try conn.send(kodi.labels_request);
                    var buf: [256]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&buf);
                    kodi.writePropertiesRequest(&w, p.id) catch unreachable;
                    try conn.send(w.buffered());
                },
                .labels => |labels| if (self.player) |p| self.onLabels(arena, p.kind, labels),
                .properties => |properties| self.onProperties(properties),
                .failed => |asked| log.debug("Kodi turned down the request for {t}", .{asked}),
                .pong, .other => {},
            }
        }
    }

    fn setNothing(self: *Client) void {
        self.player = null;
        self.mine.playback = null;
        self.publish();
    }

    /// Take in what the labels say plays: a new description, and its
    /// picture if that has changed.
    fn onLabels(self: *Client, arena: std.mem.Allocator, kind: kodi.Player.Kind, labels: kodi.Labels) void {
        const described = kodi.describe(kind, labels);
        const known = if (self.mine.track) |t| t.uri.eql(&described.track.uri) else false;
        if (!known) {
            self.watched_since = nowMs(self.io);
            var title: [now_playing.max_text]u8 = undefined;
            var artist: [now_playing.max_text]u8 = undefined;
            // Folded as the panel draws them, which leaves nothing in that
            // could pass for a line of its own in the log.
            log.debug("Kodi: playing {s} - {s}", .{
                notice.foldToFont(&artist, described.track.artist.slice()),
                notice.foldToFont(&title, described.track.title.slice()),
            });
        }
        self.mine.track = described.track;
        // Properties may have come before the labels did: they are of this.
        if (self.mine.playback) |*p| p.uri = described.track.uri;
        self.setPicture(arena, described.picture, described.shape);
        self.publish();
    }

    fn onProperties(self: *Client, properties: kodi.Properties) void {
        const uri = if (self.mine.track) |t| t.uri else now_playing.Text{};
        self.mine.playback = kodi.playbackOf(uri, properties, nowMs(self.io), self.watched_since);
        self.publish();
    }

    /// Fetch, decode and scale the picture at `label`, in `shape`, unless it
    /// is the one already held. One that cannot be had is left out, the
    /// picture of what played before included.
    fn setPicture(self: *Client, arena: std.mem.Allocator, label: []const u8, shape: now_playing.Shape) void {
        const held = self.picture_url[0..self.picture_url_len];
        if (std.mem.eql(u8, held, label) and self.mine.cover_shape == shape) return;

        const kept = @min(label.len, max_picture_url);
        @memcpy(self.picture_url[0..kept], label[0..kept]);
        self.picture_url_len = kept;
        self.mine.cover_valid = false;
        self.mine.cover_shape = shape;
        self.mine.cover_serial +%= 1;
        if (label.len == 0 or label.len > max_picture_url) return;

        var url_buf: [3 * max_picture_url]u8 = undefined;
        const url = kodi.pictureUrl(&url_buf, label) orelse {
            log.debug("Kodi: a picture not on the web over HTTPS is left out", .{});
            return;
        };

        self.https.loadCertificates("Kodi") catch return;
        const reply = self.https.request(arena, .{
            .method = "GET",
            .host = url.host,
            .port = url.port,
            .path = url.path,
            .headers = "Accept: image/jpeg\r\n",
        }) catch |err| {
            if (err != error.Stopped) log.warn("Kodi: cannot fetch a picture from {s}: {t}", .{ url.host, err });
            return;
        };
        if (reply.status != .ok) {
            log.warn("Kodi: fetching a picture from {s} was answered {d}", .{ url.host, @backingInt(reply.status) });
            return;
        }

        var image = jpeg.decodeLuma(arena, reply.body) catch |err| {
            // A WebP or a PNG, most likely, which the panel does without.
            log.info("Kodi: cannot decode the picture from {s}: {t}", .{ url.host, err });
            return;
        };
        defer image.deinit(arena);
        const rect = shape.rect();
        const pixels = self.mine.cover[0..shape.len()];
        graphics.scaleGray(image.pixels, image.width, image.height, pixels, rect.width, rect.height);
        graphics.stretchContrast(pixels);
        self.mine.cover_valid = true;
    }

    /// Wait up to `ms` for nothing but `stop_fd`.
    fn pause(self: *Client, ms: i32) Error!void {
        var fds = [_]std.posix.pollfd{.{ .fd = self.stop_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, ms) catch 0;
        if (ready > 0 or self.stopping.load(.acquire)) return error.Stopped;
    }
};

/// Kodi's JSON-RPC port: a plain TCP connection whose reads have deadlines.
const Connection = struct {
    stream: std.Io.net.Stream,
    input: https.SocketReader,
    output: std.Io.net.Stream.Writer,
    in_buf: []u8,
    out_buf: [512]u8,

    fn open(self: *Connection, owner: *Client) !void {
        var name: [256:0]u8 = undefined;
        const host_z = std.mem.printSentinel(&name, "{s}", .{owner.options.host}, 0) catch return error.HostTooLong;
        const address = lookup(null, host_z.ptr) catch return error.DnsResolutionFailed;
        self.stream = try bounded_connect.connectStream(address, owner.options.port, https.connect_timeout_ms);
        errdefer self.stream.close(owner.io);

        self.in_buf = try owner.gpa.alloc(u8, max_message);
        self.input = .init(self.stream.socket.handle, owner.stop_fd, owner.io, self.in_buf, 0);
        self.output = self.stream.writer(owner.io, &self.out_buf);
    }

    fn close(self: *Connection, owner: *Client) void {
        self.stream.close(owner.io);
        owner.gpa.free(self.in_buf);
    }

    /// Send one request, waiting a bounded time for room.
    fn send(self: *Connection, request: []const u8) !void {
        const w = &self.output.interface;
        w.writeAll(request) catch return self.output.err orelse error.WriteFailed;
        try bounded_connect.waitWritable(self.stream.socket.handle, https.send_timeout_ms);
        w.flush() catch return self.output.err orelse error.WriteFailed;
    }

    /// The next message, or null if none has begun by `deadline_ms`. Once
    /// one has, the rest of it has `message_timeout_ms` to arrive. Valid
    /// until the next call.
    fn next(self: *Connection, owner: *Client, deadline_ms: i64) !?[]const u8 {
        const r = &self.input.interface;
        var waited = false;
        while (true) {
            const buffered = r.buffered();
            if (try kodi.objectEnd(buffered)) |end| {
                r.toss(end);
                return buffered[0..end];
            }
            // Whitespace between messages, with nothing after it yet.
            if (std.mem.indexOfNone(u8, buffered, &std.ascii.whitespace) == null) r.tossBuffered();
            if (r.bufferedLen() == r.buffer.len) return error.MessageTooLong;

            if (r.bufferedLen() == 0 and !waited) {
                if (!try self.input.waitUntil(deadline_ms)) return null;
                waited = true;
            }
            self.input.deadline_ms = nowMs(owner.io) + message_timeout_ms;
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.KodiClosed,
                error.ReadFailed => return self.input.failure(),
            };
        }
    }
};
