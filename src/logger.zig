const std = @import("std");
const config = @import("config.zig");

var log_file: ?std.Io.File = null;
var mutex: std.Io.Mutex = .init;
var app_io: std.Io = undefined;

pub fn init(io: std.Io) !void {
    app_io = io;
    if (config.Config.log_to_file) {
        const path = config.Config.log_file_path;

        log_file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = false }) catch |err| {
            std.debug.print("Failed to open log file '{s}': {}\n", .{ path, err });
            return err;
        };
    }
}

pub fn deinit() void {
    const io = app_io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (log_file) |f| {
        f.close(io);
        log_file = null;
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(config.Config.log_level_std)) return;

    const io = std.Options.debug_io;
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

    const color = switch (level) {
        .err => "\x1b[31m", // Red
        .warn => "\x1b[33m", // Yellow
        .info => "\x1b[32m", // Green
        .debug => "\x1b[34m", // Blue
    };
    const reset = "\x1b[0m";
    const gray = "\x1b[90m";

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const epoch_seconds = @as(u64, @intCast(std.Io.Timestamp.now(io, .real).toSeconds()));
    const day_seconds = epoch_seconds % 86400;
    const hours = day_seconds / 3600;
    const minutes = (day_seconds % 3600) / 60;
    const seconds = day_seconds % 60;

    nosuspend {
        std.debug.print("{s}[{d:0>2}:{d:0>2}:{d:0>2}]{s} [{s}{s}{s}] {s}", .{
            gray,  hours,           minutes, seconds,                                               reset,
            color, @tagName(level), reset,   if (scope_prefix.len > 0) scope_prefix ++ " " else "",
        });
        std.debug.print(format ++ "\n", args);
    }

    if (log_file) |f| {
        var buffer: [4096]u8 = undefined;
        var writer = f.writer(io, &buffer);
        const end_pos = f.length(io) catch 0;
        writer.seekToUnbuffered(end_pos) catch {};

        nosuspend {
            writer.interface.print("[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] {s}", .{
                hours,           minutes,                                               seconds,
                @tagName(level), if (scope_prefix.len > 0) scope_prefix ++ " " else "",
            }) catch {};
            writer.interface.print(format ++ "\n", args) catch {};
            writer.flush() catch {};
        }
    }
}
