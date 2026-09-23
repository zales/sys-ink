const std = @import("std");
const config = @import("config.zig");

var mutex: std.Io.Mutex = .init;
var app_io: std.Io = undefined;

var log_file: ?std.Io.File = null;
/// Kept alive alongside `file_writer`, which borrows it.
var file_write_buf: [4096]u8 = undefined;
/// Must stay at a fixed address: `Io.Writer` finds its parent through
/// `@fieldParentPtr` on the embedded `interface`, so this may be written once at
/// init and thereafter only reached as `&file_writer.?.interface`. Copying or
/// moving it would silently break that link.
var file_writer: ?std.Io.File.Writer = null;

/// ANSI colour is only useful on a terminal; under systemd the escapes would be
/// stored verbatim in the journal.
var use_color: bool = false;

/// Set up logging. Never fails: a log file that cannot be opened is reported on
/// stderr and logging carries on there, rather than keeping the daemon — and
/// with it the panel — from starting over a logging option.
pub fn init(io: std.Io) void {
    app_io = io;

    use_color = std.Io.File.stderr().isTty(io) catch false;

    if (!config.Config.log_to_file) return;

    const path = config.Config.log_file_path;
    const file = openAppend(path) catch |err| {
        std.debug.print("Failed to open log file '{s}': {t}; logging to stderr only\n", .{ path, err });
        return;
    };

    log_file = file;
    file_writer = file.writerStreaming(io, &file_write_buf);
}

/// Open `path` for appending, creating it if needed.
///
/// O_APPEND, not a seek to the end: every write then lands at whatever the end
/// is at that moment, so `logrotate` can truncate the file under a running
/// daemon (`copytruncate`) and logging simply continues from the start. A
/// writer that tracks its own position would carry on at the old offset and
/// leave the file a hole of that size. 0640, as log files under /var/log are.
fn openAppend(path: []const u8) !std.Io.File {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o640);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

pub fn deinit() void {
    const io = app_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (file_writer) |*w| {
        w.flush() catch {};
        file_writer = null;
    }
    if (log_file) |f| {
        f.close(io);
        log_file = null;
    }
}

/// Wall-clock time, UTC.
const Clock = struct {
    year: u16,
    month: u8,
    day: u8,
    hours: u64,
    minutes: u64,
    seconds: u64,

    fn now(io: std.Io) Clock {
        return at(@intCast(std.Io.Timestamp.now(io, .real).toSeconds()));
    }

    fn at(epoch_seconds: u64) Clock {
        const day_seconds = epoch_seconds % 86400;

        const epoch: std.time.epoch.EpochSeconds = .{ .secs = epoch_seconds };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = @as(u8, month_day.day_index) + 1,
            .hours = day_seconds / 3600,
            .minutes = (day_seconds % 3600) / 60,
            .seconds = day_seconds % 60,
        };
    }
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(config.Config.log_level_std)) return;

    const io = std.Options.debug_io;
    const scope_prefix = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    const color = comptime switch (level) {
        .err => "\x1b[31m", // Red
        .warn => "\x1b[33m", // Yellow
        .info => "\x1b[32m", // Green
        .debug => "\x1b[34m", // Blue
    };

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const clock = Clock.now(io);

    // The prefixes go through the non-generic helpers below. This function is
    // instantiated once per call site, and a prefix printed inline is compiled
    // into every one of them — the date on file lines cost 10 KB of binary that
    // way, where formatting it once costs a few hundred bytes.
    nosuspend {
        stderrPrefix(clock, @tagName(level), if (use_color) color else null, scope_prefix);
        std.debug.print(format ++ "\n", args);
    }

    if (file_writer) |*w| {
        nosuspend {
            filePrefix(&w.interface, clock, @tagName(level), scope_prefix);
            w.interface.print(format ++ "\n", args) catch {};
            // Flush per record so a crash does not lose the tail of the log.
            w.flush() catch {};
        }
    }
}

/// `[hh:mm:ss] [level] (scope) ` on stderr, coloured on a terminal. The
/// journal adds its own date, so this carries only the time of day.
fn stderrPrefix(clock: Clock, level: []const u8, color: ?[]const u8, scope_prefix: []const u8) void {
    const reset = "\x1b[0m";
    const gray = "\x1b[90m";

    if (color) |c| {
        std.debug.print("{s}[{d:0>2}:{d:0>2}:{d:0>2}]{s} [{s}{s}{s}] {s}", .{
            gray,         clock.hours, clock.minutes, clock.seconds,
            reset,        c,           level,         reset,
            scope_prefix,
        });
    } else {
        std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] {s}", .{
            clock.hours, clock.minutes, clock.seconds, level, scope_prefix,
        });
    }
}

/// `[yyyy-mm-dd hh:mm:ssZ] [level] (scope) ` in the log file. The file gets the
/// date as well: unlike the journal, which stamps stderr lines itself, it has
/// nothing else to say which day a line is from. UTC, marked as such.
fn filePrefix(w: *std.Io.Writer, clock: Clock, level: []const u8, scope_prefix: []const u8) void {
    w.print("[{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z] [{s}] {s}", .{
        clock.year,    clock.month,   clock.day, clock.hours,
        clock.minutes, clock.seconds, level,     scope_prefix,
    }) catch {};
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "the clock splits an instant into its UTC date and time" {
    // 2026-09-23 18:53:01 UTC.
    const c = Clock.at(1790189581);
    try testing.expectEqual(@as(u16, 2026), c.year);
    try testing.expectEqual(@as(u8, 9), c.month);
    try testing.expectEqual(@as(u8, 23), c.day);
    try testing.expectEqual(@as(u64, 18), c.hours);
    try testing.expectEqual(@as(u64, 53), c.minutes);
    try testing.expectEqual(@as(u64, 1), c.seconds);
}

test "the first day of a month is day 1, not day 0" {
    // 2024-03-01 00:00:00 UTC, the day after a leap day.
    const c = Clock.at(1709251200);
    try testing.expectEqual(@as(u8, 3), c.month);
    try testing.expectEqual(@as(u8, 1), c.day);
}
