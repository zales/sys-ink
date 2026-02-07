const std = @import("std");

const log = std.log.scoped(.system);

/// System operations for gathering system metrics
pub const SystemOps = struct {
    allocator: std.mem.Allocator,
    last_cpu_times: ?CpuTimes = null,
    cached_cpu_temp_path: ?[]const u8 = null,
    cached_disk_temp_path: ?[]const u8 = null,
    cached_fan_path: ?[]const u8 = null,
    apt_check_running: std.atomic.Value(bool),
    apt_updates_count: std.atomic.Value(u32),
    apt_first_check_done: std.atomic.Value(bool),
    // Cached values for MQTT (to avoid re-measuring)
    last_cpu_load: u8 = 0,
    last_cpu_temp: u32 = 0,
    last_memory: u8 = 0,
    last_disk_usage: u8 = 0,
    last_disk_temp: u32 = 0,
    last_fan_speed: u32 = 0,

    const CpuTimes = struct {
        user: u64,
        nice: u64,
        system: u64,
        idle: u64,
        iowait: u64,
        irq: u64,
        softirq: u64,
    };

    pub fn init(allocator: std.mem.Allocator) SystemOps {
        return .{
            .allocator = allocator,
            .last_cpu_times = null,
            .cached_cpu_temp_path = null,
            .cached_disk_temp_path = null,
            .cached_fan_path = null,
            .apt_check_running = std.atomic.Value(bool).init(false),
            .apt_updates_count = std.atomic.Value(u32).init(0),
            .apt_first_check_done = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *SystemOps) void {
        // Free cached paths if allocated
        if (self.cached_disk_temp_path) |path| {
            self.allocator.free(path);
            self.cached_disk_temp_path = null;
        }
        if (self.cached_fan_path) |path| {
            self.allocator.free(path);
            self.cached_fan_path = null;
        }
        // cached_cpu_temp_path points to static string, no need to free
    }

    /// Get CPU temperature in Celsius from thermal zone
    pub fn getCpuTemperature(self: *SystemOps) !u32 {
        // Use cached path if available
        if (self.cached_cpu_temp_path) |path| {
            const temp = try self.readTempFromFile(path);
            self.last_cpu_temp = temp;
            return temp;
        }

        // Try multiple thermal zones
        const zones = [_][]const u8{
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/thermal/thermal_zone1/temp",
        };

        for (zones) |zone_path| {
            if (self.readTempFromFile(zone_path)) |temp| {
                self.cached_cpu_temp_path = zone_path;
                self.last_cpu_temp = temp;
                return temp;
            } else |_| {
                continue;
            }
        }

        return error.ThermalZoneNotFound;
    }

    fn readTempFromFile(_: *SystemOps, path: []const u8) !u32 {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        var buf: [32]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        const temp_str = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);

        // Temperature is in millidegrees, convert to degrees
        const temp_milli = try std.fmt.parseInt(u32, temp_str, 10);
        return temp_milli / 1000;
    }

    /// Get CPU load percentage using cached measurements
    pub fn getCpuLoad(self: *SystemOps) !u8 {
        const file = try std.fs.openFileAbsolute("/proc/stat", .{});
        defer file.close();

        var buf: [1024]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        const content = buf[0..bytes_read];

        // Parse first line: "cpu  user nice system idle iowait irq softirq ..."
        var lines = std.mem.splitScalar(u8, content, '\n');
        const first_line = lines.next() orelse return error.InvalidFormat;

        if (!std.mem.startsWith(u8, first_line, "cpu ")) {
            return error.InvalidFormat;
        }

        var parts = std.mem.tokenizeAny(u8, first_line, " ");
        _ = parts.next(); // skip "cpu"

        const current = CpuTimes{
            .user = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
            .nice = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
            .system = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
            .idle = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
            .iowait = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
            .irq = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
            .softirq = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
        };

        // First call - initialize cache
        if (self.last_cpu_times == null) {
            self.last_cpu_times = current;
            return 0;
        }

        const prev = self.last_cpu_times.?;
        self.last_cpu_times = current;

        // Calculate deltas
        const delta_user = current.user - prev.user;
        const delta_nice = current.nice - prev.nice;
        const delta_system = current.system - prev.system;
        const delta_idle = current.idle - prev.idle;
        const delta_iowait = current.iowait - prev.iowait;
        const delta_irq = current.irq - prev.irq;
        const delta_softirq = current.softirq - prev.softirq;

        const total = delta_user + delta_nice + delta_system + delta_idle +
            delta_iowait + delta_irq + delta_softirq;

        if (total == 0) return 0;

        const idle_total = delta_idle + delta_iowait;
        const cpu_usage = (100 * (total - idle_total)) / total;

        const result: u8 = @intCast(@min(100, cpu_usage));
        self.last_cpu_load = result;
        return result;
    }

    /// Get fan speed in RPM
    pub fn getFanSpeed(self: *SystemOps) !u32 {
        // Use cached path
        if (self.cached_fan_path) |path| {
            if (self.readIntFromFile(path)) |rpm| {
                self.last_fan_speed = rpm;
                return rpm;
            } else |_| {
                // If read fails (e.g. sensor disappeared), invalidate cache
                self.allocator.free(self.cached_fan_path.?);
                self.cached_fan_path = null;
            }
        }

        // Try direct hwmon paths (hwmon0-hwmon9)
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/fan1_input", .{i}) catch continue;

            // Check if file exists and is readable by trying to read it
            if (self.readIntFromFile(path)) |rpm| {
                if (rpm > 0) {
                    self.cached_fan_path = try self.allocator.dupe(u8, path);
                    self.last_fan_speed = rpm;
                    return rpm;
                }
            } else |_| {
                continue;
            }
        }

        self.last_fan_speed = 0;
        return 0; // No fan found
    }

    fn readIntFromFile(_: *SystemOps, path: []const u8) !u32 {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        var buf: [32]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        const str = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);
        return try std.fmt.parseInt(u32, str, 10);
    }

    /// Get memory usage percentage
    pub fn getMemory(self: *SystemOps) !u8 {
        const file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
        defer file.close();

        var buf: [2048]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        const content = buf[0..bytes_read];

        var mem_total: ?u64 = null;
        var mem_available: ?u64 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                var parts = std.mem.tokenizeAny(u8, line, " ");
                _ = parts.next(); // skip "MemTotal:"
                if (parts.next()) |val| {
                    mem_total = std.fmt.parseInt(u64, val, 10) catch null;
                }
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                var parts = std.mem.tokenizeAny(u8, line, " ");
                _ = parts.next(); // skip "MemAvailable:"
                if (parts.next()) |val| {
                    mem_available = std.fmt.parseInt(u64, val, 10) catch null;
                }
            }

            if (mem_total != null and mem_available != null) break;
        }

        if (mem_total == null or mem_available == null) {
            return error.InvalidMeminfo;
        }

        const used = mem_total.? - mem_available.?;
        const percent = (100 * used) / mem_total.?;
        const result: u8 = @intCast(@min(100, percent));
        self.last_memory = result;
        return result;
    }

    /// Get disk/root filesystem usage percentage
    pub fn getDiskUsage(self: *SystemOps) !u8 {
        // Manual definition compatible with Linux aarch64/musl
        const struct_statvfs = extern struct {
            f_bsize: c_ulong,
            f_frsize: c_ulong,
            f_blocks: c_ulong, // fsblkcnt_t
            f_bfree: c_ulong,  // fsblkcnt_t
            f_bavail: c_ulong, // fsblkcnt_t
            f_files: c_ulong,  // fsfilcnt_t
            f_ffree: c_ulong,  // fsfilcnt_t
            f_favail: c_ulong, // fsfilcnt_t
            f_fsid: c_ulong,
            f_flag: c_ulong,
            f_namemax: c_ulong,
            __reserved: [6]c_int,
        };

        const extern_c = struct {
            pub extern "c" fn statvfs(path: [*:0]const u8, buf: *struct_statvfs) c_int;
        };

        var stat: struct_statvfs = undefined;
        if (extern_c.statvfs("/", &stat) != 0) {
            return error.StatvfsFailed;
        }

        const total = stat.f_blocks * stat.f_frsize;
        const free = stat.f_bfree * stat.f_frsize;
        const used = total - free;

        if (total == 0) {
            self.last_disk_usage = 0;
            return 0;
        }

        const percent = (100 * used) / total;
        const result: u8 = @intCast(@min(100, percent));
        self.last_disk_usage = result;
        return result;
    }

    /// Get disk temperature in Celsius
    pub fn getDiskTemp(self: *SystemOps) !u32 {
        // Use cached path if available
        if (self.cached_disk_temp_path) |path| {
            const temp = try self.readTempFromFile(path);
            self.last_disk_temp = temp;
            return temp;
        }

        // Try direct hwmon paths (hwmon0-hwmon9)
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            var name_path_buf: [64]u8 = undefined;
            const name_path = std.fmt.bufPrint(&name_path_buf, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch continue;

            // Check if this is disk sensor (nvme)
            const name_file = std.fs.openFileAbsolute(name_path, .{}) catch continue;
            defer name_file.close();

            var name_buf: [64]u8 = undefined;
            const name_len = name_file.readAll(&name_buf) catch continue;
            const name = std.mem.trim(u8, name_buf[0..name_len], &std.ascii.whitespace);

            if (std.mem.indexOf(u8, name, "nvme") != null) {
                // Found disk sensor, read temp1_input
                var temp_path_buf: [64]u8 = undefined;
                const temp_path = std.fmt.bufPrint(&temp_path_buf, "/sys/class/hwmon/hwmon{d}/temp1_input", .{i}) catch continue;

                // Cache the path (need to duplicate it because buf is on stack)
                self.cached_disk_temp_path = try self.allocator.dupe(u8, temp_path);

                const temp = try self.readTempFromFile(self.cached_disk_temp_path.?);
                self.last_disk_temp = temp;
                return temp;
            }
        }

        self.last_disk_temp = 0;
        return 0; // No disk sensor found
    }

    /// Get system uptime in days, hours, and minutes
    pub fn getUptime(_: *SystemOps) !struct { days: u32, hours: u32, minutes: u32 } {
        const file = try std.fs.openFileAbsolute("/proc/uptime", .{});
        defer file.close();

        var buf: [64]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        const content = buf[0..bytes_read];

        // Format: "uptime_seconds idle_seconds"
        var parts = std.mem.tokenizeAny(u8, content, " ");
        const uptime_str = parts.next() orelse return error.InvalidFormat;

        // Parse as float, get integer part
        const dot_pos = std.mem.indexOf(u8, uptime_str, ".") orelse uptime_str.len;
        const uptime_seconds = try std.fmt.parseInt(u64, uptime_str[0..dot_pos], 10);

        const days: u32 = @intCast(uptime_seconds / 86400);
        const hours: u32 = @intCast((uptime_seconds % 86400) / 3600);
        const minutes: u32 = @intCast((uptime_seconds % 3600) / 60);

        return .{ .days = days, .hours = hours, .minutes = minutes };
    }

    /// Check for available APT updates
    /// Check for APT updates in a background thread
    /// Returns the last known number of available updates immediately
    /// On first call, waits for the check to complete to ensure accurate initial display
    pub fn checkUpdates(self: *SystemOps, is_root: bool, has_internet: bool) u32 {
        const is_first_check = !self.apt_first_check_done.load(.monotonic);

        // If a check is already running, just return the last known count
        if (self.apt_check_running.load(.monotonic)) {
            // For first check, wait for it to complete
            if (is_first_check) {
                while (self.apt_check_running.load(.monotonic)) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                }
                return self.apt_updates_count.load(.monotonic);
            }
            return self.apt_updates_count.load(.monotonic);
        }

        // Start a new check in a background thread
        self.apt_check_running.store(true, .monotonic);

        const run_update = is_root and has_internet;
        const thread = std.Thread.spawn(.{}, aptCheckThread, .{ self, run_update }) catch |err| {
            log.err("Failed to spawn APT check thread: {}", .{err});
            self.apt_check_running.store(false, .monotonic);
            return self.apt_updates_count.load(.monotonic);
        };

        // For first check, wait for completion; otherwise detach
        if (is_first_check) {
            thread.join();
            self.apt_first_check_done.store(true, .monotonic);
        } else {
            thread.detach();
        }

        return self.apt_updates_count.load(.monotonic);
    }

    fn aptCheckThread(self: *SystemOps, run_update: bool) void {
        defer self.apt_check_running.store(false, .monotonic);

        if (run_update) {
            // Run update with a timeout
            if (std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = &[_][]const u8{ "/usr/bin/timeout", "30", "/usr/bin/apt", "update" },
                .max_output_bytes = 5 * 1024 * 1024,
            })) |update_result| {
                // Free the output buffers from apt update
                self.allocator.free(update_result.stdout);
                self.allocator.free(update_result.stderr);
            } else |err| {
                log.warn("Failed to run apt update: {}", .{err});
                // Continue to check upgradable even if update failed (might have old lists)
            }
        }

        // Run apt list --upgradable and count lines
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/usr/bin/timeout", "10", "/usr/bin/apt", "list", "--upgradable" },
            .max_output_bytes = 1024 * 1024,
        }) catch |err| {
            log.warn("Failed to check APT updates: {}", .{err});
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return;
        }

        // Count lines (excluding header "Listing..." and empty lines)
        var count: u32 = 0;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and !std.mem.startsWith(u8, line, "Listing")) {
                count += 1;
            }
        }

        self.apt_updates_count.store(count, .monotonic);
    }
};
