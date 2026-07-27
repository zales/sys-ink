//! Interpreting the return value of a raw Linux syscall.
//!
//! `std.posix.errno` must not be used for this, and the reason is not obvious.
//! When the binary links libc — this one does — `std.posix.errno` resolves to
//! `std.c.errno`, which is:
//!
//!     if (rc == -1) @enumFromInt(_errno().*) else .SUCCESS
//!
//! That expects the libc convention: return -1, put the code in the `errno`
//! variable. Calls made through `std.os.linux` are raw syscalls that return
//! `-errno` directly and never touch that variable, so the comparison against
//! -1 never matches and *every failure was reported as success*. Worse, `rc` is
//! a `usize`, so the comparison is not merely wrong but constant.
//!
//! This shipped in eight places — every GPIO ioctl, the SPI configuration and
//! writes, the wake pipe, and the NVMe admin command. It surfaced only when a
//! deliberately broken NVMe node made the daemon announce a SMART critical
//! warning decoded from an uninitialised stack buffer.

const std = @import("std");

/// Error code carried by a raw syscall return, or `.SUCCESS`.
///
/// Kernel convention: values in [-4095, -1] are negated error codes, anything
/// else is a successful result.
pub fn errno(rc: usize) std.os.linux.E {
    const signed: isize = @bitCast(rc);
    const code = if (signed > -4096 and signed < 0) -signed else 0;
    return @enumFromInt(code);
}

/// Whether a raw syscall succeeded.
pub fn ok(rc: usize) bool {
    return errno(rc) == .SUCCESS;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

/// Reproduces `std.c.errno`, to demonstrate what it does with a raw return.
fn libcStyleErrno(rc: usize) bool {
    return rc == @as(usize, @bitCast(@as(isize, -1)));
}

test "a raw failure return is recognised as an error" {
    const enotty: usize = @bitCast(@as(isize, -25));
    try testing.expect(!ok(enotty));
    try testing.expectEqual(std.os.linux.E.NOTTY, errno(enotty));

    const ebadf: usize = @bitCast(@as(isize, -9));
    try testing.expect(!ok(ebadf));
    try testing.expectEqual(std.os.linux.E.BADF, errno(ebadf));
}

test "success and ordinary results are not mistaken for errors" {
    try testing.expect(ok(0));
    try testing.expect(ok(1));
    // A read() returning a large byte count, and a pointer-like value.
    try testing.expect(ok(65536));
    try testing.expect(ok(@bitCast(@as(isize, -4096))));
    try testing.expectEqual(std.os.linux.E.SUCCESS, errno(0));
}

test "the libc convention misses every raw error but -1" {
    // The bug this module exists to prevent. Only -1 would have been caught,
    // and no raw syscall returns -1 as an error.
    const enotty: usize = @bitCast(@as(isize, -25));
    try testing.expect(!libcStyleErrno(enotty));
    try testing.expect(!ok(enotty)); // ours does catch it

    // -1 is EPERM in the kernel convention, not a sentinel.
    const eperm: usize = @bitCast(@as(isize, -1));
    try testing.expectEqual(std.os.linux.E.PERM, errno(eperm));
}
