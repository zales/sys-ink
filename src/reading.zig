//! A reading that knows how its latest measurement went.
//!
//! Everything the daemon measures is kept for the panel, the API and MQTT to
//! report from. Kept as a bare value, a reading nobody had managed to take for
//! an hour looked exactly like one taken a moment ago: a disk temperature whose
//! sensor stopped answering stayed on the panel and went out over MQTT every
//! cycle — and since the messages kept coming, Home Assistant's `expire_after`
//! never noticed either.
//!
//! So a reading is in one of three states:
//!
//!   current      the latest attempt measured it
//!   stale        the latest attempt failed; the value is an earlier one's
//!   unavailable  there is no value: nothing to measure, or nothing measured yet
//!
//! Keeping the last value through a failed attempt is deliberate. One read
//! that fails should not blank a slot, and the last known state of a fault is
//! worth more than none. What changes is that everyone downstream can tell:
//! the panel draws a stale value faded, the API reports its age, and MQTT
//! withholds it so the entity expires.

const std = @import("std");

pub const State = enum { current, stale, unavailable };

pub fn Reading(comptime T: type) type {
    return struct {
        /// The last value measured. Outlives a failed attempt, which is what
        /// makes it stale.
        value: ?T = null,
        /// Monotonic seconds at which `value` was measured.
        taken_at: i64 = 0,
        /// Whether the latest attempt is the one that produced `value`.
        fresh: bool = false,

        const Self = @This();

        /// A current reading of `value` with no time attached, for whoever
        /// has no clock: the tests and the simulators.
        pub fn of(value: T) Self {
            return .{ .value = value, .fresh = true };
        }

        /// The attempt at `now` measured `value`.
        pub fn set(self: *Self, value: T, now: i64) void {
            self.* = .{ .value = value, .taken_at = now, .fresh = true };
        }

        /// The attempt failed. Whatever was measured before is kept, as stale.
        pub fn fail(self: *Self) void {
            self.fresh = false;
        }

        /// There is nothing to measure: no such sensor, or it has gone.
        pub fn clear(self: *Self) void {
            self.* = .{};
        }

        /// Record what an attempt came to, and hand it back. A value makes the
        /// reading current and an error makes it stale; where the attempt
        /// answers with an optional, null makes it unavailable.
        pub fn record(self: *Self, result: anytype, now: i64) @TypeOf(result) {
            if (result) |value| {
                if (@TypeOf(value) == ?T) {
                    if (value) |measured| self.set(measured, now) else self.clear();
                } else {
                    self.set(value, now);
                }
            } else |_| self.fail();
            return result;
        }

        pub fn state(self: Self) State {
            if (self.value == null) return .unavailable;
            return if (self.fresh) .current else .stale;
        }

        pub fn isStale(self: Self) bool {
            return self.state() == .stale;
        }

        /// The value while it is current, for a consumer that must not pass
        /// an old one off as new.
        pub fn current(self: Self) ?T {
            return if (self.fresh) self.value else null;
        }

        /// How many seconds ago a stale value was measured; null for a
        /// reading that is not stale.
        pub fn staleFor(self: Self, now: i64) ?u64 {
            if (!self.isStale()) return null;
            return @intCast(@max(0, now - self.taken_at));
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "a reading is unavailable until something is measured" {
    const r: Reading(u32) = .{};
    try testing.expectEqual(State.unavailable, r.state());
    try testing.expectEqual(@as(?u32, null), r.current());
    try testing.expectEqual(@as(?u64, null), r.staleFor(100));
}

test "a failed attempt keeps the value but stops calling it current" {
    var r: Reading(u32) = .{};
    r.set(41, 100);
    try testing.expectEqual(State.current, r.state());
    try testing.expectEqual(@as(?u32, 41), r.current());
    try testing.expectEqual(@as(?u64, null), r.staleFor(130));

    r.fail();
    try testing.expectEqual(State.stale, r.state());
    try testing.expectEqual(@as(?u32, 41), r.value);
    // The regression: this is what MQTT publishes from.
    try testing.expectEqual(@as(?u32, null), r.current());
    try testing.expectEqual(@as(?u64, 30), r.staleFor(130));

    // And the next good one makes it current again, with its own time.
    r.set(42, 160);
    try testing.expectEqual(State.current, r.state());
    try testing.expectEqual(@as(?u64, null), r.staleFor(200));
}

test "failing with nothing measured is unavailable, not stale" {
    var r: Reading(u32) = .{};
    r.fail();
    try testing.expectEqual(State.unavailable, r.state());
    try testing.expectEqual(@as(?u64, null), r.staleFor(100));
}

test "clearing forgets the value" {
    var r: Reading(bool) = .of(true);
    r.clear();
    try testing.expectEqual(State.unavailable, r.state());
    try testing.expectEqual(@as(?bool, null), r.value);
}

test "record follows the attempt's result and passes it through" {
    const Failing = error{Unreadable};
    var r: Reading(u32) = .{};

    try testing.expectEqual(@as(u32, 7), try r.record(@as(Failing!u32, 7), 10));
    try testing.expectEqual(State.current, r.state());

    try testing.expectError(error.Unreadable, r.record(@as(Failing!u32, error.Unreadable), 20));
    try testing.expectEqual(State.stale, r.state());
    try testing.expectEqual(@as(?u64, 15), r.staleFor(25));

    // An attempt that answers "no such sensor" leaves nothing behind.
    try testing.expectEqual(@as(?u32, null), try r.record(@as(Failing!?u32, null), 30));
    try testing.expectEqual(State.unavailable, r.state());

    try testing.expectEqual(@as(?u32, 9), try r.record(@as(Failing!?u32, 9), 40));
    try testing.expectEqual(@as(?u32, 9), r.current());
}

test "a clock that reads earlier than the measurement gives no negative age" {
    var r: Reading(u32) = .{};
    r.set(1, 100);
    r.fail();
    try testing.expectEqual(@as(?u64, 0), r.staleFor(90));
}
