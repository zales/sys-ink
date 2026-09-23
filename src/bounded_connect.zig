//! A TCP connect that gives up after a deadline.
//!
//! `net.IpAddress.ConnectOptions` has a `timeout` field, which is what this
//! should be. It is not implemented in Zig 0.16: `Io.Threaded.netConnectIpPosix`
//! panics with "TODO implement netConnectIpPosix with timeout", which only shows
//! up at runtime. Until that lands, an unbounded connect to a host that drops
//! SYNs rather than refusing them blocks for the kernel's SYN timeout — roughly
//! two minutes with the default `tcp_syn_retries=6` — and everything here runs on
//! the same thread as the render loop.
//!
//! Delete this module and pass `.timeout` to `IpAddress.connect` once std
//! implements it.

const std = @import("std");
const syscall = @import("syscall.zig");
const net = std.Io.net;
const linux = std.os.linux;

pub const Error = error{
    SocketFailed,
    /// The connect neither completed nor failed within the deadline.
    Timeout,
    ConnectFailed,
};

/// Connect to `address` on `port`, giving up after `timeout_ms`.
///
/// `address` is the four octets in dotted-quad order, which is also their
/// network order, so no byte swapping is involved.
pub fn connect(address: [4]u8, port: u16, timeout_ms: i32) Error!std.posix.fd_t {
    // CLOEXEC: `apt` runs while a connection may be open, and a child holding a
    // copy of the socket keeps it alive after this process has closed it.
    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 6); // 6 = TCP
    if (@as(isize, @bitCast(sock_rc)) < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(sock_rc);

    errdefer _ = linux.close(fd);

    var addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    const connect_rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    switch (try connectStarted(syscall.errno(connect_rc))) {
        .connected => return fd,
        .pending => {},
    }

    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return error.ConnectFailed;
    if (ready == 0) return error.Timeout;
    try checkCompletion(fds[0].revents);

    // Writable only means the attempt finished; SO_ERROR says whether it worked.
    var so_error: c_int = 0;
    var so_error_len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &so_error_len);
    if (@as(isize, @bitCast(rc)) != 0 or so_error != 0) return error.ConnectFailed;

    return fd;
}

/// What the immediate return of a non-blocking `connect` means.
///
/// The return value has to be looked at. A connect that fails on the spot —
/// `ENETUNREACH` when there is no route, which is what losing the Wi-Fi or the
/// DHCP lease looks like — leaves the socket in `TCP_CLOSE` with no pending
/// error, and `tcp_poll` reports a closed socket as writable so that nothing
/// blocks on it. `SO_ERROR` then reads 0. Ignoring the return, as this used to,
/// turned "no network at all" into a successful connection, and the internet
/// indicator showed connected in exactly the case it exists for.
fn connectStarted(err: linux.E) Error!enum { connected, pending } {
    return switch (err) {
        .SUCCESS => .connected,
        // EINTR on a non-blocking connect still leaves it completing in the
        // background, so it is waited on like any other pending attempt.
        .INPROGRESS, .INTR => .pending,
        else => error.ConnectFailed,
    };
}

/// Reject a poll result that says the socket is writable only because it is
/// closed. Belt and braces with the check above: `POLLHUP` is set on a socket
/// that never got as far as `SYN_SENT`, and on one the peer reset.
fn checkCompletion(revents: i16) Error!void {
    const P = std.posix.POLL;
    if (revents & (P.ERR | P.HUP) != 0) return error.ConnectFailed;
    if (revents & P.OUT == 0) return error.ConnectFailed;
}

/// As `connect`, but returns a stream ready for the std reader and writer.
///
/// The socket is switched back to blocking, because everything in `std.Io.net`
/// expects that: `EAGAIN` on a socket it believes is blocking is classified as a
/// programmer bug and panics a Debug build. For the same reason no `SO_RCVTIMEO`
/// is installed here — a deadline belongs on the individual receive, via
/// `Socket.receiveTimeout`, which is what the caller uses.
pub fn connectStream(address: [4]u8, port: u16, timeout_ms: i32) Error!net.Stream {
    const fd = try connect(address, port, timeout_ms);
    errdefer closeFd(fd);

    try clearNonBlocking(fd);

    return .{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .{ .bytes = address, .port = port } },
    } };
}

fn clearNonBlocking(fd: std.posix.fd_t) Error!void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return error.ConnectFailed;

    const blocking = flags & ~@as(usize, 0o4000); // O_NONBLOCK
    const rc = linux.fcntl(fd, linux.F.SETFL, blocking);
    if (@as(isize, @bitCast(rc)) < 0) return error.ConnectFailed;
}

/// Wait until `fd` has room to send, giving up after `timeout_ms`.
///
/// A send deadline without `SO_SNDTIMEO`, for the reason `connectStream`
/// gives. Waiting for `POLLOUT` bounds the one case where a blocking send
/// blocks — a full send buffer, which is what a peer that has silently gone
/// away produces after enough unacknowledged writes — without ever making the
/// send itself return `EAGAIN`. It is sufficient for small writes: TCP reports
/// writable only while at least a third of the send buffer is free, several
/// kilobytes, and nothing sent through this is larger than one.
pub fn waitWritable(fd: std.posix.fd_t, timeout_ms: i32) error{ Timeout, PollFailed }!void {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return error.PollFailed;
    if (ready == 0) return error.Timeout;
    // An error or hangup is left for the send to report, with its own errno.
}

/// Close and discard a connection opened above, without needing an `Io`.
pub fn closeFd(fd: std.posix.fd_t) void {
    _ = linux.close(fd);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "a connect that fails on the spot is a failure, not a pending attempt" {
    // The regression: with no route to the host the kernel answers straight
    // away, and the answer used to be thrown away.
    try testing.expectError(error.ConnectFailed, connectStarted(.NETUNREACH));
    try testing.expectError(error.ConnectFailed, connectStarted(.ADDRNOTAVAIL));
    try testing.expectError(error.ConnectFailed, connectStarted(.CONNREFUSED));
}

test "an attempt in progress is waited on and an immediate success returned" {
    try testing.expectEqual(.pending, try connectStarted(.INPROGRESS));
    try testing.expectEqual(.pending, try connectStarted(.INTR));
    try testing.expectEqual(.connected, try connectStarted(.SUCCESS));
}

test "a socket that is writable because it is closed did not connect" {
    const P = std.posix.POLL;
    // What tcp_poll reports for a socket left in TCP_CLOSE.
    try testing.expectError(error.ConnectFailed, checkCompletion(P.OUT | P.HUP));
    try testing.expectError(error.ConnectFailed, checkCompletion(P.OUT | P.ERR));
    try testing.expectError(error.ConnectFailed, checkCompletion(0));
    try checkCompletion(P.OUT);
}
