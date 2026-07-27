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

pub fn init(io: std.Io) !void {
    app_io = io;

    use_color = std.Io.File.stderr().isTty(io) catch false;

    if (!config.Config.log_to_file) return;

    const path = config.Config.log_file_path;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = false }) catch |err| {
        std.debug.print("Failed to open log file '{s}': {t}\n", .{ path, err });
        return err;
    };

    // Seek to the end once and keep the writer around; re-statting and
    // re-seeking on every line costs three syscalls per log record.
    var writer = file.writer(io, &file_write_buf);
    const end_pos = file.length(io) catch 0;
    writer.seekToUnbuffered(end_pos) catch {};

    log_file = file;
    file_writer = writer;
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

const Clock = struct {
    hours: u64,
    minutes: u64,
    seconds: u64,

    fn now(io: std.Io) Clock {
        const epoch_seconds: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
        const day_seconds = epoch_seconds % 86400;
        return .{
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
    const reset = "\x1b[0m";
    const gray = "\x1b[90m";

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const clock = Clock.now(io);

    nosuspend {
        if (use_color) {
            std.debug.print("{s}[{d:0>2}:{d:0>2}:{d:0>2}]{s} [{s}{s}{s}] " ++ scope_prefix, .{
                gray,  clock.hours, clock.minutes,   clock.seconds,
                reset, color,       @tagName(level), reset,
            });
        } else {
            std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] " ++ scope_prefix, .{
                clock.hours, clock.minutes, clock.seconds, @tagName(level),
            });
        }
        std.debug.print(format ++ "\n", args);
    }

    if (file_writer) |*w| {
        nosuspend {
            w.interface.print("[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] " ++ scope_prefix ++ format ++ "\n", .{
                clock.hours,
                clock.minutes,
                clock.seconds,
                @tagName(level),
            } ++ args) catch {};
            // Flush per record so a crash does not lose the tail of the log.
            w.flush() catch {};
        }
    }
}
