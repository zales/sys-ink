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

const std = @import("std");
const net = std.Io.net;
const bmp = @import("bmp.zig");
const display_config = @import("display_config.zig");
const frame_server = @import("frame_server.zig");

const log = std.log.scoped(.preview);

const width = display_config.DISPLAY_WIDTH;
const height = display_config.DISPLAY_HEIGHT;
const frame_bytes = ((width + 7) / 8) * height;

pub const WebPreview = struct {
    io: std.Io,
    address: net.IpAddress,
    server: net.Server,
    task: ?std.Io.Future(void) = null,

    /// Guards `frame` and `have_frame` between the render loop and the server.
    mutex: std.Io.Mutex = .init,
    frame: [frame_bytes]u8 = @splat(0xFF),
    have_frame: bool = false,

    /// Cleared to make the accept loop stop at its next time around.
    running: std.atomic.Value(bool) = .init(true),

    /// Bind the port. Serving does not begin until `start`.
    ///
    /// Split in two because `start` hands the runtime a pointer to this struct,
    /// which therefore must already be at its final address — the same
    /// constraint the renderer has with its transport.
    pub fn init(io: std.Io, addr: []const u8, port: u16) !WebPreview {
        const address = net.IpAddress.parse(addr, port) catch {
            log.err("WEB_PREVIEW_ADDR is not an address: {s}", .{addr});
            return error.InvalidAddress;
        };

        return .{
            .io = io,
            .address = address,
            .server = try address.listen(io, .{ .reuse_address = true }),
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
    }

    fn serveLoop(self: *WebPreview) void {
        var request_buf: [1024]u8 = undefined;
        var image: [bmp.byteSize(width, height)]u8 = undefined;
        var snapshot: [frame_bytes]u8 = undefined;

        while (self.running.load(.acquire)) {
            const stream = self.server.accept(self.io) catch |err| {
                if (!self.running.load(.acquire)) return;
                log.debug("Preview accept failed: {t}", .{err});
                continue;
            };
            defer stream.close(self.io);

            if (!self.running.load(.acquire)) return;

            switch (frame_server.readRequest(stream, self.io, &request_buf) orelse continue) {
                .index => frame_server.respondPage(stream, self.io, "Live panel"),
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
                .other => frame_server.respondNotFound(stream, self.io),
            }
        }
    }
};
