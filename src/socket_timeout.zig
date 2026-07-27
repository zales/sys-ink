//! Send and receive deadlines on a socket.
//!
//! `std.Io.net.Stream` has no notion of a deadline, so a peer that opens a
//! connection and then says nothing blocks a read for as long as it cares to.
//! `SO_RCVTIMEO` and `SO_SNDTIMEO` make that read fail instead, which is the
//! difference between a server that recovers and one that is simply gone: the
//! panel preview, before this existed, could be taken down for good by a single
//! connection that sent no request.
//!
//! Kept apart from `bounded_connect.zig`, which exists only until `std`
//! implements `ConnectOptions.timeout` and is meant to be deleted then. Deadlines
//! on an already-open socket are needed either way.

const std = @import("std");
const linux = std.os.linux;
const syscall = @import("syscall.zig");

pub const Error = error{SetTimeoutFailed};

/// Fail reads and writes on `fd` that make no progress within `timeout_ms`.
///
/// A timed-out operation reports `EAGAIN`, which surfaces through the stream as a
/// read or write error — so callers must treat those as "this peer is done" and
/// close, rather than retrying forever.
pub fn set(fd: std.posix.fd_t, timeout_ms: u32) Error!void {
    const tv = linux.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };

    for ([_]u32{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |option| {
        const rc = linux.setsockopt(fd, linux.SOL.SOCKET, option, @ptrCast(&tv), @sizeOf(linux.timeval));
        if (!syscall.ok(rc)) return error.SetTimeoutFailed;
    }
}
