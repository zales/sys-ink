const std = @import("std");

/// Simple task scheduler for periodic operations
pub const Scheduler = struct {
    tasks: std.array_list.Managed(Task),
    io: std.Io,

    const Task = struct {
        name: []const u8,
        interval_seconds: u64,
        last_run: i64,
        func: *const fn () void,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Scheduler {
        return .{
            .tasks = std.array_list.Managed(Task).init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.tasks.deinit();
    }

    /// Schedule a task to run every N seconds
    pub fn every(self: *Scheduler, seconds: u64, name: []const u8, func: *const fn () void) !void {
        try self.tasks.append(.{
            .name = name,
            .interval_seconds = seconds,
            .last_run = 0, // Will run immediately on first runPending
            .func = func,
        });
    }

    /// Run all tasks immediately (for initial setup)
    pub fn runAll(self: *Scheduler) void {
        const now: i64 = std.Io.Timestamp.now(self.io, .real).toSeconds();
        for (self.tasks.items) |*task| {
            task.func();
            task.last_run = now;
        }
    }

    /// Run pending tasks that are due
    pub fn runPending(self: *Scheduler) void {
        const now: i64 = std.Io.Timestamp.now(self.io, .real).toSeconds();

        for (self.tasks.items) |*task| {
            const elapsed: i64 = now - task.last_run;
            if (elapsed >= @as(i64, @intCast(task.interval_seconds))) {
                task.func();
                task.last_run = now;
            }
        }
    }

    /// Get seconds until next task is due (for sleep optimization)
    pub fn idleSeconds(self: *Scheduler) ?i64 {
        const now: i64 = std.Io.Timestamp.now(self.io, .real).toSeconds();
        var min_wait: ?i64 = null;

        for (self.tasks.items) |task| {
            const elapsed = now - task.last_run;
            const wait = @as(i64, @intCast(task.interval_seconds)) - elapsed;

            if (min_wait == null or wait < min_wait.?) {
                min_wait = wait;
            }
        }

        return if (min_wait) |w| @max(0, w) else null;
    }

    /// Clear all scheduled tasks
    pub fn clear(self: *Scheduler) void {
        self.tasks.clearRetainingCapacity();
    }
};
