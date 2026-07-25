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
    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 6); // 6 = TCP
    if (@as(isize, @bitCast(sock_rc)) < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(sock_rc);

    errdefer _ = linux.close(fd);

    var addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(address),
    };
    _ = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));

    // A non-blocking connect reports completion through poll, even when it
    // succeeds immediately.
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return error.ConnectFailed;
    if (ready == 0) return error.Timeout;
    if ((fds[0].revents & std.posix.POLL.OUT) == 0) return error.ConnectFailed;

    // Writable only means the attempt finished; SO_ERROR says whether it worked.
    var so_error: c_int = 0;
    var so_error_len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &so_error_len);
    if (@as(isize, @bitCast(rc)) != 0 or so_error != 0) return error.ConnectFailed;

    return fd;
}

/// As `connect`, but returns a stream ready for the std reader and writer.
///
/// The socket is switched back to blocking, because `Stream.Reader` expects that
/// — a non-blocking read returns EAGAIN, which surfaces as a read failure rather
/// than a wait. Send and receive deadlines are installed in its place, so a peer
/// that accepts the connection and then goes quiet cannot hang the render loop
/// either.
pub fn connectStream(address: [4]u8, port: u16, timeout_ms: i32) Error!net.Stream {
    const fd = try connect(address, port, timeout_ms);
    errdefer closeFd(fd);

    try clearNonBlocking(fd);
    try setIoDeadlines(fd, timeout_ms);

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

fn setIoDeadlines(fd: std.posix.fd_t, timeout_ms: i32) Error!void {
    const tv = linux.timeval{
        .sec = @intCast(@divTrunc(timeout_ms, 1000)),
        .usec = @intCast(@mod(timeout_ms, 1000) * 1000),
    };

    for ([_]u32{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |option| {
        const rc = linux.setsockopt(fd, linux.SOL.SOCKET, option, @ptrCast(&tv), @sizeOf(linux.timeval));
        if (@as(isize, @bitCast(rc)) != 0) return error.ConnectFailed;
    }
}

/// Close and discard a connection opened above, without needing an `Io`.
pub fn closeFd(fd: std.posix.fd_t) void {
    _ = linux.close(fd);
}
