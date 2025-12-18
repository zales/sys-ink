const std = @import("std");

/// Application configuration loaded from environment variables
pub const Config = struct {
    /// Display update timeout in seconds
    pub var display_update_timeout: u32 = 30;

    /// Cache TTL for internet connection check (seconds)
    pub var cache_ttl_internet: u32 = 30;

    /// Cache TTL for signal strength (seconds)
    pub var cache_ttl_signal: u32 = 60;

    /// Cache TTL for IP address (seconds)
    pub var cache_ttl_ip: u32 = 3600;

    /// CPU load high threshold (%)
    pub var threshold_cpu_high: u8 = 70;

    /// CPU load critical threshold (%)
    pub var threshold_cpu_critical: u8 = 90;

    /// Temperature high threshold (°C)
    pub var threshold_temp_high: u8 = 70;

    /// Temperature critical threshold (°C)
    pub var threshold_temp_critical: u8 = 85;

    /// Memory high threshold (%)
    pub var threshold_mem_high: u8 = 80;

    /// Memory critical threshold (%)
    pub var threshold_mem_critical: u8 = 95;

    /// Disk usage high threshold (%)
    pub var threshold_disk_high: u8 = 85;

    /// Disk usage critical threshold (%)
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
            interval_fast = std.fmt.parseInt(u32, val, 10) catch interval_fast;
        }
        if (std.posix.getenv("INTERVAL_SLOW")) |val| {
            interval_slow = std.fmt.parseInt(u32, val, 10) catch interval_slow;
        }
        if (std.posix.getenv("DISPLAY_UPDATE_TIMEOUT")) |val| {
            display_update_timeout = std.fmt.parseInt(u32, val, 10) catch display_update_timeout;
        }

        if (std.posix.getenv("DISPLAY_CACHE_TTL_INTERNET")) |val| {
            cache_ttl_internet = std.fmt.parseInt(u32, val, 10) catch cache_ttl_internet;
        }

        if (std.posix.getenv("DISPLAY_CACHE_TTL_SIGNAL")) |val| {
            cache_ttl_signal = std.fmt.parseInt(u32, val, 10) catch cache_ttl_signal;
        }

        if (std.posix.getenv("DISPLAY_CACHE_TTL_IP")) |val| {
            cache_ttl_ip = std.fmt.parseInt(u32, val, 10) catch cache_ttl_ip;
        }

        if (std.posix.getenv("THRESHOLD_CPU_HIGH")) |val| {
            threshold_cpu_high = std.fmt.parseInt(u8, val, 10) catch threshold_cpu_high;
        }

        if (std.posix.getenv("THRESHOLD_CPU_CRITICAL")) |val| {
            threshold_cpu_critical = std.fmt.parseInt(u8, val, 10) catch threshold_cpu_critical;
        }

        if (std.posix.getenv("THRESHOLD_TEMP_HIGH")) |val| {
            threshold_temp_high = std.fmt.parseInt(u8, val, 10) catch threshold_temp_high;
        }

        if (std.posix.getenv("THRESHOLD_TEMP_CRITICAL")) |val| {
            threshold_temp_critical = std.fmt.parseInt(u8, val, 10) catch threshold_temp_critical;
        }

        if (std.posix.getenv("THRESHOLD_MEM_HIGH")) |val| {
            threshold_mem_high = std.fmt.parseInt(u8, val, 10) catch threshold_mem_high;
        }

        if (std.posix.getenv("THRESHOLD_MEM_CRITICAL")) |val| {
            threshold_mem_critical = std.fmt.parseInt(u8, val, 10) catch threshold_mem_critical;
        }

        if (std.posix.getenv("THRESHOLD_DISK_HIGH")) |val| {
            threshold_disk_high = std.fmt.parseInt(u8, val, 10) catch threshold_disk_high;
        }

        if (std.posix.getenv("THRESHOLD_DISK_CRITICAL")) |val| {
            threshold_disk_critical = std.fmt.parseInt(u8, val, 10) catch threshold_disk_critical;
        }

        if (std.posix.getenv("LOG_LEVEL")) |val| {
            log_level = LogLevel.parse(val);
        }
    }

    /// Check if running as root user
    pub fn isRoot() bool {
        return std.os.linux.getuid() == 0;
    }
};
