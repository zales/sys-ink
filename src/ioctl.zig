//! ioctl request numbers, as the kernel's _IOC macros compute them.
//!
//! A request number carries the size of what the request takes. Deriving it
//! from the Zig type therefore means that a struct whose layout has drifted
//! from the kernel's yields a number the kernel does not know, and the call
//! fails with ENOTTY, instead of one it does know and a result that is subtly
//! wrong. Each module that makes such a call pins the numbers it derives
//! against the kernel's own in a test; `tools/check_ioctl.c` prints those.
//!
//! This is the generic encoding, which the daemon's targets all use: ARM,
//! aarch64 and x86. MIPS, PowerPC and SPARC lay the direction bits out
//! differently.

const std = @import("std");

/// Which way the data goes, seen from the caller.
const Direction = enum(u2) { write = 1, read = 2, read_write = 3 };

fn request(comptime direction: Direction, comptime group: u8, comptime number: u8, comptime T: type) u32 {
    // Fourteen bits in the encoding; no request here comes near.
    comptime std.debug.assert(@sizeOf(T) < 1 << 14);
    return (@as(u32, @backingInt(direction)) << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, group) << 8) | number;
}

/// _IOR(group, number, T): the kernel fills in a `T`.
pub fn ior(comptime group: u8, comptime number: u8, comptime T: type) u32 {
    return request(.read, group, number, T);
}

/// _IOW(group, number, T): the caller hands the kernel a `T`.
pub fn iow(comptime group: u8, comptime number: u8, comptime T: type) u32 {
    return request(.write, group, number, T);
}

/// _IOWR(group, number, T): a `T` goes in and comes back changed.
pub fn iowr(comptime group: u8, comptime number: u8, comptime T: type) u32 {
    return request(.read_write, group, number, T);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "each direction lands in the two bits the kernel reads it from" {
    // One request of each kind the daemon makes, by the size it takes alone:
    // SPI_IOC_WR_MODE, GPIO_GET_CHIPINFO_IOCTL and NVME_IOCTL_ADMIN_CMD.
    try testing.expectEqual(@as(u32, 0x40016b01), iow('k', 1, u8));
    try testing.expectEqual(@as(u32, 0x8044b401), ior(0xB4, 0x01, [68]u8));
    try testing.expectEqual(@as(u32, 0xc0484e41), iowr('N', 0x41, [72]u8));
}

test "the size of what a request takes is part of its number" {
    try testing.expect(iow('k', 4, u32) != iow('k', 4, u8));
    try testing.expectEqual(@as(u32, 0x40046b04), iow('k', 4, u32));
}
