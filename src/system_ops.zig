const std = @import("std");
const config = @import("config.zig");
const parse = @import("parse.zig");
const Reading = @import("reading.zig").Reading;

// statfs comes from the target libc headers (src/c.h) rather than a
// hand-rolled struct: fsblkcnt_t is 64-bit even on 32-bit ARM, so an
// all-c_ulong layout reads garbage there. (sys/statvfs.h cannot be used — musl
// declares an anonymous bitfield in it that translate-c renders opaque.)
const c = @import("c");

const log = std.log.scoped(.system);

/// hwmon devices are probed from /sys/class/hwmon/hwmon0 upwards.
const max_hwmon_devices = 10;

/// System operations for gathering system metrics
pub const SystemOps = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The daemon's environment, which the APT check derives its own from.
    /// Only ever read, so the background task may do so.
    parent_env: ?*const std.process.Environ.Map,
    last_cpu_times: ?parse.CpuTimes = null,
    // All three are owned heap copies, freed in deinit. Uniform on purpose: two
    // of them used to be duped while this one aliased a static string, with the
    // difference recorded only in a comment. Same type, different ownership is
    // how a stray free or leak gets introduced later.
    cached_cpu_temp_path: ?[]const u8 = null,
    cached_disk_temp_path: ?[]const u8 = null,
    cached_fan_path: ?[]const u8 = null,
    cached_undervoltage_path: ?[]const u8 = null,
    /// Set once the hwmon scan has run, so hardware without the sensor is not
    /// rescanned on every cycle.
    undervoltage_probed: bool = false,
    /// Same latch for the NVMe temperature sensor.
    disk_temp_probed: bool = false,
    /// Controller device path, e.g. "/dev/nvme0"; owned heap copy.
    cached_nvme_dev: ?[]const u8 = null,
    /// Set once the controller scan has run, so hardware without NVMe — or a
    /// process without the root needed to open it — is not rescanned and does
    /// not log about it on every cycle.
    nvme_probed: bool = false,
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
    /// Whether the latest check is the one that produced the count. A check
    /// that fails leaves the count it found standing, as stale.
    apt_count_fresh: std.atomic.Value(bool),
    /// Monotonic seconds at which the count was produced. In 32 bits, which
    /// hold 136 years of them: the ARMv6 of a Pi Zero or a Pi 1 has no
    /// 64-bit atomics, and with one here the build for it did not compile.
    apt_count_at: std.atomic.Value(u32),
    // What each `get*` last came to, for the API and MQTT to report without
    // measuring again. Each knows whether its latest attempt worked; see
    // `reading.zig`. Unavailable where the hardware has no such sensor, which
    // is reported as nothing rather than as a reading of zero.
    cpu_load: Reading(u8) = .{},
    cpu_temp: Reading(u32) = .{},
    memory: Reading(u8) = .{},
    disk_usage: Reading(u8) = .{},
    disk_temp: Reading(u32) = .{},
    fan_speed: Reading(u32) = .{},
    undervoltage: Reading(bool) = .{},
    nvme_health: Reading(parse.NvmeHealth) = .{},
    /// Null when it could not be read. Not kept as stale: an uptime that has
    /// stopped counting is not the last known value of anything, only a wrong
    /// one, and the small print it is set in does not survive being faded.
    last_uptime: ?parse.Uptime = null,
    /// Set while the SMART command keeps failing, so that is logged when it
    /// starts rather than on every cycle.
    nvme_failing: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, parent_env: ?*const std.process.Environ.Map) SystemOps {
        return .{
            .allocator = allocator,
            .io = io,
            .parent_env = parent_env,
            .apt_check_running = std.atomic.Value(bool).init(false),
            .apt_updates_count = std.atomic.Value(u32).init(0),
            .apt_count_known = std.atomic.Value(bool).init(false),
            .apt_count_fresh = std.atomic.Value(bool).init(false),
            .apt_count_at = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *SystemOps) void {
        // Waits properly rather than polling for a few seconds and hoping: the
        // task is bounded by its own `timeout` invocations.
        self.reapAptCheck();

        inline for (.{ "cached_cpu_temp_path", "cached_disk_temp_path", "cached_fan_path", "cached_undervoltage_path", "cached_nvme_dev" }) |field| {
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

    /// The time a reading is stamped with.
    fn nowSeconds(self: *SystemOps) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toSeconds();
    }

    // ------------------------------------------------------------------------
    // Metrics
    // ------------------------------------------------------------------------

    // Each `get*` takes one measurement and records how it went in the reading
    // of the same name. The measuring itself is in the `measure*` beside it,
    // so that no way out of one can skip the recording.

    /// Get CPU temperature in Celsius from thermal zone
    pub fn getCpuTemperature(self: *SystemOps) !u32 {
        return self.cpu_temp.record(self.measureCpuTemperature(), self.nowSeconds());
    }

    fn measureCpuTemperature(self: *SystemOps) !u32 {
        if (self.cached_cpu_temp_path) |path| return self.readTempFromFile(path);

        const zones = [_][]const u8{
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/thermal/thermal_zone1/temp",
        };

        for (zones) |zone_path| {
            const temp = self.readTempFromFile(zone_path) catch continue;
            self.cached_cpu_temp_path = try self.allocator.dupe(u8, zone_path);
            return temp;
        }

        return error.ThermalZoneNotFound;
    }

    /// Get CPU load percentage using cached measurements
    pub fn getCpuLoad(self: *SystemOps) !u8 {
        return self.cpu_load.record(self.measureCpuLoad(), self.nowSeconds());
    }

    fn measureCpuLoad(self: *SystemOps) !u8 {
        var buf: [1024]u8 = undefined;
        const current = try parse.cpuStat(try self.readFile("/proc/stat", &buf));

        defer self.last_cpu_times = current;

        // First call has no baseline to diff against.
        const prev = self.last_cpu_times orelse return 0;

        return parse.cpuUsagePercent(prev, current);
    }

    /// Fan speed in RPM, or null when no hwmon device has a fan input at all.
    ///
    /// A fan that is present but stopped reads 0, which the Pi 5's cooler does
    /// whenever it is cool enough; a machine with no fan is a different answer
    /// and gets null, so the panel shows a dash instead of claiming 0 RPM.
    pub fn getFanSpeed(self: *SystemOps) !?u32 {
        return self.fan_speed.record(self.measureFanSpeed(), self.nowSeconds());
    }

    fn measureFanSpeed(self: *SystemOps) !?u32 {
        if (self.cached_fan_path) |path| {
            if (self.readIntFromFile(path)) |rpm| {
                return rpm;
            } else |_| {
                // Sensor disappeared (module unloaded, device unplugged) — rescan.
                self.allocator.free(path);
                self.cached_fan_path = null;
            }
        }

        var path_buf: [64]u8 = undefined;
        var any_fan = false;
        for (0..max_hwmon_devices) |i| {
            const path = std.mem.print(&path_buf, "/sys/class/hwmon/hwmon{d}/fan1_input", .{i}) catch continue;

            // A reading of 0 is ambiguous (stopped fan vs. wrong device), so
            // only latch onto a sensor that is actually spinning.
            const rpm = self.readIntFromFile(path) catch continue;
            any_fan = true;
            if (rpm == 0) continue;

            self.cached_fan_path = try self.allocator.dupe(u8, path);
            return rpm;
        }

        return if (any_fan) 0 else null;
    }

    /// Get memory usage percentage
    pub fn getMemory(self: *SystemOps) !u8 {
        return self.memory.record(self.measureMemory(), self.nowSeconds());
    }

    fn measureMemory(self: *SystemOps) !u8 {
        var buf: [2048]u8 = undefined;
        return parse.memoryUsagePercent(try self.readFile("/proc/meminfo", &buf));
    }

    /// Root filesystem usage as a percentage.
    ///
    /// Matches `df`: capacity is measured against space available to
    /// unprivileged users, so the reserved blocks are excluded.
    pub fn getDiskUsage(self: *SystemOps) !u8 {
        return self.disk_usage.record(measureDiskUsage(), self.nowSeconds());
    }

    fn measureDiskUsage() !u8 {
        var stat: c.struct_statfs = undefined;
        if (c.statfs("/", &stat) != 0) return error.StatfsFailed;

        const blocks: u64 = @intCast(stat.f_blocks);
        const free: u64 = @intCast(stat.f_bfree);
        const avail: u64 = @intCast(stat.f_bavail);

        const used = blocks -| free;
        const usable = used + avail;

        if (usable == 0) return 0;

        // Round up, as df does, so the two agree rather than differing by one.
        const percent = @divCeil(100 * used, usable);
        return @intCast(@min(100, percent));
    }

    /// Locate `file` inside the hwmon device whose name contains `sensor_name`,
    /// writing the full path into `buf`.
    ///
    /// The hwmon index is assigned in probe order and is not stable across boots,
    /// so devices have to be found by name rather than by a fixed number.
    fn findHwmonFile(self: *SystemOps, buf: []u8, sensor_name: []const u8, file: []const u8) ?[]const u8 {
        var name_path_buf: [64]u8 = undefined;
        var name_buf: [64]u8 = undefined;

        for (0..max_hwmon_devices) |i| {
            const name_path = std.mem.print(&name_path_buf, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch continue;
            const raw_name = self.readFile(name_path, &name_buf) catch continue;
            const name = std.mem.trim(u8, raw_name, &std.ascii.whitespace);

            if (std.mem.find(u8, name, sensor_name) == null) continue;

            return std.mem.print(buf, "/sys/class/hwmon/hwmon{d}/{s}", .{ i, file }) catch continue;
        }
        return null;
    }

    /// Disk temperature in Celsius, or null on hardware without an NVMe sensor.
    ///
    /// Scanned once. Hardware without an NVMe hwmon device used to re-read all
    /// ten `/sys/class/hwmon/hwmonN/name` files on every cycle to reach the same
    /// answer, where `getUndervoltage` and `getNvmeHealth` already latch a
    /// missing sensor after the first look. A drive that appears later is not a
    /// case worth rescanning forever for: on this hardware it is soldered down.
    ///
    /// A sensor that was found and then stops answering is an error, not a
    /// missing sensor: the reading goes stale rather than away. It used to
    /// keep its last value with nothing to say so, on the panel and over MQTT
    /// alike.
    pub fn getDiskTemp(self: *SystemOps) !?u32 {
        return self.disk_temp.record(self.measureDiskTemp(), self.nowSeconds());
    }

    fn measureDiskTemp(self: *SystemOps) !?u32 {
        if (self.cached_disk_temp_path) |path| return try self.readTempFromFile(path);

        if (self.disk_temp_probed) return null;
        self.disk_temp_probed = true;

        var temp_path_buf: [64]u8 = undefined;
        if (self.findHwmonFile(&temp_path_buf, "nvme", "temp1_input")) |temp_path| {
            if (self.readTempFromFile(temp_path)) |temp| {
                self.cached_disk_temp_path = try self.allocator.dupe(u8, temp_path);
                return temp;
            } else |_| {}
        }

        log.debug("No NVMe hwmon sensor; disk temperature reporting disabled", .{});
        return null;
    }

    /// Whether the firmware currently reports a low input voltage.
    ///
    /// Returns null on hardware without the sensor, which is every non-Raspberry
    /// Pi and lets the caller hide the indicator entirely rather than claim the
    /// supply is fine. Null as well when the sensor is there and cannot be read:
    /// the `undervoltage` reading then keeps what it last saw, as stale.
    ///
    /// Source is `in0_lcrit_alarm` on the `rpi_volt` hwmon device, which the
    /// raspberrypi-hwmon driver derives from the firmware's live under-voltage
    /// flag — not the sticky "has occurred since boot" one. A dip shorter than
    /// the poll interval is therefore missed; sustained under-voltage, which is
    /// the case that corrupts storage, is not.
    pub fn getUndervoltage(self: *SystemOps) ?bool {
        if (self.cached_undervoltage_path) |path| {
            const alarm = self.readIntFromFile(path) catch {
                self.undervoltage.fail();
                return null;
            };
            self.undervoltage.set(alarm != 0, self.nowSeconds());
            return alarm != 0;
        }

        if (self.undervoltage_probed) return null;
        self.undervoltage_probed = true;

        var path_buf: [64]u8 = undefined;
        const path = self.findHwmonFile(&path_buf, "rpi_volt", "in0_lcrit_alarm") orelse {
            log.debug("No rpi_volt sensor; under-voltage reporting disabled", .{});
            return null;
        };

        const alarm = self.readIntFromFile(path) catch return null;
        self.cached_undervoltage_path = self.allocator.dupe(u8, path) catch return null;
        self.undervoltage.set(alarm != 0, self.nowSeconds());
        return alarm != 0;
    }

    // ------------------------------------------------------------------------
    // NVMe SMART
    // ------------------------------------------------------------------------

    /// struct nvme_passthru_cmd from uapi/linux/nvme_ioctl.h.
    const NvmePassthruCmd = extern struct {
        opcode: u8,
        flags: u8,
        rsvd1: u16,
        nsid: u32,
        cdw2: u32,
        cdw3: u32,
        metadata: u64,
        addr: u64,
        metadata_len: u32,
        data_len: u32,
        cdw10: u32,
        cdw11: u32,
        cdw12: u32,
        cdw13: u32,
        cdw14: u32,
        cdw15: u32,
        timeout_ms: u32,
        result: u32,
    };

    comptime {
        // The struct size is part of the ioctl request number, so a layout that
        // disagrees with the kernel's produces an unrecognised ioctl rather than
        // a silently wrong result. Same approach as gpio_native.
        std.debug.assert(@sizeOf(NvmePassthruCmd) == 72);
    }

    /// _IOWR('N', 0x41, struct nvme_passthru_cmd), derived rather than literal.
    const NVME_IOCTL_ADMIN_CMD: u32 =
        (3 << 30) | (@as(u32, @sizeOf(NvmePassthruCmd)) << 16) | (@as(u32, 'N') << 8) | 0x41;

    const nvme_admin_get_log_page = 0x02;
    const nvme_log_smart = 0x02;
    /// Get Log Page addresses all namespaces for controller-scoped pages.
    const nvme_nsid_all = 0xFFFF_FFFF;

    /// SMART / Health for the first NVMe controller, or null when there is no
    /// NVMe, or this process lacks the root needed to open the controller node
    /// (/dev/nvmeX is 0600 root). Null keeps the fault indicator off rather
    /// than inventing a healthy reading.
    ///
    /// Null as well when the controller is there and the page could not be
    /// had from it. The `nvme_health` reading then keeps the page it last
    /// got, as stale: a drive that stops answering has not become healthy.
    pub fn getNvmeHealth(self: *SystemOps) ?parse.NvmeHealth {
        const dev = self.nvmeDevPath() orelse return null;

        const fd = std.posix.openat(std.posix.AT.FDCWD, dev, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| {
            return self.nvmeFailed("cannot open {s}: {t}", .{ dev, err });
        };
        defer _ = std.os.linux.close(fd);

        // Zeroed, not undefined: a partially completed command would otherwise
        // leave stack garbage to be decoded as drive health.
        var page = std.mem.zeroes([512]u8);
        var cmd = std.mem.zeroes(NvmePassthruCmd);
        cmd.opcode = nvme_admin_get_log_page;
        cmd.nsid = nvme_nsid_all;
        cmd.addr = @intFromPtr(&page);
        cmd.data_len = page.len;
        // cdw10: number of dwords minus one in the upper half, log id below.
        cmd.cdw10 = ((page.len / 4 - 1) << 16) | nvme_log_smart;

        // Only a return of zero means the page was written. The kernel's own
        // failure comes back as an errno and the controller's as its status,
        // which is positive: taken for success, that left the zeroed page above
        // to be decoded as a drive with no critical warning.
        const rc = std.os.linux.ioctl(fd, NVME_IOCTL_ADMIN_CMD, @intFromPtr(&cmd));
        switch (parse.nvmeCommandResult(rc)) {
            .completed => {},
            // Node exists but is not a working controller.
            .failed => |err| return self.nvmeFailed("the kernel answered {t}", .{err}),
            .status => |status| return self.nvmeFailed(
                "the controller answered status 0x{x} (type {d}, code 0x{x}{s})",
                .{ status.raw, status.codeType(), status.code(), if (status.doNotRetry()) ", do not retry" else "" },
            ),
        }

        const health = parse.nvmeSmartLog(&page) catch |err| return self.nvmeFailed("{t}", .{err});
        if (self.nvme_failing) log.info("NVMe SMART page is readable again", .{});
        self.nvme_failing = false;
        self.nvme_health.set(health, self.nowSeconds());
        return health;
    }

    /// The SMART page could not be had this time. Says so once per run of
    /// failures: this is asked every cycle, and a warning each time would have
    /// journald drop the lines that matter.
    fn nvmeFailed(self: *SystemOps, comptime reason: []const u8, args: anytype) ?parse.NvmeHealth {
        if (self.nvme_failing) {
            log.debug("NVMe SMART page still unreadable: " ++ reason, args);
        } else {
            log.warn("Cannot read the NVMe SMART page: " ++ reason, args);
        }
        self.nvme_failing = true;
        self.nvme_health.fail();
        return null;
    }

    /// Locate the first NVMe controller node, caching the result.
    fn nvmeDevPath(self: *SystemOps) ?[]const u8 {
        if (self.cached_nvme_dev) |dev| return dev;
        if (self.nvme_probed) return null;
        self.nvme_probed = true;

        var path_buf: [64]u8 = undefined;
        // Controllers are numbered from zero; scanning a fixed range avoids
        // directory iteration and matches the hwmon approach.
        for (0..4) |i| {
            const path = std.mem.print(&path_buf, "/dev/nvme{d}", .{i}) catch continue;
            const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch continue;
            _ = std.os.linux.close(fd);

            self.cached_nvme_dev = self.allocator.dupe(u8, path) catch return null;
            return self.cached_nvme_dev;
        }

        log.debug("No accessible NVMe controller; SMART monitoring disabled", .{});
        return null;
    }

    /// Get system uptime in days, hours, and minutes
    pub fn getUptime(self: *SystemOps) !parse.Uptime {
        // Forgotten before looking, so a failure leaves nothing behind.
        self.last_uptime = null;

        var buf: [64]u8 = undefined;
        self.last_uptime = try parse.uptime(try self.readFile("/proc/uptime", &buf));
        return self.last_uptime.?;
    }

    // ------------------------------------------------------------------------
    // APT updates
    // ------------------------------------------------------------------------

    /// Number of available updates, as the most recent check to produce one
    /// counted them. Unavailable until one has, and stale once a later check
    /// fails — the count is then as old as the last one that worked, which at
    /// the slow interval can be many hours.
    pub fn aptUpdates(self: *SystemOps) Reading(u32) {
        if (!self.apt_count_known.load(.acquire)) return .{};
        return .{
            .value = self.apt_updates_count.load(.monotonic),
            .taken_at = self.apt_count_at.load(.monotonic),
            .fresh = self.apt_count_fresh.load(.acquire),
        };
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
            self.apt_count_fresh.store(false, .release);
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

        const count = self.countUpgradable(run_update) orelse {
            // The count from an earlier check stands, no longer the latest word.
            self.apt_count_fresh.store(false, .release);
            return;
        };

        self.apt_updates_count.store(count, .monotonic);
        self.apt_count_at.store(std.math.lossyCast(u32, self.nowSeconds()), .monotonic);
        self.apt_count_fresh.store(true, .release);
        self.apt_count_known.store(true, .release);
    }

    /// Ask APT how many packages can be upgraded, or null if it would not say.
    fn countUpgradable(self: *SystemOps, run_update: bool) ?u32 {
        var env = config.childEnvironment(self.allocator, self.parent_env) catch |err| {
            log.warn("Cannot prepare the APT check's environment: {t}", .{err});
            return null;
        };
        defer env.deinit();

        if (run_update) {
            if (std.process.run(self.allocator, self.io, .{
                .argv = &[_][]const u8{ "/usr/bin/timeout", "30", "/usr/bin/apt", "update" },
                .environ_map = &env,
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
            .environ_map = &env,
        }) catch |err| {
            log.warn("Failed to check APT updates: {t}", .{err});
            return null;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            log.warn("Failed to check APT updates: apt list did not finish cleanly", .{});
            return null;
        }

        return parse.aptUpgradableCount(result.stdout);
    }
};
