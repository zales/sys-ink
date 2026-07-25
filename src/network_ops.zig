const std = @import("std");
const config = @import("config.zig");
const parse = @import("parse.zig");

// C interop for network functions
const c = @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
});

const log = std.log.scoped(.network);

/// Longest IPv4 dotted quad ("255.255.255.255").
pub const max_ip_len = 15;

/// How long an internet-reachability probe stays valid. The probe blocks for up
/// to a second, and several callers ask for it each cycle.
const internet_cache_seconds = 60;

/// Network operations for gathering network metrics
pub const NetworkOps = struct {
    io: std.Io,
    cached_internet: ?bool = null,
    cached_internet_at: i64 = 0,

    pub fn init(io: std.Io) NetworkOps {
        return .{ .io = io };
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

    /// One-second bounded TCP connect against the configured probe host.
    fn probeInternet() bool {
        const linux = std.os.linux;

        const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 6); // 6 = TCP
        if (@as(isize, @bitCast(sock_rc)) < 0) return false;
        const fd: std.posix.fd_t = @intCast(sock_rc);
        defer _ = linux.close(fd);

        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, config.Config.internet_check_port),
            .addr = std.mem.nativeToBig(u32, config.Config.internet_check_ip),
        };

        _ = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));

        // A non-blocking connect reports completion through poll, even when it
        // succeeds immediately.
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.posix.poll(&fds, 1_000) catch return false; // 1s timeout
        if (ready <= 0) return false;
        if ((fds[0].revents & std.posix.POLL.OUT) == 0) return false;

        var so_error: c_int = 0;
        var so_error_len: linux.socklen_t = @sizeOf(c_int);
        const gso_rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &so_error_len);
        if (@as(isize, @bitCast(gso_rc)) != 0) return false;
        return so_error == 0;
    }

    /// Get WiFi signal strength in dBm from /proc/net/wireless
    pub fn getSignalStrength(self: *NetworkOps, interface: []const u8) ?i32 {
        const file = std.Io.Dir.openFileAbsolute(self.io, "/proc/net/wireless", .{}) catch return null;
        defer file.close(self.io);

        var buf: [2048]u8 = undefined;
        const bytes_read = file.readPositionalAll(self.io, &buf, 0) catch return null;

        return parse.wirelessSignal(buf[0..bytes_read], interface);
    }

    /// IPv4 address of the first usable interface, preferring eth0 then wlan0.
    pub fn getAnyIpAddress(_: *NetworkOps, buf: []u8) !?[]const u8 {
        if (try findIp(buf, "eth0")) |ip| return ip;
        if (try findIp(buf, "wlan0")) |ip| return ip;
        // Anything except loopback.
        return findIp(buf, null);
    }

    /// Walk getifaddrs looking for an IPv4 address. A null `interface` accepts
    /// any non-loopback interface.
    fn findIp(buf: []u8, interface: ?[]const u8) !?[]const u8 {
        var ifap: ?*c.ifaddrs = null;
        if (c.getifaddrs(&ifap) != 0) return error.GetifaddrsFailed;
        defer c.freeifaddrs(ifap);

        var current = ifap;
        while (current) |ifa| : (current = ifa.ifa_next) {
            const name = std.mem.span(ifa.ifa_name);

            if (interface) |want| {
                if (!std.mem.eql(u8, name, want)) continue;
            } else if (std.mem.eql(u8, name, "lo")) {
                continue;
            }

            const addr = ifa.ifa_addr orelse continue;
            if (addr.*.sa_family != c.AF_INET) continue;

            const sin: *c.struct_sockaddr_in = @ptrCast(@alignCast(addr));
            const ip_str = c.inet_ntoa(sin.*.sin_addr);
            const ip = std.mem.span(ip_str);

            if (ip.len > buf.len) return error.NoSpaceLeft;
            @memcpy(buf[0..ip.len], ip);
            return buf[0..ip.len];
        }

        return null;
    }
};

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
        const totals = parse.netDevTotals(buf[0..bytes_read]);

        // Monotonic: a wall-clock step would otherwise fabricate a huge or
        // negative interval and with it a nonsense rate.
        const now = std.Io.Timestamp.now(self.io, .awake).toSeconds();

        defer {
            self.last_rx_bytes = totals.rx_bytes;
            self.last_tx_bytes = totals.tx_bytes;
        }

        const last_rx = self.last_rx_bytes;
        const last_tx = self.last_tx_bytes;
        const last_time = self.last_time;

        if (last_rx == null or last_tx == null or last_time == null) {
            self.last_time = now;
            return self.currentResult();
        }

        const interval = now - last_time.?;
        // Sampled twice within the same second: keep the previous rate rather
        // than reporting a spurious zero.
        if (interval < 1) return self.currentResult();

        self.last_time = now;

        // Saturating: counters reset on reboot and on interface teardown.
        const rx_diff = totals.rx_bytes -| last_rx.?;
        const tx_diff = totals.tx_bytes -| last_tx.?;

        const interval_f: f64 = @floatFromInt(interval);
        self.last_rx_speed = @as(f64, @floatFromInt(rx_diff)) / interval_f;
        self.last_tx_speed = @as(f64, @floatFromInt(tx_diff)) / interval_f;

        return self.currentResult();
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
