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

    /// Enable/disable BMP export
    pub var export_bmp: bool = false;

    /// BMP export path
    pub var bmp_export_path: []const u8 = "/tmp/sys-ink.bmp";

    /// Scheduler interval for fast updates (CPU, RAM, etc.) in seconds
    pub var interval_fast: u32 = 30;

    /// Scheduler interval for slow updates (IP, APT, Internet) in seconds
    pub var interval_slow: u32 = 10800; // 3 hours

    /// Load configuration from environment variables
    pub fn load() void {
        if (std.posix.getenv("EXPORT_BMP")) |val| {
            export_bmp = std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
        }
        if (std.posix.getenv("BMP_EXPORT_PATH")) |val| {
            bmp_export_path = val;
        }
        if (std.posix.getenv("INTERVAL_FAST")) |val| {
            interval_fast = @max(1, std.fmt.parseInt(u32, val, 10) catch interval_fast);
        }
        if (std.posix.getenv("INTERVAL_SLOW")) |val| {
            interval_slow = @max(1, std.fmt.parseInt(u32, val, 10) catch interval_slow);
        }

        if (std.posix.getenv("THRESHOLD_CPU_CRITICAL")) |val| {
            threshold_cpu_critical = std.fmt.parseInt(u8, val, 10) catch threshold_cpu_critical;
        }

        if (std.posix.getenv("THRESHOLD_TEMP_CRITICAL")) |val| {
            threshold_temp_critical = std.fmt.parseInt(u8, val, 10) catch threshold_temp_critical;
        }

        if (std.posix.getenv("THRESHOLD_MEM_CRITICAL")) |val| {
            threshold_mem_critical = std.fmt.parseInt(u8, val, 10) catch threshold_mem_critical;
        }

        if (std.posix.getenv("THRESHOLD_DISK_CRITICAL")) |val| {
            threshold_disk_critical = std.fmt.parseInt(u8, val, 10) catch threshold_disk_critical;
        }

        if (std.posix.getenv("LOG_LEVEL")) |val| {
            log_level = LogLevel.parse(val);
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
};
