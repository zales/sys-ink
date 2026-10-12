const std = @import("std");
const builtin = @import("builtin");
const GpioNative = @import("../gpio_native.zig").GpioNative;
const ioctl = @import("../ioctl.zig");
const syscall = @import("../syscall.zig");

const log = std.log.scoped(.epd_config);

const is_linux = builtin.target.os.tag == .linux;

/// GPIO and SPI configuration for Waveshare e-ink display using native chardev
pub const EpdConfig = struct {
    // Pin definitions (BCM numbering)
    pub const rst_pin: u32 = 17;
    pub const dc_pin: u32 = 25;
    pub const cs_pin: u32 = 8;
    pub const busy_pin: u32 = 24;
    pub const pwr_pin: u32 = 18;

    pub const Options = struct {
        /// GPIO chip the panel's lines are on. Null: the one whose label says
        /// it is the header's, and failing that `fallback_gpio_chip`.
        gpio_chip: ?[]const u8 = null,
        spi_device: []const u8 = "/dev/spidev0.0",
    };

    /// Where the header is on every Pi up to the 4.
    const fallback_gpio_chip = "/dev/gpiochip0";

    options: Options,
    spi_fd: std.posix.fd_t = -1,

    line_rst: ?GpioNative.Handle = null,
    line_dc: ?GpioNative.Handle = null,
    line_pwr: ?GpioNative.Handle = null,
    line_busy: ?GpioNative.Handle = null,

    pub fn init(options: Options) EpdConfig {
        return .{ .options = options };
    }

    /// Initialize SPI and GPIO using chardev
    pub fn moduleInit(self: *EpdConfig) !void {
        if (!is_linux) return error.UnsupportedPlatform;

        // Ensure partial initialization is cleaned up on failure. moduleExit is
        // idempotent, so the later deinit-time call is a no-op.
        errdefer self.moduleExit();

        var found_chip: [GpioNative.chip_path_max]u8 = undefined;
        const chip_path = self.options.gpio_chip orelse
            GpioNative.findChip(&found_chip) orelse
            fallback_gpio_chip;
        log.info("Requesting GPIO lines from {s}", .{chip_path});

        // Request pins
        self.line_rst = try GpioNative.requestLine(chip_path, rst_pin, .output);
        self.line_dc = try GpioNative.requestLine(chip_path, dc_pin, .output);
        self.line_pwr = try GpioNative.requestLine(chip_path, pwr_pin, .output);
        self.line_busy = try GpioNative.requestLine(chip_path, busy_pin, .input);

        log.info("All GPIO lines requested successfully", .{});

        // Set initial values - PWR high (on)
        try self.digitalWrite(pwr_pin, 1);
        log.info("Power on, waiting for display to stabilize", .{});
        self.delayMs(200); // Give display time to power up

        const spi_path = self.options.spi_device;
        log.info("Opening SPI device {s}", .{spi_path});
        self.spi_fd = std.posix.openat(std.posix.AT.FDCWD, spi_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch |err| {
            log.err("Failed to open SPI device {s}: {t}", .{ spi_path, err });
            log.err("Is SPI enabled, and is this user in the 'spi' group?", .{});
            return error.SpiOpenFailed;
        };

        log.info("Configuring SPI", .{});

        var mode: u8 = 0; // SPI_MODE_0
        var bits: u8 = 8;
        var speed: u32 = 10_000_000; // 10MHz (SSD1680 supports up to 20MHz)

        try self.spiIoctl(SPI_IOC_WR_MODE, @intFromPtr(&mode), "mode");
        try self.spiIoctl(SPI_IOC_WR_BITS_PER_WORD, @intFromPtr(&bits), "bits per word");
        try self.spiIoctl(SPI_IOC_WR_MAX_SPEED_HZ, @intFromPtr(&speed), "max speed");

        log.info("SPI configured successfully", .{});
    }

    // uapi/linux/spi/spidev.h, under the names it gives them. Derived from
    // the type each takes, as the GPIO and NVMe requests are from theirs, and
    // pinned by the test below.
    const SPI_IOC_WR_MODE = ioctl.iow('k', 1, u8);
    const SPI_IOC_WR_BITS_PER_WORD = ioctl.iow('k', 3, u8);
    const SPI_IOC_WR_MAX_SPEED_HZ = ioctl.iow('k', 4, u32);

    fn spiIoctl(self: *EpdConfig, request: u32, arg: usize, what: []const u8) !void {
        const rc = std.os.linux.ioctl(self.spi_fd, request, arg);
        const err = syscall.errno(rc);
        if (err != .SUCCESS) {
            log.err("Failed to set SPI {s}: errno={t}", .{ what, err });
            return error.SpiConfigFailed;
        }
    }

    /// Cleanup and close SPI/GPIO. Safe to call more than once.
    pub fn moduleExit(self: *EpdConfig) void {
        if (!is_linux) return;

        // Set pins low before releasing
        self.digitalWrite(rst_pin, 0) catch {};
        self.digitalWrite(dc_pin, 0) catch {};
        self.digitalWrite(pwr_pin, 0) catch {};

        // Release lines
        inline for (.{ "line_rst", "line_dc", "line_pwr", "line_busy" }) |field| {
            if (@field(self, field)) |h| {
                h.deinit();
                @field(self, field) = null;
            }
        }

        // Close SPI
        if (self.spi_fd >= 0) {
            _ = std.os.linux.close(self.spi_fd);
            self.spi_fd = -1;
        }
    }

    /// Write digital value to GPIO pin
    pub fn digitalWrite(self: *EpdConfig, pin: u32, value: u8) !void {
        if (!is_linux) return;

        // cs_pin (Chip Select) is automatically controlled by SPI hardware driver
        // when using /dev/spidev. Manual GPIO control would interfere with SPI timing.
        if (pin == cs_pin) return;

        const handle = switch (pin) {
            rst_pin => self.line_rst,
            dc_pin => self.line_dc,
            pwr_pin => self.line_pwr,
            else => return error.InvalidPin,
        };

        if (handle) |h| {
            try h.setValue(value);
        } else {
            return error.NotInitialized;
        }
    }

    /// Read digital value from GPIO pin
    pub fn digitalRead(self: *EpdConfig, pin: u32) !u8 {
        if (!is_linux) return 0;

        if (pin != busy_pin) return error.InvalidPin;

        if (self.line_busy) |h| {
            return try h.getValue();
        } else {
            return error.NotInitialized;
        }
    }

    /// Delay for specified milliseconds, resuming across signal interruptions.
    ///
    /// A method rather than a free function so the driver's notion of time comes
    /// entirely from its transport, and a test can substitute one that does not
    /// actually sleep.
    pub fn delayMs(_: *EpdConfig, millis: u64) void {
        if (!is_linux) return;

        var ts = std.os.linux.timespec{
            .sec = @intCast(millis / 1000),
            .nsec = @intCast((millis % 1000) * std.time.ns_per_ms),
        };
        while (true) {
            const rc = std.os.linux.nanosleep(&ts, &ts);
            if (syscall.errno(rc) != .INTR) return;
        }
    }

    /// Monotonic milliseconds, used for the busy-wait timeout.
    pub fn monotonicMillis(_: *EpdConfig) u64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    }

    /// Write bytes via SPI
    pub fn spiWrite(self: *EpdConfig, data: []const u8) !void {
        if (self.spi_fd < 0) return error.NotInitialized;

        // SPI has transfer size limits, split into chunks if needed
        const chunk_size = 4096;
        var offset: usize = 0;

        while (offset < data.len) {
            const to_write = @min(data.len - offset, chunk_size);
            const rc = std.os.linux.write(self.spi_fd, data.ptr + offset, to_write);
            const err = syscall.errno(rc);
            switch (err) {
                .SUCCESS => {
                    if (rc == 0) return error.SpiWriteFailed;
                    offset += rc;
                },
                .INTR => continue, // retry without advancing
                else => {
                    log.err("SPI write failed: errno={t}", .{err});
                    return error.SpiWriteFailed;
                },
            }
        }
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "the SPI request numbers are the ones the kernel's headers define" {
    // As `tools/check_ioctl.c` prints them from uapi/linux/spi/spidev.h.
    try testing.expectEqual(@as(u32, 0x40016b01), EpdConfig.SPI_IOC_WR_MODE);
    try testing.expectEqual(@as(u32, 0x40016b03), EpdConfig.SPI_IOC_WR_BITS_PER_WORD);
    try testing.expectEqual(@as(u32, 0x40046b04), EpdConfig.SPI_IOC_WR_MAX_SPEED_HZ);
}

test "nothing is driven before the transport is brought up" {
    var transport = EpdConfig.init(.{});
    try testing.expectError(error.NotInitialized, transport.spiWrite("x"));
    // Safe on a transport that never came up, and safe to repeat.
    transport.moduleExit();
    transport.moduleExit();
}
