const std = @import("std");
const builtin = @import("builtin");
const parse = @import("parse.zig");

const is_linux = builtin.target.os.tag == .linux;

/// Parse a boolean environment variable. Accepts "1", "true", "yes", "on"
/// (case-insensitive); anything else is false.
pub fn parseBool(val: []const u8) bool {
    for ([_][]const u8{ "1", "true", "yes", "on" }) |truthy| {
        if (std.ascii.eqlIgnoreCase(val, truthy)) return true;
    }
    return false;
}

/// Application configuration loaded from environment variables
pub const Config = struct {
    /// CPU load critical threshold (%) - values above this are highlighted
    pub var threshold_cpu_critical: u8 = 90;

    /// Temperature critical threshold (°C) - values above this are highlighted
    pub var threshold_temp_critical: u8 = 85;

    /// Memory critical threshold (%) - values above this are highlighted
    pub var threshold_mem_critical: u8 = 95;

    /// Disk usage critical threshold (%) - values above this are highlighted
    pub var threshold_disk_critical: u8 = 95;

    /// Log level
    pub const LogLevel = enum {
        debug,
        info,
        warn,
        err,

        pub fn parse(str: []const u8) LogLevel {
            const table = [_]struct { name: []const u8, level: LogLevel }{
                .{ .name = "DEBUG", .level = .debug },
                .{ .name = "INFO", .level = .info },
                .{ .name = "WARN", .level = .warn },
                .{ .name = "WARNING", .level = .warn },
                .{ .name = "ERROR", .level = .err },
                .{ .name = "ERR", .level = .err },
            };
            for (table) |entry| {
                if (std.ascii.eqlIgnoreCase(str, entry.name)) return entry.level;
            }
            return .info; // default
        }

        pub fn toStd(self: LogLevel) std.log.Level {
            return switch (self) {
                .debug => .debug,
                .info => .info,
                .warn => .warn,
                .err => .err,
            };
        }
    };

    pub var log_level: LogLevel = .info;
    pub var log_level_std: std.log.Level = .info;

    /// Enable/disable logging to file
    pub var log_to_file: bool = false;

    /// Log file path
    pub var log_file_path: []const u8 = "/var/log/sys-ink.log";

    /// Enable/disable BMP export
    pub var export_bmp: bool = false;

    /// BMP export path
    pub var bmp_export_path: []const u8 = "/tmp/sys-ink.bmp";

    /// GPIO chip path
    pub var gpio_chip: []const u8 = "/dev/gpiochip0";

    /// SPI device path
    pub var spi_device: []const u8 = "/dev/spidev0.0";

    /// Scheduler interval for fast updates (CPU, RAM, etc.) in seconds
    pub var interval_fast: u32 = 30;

    /// Scheduler interval for slow updates (IP, APT, Internet) in seconds
    pub var interval_slow: u32 = 10800; // 3 hours

    /// How often to force a full (non-partial) refresh, in seconds. Full
    /// refreshes clear the ghosting that partial updates accumulate.
    pub var interval_full_refresh: u32 = 600; // 10 minutes

    /// Park the panel in deep sleep between refreshes. Waveshare advises against
    /// leaving an e-paper panel driven continuously, and idle cycles (an
    /// unchanged frame) then cost nothing at all. Costs ~200ms per visible
    /// update to wake and restore the partial-update reference.
    pub var panel_sleep: bool = true;

    /// Host probed to decide whether the machine has internet access.
    pub var internet_check_ip: [4]u8 = .{ 8, 8, 8, 8 };
    pub var internet_check_port: u16 = 53;

    /// Load configuration from environment variables
    pub fn load(init: std.process.Init) void {
        const env = init.environ_map;

        if (env.get("GPIO_CHIP")) |val| {
            gpio_chip = val;
        } else if (findGpioChip()) |path| {
            gpio_chip = path;
        }
        if (env.get("SPI_DEVICE")) |val| {
            spi_device = val;
        }
        if (env.get("EXPORT_BMP")) |val| {
            export_bmp = parseBool(val);
        }
        if (env.get("BMP_EXPORT_PATH")) |val| {
            bmp_export_path = val;
        }
        if (env.get("INTERVAL_FAST")) |val| {
            interval_fast = @max(1, std.fmt.parseInt(u32, val, 10) catch interval_fast);
        }
        if (env.get("INTERVAL_SLOW")) |val| {
            interval_slow = @max(1, std.fmt.parseInt(u32, val, 10) catch interval_slow);
        }
        if (env.get("INTERVAL_FULL_REFRESH")) |val| {
            interval_full_refresh = @max(1, std.fmt.parseInt(u32, val, 10) catch interval_full_refresh);
        }
        if (env.get("PANEL_SLEEP")) |val| {
            panel_sleep = parseBool(val);
        }

        if (env.get("INTERNET_CHECK_IP")) |val| {
            internet_check_ip = parse.ipv4(val) catch internet_check_ip;
        }
        if (env.get("INTERNET_CHECK_PORT")) |val| {
            internet_check_port = std.fmt.parseInt(u16, val, 10) catch internet_check_port;
        }

        if (env.get("THRESHOLD_CPU_CRITICAL")) |val| {
            threshold_cpu_critical = std.fmt.parseInt(u8, val, 10) catch threshold_cpu_critical;
        }
        if (env.get("THRESHOLD_TEMP_CRITICAL")) |val| {
            threshold_temp_critical = std.fmt.parseInt(u8, val, 10) catch threshold_temp_critical;
        }
        if (env.get("THRESHOLD_MEM_CRITICAL")) |val| {
            threshold_mem_critical = std.fmt.parseInt(u8, val, 10) catch threshold_mem_critical;
        }
        if (env.get("THRESHOLD_DISK_CRITICAL")) |val| {
            threshold_disk_critical = std.fmt.parseInt(u8, val, 10) catch threshold_disk_critical;
        }

        if (env.get("LOG_LEVEL")) |val| {
            log_level = LogLevel.parse(val);
        }
        if (env.get("LOG_TO_FILE")) |val| {
            log_to_file = parseBool(val);
        }
        if (env.get("LOG_FILE_PATH")) |val| {
            log_file_path = val;
        }

        log_level_std = log_level.toStd();
    }

    /// Check if running as root user
    pub fn isRoot() bool {
        if (!is_linux) return false;
        return std.os.linux.getuid() == 0;
    }

    /// Static buffer for the auto-detected GPIO chip path
    var gpio_chip_buf: [32]u8 = undefined;

    /// GPIO chip labels for the SoCs this runs on, most recent first.
    const known_gpio_labels = [_][]const u8{
        "pinctrl-rp1", // Pi 5
        "pinctrl-bcm2711", // Pi 4
        "pinctrl-bcm2835", // Pi 3 and older
    };

    fn findGpioChip() ?[]const u8 {
        if (!is_linux) return null;

        for (known_gpio_labels) |label| {
            if (findGpioChipByLabel(label)) |path| return path;
        }
        return null;
    }

    /// Scan /dev/gpiochip0..31 and return path of the chip whose label matches.
    /// Returns null if not found. Uses GPIO_GET_CHIPINFO_IOCTL (same as gpiodetect).
    fn findGpioChipByLabel(label: []const u8) ?[]const u8 {
        // struct gpiochip_info: name[32], label[32], lines(u32)
        const GpiochipInfo = extern struct {
            name: [32]u8,
            label: [32]u8,
            lines: u32,
        };
        const GPIO_GET_CHIPINFO_IOCTL: u32 = 0x8044b401;

        var path_buf: [32]u8 = undefined;
        var i: u8 = 0;
        while (i < 32) : (i += 1) {
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/gpiochip{d}", .{i}) catch continue;
            const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
            defer _ = std.os.linux.close(fd);

            var info: GpiochipInfo = undefined;
            const rc = std.os.linux.ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, @intFromPtr(&info));
            if (rc != 0) continue;

            const chip_label = std.mem.sliceTo(&info.label, 0);
            if (std.mem.eql(u8, chip_label, label)) {
                return std.fmt.bufPrint(&gpio_chip_buf, "/dev/gpiochip{d}", .{i}) catch continue;
            }
        }
        return null;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "parseBool accepts the usual truthy spellings" {
    for ([_][]const u8{ "1", "true", "TRUE", "True", "yes", "YES", "on", "ON" }) |val| {
        try testing.expect(parseBool(val));
    }
    for ([_][]const u8{ "0", "false", "no", "off", "", "2", "maybe" }) |val| {
        try testing.expect(!parseBool(val));
    }
}

test "LogLevel.parse accepts both WARN and WARNING" {
    try testing.expectEqual(Config.LogLevel.warn, Config.LogLevel.parse("WARN"));
    try testing.expectEqual(Config.LogLevel.warn, Config.LogLevel.parse("WARNING"));
    try testing.expectEqual(Config.LogLevel.warn, Config.LogLevel.parse("warn"));
}

test "LogLevel.parse maps the remaining levels" {
    try testing.expectEqual(Config.LogLevel.debug, Config.LogLevel.parse("debug"));
    try testing.expectEqual(Config.LogLevel.info, Config.LogLevel.parse("INFO"));
    try testing.expectEqual(Config.LogLevel.err, Config.LogLevel.parse("ERROR"));
    try testing.expectEqual(Config.LogLevel.err, Config.LogLevel.parse("ERR"));
}

test "LogLevel.parse falls back to info" {
    try testing.expectEqual(Config.LogLevel.info, Config.LogLevel.parse("nonsense"));
    try testing.expectEqual(Config.LogLevel.info, Config.LogLevel.parse(""));
}
