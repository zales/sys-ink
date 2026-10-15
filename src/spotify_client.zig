//! The connection to Spotify, on a task of its own: linking the panel to an
//! account, holding the dealer's WebSocket open, and looking up what plays.
//!
//! What is said over it is `spotify.zig`, free of I/O and tested; this is the
//! part that talks, Linux-only like the rest of the daemon's networking, and
//! left to the device.
//!
//! It runs off the main loop, which it hands what it learns through a
//! one-slot mailbox and an eventfd, as the HTTP API hands over notices: the
//! main loop polls `readyFd` and takes the newest `Snapshot`. Even so, every
//! wait it makes has a deadline, and watches `stop_fd` as well, so the
//! daemon stops promptly and a server that goes quiet costs a reconnect, not
//! a task stuck for good. The exceptions are the name lookup, which has
//! libc's timeouts, and the connect, which has its own.
//!
//! Secrets stay here: the refresh token is in the state file, readable by
//! root alone, and neither it nor an access token is ever logged.

const std = @import("std");
const linux = std.os.linux;
const spotify = @import("spotify.zig");
const now_playing = @import("now_playing.zig");
const websocket = @import("websocket.zig");
const jpeg = @import("jpeg.zig");
const graphics = @import("graphics.zig");
const bounded_connect = @import("bounded_connect.zig");
const syscall = @import("syscall.zig");
const lookup = @import("mqtt.zig").lookup;

const Value = std.json.Value;

const log = std.log.scoped(.spotify);

pub const Options = struct {
    /// Where the link to the account is kept between runs.
    state_path: []const u8,
};

/// A TCP connect, as the broker's has.
const connect_timeout_ms = 5000;
/// A whole HTTPS request, from connecting to the last byte of the reply.
const request_timeout_ms = 15_000;
/// Opening the dealer, through the WebSocket handshake.
const handshake_timeout_ms = 10_000;
/// The rest of a WebSocket message, once its first byte has arrived.
const frame_timeout_ms = 10_000;
/// Waiting for room to send; see `bounded_connect.waitWritable`.
const send_timeout_ms = 5000;
/// Longest message taken from the dealer. A cluster lists the queue, and
/// runs to tens of kilobytes with a long one.
const max_message = 512 * 1024;
/// Longest reply body taken: a cover is some 30 kB, JSON less.
const max_body = 1024 * 1024;
/// The dealer is reconnected with a fresh token this long before the old one
/// runs out.
const renew_margin_s = 300;
/// Heard nothing for this long, despite pinging: the connection is gone.
const silence_limit_ms = (2 * spotify.ping_interval_s + 15) * 1000;

pub const Error = error{
    /// `stop_fd` was written: the daemon is going.
    Stopped,
    /// Waited past a deadline.
    Timeout,
    /// There is no link to an account, and none will be made this run.
    NotLinked,
    /// The account has withdrawn the panel's link.
    Revoked,
    UnexpectedReply,
    DealerClosed,
    DealerSilent,
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
    cover_id: ?[40]u8 = null,
    ca: std.crypto.Certificate.Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,
    ca_loaded: bool = false,
    /// A code is asked for at most once a run: the screen asking for it hides
    /// the dashboard, which must not go on for good on a panel nobody links.
    pairing_tried: bool = false,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, options: Options) !Client {
        const ready = try eventFd();
        errdefer bounded_connect.closeFd(ready);
        const stop = try eventFd();
        return .{ .io = io, .gpa = gpa, .options = options, .ready_fd = ready, .stop_fd = stop };
    }

    /// Begin on a task of its own. Like `WebPreview.start`, it needs this at
    /// its final address, and it stays off rather than share the main loop.
    pub fn start(self: *Client) void {
        self.task = self.io.concurrent(run, .{self}) catch |err| {
            log.warn("Cannot run the Spotify client concurrently: {t}; disabled", .{err});
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
        self.ca.deinit(self.gpa);
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
                error.NotLinked => {
                    // Said why where it was decided; nothing to retry.
                    self.forgetPlayback();
                    self.pause(std.math.maxInt(i32)) catch {};
                    break;
                },
                else => {
                    failures += 1;
                    const wait = spotify.backoffSeconds(failures);
                    // What was on show is no longer known to be so.
                    self.forgetPlayback();
                    if (failures == 1) {
                        log.warn("Spotify: {t}; trying again in {d}s", .{ err, wait });
                    } else {
                        log.debug("Spotify: {t} (attempt {d}); trying again in {d}s", .{ err, failures, wait });
                    }
                    self.pause(@intCast(wait * 1000)) catch break;
                },
            };
        }
    }

    fn forgetPlayback(self: *Client) void {
        if (self.mine.playback == null) return;
        self.mine.playback = null;
        self.publish();
    }

    /// One connection to the dealer, from authorising to the token running
    /// out, which ends it without an error: the next one starts at once.
    fn session(self: *Client, failures: *u32) !void {
        try self.loadCertificates();

        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const auth = try self.authorize(arena);
        const renew_at = nowMs(self.io) + @as(i64, @max(60, @as(i64, auth.expires_in) - renew_margin_s)) * 1000;
        const hosts = try self.resolveHosts(arena);

        const dealer = try self.gpa.create(Dealer);
        defer self.gpa.destroy(dealer);
        try dealer.open(self, hosts.dealer, auth.token);
        defer dealer.close(self);

        // Each message is parsed into this, and it is emptied after each.
        var message_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer message_arena.deinit();

        const connection_id = try arena.dupe(u8, try self.awaitConnectionId(dealer, &message_arena));
        try self.register(&message_arena, hosts.spclient, auth, connection_id);

        if (failures.* > 0) log.info("Spotify: connected again", .{});
        failures.* = 0;

        var last_ping = nowMs(self.io);
        while (true) {
            _ = message_arena.reset(.retain_capacity);
            const now = nowMs(self.io);
            if (now >= renew_at) return;
            if (now - dealer.last_heard > silence_limit_ms) return error.DealerSilent;

            const ping_at = last_ping + spotify.ping_interval_s * 1000;
            if (now >= ping_at) {
                try dealer.send(self, .text, spotify.ping_message);
                last_ping = now;
                continue;
            }

            switch (try dealer.next(self, @min(ping_at, renew_at))) {
                .timeout, .skipped => {},
                .close => return error.DealerClosed,
                .ping => |payload| try dealer.send(self, .pong, payload),
                .text => |text| {
                    const root = std.json.parseFromSliceLeaky(Value, message_arena.allocator(), text, .{}) catch {
                        log.debug("Spotify: a dealer message that is not JSON", .{});
                        continue;
                    };
                    const message = spotify.parseDealer(root) orelse continue;
                    switch (message) {
                        .cluster => |cluster| self.onCluster(&message_arena, hosts.spclient, auth.token, cluster),
                        .pong, .connection_id => {},
                        .other => |uri| log.debug("Spotify: ignoring {s}", .{uri}),
                    }
                },
            }
        }
    }

    fn awaitConnectionId(self: *Client, dealer: *Dealer, message_arena: *std.heap.ArenaAllocator) ![]const u8 {
        const deadline = nowMs(self.io) + handshake_timeout_ms;
        while (true) {
            switch (try dealer.next(self, deadline)) {
                .timeout => return error.Timeout,
                .close => return error.DealerClosed,
                .ping => |payload| try dealer.send(self, .pong, payload),
                .skipped => {},
                .text => |text| {
                    const root = std.json.parseFromSliceLeaky(Value, message_arena.allocator(), text, .{}) catch continue;
                    const message = spotify.parseDealer(root) orelse continue;
                    if (message == .connection_id) return message.connection_id;
                },
            }
        }
    }

    /// Register as a hidden device, which has the dealer send the account's
    /// playback from now on; the reply is how it stands now.
    fn register(
        self: *Client,
        message_arena: *std.heap.ArenaAllocator,
        spclient: spotify.HostPort,
        auth: Authorized,
        connection_id: []const u8,
    ) !void {
        const arena = message_arena.allocator();
        const path = try std.fmt.allocPrint(arena, "/connect-state/v1/devices/{s}", .{auth.state.device_id});
        const headers = try std.fmt.allocPrint(
            arena,
            "Authorization: Bearer {s}\r\nX-Spotify-Connection-Id: {s}\r\nAccept: application/json\r\n",
            .{ auth.token, connection_id },
        );
        const reply = try self.request(arena, .{
            .method = "PUT",
            .host = spclient,
            .path = path,
            .headers = headers,
            .body = spotify.register_body,
            .content_type = "application/json",
        });
        if (reply.status != .ok) {
            log.warn("Spotify: registering the panel was answered {d}", .{@backingInt(reply.status)});
            return error.UnexpectedReply;
        }
        const root = std.json.parseFromSliceLeaky(Value, arena, reply.body, .{}) catch return error.UnexpectedReply;
        self.onCluster(message_arena, spclient, auth.token, root);
    }

    /// Take in how the account's playback stands, looking up whatever plays
    /// that has not been looked up yet, and hand it to the main loop.
    fn onCluster(
        self: *Client,
        message_arena: *std.heap.ArenaAllocator,
        spclient: spotify.HostPort,
        token: []const u8,
        cluster: Value,
    ) void {
        const playback = spotify.playbackFromCluster(cluster, nowMs(self.io));
        if (playback) |p| {
            const known = if (self.mine.track) |t| t.uri.eql(&p.uri) else false;
            if (!known) self.describe(message_arena.allocator(), spclient, token, p.uri.slice());
        }
        self.mine.playback = playback;
        self.publish();
    }

    /// Look up what `uri` is called and its cover. What cannot be found out
    /// is left out, and not asked again until something else plays.
    fn describe(self: *Client, arena: std.mem.Allocator, spclient: spotify.HostPort, token: []const u8, uri: []const u8) void {
        self.mine.track = .{ .uri = .init(uri) };
        const item = spotify.itemOf(uri) orelse {
            self.setCover(arena, null);
            return;
        };

        var path_buf: [128]u8 = undefined;
        const path = item.metadataPath(&path_buf) orelse return;
        const headers = std.fmt.allocPrint(arena, "Authorization: Bearer {s}\r\nAccept: application/json\r\n", .{token}) catch return;
        const reply = self.request(arena, .{ .method = "GET", .host = spclient, .path = path, .headers = headers }) catch |err| {
            // Cut short by the daemon stopping: nothing went wrong.
            if (err != error.Stopped) log.warn("Spotify: cannot look up {s}: {t}", .{ uri, err });
            return;
        };
        if (reply.status != .ok) {
            log.warn("Spotify: looking up {s} was answered {d}", .{ uri, @backingInt(reply.status) });
            return;
        }
        const root = std.json.parseFromSliceLeaky(Value, arena, reply.body, .{}) catch {
            log.warn("Spotify: what {s} is came back as something other than JSON", .{uri});
            return;
        };
        const described = spotify.describe(item, uri, root) orelse return;
        self.mine.track = described.track;
        log.debug("Spotify: playing {s} - {s} ({s})", .{
            described.track.artist.slice(),
            described.track.title.slice(),
            described.track.album.slice(),
        });
        self.setCover(arena, described.cover);
    }

    /// Fetch, decode and scale the cover `id`, unless it is the one already
    /// held, as it is for the next track of an album.
    fn setCover(self: *Client, arena: std.mem.Allocator, id: ?[40]u8) void {
        if (self.cover_id) |current| {
            if (id != null and std.mem.eql(u8, &current, &id.?)) return;
        } else if (id == null) return;

        self.cover_id = id;
        self.mine.cover_valid = false;
        self.mine.cover_serial +%= 1;
        const file_id = id orelse return;

        var path_buf: [64]u8 = undefined;
        const path = spotify.imagePath(&path_buf, &file_id) orelse return;
        const reply = self.request(arena, .{
            .method = "GET",
            .host = .{ .host = spotify.image_host, .port = 443 },
            .path = path,
        }) catch |err| {
            if (err != error.Stopped) log.warn("Spotify: cannot fetch a cover: {t}", .{err});
            return;
        };
        if (reply.status != .ok) {
            log.warn("Spotify: fetching a cover was answered {d}", .{@backingInt(reply.status)});
            return;
        }

        var image = jpeg.decodeLuma(arena, reply.body) catch |err| {
            log.warn("Spotify: cannot decode a cover: {t}", .{err});
            return;
        };
        defer image.deinit(arena);
        graphics.scaleGray(image.pixels, image.width, image.height, &self.mine.cover, now_playing.cover_side, now_playing.cover_side);
        graphics.stretchContrast(&self.mine.cover);
        self.mine.cover_valid = true;
    }

    // ------------------------------------------------------------------------
    // Linking and tokens
    // ------------------------------------------------------------------------

    const Authorized = struct {
        state: spotify.State,
        token: []const u8,
        expires_in: u32,
    };

    fn authorize(self: *Client, arena: std.mem.Allocator) !Authorized {
        var state = (try self.loadState(arena)) orelse return self.pair(arena);
        return self.refresh(arena, &state) catch |err| switch (err) {
            error.Revoked => {
                log.warn("Spotify: the account no longer accepts this panel's link; linking it again", .{});
                std.Io.Dir.cwd().deleteFile(self.io, self.options.state_path) catch {};
                return self.pair(arena);
            },
            else => return err,
        };
    }

    /// A fresh access token for the link in `state`, keeping whatever new
    /// refresh token comes with it: the old one may stop working once a new
    /// one has been issued.
    fn refresh(self: *Client, arena: std.mem.Allocator, state: *spotify.State) !Authorized {
        const body = try formBody(arena, &.{
            .{ "grant_type", "refresh_token" },
            .{ "refresh_token", state.refresh_token },
            .{ "client_id", spotify.client_id },
        });
        const reply = try self.request(arena, .{
            .method = "POST",
            .host = .{ .host = spotify.accounts_host, .port = 443 },
            .path = "/api/token",
            .body = body,
            .content_type = "application/x-www-form-urlencoded",
        });
        const root = std.json.parseFromSliceLeaky(Value, arena, reply.body, .{}) catch return error.UnexpectedReply;
        switch (spotify.parseTokenReply(root)) {
            .token => |token| {
                if (token.refresh_token) |renewed| {
                    if (!std.mem.eql(u8, renewed, state.refresh_token)) {
                        state.refresh_token = renewed;
                        try self.saveState(state.*);
                    }
                }
                return .{ .state = state.*, .token = token.access_token, .expires_in = token.expires_in };
            },
            .failed => |reason| {
                if (std.mem.eql(u8, reason, "invalid_grant")) return error.Revoked;
                log.warn("Spotify: a fresh token was refused: {s}", .{reason});
                return error.UnexpectedReply;
            },
            .pending, .slow_down => return error.UnexpectedReply,
        }
    }

    /// Link the panel to an account: put a code on the panel, and wait for
    /// someone to enter it at spotify.com/pair.
    fn pair(self: *Client, arena: std.mem.Allocator) !Authorized {
        if (self.pairing_tried) return error.NotLinked;
        self.pairing_tried = true;

        const request_body = try formBody(arena, &.{
            .{ "client_id", spotify.client_id },
            .{ "scope", spotify.scopes },
        });
        const reply = try self.request(arena, .{
            .method = "POST",
            .host = .{ .host = spotify.accounts_host, .port = 443 },
            .path = "/oauth2/device/authorize",
            .body = request_body,
            .content_type = "application/x-www-form-urlencoded",
        });
        const root = std.json.parseFromSliceLeaky(Value, arena, reply.body, .{}) catch return error.UnexpectedReply;
        const code = spotify.parseDeviceCode(root) orelse {
            log.warn("Spotify: asking for a code to link with was answered {d}", .{@backingInt(reply.status)});
            return error.UnexpectedReply;
        };

        const expires = nowMs(self.io) + @as(i64, code.expires_in) * 1000;
        log.info("Spotify: to link this panel, enter {s} at https://{s}", .{ code.user_code, spotify.pair_url });
        self.mine.pairing = .{ .code = .init(code.user_code), .expires_ms = expires };
        self.publish();
        defer {
            self.mine.pairing = null;
            self.publish();
        }

        const poll_body = try formBody(arena, &.{
            .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" },
            .{ "device_code", code.device_code },
            .{ "client_id", spotify.client_id },
        });

        // Each poll's reply is read into this and dropped: there may be
        // hundreds of them.
        var poll_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer poll_arena.deinit();

        var interval_ms: i32 = @as(i32, @intCast(@min(code.interval, 60))) * 1000;
        while (true) {
            try self.pause(interval_ms);
            if (nowMs(self.io) >= expires) {
                log.warn("Spotify: the code ran out before it was entered; restart the service to link the panel", .{});
                return error.NotLinked;
            }

            _ = poll_arena.reset(.retain_capacity);
            const polled = self.request(poll_arena.allocator(), .{
                .method = "POST",
                .host = .{ .host = spotify.accounts_host, .port = 443 },
                .path = "/api/token",
                .body = poll_body,
                .content_type = "application/x-www-form-urlencoded",
            }) catch |err| {
                // The code stays good; a later poll may well get through.
                log.debug("Spotify: polling for the link failed: {t}", .{err});
                continue;
            };
            const answer = std.json.parseFromSliceLeaky(Value, poll_arena.allocator(), polled.body, .{}) catch continue;
            switch (spotify.parseTokenReply(answer)) {
                .pending => {},
                .slow_down => interval_ms += 5000,
                .failed => |reason| {
                    log.warn("Spotify: linking the panel failed: {s}", .{reason});
                    return error.NotLinked;
                },
                .token => |token| {
                    const refresh_token = token.refresh_token orelse return error.UnexpectedReply;
                    var random: [20]u8 = undefined;
                    self.io.random(&random);
                    const state: spotify.State = .{
                        .refresh_token = try arena.dupe(u8, refresh_token),
                        .device_id = try arena.dupe(u8, &spotify.newDeviceId(random)),
                    };
                    try self.saveState(state);
                    log.info("Spotify: linked", .{});
                    return .{
                        .state = state,
                        .token = try arena.dupe(u8, token.access_token),
                        .expires_in = token.expires_in,
                    };
                },
            }
        }
    }

    fn loadState(self: *Client, arena: std.mem.Allocator) !?spotify.State {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, self.options.state_path, arena, .limited(16 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| {
                log.warn("Spotify: cannot read {s}: {t}", .{ self.options.state_path, e });
                return e;
            },
        };
        const root = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch null;
        return (if (root) |r| spotify.parseState(r) else null) orelse {
            log.warn("Spotify: {s} is not a state file this daemon wrote; linking the panel again", .{self.options.state_path});
            return null;
        };
    }

    /// Replace the state file in one step, readable by its owner alone.
    fn saveState(self: *Client, state: spotify.State) !void {
        var atomic = std.Io.Dir.cwd().createFileAtomic(self.io, self.options.state_path, .{
            .replace = true,
            .make_path = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
        }) catch |err| {
            log.err("Spotify: cannot write {s}: {t}", .{ self.options.state_path, err });
            return err;
        };
        defer atomic.deinit(self.io);

        var buf: [1024]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buf);
        try spotify.writeState(&writer.interface, state);
        try writer.interface.flush();
        try atomic.replace(self.io);
    }

    fn resolveHosts(self: *Client, arena: std.mem.Allocator) !spotify.Hosts {
        const reply = try self.request(arena, .{
            .method = "GET",
            .host = .{ .host = spotify.apresolve_host, .port = 443 },
            .path = "/?type=dealer&type=spclient",
        });
        const root = std.json.parseFromSliceLeaky(Value, arena, reply.body, .{}) catch return error.UnexpectedReply;
        return spotify.parseHosts(root) orelse error.UnexpectedReply;
    }

    fn loadCertificates(self: *Client) !void {
        if (self.ca_loaded) return;
        self.ca.rescan(self.gpa, self.io, std.Io.Clock.real.now(self.io)) catch |err| {
            log.err("Spotify: cannot load the system's CA certificates: {t}", .{err});
            return err;
        };
        self.ca_loaded = true;
    }

    // ------------------------------------------------------------------------
    // HTTPS
    // ------------------------------------------------------------------------

    const Request = struct {
        method: []const u8,
        host: spotify.HostPort,
        path: []const u8,
        /// Whole header lines, each ending in CRLF.
        headers: []const u8 = "",
        body: ?[]const u8 = null,
        content_type: []const u8 = "",
    };

    const Reply = struct {
        status: std.http.Status,
        body: []u8,
    };

    /// One request on a connection of its own, closed after the reply.
    fn request(self: *Client, arena: std.mem.Allocator, req: Request) !Reply {
        const conn = try self.gpa.create(Tls);
        defer self.gpa.destroy(conn);
        try conn.open(self, req.host, nowMs(self.io) + request_timeout_ms);
        defer conn.close(self);

        const w = &conn.client.writer;
        try w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: sys-ink\r\nAccept-Encoding: identity\r\nConnection: close\r\n{s}", .{
            req.method, req.path, req.host.host, req.headers,
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
        var transfer: [4096]u8 = undefined;
        const body_reader = http_reader.bodyReader(&transfer, head.transfer_encoding, head.content_length);
        const body = body_reader.allocRemaining(arena, .limited(max_body)) catch |err| switch (err) {
            error.ReadFailed => return conn.readError(),
            else => |e| return e,
        };
        return .{ .status = status, .body = body };
    }

    /// Wait up to `ms` for nothing but `stop_fd`.
    fn pause(self: *Client, ms: i32) Error!void {
        var fds = [_]std.posix.pollfd{.{ .fd = self.stop_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, ms) catch 0;
        if (ready > 0 or self.stopping.load(.acquire)) return error.Stopped;
    }
};

fn eventFd() !linux.fd_t {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (!syscall.ok(rc)) return error.EventFdFailed;
    return @intCast(rc);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn formBody(arena: std.mem.Allocator, pairs: []const [2][]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try spotify.writeForm(&out.writer, pairs);
    return out.written();
}

/// A TLS connection whose every read has a deadline.
///
/// Its buffers, and the pointers the TLS client keeps into it, pin it in
/// place: it is opened where it is to stay.
const Tls = struct {
    stream: std.Io.net.Stream,
    input: SocketReader,
    output: std.Io.net.Stream.Writer,
    client: std.crypto.tls.Client,
    buffers: []u8,

    const tls_len = std.crypto.tls.Client.min_buffer_len;
    /// The socket's buffer, the TLS record buffer both ways, and room for an
    /// HTTP head in the plaintext one.
    const buffers_len = 3 * tls_len + (tls_len + 16 * 1024);

    fn open(self: *Tls, owner: *Client, at: spotify.HostPort, deadline_ms: i64) !void {
        var name: [256:0]u8 = undefined;
        const host_z = std.mem.printSentinel(&name, "{s}", .{at.host}, 0) catch return error.HostTooLong;
        const address = lookup(null, host_z.ptr) catch return error.DnsResolutionFailed;
        self.stream = try bounded_connect.connectStream(address, at.port, connect_timeout_ms);
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
            .host = .{ .explicit = at.host },
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

    fn close(self: *Tls, owner: *Client) void {
        self.stream.close(owner.io);
        owner.gpa.free(self.buffers);
    }

    /// Send what has been written, waiting a bounded time for room.
    fn flush(self: *Tls) !void {
        try self.client.writer.flush();
        try bounded_connect.waitWritable(self.stream.socket.handle, send_timeout_ms);
        self.output.interface.flush() catch return self.output.err orelse error.WriteFailed;
    }

    /// Whether a read can go ahead without waiting for the network.
    fn hasBuffered(self: *Tls) bool {
        return self.client.reader.bufferedLen() > 0 or self.input.interface.bufferedLen() > 0;
    }

    /// Why a read failed: the socket's reason if it had one, else TLS's.
    fn readError(self: *Tls) anyerror {
        if (self.input.err != null) return self.input.failure();
        return self.client.read_err orelse error.ReadFailed;
    }

    fn mapRead(self: *Tls, result: anytype) !@typeInfo(@TypeOf(result)).error_union.payload {
        return result catch |err| switch (err) {
            error.ReadFailed => self.readError(),
            else => |e| e,
        };
    }
};

/// Reads a socket the way `std.Io.net.Stream.Reader` does, but waits for each
/// read no later than `deadline_ms`, and gives up at once when `stop_fd`
/// becomes readable.
const SocketReader = struct {
    interface: std.Io.Reader,
    fd: linux.fd_t,
    stop_fd: linux.fd_t,
    io: std.Io,
    deadline_ms: i64,
    err: ?anyerror = null,

    fn init(fd: linux.fd_t, stop_fd: linux.fd_t, io: std.Io, buffer: []u8, deadline_ms: i64) SocketReader {
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

    fn failure(self: *const SocketReader) anyerror {
        return self.err orelse error.ReadFailed;
    }

    /// Wait until the socket has something to read: true when it has, false
    /// at `deadline_ms`.
    fn waitUntil(self: *SocketReader, deadline_ms: i64) Error!bool {
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

/// The dealer's WebSocket.
const Dealer = struct {
    conn: Tls,
    receiver: websocket.Receiver,
    storage: []u8,
    /// Monotonic milliseconds of the last message in, of any kind.
    last_heard: i64,

    const Event = union(enum) {
        /// Nothing by the deadline.
        timeout,
        text: []const u8,
        ping: []const u8,
        close,
        /// Something that needs nothing done: a pong, or a message too long
        /// to take.
        skipped,
    };

    fn open(self: *Dealer, owner: *Client, at: spotify.HostPort, token: []const u8) !void {
        try self.conn.open(owner, at, nowMs(owner.io) + handshake_timeout_ms);
        errdefer self.conn.close(owner);

        var random: [16]u8 = undefined;
        owner.io.random(&random);
        const key = websocket.makeKey(random);

        var target_buf: [2048]u8 = undefined;
        var target: std.Io.Writer = .fixed(&target_buf);
        target.writeAll("/?access_token=") catch return error.TokenTooLong;
        spotify.writeEscaped(&target, token) catch return error.TokenTooLong;

        try websocket.writeHandshake(&self.conn.client.writer, at.host, target.buffered(), &key);
        try self.conn.flush();

        var http_reader: std.http.Reader = .{
            .in = &self.conn.client.reader,
            .interface = undefined,
            .state = .ready,
            .max_head_len = 16 * 1024,
        };
        const head = try self.conn.mapRead(http_reader.receiveHead());
        const status = statusOf(head) orelse return error.UnexpectedReply;
        websocket.checkHandshake(status, head, &key) catch |err| {
            log.warn("Spotify: the dealer answered {d} instead of opening", .{@backingInt(status)});
            return err;
        };

        self.storage = try owner.gpa.alloc(u8, max_message);
        self.receiver = .init(self.storage);
        self.last_heard = nowMs(owner.io);
    }

    fn close(self: *Dealer, owner: *Client) void {
        owner.gpa.free(self.storage);
        self.conn.close(owner);
    }

    fn send(self: *Dealer, owner: *Client, opcode: websocket.Opcode, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        owner.io.random(&mask);
        try websocket.writeFrame(&self.conn.client.writer, opcode, payload, mask);
        try self.conn.flush();
    }

    /// The next message, or `.timeout` if none has begun by `deadline_ms`.
    /// Once one has, the rest of it has `frame_timeout_ms` to arrive.
    fn next(self: *Dealer, owner: *Client, deadline_ms: i64) !Event {
        if (!self.conn.hasBuffered()) {
            if (!try self.conn.input.waitUntil(deadline_ms)) return .timeout;
        }
        self.conn.input.deadline_ms = nowMs(owner.io) + frame_timeout_ms;

        const message = self.receiver.next(&self.conn.client.reader) catch |err| switch (err) {
            error.MessageTooLarge => {
                log.warn("Spotify: skipped a dealer message longer than {d} bytes", .{max_message});
                return .skipped;
            },
            error.ReadFailed => return self.conn.readError(),
            else => |e| return e,
        };
        self.last_heard = nowMs(owner.io);
        return switch (message.opcode) {
            .text, .binary => .{ .text = message.payload },
            .ping => .{ .ping = message.payload },
            .close => .close,
            else => .skipped,
        };
    }
};

/// The status code of the response head `head`.
fn statusOf(head: []const u8) ?std.http.Status {
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return null;
    const code = std.fmt.parseInt(u10, head[9..12], 10) catch return null;
    return @fromBackingInt(@intCast(code));
}
