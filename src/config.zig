//! The daemon's settings, read from the environment once at startup.
//!
//! A value rather than a set of globals: `Config.fromEnv` returns it, and
//! `main` hands each part of the daemon the settings that part needs. Nothing
//! reaches back in here, so what a module depends on is in its `init`, and a
//! test can give it anything.
//!
//! Every setting is read through `Env`, the broker's in `mqtt.zig` included,
//! and what `Env` finds wrong goes into a `Report` for `main` to log once the
//! logger is up: a variable given a value that cannot be used, and one whose
//! name is not a setting but looks as if it was meant to be. Neither is
//! passed over in silence.

const std = @import("std");
const parse = @import("parse.zig");

const EnvMap = std.process.Environ.Map;

/// Parse a boolean setting. "1", "true", "yes" and "on" are true; "0",
/// "false", "no" and "off" are false; all case-insensitive. Null for anything
/// else.
pub fn parseBool(val: []const u8) ?bool {
    for ([_][]const u8{ "1", "true", "yes", "on" }) |truthy| {
        if (std.ascii.eqlIgnoreCase(val, truthy)) return true;
    }
    for ([_][]const u8{ "0", "false", "no", "off" }) |falsy| {
        if (std.ascii.eqlIgnoreCase(val, falsy)) return false;
    }
    return null;
}

/// Variables withheld from child processes. The daemon has no use for passing
/// them on, and `apt update` runs every configured hook with the environment it
/// is given.
const secret_variables = [_][]const u8{ "MQTT_PASSWORD", "WEB_API_TOKEN" };

/// The environment for commands whose output is parsed: the daemon's own, in
/// the C locale, without the secrets.
///
/// C locale because the parsers match on the output's words, and a service
/// inherits the system LANG. The environment is otherwise kept whole rather
/// than rebuilt from scratch, so settings such as `http_proxy` still reach apt.
/// Caller owns the result.
pub fn childEnvironment(
    gpa: std.mem.Allocator,
    parent: ?*const EnvMap,
) !EnvMap {
    var env: EnvMap = if (parent) |p| try p.clone(gpa) else .init(gpa);
    errdefer env.deinit();

    try env.put("LC_ALL", "C");
    for (secret_variables) |name| _ = env.swapRemove(name);
    return env;
}

/// A variable whose value could not be used, and what was used instead.
pub const Rejection = struct {
    name: []const u8,
    /// What the variable takes, to finish the sentence "expected ...".
    expected: []const u8,
    shown_buf: [shown_max]u8 = undefined,
    shown_len: usize = 0,
    used_buf: [24]u8 = undefined,
    used_len: usize = 0,

    /// As much of a value as a log line gets.
    const shown_max = 48;

    /// The offending value, made fit for a log line: cut to `shown_max`
    /// bytes, and with everything that is not printable ASCII replaced. No
    /// value any of these settings takes has anything else in it, and one
    /// that does must not get to start a line of its own in the journal.
    pub fn shown(self: *const Rejection) []const u8 {
        return self.shown_buf[0..self.shown_len];
    }

    /// The value in effect, as text.
    pub fn used(self: *const Rejection) []const u8 {
        return self.used_buf[0..self.used_len];
    }
};

/// A variable that is not a setting, but looks as if it was meant to be one.
pub const Unknown = struct {
    name: []const u8,
    /// The setting it is a letter or two away from, if there is one.
    meant: ?[]const u8,
};

/// What reading the environment turned up besides the settings themselves,
/// for the caller to report.
///
/// Collected rather than logged on the spot: the log level and the log file
/// are themselves settings, so nothing can be logged properly until the
/// environment has been read.
pub const Report = struct {
    rejections: [max_rejections]Rejection = undefined,
    rejection_count: usize = 0,
    /// Every name a setting was looked up under. This is the list of what the
    /// daemon's settings are: nothing else keeps one.
    settings: [max_settings][]const u8 = undefined,
    setting_count: usize = 0,
    unknowns: [max_unknowns]Unknown = undefined,
    unknown_count: usize = 0,

    /// More than there are settings that can be rejected.
    const max_rejections = 32;
    /// More than there are settings.
    const max_settings = 64;
    /// As many stray names as are worth a line each.
    const max_unknowns = 16;

    /// Names that share a prefix with a setting and belong to someone else:
    /// systemd sets this one for a service that reports its own readiness.
    const foreign = [_][]const u8{"NOTIFY_SOCKET"};

    pub fn rejected(self: *const Report) []const Rejection {
        return self.rejections[0..self.rejection_count];
    }

    pub fn unknown(self: *const Report) []const Unknown {
        return self.unknowns[0..self.unknown_count];
    }

    fn reject(
        self: *Report,
        name: []const u8,
        value: []const u8,
        expected: []const u8,
        comptime used_fmt: []const u8,
        used_args: anytype,
    ) void {
        if (self.rejection_count == max_rejections) return;
        const entry = &self.rejections[self.rejection_count];
        entry.* = .{ .name = name, .expected = expected };

        entry.shown_len = @min(value.len, Rejection.shown_max);
        for (entry.shown_buf[0..entry.shown_len], value[0..entry.shown_len]) |*out, byte| {
            out.* = if (std.ascii.isPrint(byte)) byte else '?';
        }
        const used = std.mem.print(&entry.used_buf, used_fmt, used_args) catch "";
        entry.used_len = used.len;
        self.rejection_count += 1;
    }

    /// Note that `name` is a setting.
    fn know(self: *Report, name: []const u8) void {
        if (self.isSetting(name)) return;
        // A setting that does not fit only goes unrecognised below, where it
        // can at worst be reported as a stray: the tests hold the count under.
        if (self.setting_count == max_settings) return;
        self.settings[self.setting_count] = name;
        self.setting_count += 1;
    }

    fn isSetting(self: *const Report, name: []const u8) bool {
        for (self.settings[0..self.setting_count]) |setting| {
            if (std.mem.eql(u8, setting, name)) return true;
        }
        return false;
    }

    /// Look through `map` for variables that are not settings but were
    /// probably meant to be. Call it once every setting has been read: what
    /// counts as one is what was asked for until then.
    ///
    /// The environment is full of names that are none of the daemon's
    /// business, so only two kinds are picked out. One is a letter or two
    /// away from a setting, `INTERVL_FAST`. The other begins as a family of
    /// settings does, `THRESHOLD_CPU_HIGH` beside `THRESHOLD_CPU_CRITICAL`: a
    /// setting from some other version, or one that was never there. Only the
    /// name is kept. A misspelt `MQTT_PASSWORD` is exactly what turns up here,
    /// and its value has no place in a log.
    pub fn findUnknown(self: *Report, map: *const EnvMap) void {
        for (map.keys()) |name| {
            if (self.unknown_count == max_unknowns) return;
            if (!looksLikeASetting(name) or self.isSetting(name)) continue;
            if (isForeign(name)) continue;

            const meant = self.closestSetting(name);
            if (meant == null and !self.sharesAFamily(name)) continue;

            self.unknowns[self.unknown_count] = .{ .name = name, .meant = meant };
            self.unknown_count += 1;
        }
    }

    /// Capitals, digits and underscores, as every setting is; and so nothing
    /// that could do to a log line what `Rejection.shown` guards against.
    fn looksLikeASetting(name: []const u8) bool {
        if (name.len == 0 or name.len > max_name_len) return false;
        for (name) |ch| {
            if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch) and ch != '_') return false;
        }
        return true;
    }

    fn isForeign(name: []const u8) bool {
        for (foreign) |other| {
            if (std.mem.eql(u8, other, name)) return true;
        }
        return false;
    }

    /// Whether `name` starts as some setting does, up to its first underscore.
    fn sharesAFamily(self: *const Report, name: []const u8) bool {
        const family = familyOf(name) orelse return false;
        for (self.settings[0..self.setting_count]) |setting| {
            if (std.mem.startsWith(u8, setting, family)) return true;
        }
        return false;
    }

    /// `MQTT_` of `MQTT_HOST`: the name through its first underscore.
    fn familyOf(name: []const u8) ?[]const u8 {
        const underscore = std.mem.indexOfScalar(u8, name, '_') orelse return null;
        return name[0 .. underscore + 1];
    }

    /// The setting `name` is at most two edits from, if any; the nearest of
    /// them if several.
    fn closestSetting(self: *const Report, name: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_distance: usize = max_typo_distance + 1;
        for (self.settings[0..self.setting_count]) |setting| {
            const distance = editDistance(name, setting);
            if (distance < best_distance) {
                best = setting;
                best_distance = distance;
            }
        }
        return best;
    }
};

/// Longest name looked at as a possible setting; the longest there is has 23
/// characters.
const max_name_len = 40;

/// How far from a setting a name may be and still be taken for it misspelt.
const max_typo_distance = 2;

/// The number of single-character insertions, deletions and substitutions
/// between `a` and `b`, neither longer than `max_name_len`.
fn editDistance(a: []const u8, b: []const u8) usize {
    std.debug.assert(a.len <= max_name_len and b.len <= max_name_len);

    // One row of the table at a time: `row[j]` is the distance between what
    // of `a` has been gone through and the first `j` characters of `b`.
    var row: [max_name_len + 1]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;

    for (a, 1..) |ch_a, i| {
        var diagonal = row[0];
        row[0] = i;
        for (b, 1..) |ch_b, j| {
            const above = row[j];
            const substituted = diagonal + @intFromBool(ch_a != ch_b);
            row[j] = @min(substituted, @min(above, row[j - 1]) + 1);
            diagonal = above;
        }
    }
    return row[b.len];
}

/// Reads typed settings out of an environment, noting each one it has to
/// turn down.
///
/// A variable set to nothing counts as unset, whatever kind of setting it is:
/// `NAME=` in an environment file is how a setting is left blank, and it
/// reads as if the line were not there.
pub const Env = struct {
    map: *const EnvMap,
    report: *Report,

    /// The variable's value, or null when it is unset or set to nothing.
    pub fn get(self: Env, name: []const u8) ?[]const u8 {
        self.report.know(name);
        const val = self.map.get(name) orelse return null;
        return if (val.len > 0) val else null;
    }

    pub fn string(self: Env, name: []const u8, default: []const u8) []const u8 {
        return self.get(name) orelse default;
    }

    /// Something that is not a boolean reads as false, as it always has, so a
    /// setting spelled `disabled` still turns the thing off — but it is noted,
    /// so that `MQTT_ENABLED=ture` does not pass for a decision.
    pub fn boolean(self: Env, name: []const u8, default: bool) bool {
        const expected = "1/true/yes/on or 0/false/no/off";
        self.report.know(name);
        const val = self.map.get(name) orelse return default;

        if (val.len == 0) {
            // Unset, like any other blank. Said aloud where that is not what
            // it used to mean: every release before this read a blank as
            // false, which for a setting that is on by default turned it off.
            if (default) self.report.reject(name, val, expected, "true", .{});
            return default;
        }
        return parseBool(val) orelse {
            self.report.reject(name, val, expected, "false", .{});
            return false;
        };
    }

    /// A whole number no smaller than `min`. Anything else keeps `default`,
    /// except a number below `min`, which is raised to it.
    pub fn int(self: Env, comptime T: type, name: []const u8, default: T, comptime min: T) T {
        const val = self.get(name) orelse return default;
        const expected = std.fmt.comptimePrint("a whole number from {d} to {d}", .{ min, std.math.maxInt(T) });

        const parsed = std.fmt.parseInt(T, val, 10) catch {
            self.report.reject(name, val, expected, "{d}", .{default});
            return default;
        };
        if (parsed < min) {
            self.report.reject(name, val, expected, "{d}", .{min});
            return min;
        }
        return parsed;
    }
};

/// Readings at or above these are drawn inverted on the panel.
pub const Thresholds = struct {
    /// CPU load, percent.
    cpu: u8 = 90,
    /// CPU and disk temperature, °C.
    temp: u8 = 85,
    /// Memory in use, percent.
    mem: u8 = 95,
    /// Root filesystem in use, percent.
    disk: u8 = 95,
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    /// Null for a name that is not a level.
    pub fn parse(str: []const u8) ?LogLevel {
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
        return null;
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

/// Application configuration loaded from environment variables
pub const Config = struct {
    thresholds: Thresholds = .{},

    log_level: LogLevel = .info,
    /// Enable/disable logging to file
    log_to_file: bool = false,
    log_file_path: []const u8 = "/var/log/sys-ink.log",

    /// Enable/disable BMP export
    export_bmp: bool = false,
    bmp_export_path: []const u8 = "/tmp/sys-ink.bmp",

    /// GPIO chip path. Null: found by its label; see `GpioNative.findChip`.
    gpio_chip: ?[]const u8 = null,
    /// SPI device path
    spi_device: []const u8 = "/dev/spidev0.0",

    /// Scheduler interval for fast updates (CPU, RAM, IP, etc.) in seconds
    interval_fast: u32 = 30,
    /// Scheduler interval for slow updates (APT, Internet) in seconds
    interval_slow: u32 = 10800, // 3 hours
    /// How often to force a full (non-partial) refresh, in seconds. Full
    /// refreshes clear the ghosting that partial updates accumulate.
    interval_full_refresh: u32 = 600, // 10 minutes

    /// Park the panel in deep sleep between refreshes. Waveshare advises against
    /// leaving an e-paper panel driven continuously, and idle cycles (an
    /// unchanged frame) then cost nothing at all. Costs ~200ms per visible
    /// update to wake and restore the partial-update reference.
    panel_sleep: bool = true,

    /// Host probed to decide whether the machine has internet access.
    internet_check_ip: [4]u8 = .{ 8, 8, 8, 8 },
    internet_check_port: u16 = 53,

    /// Serve the current panel frame over HTTP. See `web_preview.zig`.
    web_preview: bool = false,
    /// Loopback by default: the preview has no authentication and the frame
    /// carries addresses and load figures. Widening this is a decision.
    web_preview_addr: []const u8 = "127.0.0.1",
    web_preview_port: u16 = 8390,
    /// Bearer token for the API's notice routes. Unset: they stay shut. See
    /// `api.zig`.
    web_api_token: ?[]const u8 = null,

    /// Accept notices through a named pipe. See `notice_fifo.zig`.
    notify_enabled: bool = true,
    notify_fifo: []const u8 = "/run/sys-ink/notify",
    /// Group allowed to write to the pipe besides root. Unset: root only.
    notify_group: ?[]const u8 = null,
    /// How long a notice stays on the panel, in seconds.
    notify_duration: u32 = 30,

    /// Show what Spotify plays. See `spotify_client.zig`.
    spotify_enabled: bool = false,
    /// Where the link to the Spotify account is kept between runs. It holds
    /// a refresh token, so it is written readable by its owner alone.
    spotify_state_file: []const u8 = "/var/lib/sys-ink/spotify.json",
    /// How long the music screen stays up once playback pauses, in seconds.
    spotify_pause_hold: u32 = 30,
    /// Seconds between redraws of the music screen while it plays, which move
    /// its progress bar. Each is a partial refresh of the panel.
    spotify_interval: u32 = 5,

    /// The settings `map` gives, over the defaults above. Strings are borrowed
    /// from `map`, which must outlive the result.
    pub fn fromEnv(map: *const EnvMap, report: *Report) Config {
        const env: Env = .{ .map = map, .report = report };
        const defaults: Config = .{};

        return .{
            .thresholds = .{
                .cpu = env.int(u8, "THRESHOLD_CPU_CRITICAL", defaults.thresholds.cpu, 0),
                .temp = env.int(u8, "THRESHOLD_TEMP_CRITICAL", defaults.thresholds.temp, 0),
                .mem = env.int(u8, "THRESHOLD_MEM_CRITICAL", defaults.thresholds.mem, 0),
                .disk = env.int(u8, "THRESHOLD_DISK_CRITICAL", defaults.thresholds.disk, 0),
            },

            .log_level = logLevel(env, defaults.log_level),
            .log_to_file = env.boolean("LOG_TO_FILE", defaults.log_to_file),
            .log_file_path = env.string("LOG_FILE_PATH", defaults.log_file_path),

            .export_bmp = env.boolean("EXPORT_BMP", defaults.export_bmp),
            .bmp_export_path = env.string("BMP_EXPORT_PATH", defaults.bmp_export_path),

            .gpio_chip = env.get("GPIO_CHIP"),
            .spi_device = env.string("SPI_DEVICE", defaults.spi_device),

            .interval_fast = env.int(u32, "INTERVAL_FAST", defaults.interval_fast, 1),
            .interval_slow = env.int(u32, "INTERVAL_SLOW", defaults.interval_slow, 1),
            .interval_full_refresh = env.int(u32, "INTERVAL_FULL_REFRESH", defaults.interval_full_refresh, 1),
            .panel_sleep = env.boolean("PANEL_SLEEP", defaults.panel_sleep),

            .internet_check_ip = probeAddress(env, defaults.internet_check_ip),
            .internet_check_port = env.int(u16, "INTERNET_CHECK_PORT", defaults.internet_check_port, 0),

            .web_preview = env.boolean("WEB_PREVIEW", defaults.web_preview),
            .web_preview_addr = env.string("WEB_PREVIEW_ADDR", defaults.web_preview_addr),
            .web_preview_port = env.int(u16, "WEB_PREVIEW_PORT", defaults.web_preview_port, 0),
            .web_api_token = env.get("WEB_API_TOKEN"),

            .notify_enabled = env.boolean("NOTIFY_ENABLED", defaults.notify_enabled),
            .notify_fifo = env.string("NOTIFY_FIFO", defaults.notify_fifo),
            .notify_group = env.get("NOTIFY_GROUP"),
            .notify_duration = env.int(u32, "NOTIFY_DURATION", defaults.notify_duration, 1),

            .spotify_enabled = env.boolean("SPOTIFY_ENABLED", defaults.spotify_enabled),
            .spotify_state_file = env.string("SPOTIFY_STATE_FILE", defaults.spotify_state_file),
            .spotify_pause_hold = env.int(u32, "SPOTIFY_PAUSE_HOLD", defaults.spotify_pause_hold, 0),
            .spotify_interval = env.int(u32, "SPOTIFY_INTERVAL", defaults.spotify_interval, 1),
        };
    }

    fn logLevel(env: Env, default: LogLevel) LogLevel {
        const val = env.get("LOG_LEVEL") orelse return default;
        return LogLevel.parse(val) orelse {
            env.report.reject("LOG_LEVEL", val, "DEBUG, INFO, WARN or ERROR", "{s}", .{"INFO"});
            return .info;
        };
    }

    fn probeAddress(env: Env, default: [4]u8) [4]u8 {
        const val = env.get("INTERNET_CHECK_IP") orelse return default;
        return parse.ipv4(val) catch {
            env.report.reject("INTERNET_CHECK_IP", val, "an IPv4 address", "{d}.{d}.{d}.{d}", .{
                default[0], default[1], default[2], default[3],
            });
            return default;
        };
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "parseBool knows true from false from neither" {
    for ([_][]const u8{ "1", "true", "TRUE", "True", "yes", "YES", "on", "ON" }) |val| {
        try testing.expectEqual(@as(?bool, true), parseBool(val));
    }
    for ([_][]const u8{ "0", "false", "FALSE", "no", "off", "Off" }) |val| {
        try testing.expectEqual(@as(?bool, false), parseBool(val));
    }
    for ([_][]const u8{ "2", "maybe", "ture", "disabled", " true", "" }) |val| {
        try testing.expectEqual(@as(?bool, null), parseBool(val));
    }
}

test "childEnvironment forces the C locale and drops the secrets" {
    var parent: EnvMap = .init(testing.allocator);
    defer parent.deinit();
    try parent.put("LANG", "cs_CZ.UTF-8");
    try parent.put("LC_ALL", "cs_CZ.UTF-8");
    try parent.put("MQTT_PASSWORD", "secret");
    try parent.put("WEB_API_TOKEN", "token");
    try parent.put("http_proxy", "http://proxy:3128");

    var child = try childEnvironment(testing.allocator, &parent);
    defer child.deinit();

    try testing.expectEqualStrings("C", child.get("LC_ALL").?);
    try testing.expect(child.get("MQTT_PASSWORD") == null);
    try testing.expect(child.get("WEB_API_TOKEN") == null);
    // Everything else passes through, proxies included.
    try testing.expectEqualStrings("http://proxy:3128", child.get("http_proxy").?);
    // And the daemon's own environment is left as it was.
    try testing.expectEqualStrings("secret", parent.get("MQTT_PASSWORD").?);
}

test "childEnvironment works without a parent environment" {
    var child = try childEnvironment(testing.allocator, null);
    defer child.deinit();
    try testing.expectEqualStrings("C", child.get("LC_ALL").?);
    try testing.expectEqual(@as(usize, 1), child.count());
}

test "LogLevel.parse accepts both WARN and WARNING" {
    try testing.expectEqual(LogLevel.warn, LogLevel.parse("WARN").?);
    try testing.expectEqual(LogLevel.warn, LogLevel.parse("WARNING").?);
    try testing.expectEqual(LogLevel.warn, LogLevel.parse("warn").?);
}

test "LogLevel.parse maps the remaining levels" {
    try testing.expectEqual(LogLevel.debug, LogLevel.parse("debug").?);
    try testing.expectEqual(LogLevel.info, LogLevel.parse("INFO").?);
    try testing.expectEqual(LogLevel.err, LogLevel.parse("ERROR").?);
    try testing.expectEqual(LogLevel.err, LogLevel.parse("ERR").?);
}

test "LogLevel.parse knows no other names" {
    try testing.expect(LogLevel.parse("nonsense") == null);
    try testing.expect(LogLevel.parse("") == null);
}

/// An environment holding `pairs`, name then value.
fn envOf(pairs: []const [2][]const u8) !EnvMap {
    var map: EnvMap = .init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

fn rejectionOf(report: *const Report, name: []const u8) ?*const Rejection {
    for (report.rejected()) |*r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

fn unknownNamed(report: *const Report, name: []const u8) ?Unknown {
    for (report.unknown()) |u| if (std.mem.eql(u8, u.name, name)) return u;
    return null;
}

test "an empty environment gives the defaults and nothing to report" {
    var map = try envOf(&.{});
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    report.findUnknown(&map);
    try testing.expectEqual(@as(usize, 0), report.rejected().len);
    try testing.expectEqual(@as(usize, 0), report.unknown().len);
    try testing.expectEqual(@as(u32, 30), cfg.interval_fast);
    try testing.expectEqual(@as(u8, 90), cfg.thresholds.cpu);
    try testing.expect(cfg.notify_enabled);
    try testing.expect(cfg.gpio_chip == null);
    try testing.expect(cfg.web_api_token == null);
    try testing.expectEqualStrings("/dev/spidev0.0", cfg.spi_device);
}

test "what the environment sets is what the config holds" {
    var map = try envOf(&.{
        .{ "INTERVAL_FAST", "10" },
        .{ "THRESHOLD_TEMP_CRITICAL", "70" },
        .{ "EXPORT_BMP", "yes" },
        .{ "NOTIFY_ENABLED", "off" },
        .{ "GPIO_CHIP", "/dev/gpiochip4" },
        .{ "INTERNET_CHECK_IP", "1.1.1.1" },
        .{ "LOG_LEVEL", "debug" },
        .{ "WEB_API_TOKEN", "s3cret" },
        .{ "NOTIFY_GROUP", "panel" },
    });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    report.findUnknown(&map);
    try testing.expectEqual(@as(usize, 0), report.rejected().len);
    try testing.expectEqual(@as(usize, 0), report.unknown().len);
    try testing.expectEqual(@as(u32, 10), cfg.interval_fast);
    try testing.expectEqual(@as(u8, 70), cfg.thresholds.temp);
    try testing.expect(cfg.export_bmp);
    try testing.expect(!cfg.notify_enabled);
    try testing.expectEqualStrings("/dev/gpiochip4", cfg.gpio_chip.?);
    try testing.expectEqual([4]u8{ 1, 1, 1, 1 }, cfg.internet_check_ip);
    try testing.expectEqual(LogLevel.debug, cfg.log_level);
    try testing.expectEqualStrings("s3cret", cfg.web_api_token.?);
    try testing.expectEqualStrings("panel", cfg.notify_group.?);
}

test "Spotify stays off unless asked for, and its settings are read when given" {
    var off = try envOf(&.{});
    defer off.deinit();
    var report: Report = .{};
    const defaults = Config.fromEnv(&off, &report);
    try testing.expect(!defaults.spotify_enabled);
    try testing.expectEqualStrings("/var/lib/sys-ink/spotify.json", defaults.spotify_state_file);

    var map = try envOf(&.{
        .{ "SPOTIFY_ENABLED", "true" },
        .{ "SPOTIFY_STATE_FILE", "/srv/spotify.json" },
        .{ "SPOTIFY_PAUSE_HOLD", "0" },
        .{ "SPOTIFY_INTERVAL", "0" },
    });
    defer map.deinit();
    report = .{};
    const cfg = Config.fromEnv(&map, &report);
    try testing.expect(cfg.spotify_enabled);
    try testing.expectEqualStrings("/srv/spotify.json", cfg.spotify_state_file);
    // No hold at all is a choice; no interval between redraws is not.
    try testing.expectEqual(@as(u32, 0), cfg.spotify_pause_hold);
    try testing.expectEqual(@as(u32, 1), cfg.spotify_interval);
    try testing.expectEqual(@as(usize, 1), report.rejected().len);
    try testing.expect(rejectionOf(&report, "SPOTIFY_INTERVAL") != null);
}

test "a number that is not one keeps the default, and says so" {
    var map = try envOf(&.{
        .{ "INTERVAL_FAST", "abc" },
        .{ "WEB_PREVIEW_PORT", "99999" },
        .{ "THRESHOLD_CPU_CRITICAL", "-5" },
    });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    try testing.expectEqual(@as(u32, 30), cfg.interval_fast);
    try testing.expectEqual(@as(u16, 8390), cfg.web_preview_port);
    try testing.expectEqual(@as(u8, 90), cfg.thresholds.cpu);
    try testing.expectEqual(@as(usize, 3), report.rejected().len);

    const interval = rejectionOf(&report, "INTERVAL_FAST").?;
    try testing.expectEqualStrings("abc", interval.shown());
    try testing.expectEqualStrings("30", interval.used());
    try testing.expectEqualStrings("a whole number from 1 to 4294967295", interval.expected);
    try testing.expectEqualStrings("8390", rejectionOf(&report, "WEB_PREVIEW_PORT").?.used());
}

test "an interval of zero is raised to one second, and says so" {
    var map = try envOf(&.{ .{ "INTERVAL_FAST", "0" }, .{ "NOTIFY_DURATION", "0" } });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    try testing.expectEqual(@as(u32, 1), cfg.interval_fast);
    try testing.expectEqual(@as(u32, 1), cfg.notify_duration);
    try testing.expectEqual(@as(usize, 2), report.rejected().len);
    try testing.expectEqualStrings("1", rejectionOf(&report, "INTERVAL_FAST").?.used());
}

test "a boolean that is not one reads as false, and says so" {
    // False rather than the default: `NOTIFY_ENABLED=disabled` has always
    // turned notices off, and must not start turning them on.
    var map = try envOf(&.{ .{ "NOTIFY_ENABLED", "disabled" }, .{ "WEB_PREVIEW", "ture" } });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    try testing.expect(!cfg.notify_enabled);
    try testing.expect(!cfg.web_preview);
    try testing.expectEqual(@as(usize, 2), report.rejected().len);
    try testing.expectEqualStrings("false", rejectionOf(&report, "NOTIFY_ENABLED").?.used());
}

test "an address or a log level that is not one keeps the default, and says so" {
    var map = try envOf(&.{ .{ "INTERNET_CHECK_IP", "one.one.one.one" }, .{ "LOG_LEVEL", "LOUD" } });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    try testing.expectEqual([4]u8{ 8, 8, 8, 8 }, cfg.internet_check_ip);
    try testing.expectEqual(LogLevel.info, cfg.log_level);
    try testing.expectEqualStrings("8.8.8.8", rejectionOf(&report, "INTERNET_CHECK_IP").?.used());
    try testing.expectEqualStrings("INFO", rejectionOf(&report, "LOG_LEVEL").?.used());
}

test "a variable left blank counts as unset, whatever kind it is" {
    var map = try envOf(&.{
        .{ "INTERVAL_FAST", "" },
        .{ "LOG_LEVEL", "" },
        .{ "INTERNET_CHECK_IP", "" },
        .{ "WEB_API_TOKEN", "" },
        .{ "NOTIFY_GROUP", "" },
        .{ "GPIO_CHIP", "" },
        .{ "SPI_DEVICE", "" },
        .{ "NOTIFY_FIFO", "" },
        // Off by default, and off when blank: nothing to say.
        .{ "EXPORT_BMP", "" },
    });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    try testing.expectEqual(@as(usize, 0), report.rejected().len);
    try testing.expectEqual(@as(u32, 30), cfg.interval_fast);
    try testing.expect(cfg.web_api_token == null);
    try testing.expect(cfg.notify_group == null);
    // A path left blank is the default path, not an empty one to fail on.
    try testing.expect(cfg.gpio_chip == null);
    try testing.expectEqualStrings("/dev/spidev0.0", cfg.spi_device);
    try testing.expectEqualStrings("/run/sys-ink/notify", cfg.notify_fifo);
    try testing.expect(!cfg.export_bmp);
}

test "a blank that used to turn a default off now leaves it on, and says so" {
    // Every release before this read `NOTIFY_ENABLED=` as false. Unset is
    // what a blank means everywhere else, so it means that here too; but
    // nobody who relied on the old reading finds out by accident.
    var map = try envOf(&.{ .{ "NOTIFY_ENABLED", "" }, .{ "PANEL_SLEEP", "" } });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    try testing.expect(cfg.notify_enabled);
    try testing.expect(cfg.panel_sleep);
    try testing.expectEqual(@as(usize, 2), report.rejected().len);

    const notices = rejectionOf(&report, "NOTIFY_ENABLED").?;
    try testing.expectEqualStrings("", notices.shown());
    try testing.expectEqualStrings("true", notices.used());
}

test "a rejected value is made fit for a log line before it is kept" {
    var report: Report = .{};

    // A line of its own, an escape sequence, and bytes that are no character.
    report.reject("INTERVAL_FAST", "5\n[err] (main) all is lost \x1b[2J\xff\xc3", "a number", "{d}", .{30});
    try testing.expectEqualStrings("5?[err] (main) all is lost ?[2J??", report.rejected()[0].shown());

    // Cut to length, and the list does not overflow.
    const long: [200]u8 = @splat('x');
    for (0..Report.max_rejections + 5) |_| report.reject("X", &long, "a number", "{d}", .{1});
    try testing.expectEqual(Report.max_rejections, report.rejected().len);
    try testing.expectEqual(Rejection.shown_max, report.rejected()[1].shown().len);
}

test "a name a letter or two from a setting is pointed out, with the setting it was meant for" {
    var map = try envOf(&.{
        .{ "INTERVL_FAST", "10" },
        .{ "MQTT_PASSWRD", "hunter2" },
        .{ "INTERVAL_FAST", "20" },
    });
    defer map.deinit();
    var report: Report = .{};

    const cfg = Config.fromEnv(&map, &report);
    // The broker's settings are read through the same `Env` in `mqtt.zig`;
    // this one stands in for them here.
    _ = (Env{ .map = &map, .report = &report }).get("MQTT_PASSWORD");
    report.findUnknown(&map);

    try testing.expectEqual(@as(u32, 20), cfg.interval_fast);
    try testing.expectEqual(@as(usize, 2), report.unknown().len);
    try testing.expectEqualStrings("INTERVAL_FAST", unknownNamed(&report, "INTERVL_FAST").?.meant.?);
    try testing.expectEqualStrings("MQTT_PASSWORD", unknownNamed(&report, "MQTT_PASSWRD").?.meant.?);
    // The name only: there is nowhere for the value of a misspelt secret to go.
    try testing.expect(!@hasField(Unknown, "value"));
}

test "a name from a family of settings that is not one of them is pointed out" {
    var map = try envOf(&.{
        .{ "THRESHOLD_CPU_HIGH", "70" },
        .{ "THRESHOLD_CPU_CRITICAL", "90" },
        .{ "LOG_COLOUR", "always" },
    });
    defer map.deinit();
    var report: Report = .{};

    _ = Config.fromEnv(&map, &report);
    report.findUnknown(&map);

    try testing.expectEqual(@as(usize, 2), report.unknown().len);
    const high = unknownNamed(&report, "THRESHOLD_CPU_HIGH").?;
    // Not a misspelling of anything: there is no setting to suggest.
    try testing.expect(high.meant == null);
    try testing.expect(unknownNamed(&report, "LOG_COLOUR") != null);
}

test "what is none of the daemon's business is left alone" {
    var map = try envOf(&.{
        .{ "PATH", "/usr/bin" },
        .{ "LANG", "cs_CZ.UTF-8" },
        .{ "HOME", "/root" },
        .{ "INVOCATION_ID", "0123" },
        .{ "RUNTIME_DIRECTORY", "/run/sys-ink" },
        // Other programs' settings, in the same file.
        .{ "DISPLAY_MODE", "ha" },
        .{ "HA_URL", "https://example.invalid" },
        // systemd's, for all that it starts as the notice settings do.
        .{ "NOTIFY_SOCKET", "/run/systemd/notify" },
        // Lower case is not how a setting is spelled, typo or not.
        .{ "http_proxy", "http://proxy:3128" },
        .{ "interval_fast", "10" },
    });
    defer map.deinit();
    var report: Report = .{};

    _ = Config.fromEnv(&map, &report);
    report.findUnknown(&map);
    try testing.expectEqual(@as(usize, 0), report.unknown().len);
}

test "the list of strays stops when it is full" {
    var map: EnvMap = .init(testing.allocator);
    defer map.deinit();
    var names: [Report.max_unknowns + 4][16]u8 = undefined;
    for (&names, 0..) |*name, i| {
        try map.put(try std.mem.print(name, "MQTT_STRAY_{d}", .{i}), "x");
    }
    var report: Report = .{};

    report.know("MQTT_HOST");
    report.findUnknown(&map);
    try testing.expectEqual(Report.max_unknowns, report.unknown().len);
}

test "the distance between two names counts each edit once" {
    try testing.expectEqual(@as(usize, 0), editDistance("MQTT_HOST", "MQTT_HOST"));
    try testing.expectEqual(@as(usize, 1), editDistance("INTERVL_FAST", "INTERVAL_FAST"));
    try testing.expectEqual(@as(usize, 1), editDistance("MQTT_PORTS", "MQTT_PORT"));
    try testing.expectEqual(@as(usize, 2), editDistance("LOG_LEVLE", "LOG_LEVEL"));
    try testing.expectEqual(@as(usize, 9), editDistance("", "MQTT_HOST"));
    try testing.expect(editDistance("THRESHOLD_CPU_HIGH", "THRESHOLD_CPU_CRITICAL") > max_typo_distance);
}

test "every setting there is fits the list of them" {
    var map = try envOf(&.{});
    defer map.deinit();
    var report: Report = .{};
    _ = Config.fromEnv(&map, &report);

    // With room left for the broker's, which `mqtt.zig` reads the same way.
    try testing.expect(report.setting_count > 20);
    try testing.expect(report.setting_count + 12 <= Report.max_settings);
    for (report.settings[0..report.setting_count]) |name| {
        try testing.expect(name.len <= max_name_len);
    }
}
