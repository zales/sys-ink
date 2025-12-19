const std = @import("std");
const GpioNative = @import("../gpio_native.zig").GpioNative;

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
        // Only on Linux
        if (@import("builtin").target.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }

        // Ensure partial initialization is cleaned up on failure
        errdefer self.moduleExit();
        self.spi_fd = -1;

        const chip_path = std.posix.getenv("GPIO_CHIP") orelse "/dev/gpiochip0";
        std.log.info("Requesting GPIO lines from {s}...", .{chip_path});

        // Request pins
        self.line_rst = try GpioNative.requestLine(chip_path, RST_PIN, .Output);
        self.line_dc = try GpioNative.requestLine(chip_path, DC_PIN, .Output);
        self.line_pwr = try GpioNative.requestLine(chip_path, PWR_PIN, .Output);
        self.line_busy = try GpioNative.requestLine(chip_path, BUSY_PIN, .Input);

        std.log.info("All GPIO lines requested successfully", .{});

        // Set initial values - PWR high (on)
        try self.digitalWrite(PWR_PIN, 1);
        std.log.info("Power on, waiting for display to stabilize...", .{});
        delayMs(200); // Give display time to power up

        std.log.info("Opening SPI device...", .{});
        // Open SPI device
        self.spi_fd = try std.posix.open("/dev/spidev0.0", .{ .ACCMODE = .RDWR }, 0);

        std.log.info("Configuring SPI...", .{});
        // Configure SPI
        const SPI_IOC_WR_MODE: u32 = 0x40016b01;
        const SPI_IOC_WR_BITS_PER_WORD: u32 = 0x40016b03;
        const SPI_IOC_WR_MAX_SPEED_HZ: u32 = 0x40046b04;

        var mode: u8 = 0; // SPI_MODE_0
        var bits: u8 = 8;
        var speed: u32 = 4000000; // 4MHz

        if (std.os.linux.ioctl(self.spi_fd, SPI_IOC_WR_MODE, @intFromPtr(&mode)) != 0) {
            std.log.err("Failed to set SPI mode", .{});
            return error.SpiConfigFailed;
        }
        if (std.os.linux.ioctl(self.spi_fd, SPI_IOC_WR_BITS_PER_WORD, @intFromPtr(&bits)) != 0) {
            std.log.err("Failed to set SPI bits", .{});
            return error.SpiConfigFailed;
        }
        if (std.os.linux.ioctl(self.spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, @intFromPtr(&speed)) != 0) {
            std.log.err("Failed to set SPI speed", .{});
            return error.SpiConfigFailed;
        }
        std.log.info("SPI configured successfully", .{});
    }

    /// Cleanup and close SPI/GPIO
    pub fn moduleExit(self: *EpdConfig) void {
        if (@import("builtin").target.os.tag != .linux) return;

        // Set pins low before releasing
        self.digitalWrite(RST_PIN, 0) catch {};
        self.digitalWrite(DC_PIN, 0) catch {};
        self.digitalWrite(PWR_PIN, 0) catch {};

        // Release lines
        if (self.line_rst) |h| h.deinit();
        if (self.line_dc) |h| h.deinit();
        if (self.line_pwr) |h| h.deinit();
        if (self.line_busy) |h| h.deinit();

        // Close SPI
        if (self.spi_fd >= 0) {
            std.posix.close(self.spi_fd);
        }
    }

    /// Write digital value to GPIO pin
    pub fn digitalWrite(self: *EpdConfig, pin: u32, value: u8) !void {
        if (@import("builtin").target.os.tag != .linux) return;

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
        if (@import("builtin").target.os.tag != .linux) return 0;

        if (pin != BUSY_PIN) return error.InvalidPin;

        if (self.line_busy) |h| {
            return try h.getValue();
        } else {
            return error.NotInitialized;
        }
    }

    /// Delay for specified milliseconds
    pub fn delayMs(millis: u64) void {
        std.Thread.sleep(millis * std.time.ns_per_ms);
    }

    /// Write bytes via SPI
    pub fn spiWrite(self: *EpdConfig, data: []const u8) !void {
        // SPI has transfer size limits, split into chunks if needed
        const chunk_size = 4096;
        var offset: usize = 0;

        while (offset < data.len) {
            const remaining = data.len - offset;
            const to_write = @min(remaining, chunk_size);
            const chunk = data[offset .. offset + to_write];
            _ = try std.posix.write(self.spi_fd, chunk);
            offset += to_write;
        }
    }
};
