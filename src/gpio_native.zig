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
            if (std.posix.errno(rc) != .SUCCESS) return error.GpioSetFailed;
        }

        pub fn getValue(self: Handle) !u8 {
            var values = LineValues{ .bits = 0, .mask = 1 };

            const rc = std.os.linux.ioctl(self.fd, LINE_GET_VALUES_IOCTL, @intFromPtr(&values));
            if (std.posix.errno(rc) != .SUCCESS) return error.GpioGetFailed;

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

    /// _IOWR(type, nr, size) as the kernel computes it.
    ///
    /// Derived from `@sizeOf` rather than written out as a literal: the size is
    /// part of the request number, so a struct that does not match the kernel's
    /// layout produces a wrong ioctl instead of a subtly wrong result. The
    /// assertions below pin the layouts the kernel actually expects.
    fn iowr(comptime typ: u8, comptime nr: u8, comptime T: type) u32 {
        return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, typ) << 8) | nr;
    }

    comptime {
        // Sizes taken from uapi/linux/gpio.h. If any of these trip, `iowr` would
        // silently produce a request number the kernel does not recognise.
        std.debug.assert(@sizeOf(LineAttribute) == 16);
        std.debug.assert(@sizeOf(LineConfigAttribute) == 24);
        std.debug.assert(@sizeOf(LineConfig) == 272);
        std.debug.assert(@sizeOf(LineRequest) == 592);
        std.debug.assert(@sizeOf(LineValues) == 16);
    }

    const GET_LINE_IOCTL = iowr(0xB4, 0x07, LineRequest);
    const LINE_GET_VALUES_IOCTL = iowr(0xB4, 0x0E, LineValues);
    const LINE_SET_VALUES_IOCTL = iowr(0xB4, 0x0F, LineValues);

    pub fn requestLine(chip_path: []const u8, pin: u32, direction: RequestType) !Handle {
        const chip_fd = try std.posix.openat(std.posix.AT.FDCWD, chip_path, .{ .ACCMODE = .RDWR }, 0);
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
        if (std.posix.errno(rc) != .SUCCESS) return error.GpioRequestFailed;

        return .{ .fd = req.fd };
    }
};
