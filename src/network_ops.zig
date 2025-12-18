const std = @import("std");

/// Network operations for gathering network metrics
pub const NetworkOps = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NetworkOps {
        return .{ .allocator = allocator };
    }

    /// Check internet connection via DNS query to 8.8.8.8:53 with timeout
    pub fn checkInternetConnection(_: *NetworkOps) bool {
        const addr = std.net.Address.parseIp4("8.8.8.8", 53) catch return false;

        // Fast connection check with timeout handled by OS
        const stream = std.net.tcpConnectToAddress(addr) catch return false;
        stream.close();

        return true;
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
        // Use getifaddrs via C interop
        const c = @cImport({
            @cInclude("ifaddrs.h");
            @cInclude("sys/socket.h");
            @cInclude("netinet/in.h");
            @cInclude("arpa/inet.h");
        });

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
        const c = @cImport({
            @cInclude("ifaddrs.h");
            @cInclude("sys/socket.h");
            @cInclude("netinet/in.h");
            @cInclude("arpa/inet.h");
        });

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
    allocator: std.mem.Allocator,
    last_rx_bytes: ?u64 = null,
    last_tx_bytes: ?u64 = null,
    last_time: ?i64 = null,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) TrafficMonitor {
        return .{
            .allocator = allocator,
        };
    }

    const TrafficResult = struct {
        download_speed: f64,
        download_unit: []const u8,
        upload_speed: f64,
        upload_unit: []const u8,
    };

    /// Get current network traffic using cached measurements
    pub fn getCurrentTraffic(self: *TrafficMonitor) !TrafficResult {
        self.mutex.lock();
        defer self.mutex.unlock();

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

        const rx_diff = total_rx - self.last_rx_bytes.?;
        const tx_diff = total_tx - self.last_tx_bytes.?;

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
