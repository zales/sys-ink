const std = @import("std");
const builtin = @import("builtin");
const GpioNative = @import("../gpio_native.zig").GpioNative;
const syscall = @import("../syscall.zig");

const log = std.log.scoped(.epd_config);

const is_linux = builtin.target.os.tag == .linux;

/// GPIO and SPI configuration for Waveshare e-ink display using native chardev
pub const EpdConfig = struct {
    // Pin definitions (BCM numbering)
    pub const RST_PIN: u32 = 17;
    pub const DC_PIN: u32 = 25;
    pub const CS_PIN: u32 = 8;
    pub const BUSY_PIN: u32 = 24;
    pub const PWR_PIN: u32 = 18;

    allocator: std.mem.Allocator,
    spi_fd: std.posix.fd_t,

    line_rst: ?GpioNative.Handle,
    line_dc: ?GpioNative.Handle,
    line_pwr: ?GpioNative.Handle,
    line_busy: ?GpioNative.Handle,

    pub fn init(allocator: std.mem.Allocator) EpdConfig {
        return .{
            .allocator = allocator,
            .spi_fd = -1,
            .line_rst = null,
            .line_dc = null,
            .line_pwr = null,
            .line_busy = null,
        };
    }

    /// Initialize SPI and GPIO using chardev
    pub fn moduleInit(self: *EpdConfig) !void {
        if (!is_linux) return error.UnsupportedPlatform;

        // Ensure partial initialization is cleaned up on failure. moduleExit is
        // idempotent, so the later deinit-time call is a no-op.
        errdefer self.moduleExit();

        const chip_path = @import("../config.zig").Config.gpio_chip;
        log.info("Requesting GPIO lines from {s}", .{chip_path});

        // Request pins
        self.line_rst = try GpioNative.requestLine(chip_path, RST_PIN, .Output);
        self.line_dc = try GpioNative.requestLine(chip_path, DC_PIN, .Output);
        self.line_pwr = try GpioNative.requestLine(chip_path, PWR_PIN, .Output);
        self.line_busy = try GpioNative.requestLine(chip_path, BUSY_PIN, .Input);

        log.info("All GPIO lines requested successfully", .{});

        // Set initial values - PWR high (on)
        try self.digitalWrite(PWR_PIN, 1);
        log.info("Power on, waiting for display to stabilize", .{});
        self.delayMs(200); // Give display time to power up

        const spi_path = @import("../config.zig").Config.spi_device;
        log.info("Opening SPI device {s}", .{spi_path});
        self.spi_fd = std.posix.openat(std.posix.AT.FDCWD, spi_path, .{ .ACCMODE = .RDWR }, 0) catch |err| {
            log.err("Failed to open SPI device {s}: {t}", .{ spi_path, err });
            log.err("Is SPI enabled, and is this user in the 'spi' group?", .{});
            return error.SpiOpenFailed;
        };

        log.info("Configuring SPI", .{});
        const SPI_IOC_WR_MODE: u32 = 0x40016b01;
        const SPI_IOC_WR_BITS_PER_WORD: u32 = 0x40016b03;
        const SPI_IOC_WR_MAX_SPEED_HZ: u32 = 0x40046b04;

        var mode: u8 = 0; // SPI_MODE_0
        var bits: u8 = 8;
        var speed: u32 = 10_000_000; // 10MHz (SSD1680 supports up to 20MHz)

        try self.spiIoctl(SPI_IOC_WR_MODE, @intFromPtr(&mode), "mode");
        try self.spiIoctl(SPI_IOC_WR_BITS_PER_WORD, @intFromPtr(&bits), "bits per word");
        try self.spiIoctl(SPI_IOC_WR_MAX_SPEED_HZ, @intFromPtr(&speed), "max speed");

        log.info("SPI configured successfully", .{});
    }

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
        self.digitalWrite(RST_PIN, 0) catch {};
        self.digitalWrite(DC_PIN, 0) catch {};
        self.digitalWrite(PWR_PIN, 0) catch {};

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

        // CS_PIN (Chip Select) is automatically controlled by SPI hardware driver
        // when using /dev/spidev. Manual GPIO control would interfere with SPI timing.
        if (pin == CS_PIN) return;

        const handle = switch (pin) {
            RST_PIN => self.line_rst,
            DC_PIN => self.line_dc,
            PWR_PIN => self.line_pwr,
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

        if (pin != BUSY_PIN) return error.InvalidPin;

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
