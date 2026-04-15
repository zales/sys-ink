const std = @import("std");

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
            if (std.ascii.eqlIgnoreCase(str, "DEBUG")) return .debug;
            if (std.ascii.eqlIgnoreCase(str, "INFO")) return .info;
            if (std.ascii.eqlIgnoreCase(str, "WARNING")) return .warn;
            if (std.ascii.eqlIgnoreCase(str, "ERROR")) return .err;
            return .info; // default
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

    /// Scheduler interval for fast updates (CPU, RAM, etc.) in seconds
    pub var interval_fast: u32 = 30;

    /// Scheduler interval for slow updates (IP, APT, Internet) in seconds
    pub var interval_slow: u32 = 10800; // 3 hours

    /// Load configuration from environment variables
    pub fn load(init: std.process.Init) void {
        if (init.environ_map.get("GPIO_CHIP")) |val| {
            gpio_chip = val;
        } else {
            // Auto-detect by label if GPIO_CHIP not set explicitly
            if (findGpioChipByLabel("pinctrl-rp1")) |path| {
                gpio_chip = path;
            }
        }
        if (init.environ_map.get("EXPORT_BMP")) |val| {
            export_bmp = std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
        }
        if (init.environ_map.get("BMP_EXPORT_PATH")) |val| {
            bmp_export_path = val;
        }
        if (init.environ_map.get("INTERVAL_FAST")) |val| {
            interval_fast = @max(1, std.fmt.parseInt(u32, val, 10) catch interval_fast);
        }
        if (init.environ_map.get("INTERVAL_SLOW")) |val| {
            interval_slow = @max(1, std.fmt.parseInt(u32, val, 10) catch interval_slow);
        }

        if (init.environ_map.get("THRESHOLD_CPU_CRITICAL")) |val| {
            threshold_cpu_critical = std.fmt.parseInt(u8, val, 10) catch threshold_cpu_critical;
        }

        if (init.environ_map.get("THRESHOLD_TEMP_CRITICAL")) |val| {
            threshold_temp_critical = std.fmt.parseInt(u8, val, 10) catch threshold_temp_critical;
        }

        if (init.environ_map.get("THRESHOLD_MEM_CRITICAL")) |val| {
            threshold_mem_critical = std.fmt.parseInt(u8, val, 10) catch threshold_mem_critical;
        }

        if (init.environ_map.get("THRESHOLD_DISK_CRITICAL")) |val| {
            threshold_disk_critical = std.fmt.parseInt(u8, val, 10) catch threshold_disk_critical;
        }

        if (init.environ_map.get("LOG_LEVEL")) |val| {
            log_level = LogLevel.parse(val);
        }

        if (init.environ_map.get("LOG_TO_FILE")) |val| {
            log_to_file = std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
        }

        if (init.environ_map.get("LOG_FILE_PATH")) |val| {
            log_file_path = val;
        }

        log_level_std = toStdLogLevel(log_level);
    }

    fn toStdLogLevel(level: LogLevel) std.log.Level {
        return switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }

    /// Check if running as root user
    pub fn isRoot() bool {
        return std.os.linux.getuid() == 0;
    }

    /// Static buffer for auto-detected GPIO chip path
    var gpio_chip_buf: [32]u8 = undefined;

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
                const result = std.fmt.bufPrint(&gpio_chip_buf, "/dev/gpiochip{d}", .{i}) catch continue;
                return result;
            }
        }
        return null;
    }
};
