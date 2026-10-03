//! Receiving notices through a named pipe.
//!
//! Anything on the machine allowed to write to the pipe can put a notice on
//! the panel:
//!
//!     echo "Backup finished" > /run/sys-ink/notify
//!
//! One line is one notice, and a newer one replaces the one on show; see
//! `notice.pipeMessage`. The pipe is local by nature, which is its whole
//! security model: there is no port to expose, and who may write is decided by
//! ordinary file permissions.
//!
//! ## Who may write
//!
//! The pipe is created 0600, root only. `NOTIFY_GROUP` names a group whose
//! members may write too (0620), which is how an unprivileged program is let
//! in without opening it to every user on the machine.
//!
//! ## A writer while the daemon is down
//!
//! Opening a FIFO for writing blocks until something opens it for reading.
//! Under systemd the whole runtime directory goes away when the service stops,
//! so a writer fails at once instead; otherwise the pipe stays behind, and a
//! sender that must never hang should bound its write, e.g. with `timeout 2`.

const std = @import("std");
const linux = std.os.linux;
const syscall = @import("syscall.zig");
const notice = @import("notice.zig");
const parse = @import("parse.zig");

const log = std.log.scoped(.notice);

/// Most that one `receive` reads before handing back to its caller: a full
/// pipe, at Linux's default capacity.
///
/// Whatever was waiting when the main loop woke fits in that, so only a sender
/// still writing can run past it — and one that never stops (`yes > pipe`) must
/// not keep the loop from everything else it does, noticing a shutdown signal
/// included. The rest stays in the pipe, which poll then reports again.
const max_drain = 64 * 1024;

pub const Fifo = struct {
    fd: linux.fd_t,
    /// Holds the latest notice between the reads that find it and the caller.
    /// Room for a pretty-printed JSON notice around the longest text the panel
    /// shows: cutting JSON short would show it raw instead.
    latest: [4096]u8 = undefined,

    pub const Error = error{ NameTooLong, CreateFailed, OpenFailed, NotAFifo };

    /// Create the pipe, or reuse one a previous run left behind, and open it.
    pub fn open(io: std.Io, path: []const u8, group: ?[]const u8) Error!Fifo {
        var path_buf: [256]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.NameTooLong;

        makeParentDir(path);

        const mknod_rc = linux.mknodat(linux.AT.FDCWD, path_z, linux.S.IFIFO | 0o600, 0);
        switch (syscall.errno(mknod_rc)) {
            .SUCCESS, .EXIST => {},
            else => |err| {
                log.err("Cannot create notice pipe {s}: {t}", .{ path, err });
                return error.CreateFailed;
            },
        }

        // Read-write, not read-only: holding a writer end ourselves means the
        // pipe never reports end-of-file between one sender closing and the
        // next opening, which would otherwise leave poll signalling a hangup
        // in a tight loop. Linux defines O_RDWR on a FIFO; POSIX does not.
        const open_rc = linux.openat(linux.AT.FDCWD, path_z, .{
            .ACCMODE = .RDWR,
            .NONBLOCK = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0);
        if (!syscall.ok(open_rc)) {
            log.err("Cannot open notice pipe {s}: {t}", .{ path, syscall.errno(open_rc) });
            return error.OpenFailed;
        }
        const fd: linux.fd_t = @intCast(open_rc);
        errdefer _ = linux.close(fd);

        // Checked on the open descriptor, not the path, so nothing can be
        // swapped in between. What was there already may be anything at all.
        var st: linux.Statx = undefined;
        if (!syscall.ok(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &st)) or
            !linux.S.ISFIFO(st.mode))
        {
            log.err("{s} exists and is not a pipe; remove it or set NOTIFY_FIFO", .{path});
            return error.NotAFifo;
        }

        restrictAccess(io, fd, group);
        return .{ .fd = fd };
    }

    pub fn close(self: *Fifo) void {
        _ = linux.close(self.fd);
    }

    /// Read everything waiting and return the latest notice in it, if any.
    /// Borrowed: valid until the next call.
    ///
    /// All of it is gathered before it is looked at, so a line that straddles
    /// two reads, or a JSON notice written over several lines, stays whole.
    /// "Everything" stops at `max_drain`, so this always returns.
    pub fn receive(self: *Fifo) ?[]const u8 {
        var data: [8192]u8 = undefined;
        var len: usize = 0;
        var drained: usize = 0;

        while (drained < max_drain) {
            // More than fits: the newest half is kept, since the latest notice
            // is at the end.
            if (len == data.len) {
                const half = data.len / 2;
                std.mem.copyForwards(u8, data[0..half], data[half..]);
                len = half;
            }

            const want = @min(data.len - len, max_drain - drained);
            const rc = linux.read(self.fd, data[len..].ptr, want);
            switch (syscall.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => break,
                else => |err| {
                    log.warn("Reading the notice pipe failed: {t}", .{err});
                    break;
                },
            }
            if (rc == 0) break;
            len += rc;
            drained += rc;
        }

        const message = notice.pipeMessage(data[0..len]) orelse return null;
        const n = @min(message.len, self.latest.len);
        @memcpy(self.latest[0..n], message[0..n]);
        return self.latest[0..n];
    }
};

/// The pipe's directory, if it is missing. Only the last component: anything
/// further up is not ours to create. A failure shows up as the mknod after it.
fn makeParentDir(path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    var buf: [256]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&buf, "{s}", .{dir}) catch return;
    _ = linux.mkdirat(linux.AT.FDCWD, dir_z, 0o755);
}

/// Root only, or root and `group` when one is given and exists.
fn restrictAccess(io: std.Io, fd: linux.fd_t, group: ?[]const u8) void {
    const gid = if (group) |name| lookupGroup(io, name) else null;
    if (group != null and gid == null) {
        log.warn("Group {s} not found; the notice pipe stays root-only", .{group.?});
    }

    if (gid) |id| {
        // Owner left as it is: -1 means "unchanged".
        if (!syscall.ok(linux.fchown(fd, std.math.maxInt(linux.uid_t), id))) {
            log.warn("Cannot hand the notice pipe to group {s}", .{group.?});
            return;
        }
    }

    const mode: linux.mode_t = if (gid != null) 0o620 else 0o600;
    if (!syscall.ok(linux.fchmod(fd, mode))) {
        log.warn("Cannot set the notice pipe's permissions", .{});
    }
}

fn lookupGroup(io: std.Io, name: []const u8) ?u32 {
    const file = std.Io.Dir.openFileAbsolute(io, "/etc/group", .{}) catch return null;
    defer file.close(io);

    var buf: [32 * 1024]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    return parse.groupId(buf[0..n], name);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
//
// Linux only, as the module is: `tests.zig` leaves it out anywhere else.

const testing = std.testing;

/// Where one test's pipe goes: a directory of its own, which `open` creates
/// and `cleanup` removes. Call `init` on it where it will stay, since the
/// paths point into its own buffers.
const Scratch = struct {
    dir_buf: [64]u8 = undefined,
    path_buf: [72]u8 = undefined,
    dir: [:0]const u8 = undefined,
    path: [:0]const u8 = undefined,

    var next: std.atomic.Value(u32) = .init(0);

    fn init(self: *Scratch) !void {
        const n = next.fetchAdd(1, .monotonic);
        self.dir = try std.fmt.bufPrintZ(&self.dir_buf, "/tmp/sys-ink-test-{d}-{d}", .{ linux.getpid(), n });
        self.path = try std.fmt.bufPrintZ(&self.path_buf, "{s}/notify", .{self.dir});
    }

    fn cleanup(self: *Scratch) void {
        _ = linux.unlinkat(linux.AT.FDCWD, self.path, 0);
        _ = linux.unlinkat(linux.AT.FDCWD, self.dir, linux.AT.REMOVEDIR);
    }
};

/// What `echo text > pipe` does: open for writing, write, close.
fn send(path: [:0]const u8, bytes: []const u8) !void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    if (!syscall.ok(rc)) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    if (linux.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.WriteFailed;
}

/// What poll has to say about `fd` right now.
fn polled(fd: linux.fd_t) i16 {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = std.posix.poll(&fds, 0) catch return std.posix.POLL.ERR;
    return fds[0].revents;
}

fn permissions(fd: linux.fd_t) !u32 {
    var st: linux.Statx = undefined;
    if (!syscall.ok(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MODE = true }, &st))) return error.StatFailed;
    return @as(u32, st.mode) & 0o777;
}

test "what a sender writes to the pipe is received, once" {
    var scratch: Scratch = .{};
    try scratch.init();
    defer scratch.cleanup();

    var fifo = try Fifo.open(testing.io, scratch.path, null);
    defer fifo.close();

    try testing.expect(fifo.receive() == null);

    try send(scratch.path, "Backup finished\n");
    try testing.expect(polled(fifo.fd) & std.posix.POLL.IN != 0);
    try testing.expectEqualStrings("Backup finished", fifo.receive().?);
    try testing.expect(fifo.receive() == null);

    // The sender has closed its end. With a writer end held here that is not
    // an end-of-file, so poll has nothing to report: no hangup to spin on.
    try testing.expectEqual(@as(i16, 0), polled(fifo.fd));

    // The next sender is heard too, and of several notices the last is kept.
    try send(scratch.path, "first\n");
    try send(scratch.path, "{\"text\": \"second\"}\n");
    try testing.expectEqualStrings("{\"text\": \"second\"}", fifo.receive().?);
}

test "the pipe is its owner's alone, even where a looser one was left behind" {
    var scratch: Scratch = .{};
    try scratch.init();
    defer scratch.cleanup();

    {
        var fifo = try Fifo.open(testing.io, scratch.path, null);
        defer fifo.close();
        try testing.expectEqual(@as(u32, 0o600), try permissions(fifo.fd));
    }

    // Still there from that run, and opened up to everyone since.
    try testing.expect(syscall.ok(linux.fchmodat(linux.AT.FDCWD, scratch.path, 0o666)));

    var fifo = try Fifo.open(testing.io, scratch.path, null);
    defer fifo.close();
    try testing.expectEqual(@as(u32, 0o600), try permissions(fifo.fd));
}

test "a group that does not exist lets nobody else in" {
    var scratch: Scratch = .{};
    try scratch.init();
    defer scratch.cleanup();

    // The warning is expected; keep it out of the test output.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;

    var fifo = try Fifo.open(testing.io, scratch.path, "sys-ink-no-such-group");
    defer fifo.close();
    try testing.expectEqual(@as(u32, 0o600), try permissions(fifo.fd));
}

test "a sender that never stops is read a pipeful at a time" {
    var scratch: Scratch = .{};
    try scratch.init();
    defer scratch.cleanup();

    var fifo = try Fifo.open(testing.io, scratch.path, null);
    defer fifo.close();

    // Room for several times what one call may read, which only a pipe made
    // larger than the default has.
    if (!syscall.ok(linux.fcntl(fifo.fd, linux.F.SETPIPE_SZ, 4 * max_drain))) return error.SkipZigTest;

    // Our own descriptor is read-write, so it can stand in for the sender.
    // Each write is under PIPE_BUF, so it goes in whole or not at all.
    const lines = "flood\n" ** 512;
    var written: usize = 0;
    while (written < 3 * max_drain) {
        const rc = linux.write(fifo.fd, lines, lines.len);
        if (!syscall.ok(rc)) break;
        written += rc;
    }
    try testing.expect(written > 2 * max_drain);

    var calls: usize = 0;
    while (polled(fifo.fd) & std.posix.POLL.IN != 0) : (calls += 1) {
        try testing.expect(calls < 8);
        try testing.expect(fifo.receive() != null);
    }
    // Every call but the last stopped at its budget with more still waiting.
    try testing.expectEqual((written + max_drain - 1) / max_drain, calls);
}
