//! GPIO character device access, v2 ABI.
//!
//! The v1 interface this replaced (GPIOHANDLE_*) has been deprecated since Linux
//! 5.10. Behaviour is deliberately unchanged: lines are still requested as plain
//! inputs and outputs with no bias, so nothing about the electrical setup moves.
//! v2 does allow biasing — which would let a disconnected panel's floating BUSY
//! line read as busy instead of idle, and so be reported rather than silently
//! looking fine — but that is a change to working hardware and belongs in its own
//! commit.

const std = @import("std");
const ioctl = @import("ioctl.zig");
const syscall = @import("syscall.zig");

pub const GpioNative = struct {
    pub const RequestType = enum { Input, Output };

    pub const Handle = struct {
        fd: std.posix.fd_t,

        pub fn deinit(self: Handle) void {
            _ = std.os.linux.close(self.fd);
        }

        pub fn setValue(self: Handle, value: u8) !void {
            // One line per request, so it is always bit 0.
            var values = LineValues{ .bits = @intFromBool(value != 0), .mask = 1 };

            const rc = std.os.linux.ioctl(self.fd, LINE_SET_VALUES_IOCTL, @intFromPtr(&values));
            if (!syscall.ok(rc)) return error.GpioSetFailed;
        }

        pub fn getValue(self: Handle) !u8 {
            var values = LineValues{ .bits = 0, .mask = 1 };

            const rc = std.os.linux.ioctl(self.fd, LINE_GET_VALUES_IOCTL, @intFromPtr(&values));
            if (!syscall.ok(rc)) return error.GpioGetFailed;

            return @intFromBool(values.bits & 1 != 0);
        }
    };

    // ------------------------------------------------------------------------
    // uapi/linux/gpio.h, v2
    // ------------------------------------------------------------------------

    const lines_max = 64;
    const line_attrs_max = 10;
    const name_size = 32;

    const flag_input: u64 = 1 << 2;
    const flag_output: u64 = 1 << 3;

    const LineAttribute = extern struct {
        id: u32,
        padding: u32,
        /// Union of flags, values and debounce_period_us; all 64-bit aligned.
        value: u64,
    };

    const LineConfigAttribute = extern struct {
        attr: LineAttribute,
        mask: u64,
    };

    const LineConfig = extern struct {
        flags: u64,
        num_attrs: u32,
        padding: [5]u32,
        attrs: [line_attrs_max]LineConfigAttribute,
    };

    const LineRequest = extern struct {
        offsets: [lines_max]u32,
        consumer: [name_size]u8,
        config: LineConfig,
        num_lines: u32,
        event_buffer_size: u32,
        padding: [5]u32,
        fd: i32,
    };

    const LineValues = extern struct {
        bits: u64,
        mask: u64,
    };

    /// struct gpiochip_info, which both ABI versions share.
    const ChipInfo = extern struct {
        name: [name_size]u8,
        label: [name_size]u8,
        lines: u32,
    };

    comptime {
        // Sizes taken from uapi/linux/gpio.h. The request numbers below are
        // derived from them (see `ioctl.zig`), so if any of these trip, one of
        // those would be a number the kernel does not recognise.
        std.debug.assert(@sizeOf(LineAttribute) == 16);
        std.debug.assert(@sizeOf(LineConfigAttribute) == 24);
        std.debug.assert(@sizeOf(LineConfig) == 272);
        std.debug.assert(@sizeOf(LineRequest) == 592);
        std.debug.assert(@sizeOf(LineValues) == 16);
        std.debug.assert(@sizeOf(ChipInfo) == 68);
    }

    // Named as uapi/linux/gpio.h names them, the v2 ones less their GPIO_V2_
    // prefix. Everything else here is snake_case, as the language's style has
    // it; a name established elsewhere is the exception that style allows, and
    // these are looked up in the kernel's headers and in what
    // `tools/check_ioctl.c` prints.
    const GPIO_GET_CHIPINFO_IOCTL = ioctl.ior(0xB4, 0x01, ChipInfo);
    const GET_LINE_IOCTL = ioctl.iowr(0xB4, 0x07, LineRequest);
    const LINE_GET_VALUES_IOCTL = ioctl.iowr(0xB4, 0x0E, LineValues);
    const LINE_SET_VALUES_IOCTL = ioctl.iowr(0xB4, 0x0F, LineValues);

    pub fn requestLine(chip_path: []const u8, pin: u32, direction: RequestType) !Handle {
        const chip_fd = try std.posix.openat(std.posix.AT.FDCWD, chip_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        defer _ = std.os.linux.close(chip_fd);

        var req = std.mem.zeroes(LineRequest);
        req.num_lines = 1;
        req.offsets[0] = pin;
        req.config.flags = switch (direction) {
            .Input => flag_input,
            .Output => flag_output,
        };

        const label = "sys-ink";
        @memcpy(req.consumer[0..label.len], label);

        const rc = std.os.linux.ioctl(chip_fd, GET_LINE_IOCTL, @intFromPtr(&req));
        if (!syscall.ok(rc)) return error.GpioRequestFailed;

        return .{ .fd = req.fd };
    }

    /// GPIO chip labels for the SoCs this runs on, most recent first.
    const known_chip_labels = [_][]const u8{
        "pinctrl-rp1", // Pi 5
        "pinctrl-bcm2711", // Pi 4
        "pinctrl-bcm2835", // Pi 3 and older
    };

    /// Longest path `findChip` writes.
    pub const chip_path_max = 32;

    /// Path of the header's GPIO chip, written into `buf`, or null when no
    /// chip carries a label that is known.
    ///
    /// By label because the number is not fixed: the header is gpiochip0 on a
    /// Pi 4 and gpiochip4 on a Pi 5 with an older kernel.
    pub fn findChip(buf: *[chip_path_max]u8) ?[]const u8 {
        for (known_chip_labels) |label| {
            if (findChipByLabel(buf, label)) |path| return path;
        }
        return null;
    }

    /// Scan /dev/gpiochip0..31 for the chip labelled `label`, as `gpiodetect`
    /// does.
    fn findChipByLabel(buf: *[chip_path_max]u8, label: []const u8) ?[]const u8 {
        for (0..32) |i| {
            const path = std.mem.printSentinel(buf, "/dev/gpiochip{d}", .{i}, 0) catch continue;
            const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch continue;
            defer _ = std.os.linux.close(fd);

            var info: ChipInfo = undefined;
            const rc = std.os.linux.ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, @intFromPtr(&info));
            if (!syscall.ok(rc)) continue;

            if (std.mem.eql(u8, std.mem.sliceTo(&info.label, 0), label)) return path;
        }
        return null;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "the request numbers are the ones the kernel's headers define" {
    // As `tools/check_ioctl.c` prints them from uapi/linux/gpio.h. A struct
    // that drifted from the kernel's layout would change its size, and with
    // it the number, into one the kernel answers with ENOTTY.
    try testing.expectEqual(@as(u32, 0x8044b401), GpioNative.GPIO_GET_CHIPINFO_IOCTL);
    try testing.expectEqual(@as(u32, 0xc250b407), GpioNative.GET_LINE_IOCTL);
    try testing.expectEqual(@as(u32, 0xc010b40e), GpioNative.LINE_GET_VALUES_IOCTL);
    try testing.expectEqual(@as(u32, 0xc010b40f), GpioNative.LINE_SET_VALUES_IOCTL);
}
