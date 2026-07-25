const std = @import("std");

/// Simple task scheduler for periodic operations.
///
/// Timing runs off the monotonic clock, so NTP steps and manual clock changes
/// cannot stall or stampede the schedule.
pub const Scheduler = struct {
    tasks: std.array_list.Managed(Task),
    io: std.Io,

    /// Type-erased task callback. Use `every` rather than building these by hand.
    pub const Callback = *const fn (*anyopaque) void;

    pub const Task = struct {
        name: []const u8,
        interval_seconds: u64,
        /// Monotonic timestamp, in seconds, at which this task is next due.
        next_run: i64,
        ctx: *anyopaque,
        func: Callback,
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

    fn nowSeconds(self: *Scheduler) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toSeconds();
    }

    /// Schedule `func` to run every `seconds`, starting immediately.
    ///
    /// `ctx` is a pointer to the callback's own state, which keeps task state out
    /// of globals. `func` is bound at comptime so the call stays direct.
    pub fn every(
        self: *Scheduler,
        seconds: u64,
        name: []const u8,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx)) void,
    ) !void {
        const Ctx = @TypeOf(ctx);
        comptime std.debug.assert(@typeInfo(Ctx) == .pointer);

        const wrapper = struct {
            fn call(erased: *anyopaque) void {
                func(@ptrCast(@alignCast(erased)));
            }
        }.call;

        try self.tasks.append(.{
            .name = name,
            .interval_seconds = @max(1, seconds),
            .next_run = self.nowSeconds(),
            .ctx = ctx,
            .func = wrapper,
        });
    }

    /// Run every task regardless of whether it is due, and reschedule from now.
    pub fn runAll(self: *Scheduler) void {
        const now = self.nowSeconds();
        for (self.tasks.items) |*task| {
            task.func(task.ctx);
            task.next_run = now + @as(i64, @intCast(task.interval_seconds));
        }
    }

    /// Run whichever tasks are due.
    pub fn runPending(self: *Scheduler) void {
        self.runPendingAt(self.nowSeconds());
    }

    /// Seconds until the next task is due, or null when nothing is scheduled.
    pub fn idleSeconds(self: *Scheduler) ?i64 {
        return self.idleSecondsAt(self.nowSeconds());
    }

    /// `runPending` against an explicit timestamp. Separated out so the schedule
    /// logic is testable without a clock.
    pub fn runPendingAt(self: *Scheduler, now: i64) void {
        for (self.tasks.items) |*task| {
            if (now < task.next_run) continue;

            task.func(task.ctx);

            const interval = @as(i64, @intCast(task.interval_seconds));
            task.next_run = now + interval;
        }
    }

    /// `idleSeconds` against an explicit timestamp.
    pub fn idleSecondsAt(self: *Scheduler, now: i64) ?i64 {
        var min_wait: ?i64 = null;

        for (self.tasks.items) |task| {
            const wait = @max(0, task.next_run - now);
            if (min_wait == null or wait < min_wait.?) min_wait = wait;
        }

        return min_wait;
    }

    /// Clear all scheduled tasks.
    pub fn clear(self: *Scheduler) void {
        self.tasks.clearRetainingCapacity();
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

const Counter = struct {
    hits: u32 = 0,
    fn bump(self: *Counter) void {
        self.hits += 1;
    }
};

/// Builds a scheduler with no usable `io`; every test drives it through the
/// explicit-timestamp entry points instead of the clock.
fn testScheduler(tasks: []const Scheduler.Task) Scheduler {
    var s = Scheduler.init(testing.allocator, undefined);
    s.tasks.appendSlice(tasks) catch unreachable;
    return s;
}

fn makeTask(name: []const u8, interval: u64, next_run: i64, ctx: *Counter) Scheduler.Task {
    return .{
        .name = name,
        .interval_seconds = interval,
        .next_run = next_run,
        .ctx = ctx,
        .func = struct {
            fn call(erased: *anyopaque) void {
                Counter.bump(@ptrCast(@alignCast(erased)));
            }
        }.call,
    };
}

test "runPendingAt only runs tasks that are due" {
    var due = Counter{};
    var not_due = Counter{};

    var s = testScheduler(&.{
        makeTask("due", 10, 100, &due),
        makeTask("not_due", 10, 200, &not_due),
    });
    defer s.deinit();

    s.runPendingAt(100);
    try testing.expectEqual(@as(u32, 1), due.hits);
    try testing.expectEqual(@as(u32, 0), not_due.hits);
}

test "runPendingAt reschedules a full interval ahead" {
    var counter = Counter{};
    var s = testScheduler(&.{makeTask("t", 30, 0, &counter)});
    defer s.deinit();

    s.runPendingAt(0);
    try testing.expectEqual(@as(i64, 30), s.tasks.items[0].next_run);

    // Not due yet.
    s.runPendingAt(29);
    try testing.expectEqual(@as(u32, 1), counter.hits);

    s.runPendingAt(30);
    try testing.expectEqual(@as(u32, 2), counter.hits);
    try testing.expectEqual(@as(i64, 60), s.tasks.items[0].next_run);
}

test "a long stall runs a task once, not once per missed interval" {
    var counter = Counter{};
    var s = testScheduler(&.{makeTask("t", 10, 0, &counter)});
    defer s.deinit();

    // Woke up 500s late; the task should fire a single time and resync.
    s.runPendingAt(500);
    try testing.expectEqual(@as(u32, 1), counter.hits);
    try testing.expectEqual(@as(i64, 510), s.tasks.items[0].next_run);
}

test "idleSecondsAt reports the soonest task" {
    var a = Counter{};
    var b = Counter{};

    var s = testScheduler(&.{
        makeTask("far", 100, 500, &a),
        makeTask("near", 10, 130, &b),
    });
    defer s.deinit();

    try testing.expectEqual(@as(?i64, 30), s.idleSecondsAt(100));
}

test "idleSecondsAt never goes negative" {
    var counter = Counter{};
    var s = testScheduler(&.{makeTask("overdue", 10, 50, &counter)});
    defer s.deinit();

    try testing.expectEqual(@as(?i64, 0), s.idleSecondsAt(999));
}

test "idleSecondsAt returns null with no tasks" {
    var s = testScheduler(&.{});
    defer s.deinit();

    try testing.expectEqual(@as(?i64, null), s.idleSecondsAt(0));
}

test "clear removes every task" {
    var counter = Counter{};
    var s = testScheduler(&.{makeTask("t", 10, 0, &counter)});
    defer s.deinit();

    s.clear();
    s.runPendingAt(1000);
    try testing.expectEqual(@as(u32, 0), counter.hits);
    try testing.expectEqual(@as(?i64, null), s.idleSecondsAt(0));
}
