const std = @import("std");
const config = @import("config.zig");

var log_file: ?std.fs.File = null;
var mutex = std.Thread.Mutex{};

pub fn init() !void {
    if (config.Config.log_to_file) {
        const path = config.Config.log_file_path;
        // Ensure directory exists? For now assume user provides valid path or we fail.
        // We use openFileAbsolute with mode .read_write and .create if not exists.
        // Actually createFileAbsolute is easier, but we want to append.

        log_file = std.fs.createFileAbsolute(path, .{ .truncate = false, .read = false }) catch |err| {
            std.debug.print("Failed to open log file '{s}': {}\n", .{ path, err });
            return err;
        };
        try log_file.?.seekFromEnd(0);
    }
}

pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Filter logs by runtime-configured level
    if (@intFromEnum(level) > @intFromEnum(config.Config.log_level_std)) return;

    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

    // Colors for console
    const color = switch (level) {
        .err => "\x1b[31m", // Red
        .warn => "\x1b[33m", // Yellow
        .info => "\x1b[32m", // Green
        .debug => "\x1b[34m", // Blue
    };
    const reset = "\x1b[0m";
    const gray = "\x1b[90m";

    mutex.lock();
    defer mutex.unlock();

    // Get timestamp
    const now_sec = std.time.timestamp();
    const epoch_seconds = @as(u64, @intCast(now_sec));
    const day_seconds = epoch_seconds % 86400;
    const hours = day_seconds / 3600;
    const minutes = (day_seconds % 3600) / 60;
    const seconds = day_seconds % 60;

    // Format: [HH:MM:SS][LEVEL][Scope] Message

    nosuspend {
        std.debug.print("{s}[{d:0>2}:{d:0>2}:{d:0>2}]{s} [{s}{s}{s}] {s}", .{
            gray,  hours,           minutes, seconds,                                               reset,
            color, @tagName(level), reset,   if (scope_prefix.len > 0) scope_prefix ++ " " else "",
        });
        std.debug.print(format ++ "\n", args);
    }

    if (log_file) |f| {
        const writer = std.io.GenericWriter(std.fs.File, std.fs.File.WriteError, std.fs.File.write){ .context = f };
        nosuspend {
            // No colors in file
            writer.print("[{d:0>2}:{d:0>2}:{d:0>2}] [{s}] {s}", .{
                hours,           minutes,                                               seconds,
                @tagName(level), if (scope_prefix.len > 0) scope_prefix ++ " " else "",
            }) catch {};
            writer.print(format ++ "\n", args) catch {};
        }
    }
}
