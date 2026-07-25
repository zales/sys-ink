const std = @import("std");
const parse = @import("parse.zig");

// statfs comes from the target libc headers rather than a hand-rolled struct:
// fsblkcnt_t is 64-bit even on 32-bit ARM, so an all-c_ulong layout reads
// garbage there. (sys/statvfs.h cannot be used — musl declares an anonymous
// bitfield in it that translate-c renders opaque.)
const c = @cImport({
    @cInclude("sys/vfs.h");
});

const log = std.log.scoped(.system);

/// hwmon devices are probed from /sys/class/hwmon/hwmon0 upwards.
const max_hwmon_devices = 10;

/// System operations for gathering system metrics
pub const SystemOps = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    last_cpu_times: ?parse.CpuTimes = null,
    // All three are owned heap copies, freed in deinit. Uniform on purpose: two
    // of them used to be duped while this one aliased a static string, with the
    // difference recorded only in a comment. Same type, different ownership is
    // how a stray free or leak gets introduced later.
    cached_cpu_temp_path: ?[]const u8 = null,
    cached_disk_temp_path: ?[]const u8 = null,
    cached_fan_path: ?[]const u8 = null,
    /// Owns the in-flight check rather than detaching it: the task holds a
    /// pointer to this struct, which normally lives on main's stack.
    apt_check: ?std.Io.Future(void) = null,
    /// Read by the main thread to decide whether the future can be reaped
    /// without blocking. `Future` offers only a blocking await, no completion
    /// poll, so this stays.
    apt_check_running: std.atomic.Value(bool),
    apt_updates_count: std.atomic.Value(u32),
    /// False until a check has actually produced a count, so the UI can tell
    /// "no updates" apart from "not known yet".
    apt_count_known: std.atomic.Value(bool),
    // Cached values for MQTT (to avoid re-measuring)
    last_cpu_load: u8 = 0,
    last_cpu_temp: u32 = 0,
    last_memory: u8 = 0,
    last_disk_usage: u8 = 0,
    last_disk_temp: u32 = 0,
    last_fan_speed: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SystemOps {
        return .{
            .allocator = allocator,
            .io = io,
            .apt_check_running = std.atomic.Value(bool).init(false),
            .apt_updates_count = std.atomic.Value(u32).init(0),
            .apt_count_known = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *SystemOps) void {
        // Waits properly rather than polling for a few seconds and hoping: the
        // task is bounded by its own `timeout` invocations.
        self.reapAptCheck();

        inline for (.{ "cached_cpu_temp_path", "cached_disk_temp_path", "cached_fan_path" }) |field| {
            if (@field(self, field)) |path| {
                self.allocator.free(path);
                @field(self, field) = null;
            }
        }
    }

    // ------------------------------------------------------------------------
    // File helpers
    // ------------------------------------------------------------------------

    /// Read a small sysfs/procfs file into `buf` and return the populated slice.
    fn readFile(self: *SystemOps, path: []const u8, buf: []u8) ![]const u8 {
        const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);

        const bytes_read = try file.readPositionalAll(self.io, buf, 0);
        return buf[0..bytes_read];
    }

    fn readTempFromFile(self: *SystemOps, path: []const u8) !u32 {
        var buf: [32]u8 = undefined;
        return parse.temperatureCelsius(try self.readFile(path, &buf));
    }

    fn readIntFromFile(self: *SystemOps, path: []const u8) !u32 {
        var buf: [32]u8 = undefined;
        return parse.unsignedInt(try self.readFile(path, &buf));
    }

    // ------------------------------------------------------------------------
    // Metrics
    // ------------------------------------------------------------------------

    /// Get CPU temperature in Celsius from thermal zone
    pub fn getCpuTemperature(self: *SystemOps) !u32 {
        if (self.cached_cpu_temp_path) |path| {
            self.last_cpu_temp = try self.readTempFromFile(path);
            return self.last_cpu_temp;
        }

        const zones = [_][]const u8{
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/thermal/thermal_zone1/temp",
        };

        for (zones) |zone_path| {
            const temp = self.readTempFromFile(zone_path) catch continue;
            self.cached_cpu_temp_path = try self.allocator.dupe(u8, zone_path);
            self.last_cpu_temp = temp;
            return temp;
        }

        return error.ThermalZoneNotFound;
    }

    /// Get CPU load percentage using cached measurements
    pub fn getCpuLoad(self: *SystemOps) !u8 {
        var buf: [1024]u8 = undefined;
        const current = try parse.cpuStat(try self.readFile("/proc/stat", &buf));

        defer self.last_cpu_times = current;

        // First call has no baseline to diff against.
        const prev = self.last_cpu_times orelse return 0;

        self.last_cpu_load = parse.cpuUsagePercent(prev, current);
        return self.last_cpu_load;
    }

    /// Get fan speed in RPM
    pub fn getFanSpeed(self: *SystemOps) !u32 {
        if (self.cached_fan_path) |path| {
            if (self.readIntFromFile(path)) |rpm| {
                self.last_fan_speed = rpm;
                return rpm;
            } else |_| {
                // Sensor disappeared (module unloaded, device unplugged) — rescan.
                self.allocator.free(path);
                self.cached_fan_path = null;
            }
        }

        var path_buf: [64]u8 = undefined;
        for (0..max_hwmon_devices) |i| {
            const path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/fan1_input", .{i}) catch continue;

            // A reading of 0 is ambiguous (stopped fan vs. wrong device), so
            // only latch onto a sensor that is actually spinning.
            const rpm = self.readIntFromFile(path) catch continue;
            if (rpm == 0) continue;

            self.cached_fan_path = try self.allocator.dupe(u8, path);
            self.last_fan_speed = rpm;
            return rpm;
        }

        self.last_fan_speed = 0;
        return 0; // No fan found
    }

    /// Get memory usage percentage
    pub fn getMemory(self: *SystemOps) !u8 {
        var buf: [2048]u8 = undefined;
        self.last_memory = try parse.memoryUsagePercent(try self.readFile("/proc/meminfo", &buf));
        return self.last_memory;
    }

    /// Root filesystem usage as a percentage.
    ///
    /// Matches `df`: capacity is measured against space available to
    /// unprivileged users, so the reserved blocks are excluded.
    pub fn getDiskUsage(self: *SystemOps) !u8 {
        var stat: c.struct_statfs = undefined;
        if (c.statfs("/", &stat) != 0) return error.StatfsFailed;

        const blocks: u64 = @intCast(stat.f_blocks);
        const free: u64 = @intCast(stat.f_bfree);
        const avail: u64 = @intCast(stat.f_bavail);

        const used = blocks -| free;
        const usable = used + avail;

        if (usable == 0) {
            self.last_disk_usage = 0;
            return 0;
        }

        // Round up, as df does, so the two agree rather than differing by one.
        const percent = (100 * used + usable - 1) / usable;
        self.last_disk_usage = @intCast(@min(100, percent));
        return self.last_disk_usage;
    }

    /// Get disk temperature in Celsius
    pub fn getDiskTemp(self: *SystemOps) !u32 {
        if (self.cached_disk_temp_path) |path| {
            self.last_disk_temp = try self.readTempFromFile(path);
            return self.last_disk_temp;
        }

        var name_path_buf: [64]u8 = undefined;
        var temp_path_buf: [64]u8 = undefined;
        var name_buf: [64]u8 = undefined;

        for (0..max_hwmon_devices) |i| {
            const name_path = std.fmt.bufPrint(&name_path_buf, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch continue;
            const raw_name = self.readFile(name_path, &name_buf) catch continue;
            const name = std.mem.trim(u8, raw_name, &std.ascii.whitespace);

            if (std.mem.find(u8, name, "nvme") == null) continue;

            const temp_path = std.fmt.bufPrint(&temp_path_buf, "/sys/class/hwmon/hwmon{d}/temp1_input", .{i}) catch continue;
            const temp = self.readTempFromFile(temp_path) catch continue;

            self.cached_disk_temp_path = try self.allocator.dupe(u8, temp_path);
            self.last_disk_temp = temp;
            return temp;
        }

        self.last_disk_temp = 0;
        return 0; // No disk sensor found
    }

    /// Get system uptime in days, hours, and minutes
    pub fn getUptime(self: *SystemOps) !parse.Uptime {
        var buf: [64]u8 = undefined;
        return parse.uptime(try self.readFile("/proc/uptime", &buf));
    }

    // ------------------------------------------------------------------------
    // APT updates
    // ------------------------------------------------------------------------

    /// Number of available updates from the most recent completed check, or
    /// null if no check has finished yet.
    pub fn updatesCount(self: *SystemOps) ?u32 {
        if (!self.apt_count_known.load(.acquire)) return null;
        return self.apt_updates_count.load(.monotonic);
    }

    /// Kick off an APT check in the background if one is not already running.
    ///
    /// Returns immediately; `updatesCount` picks up the result once the check
    /// finishes. Running `apt update` can take tens of seconds, which is far too
    /// long to hold up the render loop.
    pub fn refreshUpdates(self: *SystemOps, is_root: bool, has_internet: bool) void {
        if (self.apt_check_running.load(.acquire)) {
            log.debug("APT check already in flight, skipping", .{});
            return;
        }

        // Nothing is running, so this returns straight away; it exists to release
        // the previous task's resources before starting another.
        self.reapAptCheck();

        self.apt_check_running.store(true, .release);
        self.apt_check = self.io.concurrent(aptCheck, .{ self, is_root and has_internet }) catch |err| {
            // Single-threaded builds and resource exhaustion land here. Running
            // the check inline would stall the display for up to 40s, so skip
            // this cycle instead.
            log.warn("Cannot run APT check concurrently: {t}", .{err});
            self.apt_check_running.store(false, .release);
            return;
        };
    }

    /// Release a finished check. Blocks only if one is still running.
    fn reapAptCheck(self: *SystemOps) void {
        if (self.apt_check) |*future| {
            future.await(self.io);
            self.apt_check = null;
        }
    }

    fn aptCheck(self: *SystemOps, run_update: bool) void {
        defer self.apt_check_running.store(false, .release);

        if (run_update) {
            if (std.process.run(self.allocator, self.io, .{
                .argv = &[_][]const u8{ "/usr/bin/timeout", "30", "/usr/bin/apt", "update" },
            })) |update_result| {
                self.allocator.free(update_result.stdout);
                self.allocator.free(update_result.stderr);
            } else |err| {
                // Stale package lists still give a usable answer below.
                log.warn("Failed to run apt update: {t}", .{err});
            }
        }

        const result = std.process.run(self.allocator, self.io, .{
            .argv = &[_][]const u8{ "/usr/bin/timeout", "10", "/usr/bin/apt", "list", "--upgradable" },
        }) catch |err| {
            log.warn("Failed to check APT updates: {t}", .{err});
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) return;

        self.apt_updates_count.store(parse.aptUpgradableCount(result.stdout), .monotonic);
        self.apt_count_known.store(true, .release);
    }
};
