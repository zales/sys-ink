const std = @import("std");

// C interop for network functions
const c = @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
});

// Architecture-aware O_NONBLOCK constant
const O_NONBLOCK: u32 = if (@import("builtin").target.cpu.arch == .aarch64 or
    @import("builtin").target.cpu.arch == .arm)
    0x800 // ARM/ARM64
else
    0x4000; // x86/x86_64

/// Network operations for gathering network metrics
pub const NetworkOps = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NetworkOps {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *NetworkOps) void {
        // No resources to free - allocator is borrowed, not owned
    }

    /// Check internet connection with a 1s bounded TCP connect (non-blocking)
    pub fn checkInternetConnection(_: *NetworkOps) bool {
        const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch return false;
        defer std.posix.close(fd);

        // Make socket non-blocking using linux syscall interface
        const linux = std.os.linux;
        const flags = linux.fcntl(@intCast(fd), linux.F.GETFL, 0);
        if (@as(isize, @bitCast(flags)) < 0) return false;
        const set_result = linux.fcntl(@intCast(fd), linux.F.SETFL, flags | O_NONBLOCK);
        if (@as(isize, @bitCast(set_result)) < 0) return false;

        // sockaddr_in for 8.8.8.8:53
        const ip_num: u32 = (@as(u32, 8) << 24) | (@as(u32, 8) << 16) | (@as(u32, 8) << 8) | 8;
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, 53),
            .addr = std.mem.nativeToBig(u32, ip_num),
        };

        _ = std.posix.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)) catch |err| switch (err) {
            error.WouldBlock => {},
            else => return false,
        };

        // Non-blocking connect always goes through poll (even if it succeeds immediately on some systems)

        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.posix.poll(&fds, 1_000) catch return false; // 1s timeout
        if (ready <= 0) return false;
        if ((fds[0].revents & std.posix.POLL.OUT) == 0) return false;

        var so_error: c_int = 0;
        _ = std.posix.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, std.mem.asBytes(&so_error)) catch return false;
        return so_error == 0;
    }

    /// Get WiFi signal strength from /proc/net/wireless
    pub fn getSignalStrength(_: *NetworkOps, interface: []const u8) !?i32 {
        const file = std.fs.openFileAbsolute("/proc/net/wireless", .{}) catch return null;
        defer file.close();

        var buf: [2048]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        const content = buf[0..bytes_read];

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, interface) != null) {
                // Format: "wlan0: 0000   70.  -40.  -256        0      0      0"
                var parts = std.mem.tokenizeAny(u8, line, " ");
                _ = parts.next(); // skip interface name
                _ = parts.next(); // skip status
                _ = parts.next(); // skip link quality

                if (parts.next()) |signal_str| {
                    // Remove trailing dot if present
                    const clean_str = std.mem.trimRight(u8, signal_str, ".");
                    return try std.fmt.parseInt(i32, clean_str, 10);
                }
            }
        }

        return null; // Interface not found
    }

    /// Get IP address for the specified interface
    pub fn getIpAddress(self: *NetworkOps, interface: []const u8) !?[]u8 {
        var ifap: ?*c.ifaddrs = null;
        if (c.getifaddrs(&ifap) != 0) {
            return error.GetifaddrsFailed;
        }
        defer c.freeifaddrs(ifap);

        var current = ifap;
        while (current) |ifa| : (current = ifa.ifa_next) {
            const name = std.mem.span(ifa.ifa_name);

            if (std.mem.eql(u8, name, interface)) {
                if (ifa.ifa_addr) |addr| {
                    if (addr.*.sa_family == c.AF_INET) {
                        const sin: *c.struct_sockaddr_in = @ptrCast(@alignCast(addr));
                        const ip_str = c.inet_ntoa(sin.*.sin_addr);
                        const ip_len = std.mem.len(ip_str);

                        const result = try self.allocator.alloc(u8, ip_len);
                        @memcpy(result, ip_str[0..ip_len]);
                        return result;
                    }
                }
            }
        }

        return null; // Interface not found or no IPv4 address
    }

    /// Get IP address from any available interface (prioritize eth0, then wlan0)
    pub fn getAnyIpAddress(self: *NetworkOps) !?[]u8 {
        // Try eth0 first
        if (try self.getIpAddress("eth0")) |ip| {
            return ip;
        }
        // Then try wlan0
        if (try self.getIpAddress("wlan0")) |ip| {
            return ip;
        }
        // Finally try any interface except lo
        var ifap: ?*c.ifaddrs = null;
        if (c.getifaddrs(&ifap) != 0) {
            return error.GetifaddrsFailed;
        }
        defer c.freeifaddrs(ifap);

        var current = ifap;
        while (current) |ifa| : (current = ifa.ifa_next) {
            const name = std.mem.span(ifa.ifa_name);

            // Skip loopback
            if (std.mem.eql(u8, name, "lo")) continue;

            if (ifa.ifa_addr) |addr| {
                if (addr.*.sa_family == c.AF_INET) {
                    const sin: *c.struct_sockaddr_in = @ptrCast(@alignCast(addr));
                    const ip_str = c.inet_ntoa(sin.*.sin_addr);
                    const ip_len = std.mem.len(ip_str);

                    const result = try self.allocator.alloc(u8, ip_len);
                    @memcpy(result, ip_str[0..ip_len]);
                    return result;
                }
            }
        }

        return null;
    }
};

/// Traffic monitor for tracking network traffic
pub const TrafficMonitor = struct {
    last_rx_bytes: ?u64 = null,
    last_tx_bytes: ?u64 = null,
    last_time: ?i64 = null,

    pub fn init(_: std.mem.Allocator) TrafficMonitor {
        return .{};
    }

    pub fn deinit(_: *TrafficMonitor) void {
        // No resources to free
    }

    const TrafficResult = struct {
        download_speed: f64,
        download_unit: []const u8,
        upload_speed: f64,
        upload_unit: []const u8,
    };

    /// Get current network traffic using cached measurements
    pub fn getCurrentTraffic(self: *TrafficMonitor) !TrafficResult {
        const file = try std.fs.openFileAbsolute("/proc/net/dev", .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        const content = buf[0..bytes_read];

        // Sum all interfaces (skip loopback)
        var total_rx: u64 = 0;
        var total_tx: u64 = 0;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            // Skip header lines
            if (std.mem.indexOf(u8, line, ":") == null) continue;

            // Skip loopback
            if (std.mem.indexOf(u8, line, "lo:") != null) continue;

            // Parse line: "interface: rx_bytes rx_packets ... tx_bytes tx_packets ..."
            var parts = std.mem.tokenizeAny(u8, line, " :");
            _ = parts.next(); // skip interface name

            if (parts.next()) |rx_str| {
                const rx = std.fmt.parseInt(u64, rx_str, 10) catch 0;
                total_rx += rx;
            }

            // Skip 7 more rx fields (packets, errs, drop, fifo, frame, compressed, multicast)
            var i: u8 = 0;
            while (i < 7) : (i += 1) {
                _ = parts.next();
            }

            if (parts.next()) |tx_str| {
                const tx = std.fmt.parseInt(u64, tx_str, 10) catch 0;
                total_tx += tx;
            }
        }

        const now = std.time.timestamp();

        // First measurement - initialize cache
        if (self.last_rx_bytes == null or self.last_tx_bytes == null or self.last_time == null) {
            self.last_rx_bytes = total_rx;
            self.last_tx_bytes = total_tx;
            self.last_time = now;
            return TrafficResult{
                .download_speed = 0.0,
                .download_unit = "B",
                .upload_speed = 0.0,
                .upload_unit = "B",
            };
        }

        const interval = now - self.last_time.?;
        if (interval < 1) {
            // Too soon, return zero
            return TrafficResult{
                .download_speed = 0.0,
                .download_unit = "B",
                .upload_speed = 0.0,
                .upload_unit = "B",
            };
        }

        // Use saturating subtraction to handle counter resets (reboot, overflow)
        const rx_diff = total_rx -| self.last_rx_bytes.?;
        const tx_diff = total_tx -| self.last_tx_bytes.?;

        self.last_rx_bytes = total_rx;
        self.last_tx_bytes = total_tx;
        self.last_time = now;

        const interval_f: f64 = @floatFromInt(interval);
        const rx_speed = @as(f64, @floatFromInt(rx_diff)) / interval_f;
        const tx_speed = @as(f64, @floatFromInt(tx_diff)) / interval_f;

        const download = chooseUnit(rx_speed);
        const upload = chooseUnit(tx_speed);

        return TrafficResult{
            .download_speed = download.speed,
            .download_unit = download.unit,
            .upload_speed = upload.speed,
            .upload_unit = upload.unit,
        };
    }

    const UnitResult = struct {
        speed: f64,
        unit: []const u8,
    };

    fn chooseUnit(speed: f64) UnitResult {
        var s = speed;
        const units = [_][]const u8{ "B", "kB", "MB", "GB" };

        for (units, 0..) |unit, i| {
            if (s < 1024.0 or i == units.len - 1) {
                return UnitResult{ .speed = s, .unit = unit };
            }
            s /= 1024.0;
        }

        return UnitResult{ .speed = s, .unit = "GB" };
    }
};
