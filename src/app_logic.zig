//! The decisions the main loop makes, apart from the I/O that carries them out.
//!
//! `main.zig` reads the sensors, draws, and talks to the panel and the broker.
//! What it does when — whether this update is a full refresh, which fault has
//! just appeared, when a notice comes down, what goes to the broker — is
//! decided here, against a time and readings passed in. Each rule can then be
//! tested with no panel, no clock and no network.

const std = @import("std");
const api = @import("api.zig");
const parse = @import("parse.zig");
const Refresh = @import("panel.zig").Refresh;

/// Whether the status bar warns of a hardware fault, given what each source
/// was last seen to say.
///
/// The OR of them, so one clearing while another is still active cannot
/// blank the warning. Each counts as it was last seen, stale or not: failing
/// to read a sensor is no evidence that the fault it reported has cleared. A
/// source never read, or absent from this hardware, raises nothing.
///
/// What is passed in is what the readings hold. Nothing here keeps a copy: the
/// warning on the panel and the faults in `/api/status` come from the one
/// place, and cannot come to disagree.
pub fn faultWarning(undervoltage: ?bool, nvme_faulted: ?bool) bool {
    return (undervoltage orelse false) or (nvme_faulted orelse false);
}

/// Tells a fault appearing or going from one that is merely still there, so
/// that each is logged once rather than every cycle.
///
/// It remembers what it last announced and nothing else. Whether there is a
/// fault is not asked of this: see `faultWarning`.
pub const FaultLog = struct {
    undervoltage: ?bool = null,
    nvme: ?bool = null,

    pub const Source = enum { undervoltage, nvme };
    pub const Change = enum { none, raised, cleared };

    /// What `source` saying `seen` changes since it was last heard from. Null
    /// is a source with nothing to say, which changes nothing.
    pub fn note(self: *FaultLog, source: Source, seen: ?bool) Change {
        const active = seen orelse return .none;
        const announced = switch (source) {
            .undervoltage => &self.undervoltage,
            .nvme => &self.nvme,
        };

        const previous = announced.*;
        announced.* = active;

        if (previous == active) return .none;
        if (active) return .raised;
        // The first word from a source being a healthy one clears nothing.
        return if (previous == null) .none else .cleared;
    }
};

/// Which updates of the panel are full refreshes.
///
/// A full refresh clears the ghosting that partial updates leave behind.
/// Driven by elapsed time, so it does not depend on how often the display is
/// updated.
pub const RefreshClock = struct {
    /// Seconds between full refreshes.
    interval: i64,
    /// Monotonic timestamp of the last one.
    last_full: i64 = 0,
    /// Makes the next update a full refresh, whatever the timer says.
    forced: bool = false,

    /// How the update at `now` goes up. A full refresh is counted as taken.
    pub fn next(self: *RefreshClock, now: i64) Refresh {
        if (!self.forced and now - self.last_full < self.interval) return .partial;

        self.tookFull(now);
        return .full;
    }

    /// Record a full refresh made outside `next`, as the first frame is.
    pub fn tookFull(self: *RefreshClock, now: i64) void {
        self.last_full = now;
        self.forced = false;
    }

    pub fn force(self: *RefreshClock) void {
        self.forced = true;
    }
};

/// How long the notice on show stays up.
pub const NoticeClock = struct {
    /// Monotonic timestamp at which the notice on show is taken down, if one is.
    until: ?i64 = null,

    /// A notice went up at `now`, for `duration` seconds. One already up is
    /// replaced, and its time with it.
    pub fn show(self: *NoticeClock, now: i64, duration: u32) void {
        self.until = now + @as(i64, duration);
    }

    /// Take the notice on show down early. False when there was none.
    pub fn dismiss(self: *NoticeClock) bool {
        if (self.until == null) return false;
        self.until = null;
        return true;
    }

    /// True once, when the notice's time is up at `now`.
    pub fn expired(self: *NoticeClock, now: i64) bool {
        const until = self.until orelse return false;
        if (now < until) return false;
        self.until = null;
        return true;
    }

    /// Seconds until the notice comes down, for the main loop to wake on time.
    pub fn secondsLeft(self: NoticeClock, now: i64) ?i64 {
        const until = self.until orelse return null;
        return @max(0, until - now);
    }
};

/// A rate in whole bytes per second, as `/api/status` reports it.
pub fn wholeBytesPerSecond(rate: f64) u64 {
    return std.math.lossyCast(u64, @round(rate));
}

/// One state update for the broker: the topic under the prefix, and what is
/// published to it.
pub const Reading = struct {
    topic: []const u8,
    payload: []const u8,
};

/// One cycle's state updates.
///
/// Each payload is kept in here beside its length, not as a slice into this:
/// a copy of the whole is then as good as the original, where one holding
/// slices would have pointed back into the storage it was copied from.
pub const Readings = struct {
    topics: [capacity][]const u8 = undefined,
    payloads: [capacity][payload_max]u8 = undefined,
    payload_lens: [capacity]u8 = undefined,
    len: usize = 0,

    /// As many as there are entities, with room to spare.
    pub const capacity = 24;
    /// The longest payload is an IPv4 address or a rate.
    const payload_max = 32;

    /// The update at `index`. Its payload is borrowed from this.
    pub fn at(self: *const Readings, index: usize) Reading {
        std.debug.assert(index < self.len);
        return .{ .topic = self.topics[index], .payload = self.payloads[index][0..self.payload_lens[index]] };
    }

    /// What was published to `topic`, if anything was.
    pub fn payloadOf(self: *const Readings, topic: []const u8) ?[]const u8 {
        for (0..self.len) |index| {
            if (std.mem.eql(u8, self.topics[index], topic)) return self.at(index).payload;
        }
        return null;
    }

    fn add(self: *Readings, comptime topic: []const u8, comptime fmt: []const u8, args: anytype) void {
        std.debug.assert(self.len < capacity);
        const payload = std.mem.print(&self.payloads[self.len], fmt, args) catch return;
        self.topics[self.len] = topic;
        self.payload_lens[self.len] = @intCast(payload.len);
        self.len += 1;
    }

    fn addBinary(self: *Readings, comptime topic: []const u8, on: bool) void {
        self.add(topic, "{s}", .{if (on) "ON" else "OFF"});
    }
};

/// The state updates one cycle's readings amount to, in the order they are
/// published.
///
/// Only what is current goes out. A reading whose latest attempt failed, or
/// that there is no sensor for, publishes nothing rather than its last value
/// or a zero. Sending the last value on every cycle is what kept Home
/// Assistant showing a disk temperature hours old as live: the entity's
/// `expire_after` counts from the last message, and they never stopped.
/// Withheld, it expires and the entity reads unavailable.
///
/// The rates come separately, unrounded and already null unless current:
/// `status` carries them in whole bytes, and the broker gets kB/s to two
/// decimals.
pub fn mqttReadings(status: api.Status, rates: ?parse.NetRates) Readings {
    var out: Readings = .{};

    if (current(status, "cpu_load")) |load| out.add("cpu_load", "{d}", .{load});
    if (current(status, "cpu_temp")) |temp| out.add("cpu_temp", "{d}", .{temp});
    if (current(status, "memory")) |mem| out.add("memory", "{d}", .{mem});
    if (current(status, "disk_usage")) |usage| out.add("disk_usage", "{d}", .{usage});
    if (current(status, "disk_temp")) |temp| out.add("disk_temp", "{d}", .{temp});
    if (current(status, "fan_speed")) |rpm| out.add("fan_speed", "{d}", .{rpm});
    if (current(status, "undervoltage")) |active| out.addBinary("undervoltage", active);
    if (current(status, "nvme_fault")) |faulted| out.addBinary("nvme_fault", faulted);
    if (current(status, "ssd_wear")) |wear| out.add("ssd_wear", "{d}", .{wear});
    // Withheld until a check has actually run, so Home Assistant is not told
    // "0 updates" on the basis of no data.
    if (current(status, "apt_updates")) |count| out.add("apt_updates", "{d}", .{count});
    if (current(status, "uptime_minutes")) |minutes| out.add("uptime_days", "{d}", .{minutes / (24 * 60)});
    if (current(status, "signal_strength")) |signal| out.add("signal_strength", "{d}", .{signal});
    if (current(status, "internet")) |connected| out.addBinary("internet", connected);
    if (current(status, "ip_address")) |ip| out.add("ip_address", "{s}", .{ip});

    // kB/s, decimal, matching both the entity's declared unit and what the
    // panel shows. This divided by 1024 while calling the result kB/s, which
    // disagreed with the display by 2.4%.
    if (rates) |r| {
        out.add("traffic_down", "{d:.2}", .{r.rx_bytes_per_sec / 1000.0});
        out.add("traffic_up", "{d:.2}", .{r.tx_bytes_per_sec / 1000.0});
    }

    return out;
}

/// The reading `name` of `status` while it is current: there, and not listed
/// as stale.
///
/// By the one name, for the value and for its place under `stale`, so that
/// one reading cannot be checked against another's. A reading with no place
/// there is never kept past a failed attempt, and is current whenever it is
/// there at all; `api.zig` makes every reading be one or the other.
fn current(status: api.Status, comptime name: []const u8) @TypeOf(@field(status, name)) {
    if (@hasField(api.Stale, name) and @field(status.stale, name) != null) return null;
    return @field(status, name);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const mqtt = @import("mqtt.zig");

test "a fault is announced when it appears and when it goes, not in between" {
    var log: FaultLog = .{};

    try testing.expectEqual(FaultLog.Change.raised, log.note(.undervoltage, true));
    try testing.expectEqual(FaultLog.Change.none, log.note(.undervoltage, true));
    try testing.expectEqual(FaultLog.Change.none, log.note(.undervoltage, true));

    try testing.expectEqual(FaultLog.Change.cleared, log.note(.undervoltage, false));
    try testing.expectEqual(FaultLog.Change.none, log.note(.undervoltage, false));
}

test "a first healthy word from a source is not a fault clearing" {
    var log: FaultLog = .{};
    try testing.expectEqual(FaultLog.Change.none, log.note(.nvme, false));
    // And the fault that follows is still announced.
    try testing.expectEqual(FaultLog.Change.raised, log.note(.nvme, true));
}

test "each source is announced on its own" {
    var log: FaultLog = .{};
    try testing.expectEqual(FaultLog.Change.raised, log.note(.undervoltage, true));
    try testing.expectEqual(FaultLog.Change.raised, log.note(.nvme, true));

    // The supply recovers; the drive has not, and says nothing new.
    try testing.expectEqual(FaultLog.Change.cleared, log.note(.undervoltage, false));
    try testing.expectEqual(FaultLog.Change.none, log.note(.nvme, true));
    try testing.expectEqual(FaultLog.Change.cleared, log.note(.nvme, false));
}

test "a source with nothing to say changes nothing" {
    var log: FaultLog = .{};

    // No sensor on this hardware.
    try testing.expectEqual(FaultLog.Change.none, log.note(.undervoltage, null));

    // A fault that is up and then cannot be read is neither raised again nor
    // cleared, and is not announced a second time when it can be read.
    _ = log.note(.nvme, true);
    try testing.expectEqual(FaultLog.Change.none, log.note(.nvme, null));
    try testing.expectEqual(FaultLog.Change.none, log.note(.nvme, true));
}

test "the warning shows while any source was last seen faulted" {
    try testing.expect(!faultWarning(null, null));
    try testing.expect(!faultWarning(false, false));
    try testing.expect(!faultWarning(false, null));

    try testing.expect(faultWarning(true, null));
    try testing.expect(faultWarning(null, true));
    // One clearing does not blank it while the other is still up.
    try testing.expect(faultWarning(false, true));
    try testing.expect(faultWarning(true, false));
}

test "the panel is refreshed in full once per interval, and partially between" {
    var clock: RefreshClock = .{ .interval = 600 };
    clock.tookFull(1000);

    try testing.expectEqual(Refresh.partial, clock.next(1010));
    try testing.expectEqual(Refresh.partial, clock.next(1599));
    try testing.expectEqual(Refresh.full, clock.next(1600));

    // Counted from that one, not from the one before.
    try testing.expectEqual(Refresh.partial, clock.next(1610));
    try testing.expectEqual(Refresh.partial, clock.next(2199));
    try testing.expectEqual(Refresh.full, clock.next(2200));
}

test "a forced full refresh happens once and restarts the interval" {
    var clock: RefreshClock = .{ .interval = 600 };
    clock.tookFull(1000);

    clock.force();
    try testing.expectEqual(Refresh.full, clock.next(1010));
    try testing.expectEqual(Refresh.partial, clock.next(1020));
    try testing.expectEqual(Refresh.partial, clock.next(1609));
    try testing.expectEqual(Refresh.full, clock.next(1610));
}

test "a full refresh made elsewhere drops a pending forced one" {
    var clock: RefreshClock = .{ .interval = 600 };
    clock.force();
    clock.tookFull(50);
    try testing.expectEqual(Refresh.partial, clock.next(60));
}

test "a notice stays up for its duration and comes down once" {
    var notice: NoticeClock = .{};
    try testing.expect(notice.secondsLeft(100) == null);
    try testing.expect(!notice.expired(100));

    notice.show(100, 30);
    try testing.expectEqual(@as(?i64, 30), notice.secondsLeft(100));
    try testing.expectEqual(@as(?i64, 1), notice.secondsLeft(129));
    try testing.expect(!notice.expired(129));

    try testing.expect(notice.expired(130));
    // Down already: there is nothing to take down a second time.
    try testing.expect(!notice.expired(131));
    try testing.expect(notice.secondsLeft(131) == null);
}

test "a newer notice replaces the older one's time" {
    var notice: NoticeClock = .{};
    notice.show(100, 30);
    notice.show(120, 60);

    try testing.expect(!notice.expired(130));
    try testing.expectEqual(@as(?i64, 50), notice.secondsLeft(130));
    try testing.expect(notice.expired(180));
}

test "the main loop is never told to wait a negative time for a notice" {
    var notice: NoticeClock = .{};
    notice.show(100, 30);
    // Woken late: the notice is overdue, not due in minus five seconds.
    try testing.expectEqual(@as(?i64, 0), notice.secondsLeft(135));
}

test "dismissing takes a notice down early, and only if there is one" {
    var notice: NoticeClock = .{};
    try testing.expect(!notice.dismiss());

    notice.show(100, 30);
    try testing.expect(notice.dismiss());
    try testing.expect(!notice.dismiss());
    try testing.expect(!notice.expired(200));
}

test "a rate is reported in whole bytes, whatever the float holds" {
    try testing.expectEqual(@as(u64, 0), wholeBytesPerSecond(0));
    try testing.expectEqual(@as(u64, 1235), wholeBytesPerSecond(1234.5));
    try testing.expectEqual(@as(u64, 0), wholeBytesPerSecond(-3.0));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), wholeBytesPerSecond(1e30));
    try testing.expectEqual(@as(u64, 0), wholeBytesPerSecond(std.math.nan(f64)));
}

const full_status: api.Status = .{
    .cpu_load = 12,
    .cpu_temp = 48,
    .memory = 31,
    .disk_usage = 67,
    .disk_temp = 36,
    .fan_speed = 2100,
    .uptime_minutes = 3 * 1440 + 125,
    .ip_address = "192.168.1.20",
    .wired = true,
    .signal_strength = -52,
    .internet = true,
    .download_bytes_per_second = 1_250_000,
    .upload_bytes_per_second = 0,
    .apt_updates = 3,
    .undervoltage = false,
    .nvme_fault = true,
    .ssd_wear = 3,
};

const no_traffic: parse.NetRates = .{ .rx_bytes_per_sec = 0, .tx_bytes_per_sec = 0 };

test "every reading is published the way its entity expects it" {
    const readings = mqttReadings(full_status, .{ .rx_bytes_per_sec = 1_250_000.0, .tx_bytes_per_sec = 4_567.0 });

    try testing.expectEqualStrings("12", readings.payloadOf("cpu_load").?);
    try testing.expectEqualStrings("36", readings.payloadOf("disk_temp").?);
    try testing.expectEqualStrings("-52", readings.payloadOf("signal_strength").?);
    try testing.expectEqualStrings("192.168.1.20", readings.payloadOf("ip_address").?);
    try testing.expectEqualStrings("3", readings.payloadOf("uptime_days").?);
    try testing.expectEqualStrings("ON", readings.payloadOf("internet").?);
    try testing.expectEqualStrings("OFF", readings.payloadOf("undervoltage").?);
    try testing.expectEqualStrings("ON", readings.payloadOf("nvme_fault").?);
    // Decimal kB/s, as the entity's unit says.
    try testing.expectEqualStrings("1250.00", readings.payloadOf("traffic_down").?);
    try testing.expectEqualStrings("4.57", readings.payloadOf("traffic_up").?);
}

test "with every sensor present, each entity gets a reading and nothing else does" {
    // A topic nobody subscribed to and an entity that never updates are the
    // same mistake seen from either end: the two lists drifting apart.
    const readings = mqttReadings(full_status, no_traffic);

    try testing.expectEqual(mqtt.sensors.len, readings.len);
    for (mqtt.sensors) |sensor| {
        if (readings.payloadOf(sensor.id) == null) {
            std.debug.print("\n  no reading published for entity '{s}'\n", .{sensor.id});
            return error.EntityWithoutReading;
        }
    }
}

test "a reading that is not known publishes nothing rather than zero" {
    // A machine none of whose sensors answered: not a load of 0%, a
    // temperature of 0 °C and no traffic.
    const nothing: api.Status = .{
        .cpu_load = null,
        .cpu_temp = null,
        .memory = null,
        .disk_usage = null,
        .disk_temp = null,
        .fan_speed = null,
        .uptime_minutes = null,
        .ip_address = null,
        .wired = false,
        .signal_strength = null,
        .internet = null,
        .download_bytes_per_second = null,
        .upload_bytes_per_second = null,
        .apt_updates = null,
        .undervoltage = null,
        .nvme_fault = null,
        .ssd_wear = null,
    };

    try testing.expectEqual(@as(usize, 0), mqttReadings(nothing, null).len);
}

test "a stale reading is withheld, so that its entity expires" {
    // The regression: the disk temperature's sensor stopped answering, and
    // its last value went on being published as if just measured.
    var status = full_status;
    status.stale = .{ .disk_temp = 95, .apt_updates = 21_600, .nvme_fault = 30, .ssd_wear = 30 };

    const readings = mqttReadings(status, null);

    for ([_][]const u8{ "disk_temp", "apt_updates", "nvme_fault", "ssd_wear", "traffic_down", "traffic_up" }) |topic| {
        try testing.expect(readings.payloadOf(topic) == null);
    }
    // Its neighbours are as current as they were.
    try testing.expectEqualStrings("12", readings.payloadOf("cpu_load").?);
    try testing.expectEqualStrings("2100", readings.payloadOf("fan_speed").?);
    try testing.expectEqualStrings("OFF", readings.payloadOf("undervoltage").?);
    try testing.expectEqual(mqtt.sensors.len - 6, readings.len);
}

test "every reading that can go stale is withheld when it has" {
    // Whatever `Stale` has a place for, one at a time: each must cost the
    // broker something, or a stale value is going out as current.
    const fresh = mqttReadings(full_status, null);
    inline for (@typeInfo(api.Stale).@"struct".field_names) |name| {
        var status = full_status;
        @field(status.stale, name) = 60;
        const readings = mqttReadings(status, null);
        // The two rates are not published from `status` at all.
        const published_from_status = comptime !std.mem.endsWith(u8, name, "bytes_per_second");
        if (published_from_status) try testing.expectEqual(fresh.len - 1, readings.len);
    }
}

test "a copy of one cycle's updates stands on its own" {
    var original = mqttReadings(full_status, no_traffic);
    const copy = original;

    // The original is written over, as the next cycle would.
    original = mqttReadings(full_status, .{ .rx_bytes_per_sec = 9_000_000, .tx_bytes_per_sec = 9_000_000 });
    @memset(std.mem.asBytes(&original.payloads), 'x');

    try testing.expectEqualStrings("12", copy.payloadOf("cpu_load").?);
    try testing.expectEqualStrings("0.00", copy.payloadOf("traffic_down").?);
    try testing.expectEqualStrings("192.168.1.20", copy.at(copy.len - 3).payload);
}
