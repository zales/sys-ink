const std = @import("std");
const config = @import("config.zig");
const parse = @import("parse.zig");
const bounded_connect = @import("bounded_connect.zig");

const c = @import("c"); // src/c.h

const log = std.log.scoped(.network);

/// Longest IPv4 dotted quad ("255.255.255.255").
pub const max_ip_len = 15;

/// How long an internet-reachability probe stays valid. Several callers ask for
/// it each cycle and the probe blocks while it runs.
const internet_cache_seconds = 60;

/// Bound on the reachability probe, so an unreachable host cannot stall the
/// render loop for the kernel's TCP timeout.
const probe_timeout_ms = 1000;

/// Network operations for gathering network metrics
pub const NetworkOps = struct {
    io: std.Io,
    cached_internet: ?bool = null,
    cached_internet_at: i64 = 0,

    // Latest readings, so a second consumer in the same cycle — MQTT — reports
    // what the panel shows instead of taking the measurement again.
    last_signal: ?i32 = null,
    last_ip: [max_ip_len]u8 = undefined,
    last_ip_len: usize = 0,
    /// Whether that address is on a wired interface. See `lastIpIsWired`.
    last_ip_wired: bool = false,

    pub fn init(io: std.Io) NetworkOps {
        return .{ .io = io };
    }

    /// The most recent signal reading, or null if there was none.
    pub fn lastSignalStrength(self: *const NetworkOps) ?i32 {
        return self.last_signal;
    }

    /// The result of the most recent reachability probe, or null before the
    /// first. Takes no measurement, unlike `checkInternetConnection`.
    pub fn lastInternet(self: *const NetworkOps) ?bool {
        return self.cached_internet;
    }

    /// Whether the address the panel shows is on a cable rather than Wi-Fi.
    ///
    /// By name: `wl*` is the kernel's and udev's prefix for wireless interfaces,
    /// and everything else that carries an address here — eth0, end0, enp*,
    /// USB adapters — is wired.
    pub fn lastIpIsWired(self: *const NetworkOps) bool {
        return self.last_ip_len != 0 and self.last_ip_wired;
    }

    /// The address the most recent look found, or null if it found none.
    pub fn lastIpAddress(self: *const NetworkOps) ?[]const u8 {
        if (self.last_ip_len == 0) return null;
        return self.last_ip[0..self.last_ip_len];
    }

    /// Whether the machine can reach the configured probe host.
    ///
    /// Results are cached for `internet_cache_seconds` so the display, the APT
    /// check and MQTT publishing share a single probe.
    pub fn checkInternetConnection(self: *NetworkOps) bool {
        const now = std.Io.Timestamp.now(self.io, .awake).toSeconds();

        if (self.cached_internet) |cached| {
            if (now - self.cached_internet_at < internet_cache_seconds) return cached;
        }

        const reachable = probeInternet();
        self.cached_internet = reachable;
        self.cached_internet_at = now;
        return reachable;
    }

    /// Bounded TCP connect against the configured probe host.
    fn probeInternet() bool {
        const fd = bounded_connect.connect(
            config.Config.internet_check_ip,
            config.Config.internet_check_port,
            probe_timeout_ms,
        ) catch return false;
        bounded_connect.closeFd(fd);
        return true;
    }

    /// Get WiFi signal strength in dBm from /proc/net/wireless
    pub fn getSignalStrength(self: *NetworkOps, interface: []const u8) ?i32 {
        const file = std.Io.Dir.openFileAbsolute(self.io, "/proc/net/wireless", .{}) catch return null;
        defer file.close(self.io);

        var buf: [2048]u8 = undefined;
        const bytes_read = file.readPositionalAll(self.io, &buf, 0) catch return null;

        self.last_signal = parse.wirelessSignal(buf[0..bytes_read], interface);
        return self.last_signal;
    }

    /// IPv4 address of the interface the machine is reached on: a cable before
    /// Wi-Fi, and either before anything with no hardware behind it.
    ///
    /// One walk of the interface list rather than one per candidate. This used
    /// to call `getifaddrs` up to three times — once for eth0, once for wlan0,
    /// once for anything — and each call builds and frees the entire list, which
    /// already held every answer the next call went back for.
    pub fn getAnyIpAddress(self: *NetworkOps, buf: []u8) !?[]const u8 {
        // Forgotten before looking, so every way out below that finds nothing
        // leaves nothing behind. It used to survive losing the address, and
        // MQTT went on publishing it while the panel said "No IP".
        self.last_ip_len = 0;

        var ifap: ?*c.ifaddrs = null;
        if (c.getifaddrs(&ifap) != 0) return error.GetifaddrsFailed;
        defer c.freeifaddrs(ifap);

        // Null means nothing usable has been seen yet.
        var best_rank: ?parse.InterfaceRank = null;
        var best_len: usize = 0;
        var best_wired = false;

        var current = ifap;
        while (current) |ifa| : (current = ifa.ifa_next) {
            const name = std.mem.span(ifa.ifa_name);
            if (std.mem.eql(u8, name, "lo")) continue;

            // Before ranking: the list holds an entry per address family, and
            // only the IPv4 one is worth a look into sysfs.
            const addr = ifa.ifa_addr orelse continue;
            if (addr.*.sa_family != c.AF_INET) continue;

            const rank = parse.interfaceRank(name, hasDevice(self.io, name));

            // Ties go to the earlier entry, matching the old first-match order.
            if (best_rank) |best| {
                if (@backingInt(rank) >= @backingInt(best)) continue;
            }

            const sin: *c.struct_sockaddr_in = @ptrCast(@alignCast(addr));
            // inet_ntoa's buffer is static and reused, so copy it out now.
            const ip = std.mem.span(c.inet_ntoa(sin.*.sin_addr));
            if (ip.len > buf.len) return error.NoSpaceLeft;

            @memcpy(buf[0..ip.len], ip);
            best_rank = rank;
            best_len = ip.len;
            best_wired = !std.mem.startsWith(u8, name, "wl");

            if (rank == .wired) break; // nothing outranks a cable
        }

        if (best_rank == null) return null;

        // Kept for MQTT, which publishes the address the panel is showing rather
        // than walking the interface list a second time.
        @memcpy(self.last_ip[0..best_len], buf[0..best_len]);
        self.last_ip_len = best_len;
        self.last_ip_wired = best_wired;

        return buf[0..best_len];
    }
};

/// Whether hardware backs the interface, which shows as a `device` link in
/// sysfs. Bridges, veth pairs and tunnels have none.
fn hasDevice(io: std.Io, name: []const u8) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.mem.print(&path_buf, "/sys/class/net/{s}/device", .{name}) catch return false;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Traffic monitor for tracking network traffic
pub const TrafficMonitor = struct {
    io: std.Io,
    last_rx_bytes: ?u64 = null,
    last_tx_bytes: ?u64 = null,
    last_time: ?i64 = null,
    last_rx_speed: f64 = 0,
    last_tx_speed: f64 = 0,

    pub fn init(io: std.Io) TrafficMonitor {
        return .{ .io = io };
    }

    pub const TrafficResult = struct {
        download_speed: f64,
        download_unit: []const u8,
        upload_speed: f64,
        upload_unit: []const u8,
    };

    /// Raw traffic result in bytes per second
    pub const RawTrafficResult = struct {
        rx_bytes_per_sec: f64,
        tx_bytes_per_sec: f64,
    };

    /// Get raw traffic in bytes per second (for MQTT)
    pub fn getRawTraffic(self: *TrafficMonitor) RawTrafficResult {
        return .{
            .rx_bytes_per_sec = self.last_rx_speed,
            .tx_bytes_per_sec = self.last_tx_speed,
        };
    }

    /// Current traffic rate, measured against the previous sample.
    pub fn getCurrentTraffic(self: *TrafficMonitor) !TrafficResult {
        const file = try std.Io.Dir.openFileAbsolute(self.io, "/proc/net/dev", .{});
        defer file.close(self.io);

        var buf: [8192]u8 = undefined;
        const bytes_read = try file.readPositionalAll(self.io, &buf, 0);
        const content = buf[0..bytes_read];
        // Where nothing has a device — a container, say — count what there is
        // rather than report no traffic at all.
        const totals = parse.netDevTotalsWhere(content, Physical{ .io = self.io }) orelse
            parse.netDevTotals(content);

        // Monotonic: a wall-clock step would otherwise fabricate a huge or
        // negative interval and with it a nonsense rate.
        const now = std.Io.Timestamp.now(self.io, .awake).toSeconds();

        const last_rx = self.last_rx_bytes;
        const last_tx = self.last_tx_bytes;
        const last_time = self.last_time;

        // The sample and the instant it was taken at move together or not at
        // all. Advancing the byte counters while leaving `last_time` behind
        // would charge the next interval for traffic this one already consumed,
        // and report a rate that is quietly too low.
        if (last_rx == null or last_tx == null or last_time == null) {
            self.takeSample(totals, now);
            return self.currentResult();
        }

        const interval = now - last_time.?;
        // Sampled twice within the same second: keep the previous rate rather
        // than reporting a spurious zero, and leave the baseline untouched so
        // the next real interval still measures against a matching timestamp.
        if (interval < 1) return self.currentResult();

        self.takeSample(totals, now);

        // Saturating: counters reset on reboot and on interface teardown.
        const rx_diff = totals.rx_bytes -| last_rx.?;
        const tx_diff = totals.tx_bytes -| last_tx.?;

        const interval_f: f64 = @floatFromInt(interval);
        self.last_rx_speed = @as(f64, @floatFromInt(rx_diff)) / interval_f;
        self.last_tx_speed = @as(f64, @floatFromInt(tx_diff)) / interval_f;

        return self.currentResult();
    }

    /// Accepts interfaces backed by hardware. Bridges, veth pairs and tunnels
    /// are not, and each of them carries bytes a physical interface also
    /// counts: container traffic crosses a veth, the Docker bridge and eth0,
    /// and summing all three reported it three times over.
    const Physical = struct {
        io: std.Io,

        pub fn counts(self: Physical, name: []const u8) bool {
            return hasDevice(self.io, name);
        }
    };

    /// Record the counters and the instant they were read at, as one step.
    fn takeSample(self: *TrafficMonitor, totals: parse.NetTotals, now: i64) void {
        self.last_rx_bytes = totals.rx_bytes;
        self.last_tx_bytes = totals.tx_bytes;
        self.last_time = now;
    }

    fn currentResult(self: *TrafficMonitor) TrafficResult {
        const download = parse.scaleBytes(self.last_rx_speed);
        const upload = parse.scaleBytes(self.last_tx_speed);

        return .{
            .download_speed = download.value,
            .download_unit = download.unit,
            .upload_speed = upload.value,
            .upload_unit = upload.unit,
        };
    }
};
