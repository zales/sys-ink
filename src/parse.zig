//! Pure parsing helpers for the procfs/sysfs and command output the daemon reads.
//!
//! Everything here is free of I/O so it can be unit tested against fixtures on
//! any host, not just the target Raspberry Pi.

const std = @import("std");

pub const CpuTimes = struct {
    user: u64,
    nice: u64,
    system: u64,
    idle: u64,
    iowait: u64,
    irq: u64,
    softirq: u64,

    pub fn total(self: CpuTimes) u64 {
        return self.user + self.nice + self.system + self.idle +
            self.iowait + self.irq + self.softirq;
    }

    pub fn idleTotal(self: CpuTimes) u64 {
        return self.idle + self.iowait;
    }
};

/// Parse the aggregate "cpu " line of /proc/stat.
pub fn cpuStat(content: []const u8) !CpuTimes {
    var lines = std.mem.splitScalar(u8, content, '\n');
    const first_line = lines.next() orelse return error.InvalidFormat;

    if (!std.mem.startsWith(u8, first_line, "cpu ")) return error.InvalidFormat;

    var parts = std.mem.tokenizeAny(u8, first_line, " ");
    _ = parts.next(); // skip "cpu"

    return .{
        .user = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
        .nice = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
        .system = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
        .idle = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
        .iowait = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
        .irq = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
        .softirq = try std.fmt.parseInt(u64, parts.next() orelse "0", 10),
    };
}

/// Busy percentage between two /proc/stat samples. Deltas saturate so a counter
/// reset can never underflow.
pub fn cpuUsagePercent(prev: CpuTimes, current: CpuTimes) u8 {
    const total = current.total() -| prev.total();
    if (total == 0) return 0;

    const idle = current.idleTotal() -| prev.idleTotal();
    const busy = total -| idle;
    return @intCast(@min(100, (100 * busy) / total));
}

/// Used-memory percentage from /proc/meminfo.
pub fn memoryUsagePercent(content: []const u8) !u8 {
    var mem_total: ?u64 = null;
    var mem_available: ?u64 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const field = if (std.mem.startsWith(u8, line, "MemTotal:"))
            &mem_total
        else if (std.mem.startsWith(u8, line, "MemAvailable:"))
            &mem_available
        else
            continue;

        var parts = std.mem.tokenizeAny(u8, line, " ");
        _ = parts.next(); // skip the label
        if (parts.next()) |val| field.* = std.fmt.parseInt(u64, val, 10) catch null;

        if (mem_total != null and mem_available != null) break;
    }

    const total = mem_total orelse return error.InvalidMeminfo;
    const available = mem_available orelse return error.InvalidMeminfo;
    if (total == 0) return error.InvalidMeminfo;

    const used = total -| available;
    return @intCast(@min(100, (100 * used) / total));
}

/// Convert a sysfs millidegree reading to whole degrees Celsius.
pub fn temperatureCelsius(content: []const u8) !u32 {
    return try unsignedInt(content) / 1000;
}

/// Parse a bare unsigned integer, ignoring surrounding whitespace.
pub fn unsignedInt(content: []const u8) !u32 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    return std.fmt.parseInt(u32, trimmed, 10);
}

pub const Uptime = struct { days: u32, hours: u32, minutes: u32 };

/// Parse /proc/uptime ("<seconds>.<frac> <idle>").
pub fn uptime(content: []const u8) !Uptime {
    var parts = std.mem.tokenizeAny(u8, content, " ");
    const uptime_str = parts.next() orelse return error.InvalidFormat;

    const dot = std.mem.find(u8, uptime_str, ".") orelse uptime_str.len;
    const seconds = try std.fmt.parseInt(u64, uptime_str[0..dot], 10);

    return .{
        .days = @intCast(seconds / 86400),
        .hours = @intCast((seconds % 86400) / 3600),
        .minutes = @intCast((seconds % 3600) / 60),
    };
}

/// Signal level in dBm for `interface` from /proc/net/wireless.
/// Returns null when the interface has no entry.
pub fn wirelessSignal(content: []const u8, interface: []const u8) ?i32 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.find(u8, line, ":") orelse continue;

        const name = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
        if (!std.mem.eql(u8, name, interface)) continue;

        // "<status> <link quality> <signal level> <noise> ..."
        var parts = std.mem.tokenizeAny(u8, line[colon + 1 ..], " ");
        _ = parts.next(); // status
        _ = parts.next(); // link quality

        const level = parts.next() orelse return null;
        // Values carry a trailing '.' to mark them as updated.
        return std.fmt.parseInt(i32, std.mem.trimEnd(u8, level, "."), 10) catch null;
    }
    return null;
}

pub const NetTotals = struct { rx_bytes: u64, tx_bytes: u64 };

/// Sum rx/tx byte counters across all non-loopback interfaces in /proc/net/dev.
pub fn netDevTotals(content: []const u8) NetTotals {
    var totals = NetTotals{ .rx_bytes = 0, .tx_bytes = 0 };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.find(u8, line, ":") orelse continue; // header lines

        const name = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
        if (std.mem.eql(u8, name, "lo")) continue;

        var parts = std.mem.tokenizeAny(u8, line[colon + 1 ..], " ");

        const rx = parts.next() orelse continue;
        totals.rx_bytes += std.fmt.parseInt(u64, rx, 10) catch 0;

        // Skip packets, errs, drop, fifo, frame, compressed, multicast.
        for (0..7) |_| _ = parts.next();

        const tx = parts.next() orelse continue;
        totals.tx_bytes += std.fmt.parseInt(u64, tx, 10) catch 0;
    }

    return totals;
}

/// Count upgradable packages in `apt list --upgradable` output.
pub fn aptUpgradableCount(stdout: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "Listing")) continue;
        count += 1;
    }
    return count;
}

pub const Scaled = struct { value: f64, unit: []const u8 };

/// Scale a bytes-per-second rate into the largest unit below 1024.
pub fn scaleBytes(bytes_per_sec: f64) Scaled {
    const units = [_][]const u8{ "B", "kB", "MB", "GB" };

    var value = bytes_per_sec;
    for (units, 0..) |unit, i| {
        if (value < 1024.0 or i == units.len - 1) return .{ .value = value, .unit = unit };
        value /= 1024.0;
    }
    unreachable;
}

/// Parse a dotted-quad IPv4 address into host byte order.
pub fn ipv4(text: []const u8) !u32 {
    var octets = std.mem.splitScalar(u8, text, '.');
    var addr: u32 = 0;
    var count: u8 = 0;

    while (octets.next()) |octet| {
        if (count == 4) return error.InvalidAddress;
        addr = (addr << 8) | try std.fmt.parseInt(u8, octet, 10);
        count += 1;
    }

    if (count != 4) return error.InvalidAddress;
    return addr;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "cpuStat parses the aggregate line" {
    const content =
        \\cpu  10 20 30 40 50 60 70 80 90
        \\cpu0 1 2 3 4 5 6 7
        \\intr 12345
    ;
    const times = try cpuStat(content);
    try testing.expectEqual(@as(u64, 10), times.user);
    try testing.expectEqual(@as(u64, 40), times.idle);
    try testing.expectEqual(@as(u64, 70), times.softirq);
    try testing.expectEqual(@as(u64, 280), times.total());
    try testing.expectEqual(@as(u64, 90), times.idleTotal());
}

test "cpuStat rejects unexpected content" {
    try testing.expectError(error.InvalidFormat, cpuStat("intr 1 2 3"));
    try testing.expectError(error.InvalidFormat, cpuStat(""));
    // "cpu0" must not be mistaken for the aggregate line.
    try testing.expectError(error.InvalidFormat, cpuStat("cpu0 1 2 3 4 5 6 7"));
}

test "cpuUsagePercent computes busy share" {
    const prev = CpuTimes{ .user = 0, .nice = 0, .system = 0, .idle = 100, .iowait = 0, .irq = 0, .softirq = 0 };
    const half = CpuTimes{ .user = 100, .nice = 0, .system = 0, .idle = 200, .iowait = 0, .irq = 0, .softirq = 0 };
    try testing.expectEqual(@as(u8, 50), cpuUsagePercent(prev, half));

    // No elapsed ticks at all.
    try testing.expectEqual(@as(u8, 0), cpuUsagePercent(prev, prev));

    // Fully busy.
    const busy = CpuTimes{ .user = 100, .nice = 0, .system = 0, .idle = 100, .iowait = 0, .irq = 0, .softirq = 0 };
    try testing.expectEqual(@as(u8, 100), cpuUsagePercent(prev, busy));
}

test "cpuUsagePercent survives a counter reset" {
    const prev = CpuTimes{ .user = 900, .nice = 0, .system = 0, .idle = 900, .iowait = 0, .irq = 0, .softirq = 0 };
    const after_reset = CpuTimes{ .user = 1, .nice = 0, .system = 0, .idle = 1, .iowait = 0, .irq = 0, .softirq = 0 };
    // Must saturate to 0 rather than underflow.
    try testing.expectEqual(@as(u8, 0), cpuUsagePercent(prev, after_reset));
}

test "memoryUsagePercent uses MemAvailable" {
    const content =
        \\MemTotal:        1000 kB
        \\MemFree:          100 kB
        \\MemAvailable:     250 kB
        \\Buffers:           10 kB
    ;
    try testing.expectEqual(@as(u8, 75), try memoryUsagePercent(content));
}

test "memoryUsagePercent rejects incomplete input" {
    try testing.expectError(error.InvalidMeminfo, memoryUsagePercent("MemTotal: 1000 kB"));
    try testing.expectError(error.InvalidMeminfo, memoryUsagePercent(""));
    try testing.expectError(
        error.InvalidMeminfo,
        memoryUsagePercent("MemTotal: 0 kB\nMemAvailable: 0 kB"),
    );
}

test "temperatureCelsius converts millidegrees" {
    try testing.expectEqual(@as(u32, 47), try temperatureCelsius("47774\n"));
    try testing.expectEqual(@as(u32, 0), try temperatureCelsius("  999  "));
    try testing.expectError(error.InvalidCharacter, temperatureCelsius("n/a"));
}

test "uptime splits into days, hours and minutes" {
    // 2 days, 3 hours, 4 minutes, 5 seconds.
    const total = 2 * 86400 + 3 * 3600 + 4 * 60 + 5;
    var buf: [64]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf, "{d}.42 9999.00", .{total});

    const up = try uptime(content);
    try testing.expectEqual(@as(u32, 2), up.days);
    try testing.expectEqual(@as(u32, 3), up.hours);
    try testing.expectEqual(@as(u32, 4), up.minutes);
}

test "uptime handles a missing fractional part" {
    const up = try uptime("60 0");
    try testing.expectEqual(@as(u32, 0), up.days);
    try testing.expectEqual(@as(u32, 1), up.minutes);
}

test "wirelessSignal reads the level column" {
    const content =
        \\Inter-| sta-|   Quality        |   Discarded packets
        \\ face | tus | link level noise |  nwid crypt frag retry misc
        \\ wlan0: 0000   70.  -40.  -256        0     0    0     0    0
    ;
    try testing.expectEqual(@as(?i32, -40), wirelessSignal(content, "wlan0"));
    try testing.expectEqual(@as(?i32, null), wirelessSignal(content, "wlan1"));
}

test "wirelessSignal does not match on a name prefix" {
    const content = " wlan01: 0000   70.  -55.  -256        0     0    0     0    0";
    // "wlan0" is a prefix of "wlan01" but must not match.
    try testing.expectEqual(@as(?i32, null), wirelessSignal(content, "wlan0"));
    try testing.expectEqual(@as(?i32, -55), wirelessSignal(content, "wlan01"));
}

test "netDevTotals sums interfaces and skips loopback" {
    const content =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop
        \\    lo: 999 1 0 0 0 0 0 0 999 1 0 0
        \\  eth0: 100 1 0 0 0 0 0 0 200 1 0 0
        \\ wlan0: 300 1 0 0 0 0 0 0 400 1 0 0
    ;
    const totals = netDevTotals(content);
    try testing.expectEqual(@as(u64, 400), totals.rx_bytes);
    try testing.expectEqual(@as(u64, 600), totals.tx_bytes);
}

test "netDevTotals tolerates a missing space after the colon" {
    const content = "eth0:1234 1 0 0 0 0 0 0 5678 1 0 0";
    const totals = netDevTotals(content);
    try testing.expectEqual(@as(u64, 1234), totals.rx_bytes);
    try testing.expectEqual(@as(u64, 5678), totals.tx_bytes);
}

test "aptUpgradableCount ignores the header and blank lines" {
    const content =
        \\Listing... Done
        \\vim/stable 2:9.0 amd64 [upgradable from: 2:8.2]
        \\curl/stable 7.88 amd64 [upgradable from: 7.87]
        \\
    ;
    try testing.expectEqual(@as(u32, 2), aptUpgradableCount(content));
    try testing.expectEqual(@as(u32, 0), aptUpgradableCount("Listing... Done\n"));
    try testing.expectEqual(@as(u32, 0), aptUpgradableCount(""));
}

test "scaleBytes picks the right unit" {
    try testing.expectEqualStrings("B", scaleBytes(512).unit);
    try testing.expectEqualStrings("kB", scaleBytes(2048).unit);
    try testing.expectEqual(@as(f64, 2), scaleBytes(2048).value);
    try testing.expectEqualStrings("MB", scaleBytes(5 * 1024 * 1024).unit);
    // Saturates at the largest unit instead of running off the end.
    try testing.expectEqualStrings("GB", scaleBytes(1e15).unit);
}

test "ipv4 parses dotted quads" {
    try testing.expectEqual(@as(u32, 0x08080808), try ipv4("8.8.8.8"));
    try testing.expectEqual(@as(u32, 0xC0A80101), try ipv4("192.168.1.1"));
    try testing.expectEqual(@as(u32, 0), try ipv4("0.0.0.0"));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), try ipv4("255.255.255.255"));
}

test "ipv4 rejects malformed input" {
    try testing.expectError(error.InvalidAddress, ipv4("1.2.3"));
    try testing.expectError(error.InvalidAddress, ipv4("1.2.3.4.5"));
    try testing.expectError(error.Overflow, ipv4("256.0.0.1"));
    try testing.expectError(error.InvalidCharacter, ipv4("a.b.c.d"));
}
