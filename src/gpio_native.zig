const std = @import("std");

pub const GpioNative = struct {
    pub const RequestType = enum {
        Input,
        Output,
    };

    pub const Handle = struct {
        fd: std.posix.fd_t,
        
        pub fn deinit(self: Handle) void {
            std.posix.close(self.fd);
        }

        pub fn setValue(self: Handle, value: u8) !void {
            var data = GpioHandleData{ .values = undefined };
            @memset(&data.values, 0);
            data.values[0] = value;
            
            if (std.os.linux.ioctl(self.fd, GPIOHANDLE_SET_LINE_VALUES_IOCTL, @intFromPtr(&data)) != 0) {
                return error.GpioSetFailed;
            }
        }

        pub fn getValue(self: Handle) !u8 {
            var data = GpioHandleData{ .values = undefined };
            if (std.os.linux.ioctl(self.fd, GPIOHANDLE_GET_LINE_VALUES_IOCTL, @intFromPtr(&data)) != 0) {
                return error.GpioGetFailed;
            }
            return data.values[0];
        }
    };

    // Constants
    const GPIO_GET_LINEHANDLE_IOCTL: u32 = 0xc16cb403;
    const GPIOHANDLE_SET_LINE_VALUES_IOCTL: u32 = 0xc040b409;
    const GPIOHANDLE_GET_LINE_VALUES_IOCTL: u32 = 0xc040b408;

    const GPIOHANDLE_REQUEST_INPUT: u32 = 1;
    const GPIOHANDLE_REQUEST_OUTPUT: u32 = 2;

    const GpioHandleRequest = extern struct {
        lineoffsets: [64]u32,
        flags: u32,
        default_values: [64]u8,
        consumer_label: [32]u8,
        lines: u32,
        fd: i32,
    };

    const GpioHandleData = extern struct {
        values: [64]u8,
    };

    pub fn requestLine(chip_path: []const u8, pin: u32, direction: RequestType) !Handle {
        const chip_fd = try std.posix.open(chip_path, .{ .ACCMODE = .RDWR }, 0);
        defer std.posix.close(chip_fd);

        var req = GpioHandleRequest{
            .lineoffsets = undefined,
            .flags = 0,
            .default_values = undefined,
            .consumer_label = undefined,
            .lines = 1,
            .fd = 0,
        };
        @memset(&req.lineoffsets, 0);
        @memset(&req.default_values, 0);
        @memset(&req.consumer_label, 0);
        
        req.lineoffsets[0] = pin;
        req.flags = switch (direction) {
            .Input => GPIOHANDLE_REQUEST_INPUT,
            .Output => GPIOHANDLE_REQUEST_OUTPUT,
        };
        
        const label = "zlsnas";
        @memcpy(req.consumer_label[0..label.len], label);

        if (std.os.linux.ioctl(chip_fd, GPIO_GET_LINEHANDLE_IOCTL, @intFromPtr(&req)) != 0) {
            return error.GpioRequestFailed;
        }

        return Handle{ .fd = req.fd };
    }
};
