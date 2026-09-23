const std = @import("std");
const config = @import("config.zig");
const bounded_connect = @import("bounded_connect.zig");
const net = std.Io.net;

const c = @cImport({
    @cInclude("netdb.h");
    @cInclude("arpa/inet.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
});

const log = std.log.scoped(.mqtt);

/// A Home Assistant entity this daemon exposes.
pub const Sensor = struct {
    /// Topic suffix and unique-id stem.
    id: []const u8,
    name: []const u8,
    /// Home Assistant component; binary sensors take "ON"/"OFF" payloads.
    component: enum { sensor, binary_sensor } = .sensor,
    unit: ?[]const u8 = null,
    device_class: ?[]const u8 = null,
    /// "measurement" makes Home Assistant keep long-term statistics, which is
    /// what its history graphs past ten days and its min/max cards read from.
    state_class: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

/// Every entity published under the SysInk device.
pub const sensors = [_]Sensor{
    .{ .id = "cpu_load", .name = "CPU Load", .unit = "%", .state_class = measurement, .icon = "mdi:cpu-64-bit" },
    .{ .id = "cpu_temp", .name = "CPU Temperature", .unit = "°C", .device_class = "temperature", .state_class = measurement, .icon = "mdi:thermometer" },
    .{ .id = "memory", .name = "Memory Usage", .unit = "%", .state_class = measurement, .icon = "mdi:memory" },
    .{ .id = "disk_usage", .name = "Disk Usage", .unit = "%", .state_class = measurement, .icon = "mdi:harddisk" },
    .{ .id = "disk_temp", .name = "Disk Temperature", .unit = "°C", .device_class = "temperature", .state_class = measurement, .icon = "mdi:thermometer" },
    .{ .id = "fan_speed", .name = "Fan Speed", .unit = "RPM", .state_class = measurement, .icon = "mdi:fan" },
    .{ .id = "signal_strength", .name = "WiFi Signal", .unit = "dBm", .device_class = "signal_strength", .state_class = measurement, .icon = "mdi:wifi" },
    .{ .id = "ip_address", .name = "IP Address", .icon = "mdi:ip-network" },
    .{ .id = "internet", .name = "Internet Connected", .component = .binary_sensor, .device_class = "connectivity", .icon = "mdi:web" },
    .{ .id = "traffic_down", .name = "Download Speed", .unit = "kB/s", .device_class = "data_rate", .state_class = measurement, .icon = "mdi:download" },
    .{ .id = "traffic_up", .name = "Upload Speed", .unit = "kB/s", .device_class = "data_rate", .state_class = measurement, .icon = "mdi:upload" },
    .{ .id = "uptime_days", .name = "Uptime Days", .unit = "d", .state_class = measurement, .icon = "mdi:clock-outline" },
    .{ .id = "apt_updates", .name = "APT Updates", .state_class = measurement, .icon = "mdi:package-up" },
    // device_class problem makes Home Assistant treat ON as a fault, so it shows
    // up in the "problems" view and can drive a notification without a template.
    .{ .id = "undervoltage", .name = "Under-voltage", .component = .binary_sensor, .device_class = "problem", .icon = "mdi:flash-alert" },
    .{ .id = "nvme_fault", .name = "NVMe SMART Fault", .component = .binary_sensor, .device_class = "problem", .icon = "mdi:harddisk-remove" },
    // Vendor's life-used estimate from the same SMART page; the long-term trend
    // is the early warning the fault bit only gives at the end.
    .{ .id = "ssd_wear", .name = "SSD Wear", .unit = "%", .state_class = measurement, .icon = "mdi:chart-donut" },
};

const measurement = "measurement";

/// Node id, unique_id stem and device identifier for the default client id —
/// and what every release before this one used unconditionally. Deriving the
/// others from the client id while keeping this one for the default leaves an
/// existing single-device setup exactly as Home Assistant already knows it.
const default_node_id = "sysink";

/// Longest node id derived from a client id; longer ids are cut.
const max_node_id_len = 64;

/// The discovery node id for `client_id`, written into `buf`.
///
/// Home Assistant only recognises `[a-zA-Z0-9_-]` in that position of a
/// discovery topic and silently ignores a config published anywhere else, so
/// every other character becomes `_`.
pub fn nodeId(buf: *[max_node_id_len]u8, client_id: []const u8) []const u8 {
    if (client_id.len == 0) return default_node_id;

    const len = @min(client_id.len, buf.len);
    for (buf[0..len], client_id[0..len]) |*out, ch| {
        out.* = if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else '_';
    }
    return buf[0..len];
}

/// Simple MQTT 3.1.1 client for Home Assistant integration
pub const MqttClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: ?net.Stream = null,
    host: []const u8,
    port: u16,
    client_id: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    topic_prefix: []const u8,
    discovery_enabled: bool,
    /// Storage for `nodeId`'s result; read through `node()`.
    node_id_buf: [max_node_id_len]u8 = undefined,
    node_id_len: usize = 0,
    connected: bool = false,
    // Reconnect backoff state
    last_failed_attempt: i64 = 0,
    consecutive_failures: u32 = 0,

    const Self = @This();

    /// Max backoff between reconnect attempts, in seconds.
    const max_backoff_seconds: i64 = 300;

    /// Cap on the TCP connect. Without one, a broker host that drops SYNs rather
    /// than refusing them would block the render loop for the kernel's SYN
    /// timeout, around two minutes.
    const connect_timeout_ms = 5000;

    /// Cap on waiting for room in the send buffer. The socket is blocking, and
    /// with keepalive off nothing notices a broker that has silently vanished
    /// until TCP gives up retransmitting, around fifteen minutes. Well before
    /// that the send buffer fills, and an unbounded send would then freeze the
    /// render loop for the minutes that remain.
    const send_timeout_ms = 5000;

    /// Largest packet we will build. Discovery payloads are the big ones.
    const max_packet_len = 1024;

    // MQTT Control Packet Types
    const PacketType = enum(u4) {
        CONNECT = 1,
        CONNACK = 2,
        PUBLISH = 3,
        PUBACK = 4,
        SUBSCRIBE = 8,
        SUBACK = 9,
        PINGREQ = 12,
        PINGRESP = 13,
        DISCONNECT = 14,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cfg: MqttConfig,
    ) Self {
        var self: Self = .{
            .allocator = allocator,
            .io = io,
            .host = cfg.host,
            .port = cfg.port,
            .client_id = cfg.client_id,
            .username = cfg.username,
            .password = cfg.password,
            .topic_prefix = cfg.topic_prefix,
            .discovery_enabled = cfg.discovery_enabled,
        };
        var buf: [max_node_id_len]u8 = undefined;
        const id = nodeId(&buf, cfg.client_id);
        @memcpy(self.node_id_buf[0..id.len], id);
        self.node_id_len = id.len;
        return self;
    }

    /// This device's discovery node id. See `nodeId`.
    fn node(self: *const Self) []const u8 {
        return self.node_id_buf[0..self.node_id_len];
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
    }

    /// Connect to MQTT broker, with exponential backoff between failed attempts.
    ///
    /// Home Assistant discovery is republished on every successful connect: the
    /// broker is frequently unavailable while the Pi is still booting, and a
    /// one-shot publish at startup would leave the device missing from HA
    /// forever.
    pub fn connect(self: *Self) !void {
        if (self.connected) return;

        // Respect backoff window after a recent failure
        if (self.consecutive_failures > 0) {
            const now = std.Io.Timestamp.now(self.io, .awake).toSeconds();
            if (now - self.last_failed_attempt < self.backoffDelay()) return error.BackoffActive;
        }

        log.info("Connecting to MQTT broker {s}:{d}", .{ self.host, self.port });

        // Resolve hostname via libc getaddrinfo (supports DNS, mDNS, /etc/hosts)
        const address = resolveHost(self.host) catch |err| {
            self.recordFailure();
            log.err("Failed to resolve MQTT broker {s}: {t} (next retry in {d}s)", .{ self.host, err, self.backoffDelay() });
            return err;
        };

        self.stream = bounded_connect.connectStream(address, self.port, connect_timeout_ms) catch |err| {
            self.recordFailure();
            log.err("Failed to connect to MQTT broker {s}:{d}: {t} (next retry in {d}s)", .{ self.host, self.port, err, self.backoffDelay() });
            return err;
        };
        errdefer self.closeStream();

        try self.handshake();

        self.connected = true;
        self.consecutive_failures = 0;
        log.info("Connected to MQTT broker", .{});

        if (self.discovery_enabled) self.publishDiscovery();
    }

    fn handshake(self: *Self) !void {
        self.sendConnect() catch |err| {
            self.recordFailure();
            return err;
        };
        self.receiveConnack() catch |err| {
            self.recordFailure();
            return err;
        };
    }

    fn closeStream(self: *Self) void {
        if (self.stream) |s| s.close(self.io);
        self.stream = null;
    }

    /// Current backoff window in seconds, doubling per failure up to max_backoff_seconds.
    fn backoffDelay(self: *const Self) i64 {
        if (self.consecutive_failures == 0) return 0;
        // 2, 4, 8, 16 ... capped at max_backoff_seconds
        const shift: u6 = @intCast(@min(self.consecutive_failures, 10));
        return @min(@as(i64, 1) << shift, max_backoff_seconds);
    }

    fn recordFailure(self: *Self) void {
        self.last_failed_attempt = std.Io.Timestamp.now(self.io, .awake).toSeconds();
        self.consecutive_failures = self.consecutive_failures +| 1;
    }

    /// Disconnect from MQTT broker
    pub fn disconnect(self: *Self) void {
        if (!self.connected) {
            self.closeStream();
            return;
        }

        // Best-effort; the broker reaps us on socket close anyway.
        const disconnect_packet = [_]u8{ 0xE0, 0x00 }; // DISCONNECT, 0 remaining length
        self.sendPacket(&disconnect_packet) catch |err| {
            log.debug("DISCONNECT send failed: {t}", .{err});
        };

        self.closeStream();
        self.connected = false;
        log.info("Disconnected from MQTT broker", .{});
    }

    /// Publish a message under the configured topic prefix.
    pub fn publish(self: *Self, topic: []const u8, payload: []const u8, retain: bool) !void {
        var full_topic_buf: [256]u8 = undefined;
        const full_topic = std.fmt.bufPrint(&full_topic_buf, "{s}/{s}", .{ self.topic_prefix, topic }) catch
            return error.TopicTooLong;

        return self.publishRaw(full_topic, payload, retain);
    }

    /// Publish to an exact topic, bypassing the prefix.
    ///
    /// Never connects. Reconnecting is `connect`'s job alone, which the caller
    /// invokes once per cycle behind the backoff. This used to reconnect on its
    /// own whenever the connection had dropped, and `connect` publishes
    /// discovery through this very function — so a broker that dropped the
    /// client after CONNACK (an ACL that disconnects on a denied publish does)
    /// recursed connect → discovery → publish → connect without bound, a fresh
    /// TCP connection per level, until the stack ran out.
    fn publishRaw(self: *Self, topic: []const u8, payload: []const u8, retain: bool) !void {
        if (!self.connected) return error.NotConnected;

        var packet_buf: [max_packet_len]u8 = undefined;
        const packet = try buildPublish(&packet_buf, topic, payload, retain);

        self.sendPacket(packet) catch |err| {
            log.warn("MQTT publish failed (topic={s}): {t}", .{ topic, err });
            self.connected = false;
            self.closeStream();
            // Counted like a failed connect, so a broker that accepts the
            // connection and then drops it is retried behind the backoff rather
            // than immediately.
            self.recordFailure();
            return err;
        };
    }

    /// Publish Home Assistant auto-discovery configs for every sensor.
    fn publishDiscovery(self: *Self) void {
        log.info("Publishing Home Assistant discovery configs", .{});

        var published: usize = 0;
        for (sensors) |sensor| {
            self.publishSensorDiscovery(sensor) catch |err| {
                log.warn("Discovery publish failed for {s}: {t}", .{ sensor.id, err });
                // The rest would only fail the same way, one warning each.
                if (!self.connected) break;
                continue;
            };
            published += 1;
        }

        log.info("Published {d}/{d} discovery configs", .{ published, sensors.len });
    }

    fn publishSensorDiscovery(self: *Self, sensor: Sensor) !void {
        var topic_buf: [160]u8 = undefined;
        const topic = try discoveryTopic(&topic_buf, sensor, self.node());

        var payload_buf: [discovery_payload_max]u8 = undefined;
        const payload = try discoveryPayload(&payload_buf, sensor, .{
            .node_id = self.node(),
            .topic_prefix = self.topic_prefix,
            .expire_after = expireAfterSeconds(),
        });

        try self.publishRaw(topic, payload, true);
    }

    fn sendConnect(self: *Self) !void {
        var packet_buf: [max_packet_len]u8 = undefined;
        const packet = try buildConnect(&packet_buf, self.client_id, self.username, self.password);

        try self.sendPacket(packet);
    }

    /// Send one whole packet, waiting at most `send_timeout_ms` for room.
    fn sendPacket(self: *Self, packet: []const u8) !void {
        const stream = self.stream orelse return error.NotConnected;
        try bounded_connect.waitWritable(stream.socket.handle, send_timeout_ms);
        try stream.socket.send(self.io, &stream.socket.address, packet);
    }

    fn receiveConnack(self: *Self) !void {
        const stream = self.stream orelse return error.NotConnected;

        // One deadline for the whole handshake, converted up front so a broker
        // that sends the CONNACK a byte at a time cannot renew it per read.
        //
        // `receiveTimeout` rather than a `Stream.Reader`: the reader has no
        // deadline, and `SO_RCVTIMEO` cannot supply one, because `Io.Threaded`
        // treats the resulting `EAGAIN` as a programmer bug and panics on it in
        // a Debug build. A broker that accepts the connection and then goes
        // quiet is exactly the case this has to survive.
        const deadline = (std.Io.Timeout{
            .duration = .{ .raw = .fromMilliseconds(connect_timeout_ms), .clock = .awake },
        }).toDeadline(self.io);

        // TCP can split the 4-byte CONNACK, so keep receiving until it is whole.
        var connack: [4]u8 = undefined;
        var have: usize = 0;
        while (have < connack.len) {
            const message = stream.socket.receiveTimeout(self.io, connack[have..], deadline) catch |err| {
                log.err("Failed to read CONNACK: {t}", .{err});
                return error.InvalidConnack;
            };
            if (message.data.len == 0) {
                log.err("Broker closed the connection before sending CONNACK", .{});
                return error.InvalidConnack;
            }
            have += message.data.len;
        }

        return interpretConnack(connack) catch |err| {
            log.err("MQTT handshake rejected: {t} (packet type {d}, return code {d})", .{
                err,
                connack[0] >> 4,
                connack[3],
            });
            return err;
        };
    }
};

/// Where Home Assistant looks for `sensor`'s discovery config.
fn discoveryTopic(buf: []u8, sensor: Sensor, node_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "homeassistant/{t}/{s}/{s}/config", .{ sensor.component, node_id, sensor.id });
}

/// Room for the largest discovery payload, with space for a long prefix.
const discovery_payload_max = 768;

const DiscoveryOptions = struct {
    node_id: []const u8,
    topic_prefix: []const u8,
    /// Seconds without a state update before Home Assistant shows the entity
    /// as unavailable.
    expire_after: u64,
};

/// How long a reading stays valid in Home Assistant: three publish intervals.
///
/// Without an expiry a Pi that is switched off, or a daemon that has stopped,
/// leaves every entity showing its last value indefinitely, which reads as a
/// healthy machine. Three intervals ride out a missed cycle or two.
fn expireAfterSeconds() u64 {
    return 3 * @as(u64, config.Config.interval_fast);
}

/// Build `sensor`'s discovery config as JSON.
///
/// The topic prefix comes from the environment and is escaped; every other
/// string is either a constant here or a node id, which `nodeId` restricts to
/// characters JSON leaves alone.
fn discoveryPayload(buf: []u8, sensor: Sensor, opts: DiscoveryOptions) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const w = &writer;

    var state_topic_buf: [320]u8 = undefined;
    const state_topic = try std.fmt.bufPrint(&state_topic_buf, "{s}/{s}", .{ opts.topic_prefix, sensor.id });

    try w.print("{{\"name\":\"{s}\"", .{sensor.name});
    try w.writeAll(",\"state_topic\":");
    try std.json.Stringify.encodeJsonString(state_topic, .{}, w);
    try w.print(",\"unique_id\":\"{s}_{s}\"", .{ opts.node_id, sensor.id });

    if (sensor.unit) |unit| try w.print(",\"unit_of_measurement\":\"{s}\"", .{unit});
    if (sensor.device_class) |dc| try w.print(",\"device_class\":\"{s}\"", .{dc});
    if (sensor.state_class) |sc| try w.print(",\"state_class\":\"{s}\"", .{sc});
    if (sensor.icon) |icon| try w.print(",\"icon\":\"{s}\"", .{icon});
    try w.print(",\"expire_after\":{d}", .{opts.expire_after});

    // The default device keeps the name it always had; any other gets its node
    // id appended, so two panels do not both appear as "SysInk".
    try w.print(",\"device\":{{\"identifiers\":[\"{s}\"],\"name\":\"SysInk", .{opts.node_id});
    if (!std.mem.eql(u8, opts.node_id, default_node_id)) try w.print(" {s}", .{opts.node_id});
    try w.writeAll(
        \\","manufacturer":"SysInk","model":"E-Paper Monitor"}}
    );

    return writer.buffered();
}

/// Validate a CONNACK packet and map its return code to an error.
fn interpretConnack(packet: [4]u8) !void {
    if (packet[0] >> 4 != @intFromEnum(MqttClient.PacketType.CONNACK)) return error.UnexpectedPacket;

    return switch (packet[3]) {
        0 => {},
        1 => error.UnacceptableProtocol,
        2 => error.IdentifierRejected,
        3 => error.ServerUnavailable,
        4 => error.BadCredentials,
        5 => error.NotAuthorized,
        else => error.ConnectionRefused,
    };
}

/// Encode MQTT's variable-length integer. Returns bytes written.
fn encodeRemainingLength(buf: []u8, length: usize) usize {
    var len = length;
    var pos: usize = 0;

    while (true) {
        var byte: u8 = @intCast(len % 128);
        len /= 128;
        if (len > 0) byte |= 0x80;
        buf[pos] = byte;
        pos += 1;
        if (len == 0) return pos;
    }
}

/// Write a length-prefixed UTF-8 string. Returns bytes written.
fn writeString(buf: []u8, str: []const u8) usize {
    std.mem.writeInt(u16, buf[0..2], @intCast(str.len), .big);
    @memcpy(buf[2..][0..str.len], str);
    return 2 + str.len;
}

/// Build a QoS 0 PUBLISH packet into `buf`.
fn buildPublish(buf: []u8, topic: []const u8, payload: []const u8, retain: bool) ![]const u8 {
    if (topic.len > std.math.maxInt(u16)) return error.TopicTooLong;

    const remaining_len = 2 + topic.len + payload.len;
    // Fixed header byte + up to 4 length bytes.
    if (5 + remaining_len > buf.len) return error.PayloadTooLarge;

    var pos: usize = 0;
    buf[pos] = (@as(u8, @intFromEnum(MqttClient.PacketType.PUBLISH)) << 4) | @intFromBool(retain);
    pos += 1;

    pos += encodeRemainingLength(buf[pos..], remaining_len);
    pos += writeString(buf[pos..], topic);

    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;

    return buf[0..pos];
}

/// Build a CONNECT packet into `buf`.
fn buildConnect(buf: []u8, client_id: []const u8, username: ?[]const u8, password: ?[]const u8) ![]const u8 {
    const protocol_name = "MQTT";
    const protocol_level: u8 = 4; // MQTT 3.1.1

    // Keep alive 0 disables the broker's inactivity timeout (MQTT-3.1.2-10).
    // This client only publishes and never reads, so it cannot answer PINGREQ
    // deadlines; with a nonzero keepalive the broker would silently drop us
    // whenever the publish interval exceeded it.
    const keepalive: u16 = 0;

    var connect_flags: u8 = 0x02; // Clean session
    if (username != null) connect_flags |= 0x80;
    if (password != null) connect_flags |= 0x40;

    var remaining_len: usize = 2 + protocol_name.len + 1 + 1 + 2 + 2 + client_id.len;
    if (username) |u| remaining_len += 2 + u.len;
    if (password) |p| remaining_len += 2 + p.len;

    if (5 + remaining_len > buf.len) return error.PacketTooLarge;

    var pos: usize = 0;
    buf[pos] = @as(u8, @intFromEnum(MqttClient.PacketType.CONNECT)) << 4;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], remaining_len);

    // Variable header
    pos += writeString(buf[pos..], protocol_name);
    buf[pos] = protocol_level;
    pos += 1;
    buf[pos] = connect_flags;
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], keepalive, .big);
    pos += 2;

    // Payload
    pos += writeString(buf[pos..], client_id);
    if (username) |u| pos += writeString(buf[pos..], u);
    if (password) |p| pos += writeString(buf[pos..], p);

    return buf[0..pos];
}

/// Resolve a hostname to its four IPv4 octets using libc getaddrinfo.
///
/// libc rather than std's resolver on purpose: it follows the system resolver
/// configuration, which is what makes `.local` names work in practice. Not via
/// NSS — nss-mdns is a glibc plugin mechanism that can never load into a
/// statically linked musl binary. musl reads /etc/resolv.conf and sends a plain
/// DNS query; on a stock Raspberry Pi OS that points at the systemd-resolved
/// stub (127.0.0.53), and *resolved* does the mDNS part server-side. Verified on
/// the target host rather than assumed. It is still an unbounded call —
/// getaddrinfo has internal timeouts but none we control.
fn resolveHost(host: []const u8) ![4]u8 {
    var host_buf: [256]u8 = undefined;
    const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{host}) catch return error.HostTooLong;

    var hints = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_INET;
    hints.ai_socktype = c.SOCK_STREAM;

    var result: ?*c.struct_addrinfo = null;
    if (c.getaddrinfo(host_z.ptr, null, &hints, &result) != 0) return error.DnsResolutionFailed;
    defer c.freeaddrinfo(result);

    const addr_info = result orelse return error.DnsResolutionFailed;
    const sin: *c.struct_sockaddr_in = @ptrCast(@alignCast(addr_info.ai_addr));

    // s_addr is already in network order, which is the octet order we want.
    return @bitCast(sin.sin_addr.s_addr);
}

/// MQTT configuration
pub const MqttConfig = struct {
    enabled: bool = false,
    host: []const u8 = "localhost",
    port: u16 = 1883,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    client_id: []const u8 = "sysink",
    topic_prefix: []const u8 = "sysink",
    discovery_enabled: bool = true,

    pub fn load(init: std.process.Init) MqttConfig {
        return fromEnv(init.environ_map);
    }

    pub fn fromEnv(env: *const std.process.Environ.Map) MqttConfig {
        var cfg = MqttConfig{};

        if (env.get("MQTT_ENABLED")) |val| cfg.enabled = config.parseBool(val);
        if (env.get("MQTT_HOST")) |val| cfg.host = val;
        if (env.get("MQTT_PORT")) |val| cfg.port = std.fmt.parseInt(u16, val, 10) catch cfg.port;
        if (env.get("MQTT_USERNAME")) |val| cfg.username = val;
        if (env.get("MQTT_PASSWORD")) |val| cfg.password = val;
        if (env.get("MQTT_CLIENT_ID")) |val| cfg.client_id = val;
        // Follows the client id unless set, so a second panel on the same broker
        // needs one variable changed rather than two. The defaults are equal, so
        // an existing setup keeps its topics.
        cfg.topic_prefix = env.get("MQTT_TOPIC_PREFIX") orelse cfg.client_id;
        if (env.get("MQTT_DISCOVERY")) |val| cfg.discovery_enabled = config.parseBool(val);

        return cfg;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "encodeRemainingLength matches the MQTT 3.1.1 examples" {
    var buf: [4]u8 = undefined;

    try testing.expectEqual(@as(usize, 1), encodeRemainingLength(&buf, 0));
    try testing.expectEqual(@as(u8, 0x00), buf[0]);

    try testing.expectEqual(@as(usize, 1), encodeRemainingLength(&buf, 127));
    try testing.expectEqual(@as(u8, 0x7F), buf[0]);

    try testing.expectEqual(@as(usize, 2), encodeRemainingLength(&buf, 128));
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf[0..2]);

    try testing.expectEqual(@as(usize, 2), encodeRemainingLength(&buf, 16_383));
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x7F }, buf[0..2]);

    try testing.expectEqual(@as(usize, 3), encodeRemainingLength(&buf, 16_384));
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, buf[0..3]);
}

test "buildPublish lays out a QoS 0 packet" {
    var buf: [64]u8 = undefined;
    const packet = try buildPublish(&buf, "a/b", "42", false);

    try testing.expectEqual(@as(u8, 0x30), packet[0]); // PUBLISH, no flags
    try testing.expectEqual(@as(u8, 7), packet[1]); // 2 + 3 + 2
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, packet[2..4], .big));
    try testing.expectEqualStrings("a/b", packet[4..7]);
    try testing.expectEqualStrings("42", packet[7..9]);
    try testing.expectEqual(@as(usize, 9), packet.len);
}

test "buildPublish sets the retain flag" {
    var buf: [64]u8 = undefined;
    const packet = try buildPublish(&buf, "t", "x", true);
    try testing.expectEqual(@as(u8, 0x31), packet[0]);
}

test "buildPublish refuses to overflow the buffer" {
    var buf: [16]u8 = undefined;
    const payload = "0123456789abcdef0123456789";
    try testing.expectError(error.PayloadTooLarge, buildPublish(&buf, "topic", payload, false));
}

test "buildConnect emits protocol name, level and clean session" {
    var buf: [128]u8 = undefined;
    const packet = try buildConnect(&buf, "sysink", null, null);

    try testing.expectEqual(@as(u8, 0x10), packet[0]); // CONNECT
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, packet[2..4], .big));
    try testing.expectEqualStrings("MQTT", packet[4..8]);
    try testing.expectEqual(@as(u8, 4), packet[8]); // protocol level 3.1.1
    try testing.expectEqual(@as(u8, 0x02), packet[9]); // clean session, no auth
    // Keep alive must be 0 so the broker never times this publish-only client out.
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, packet[10..12], .big));
    try testing.expectEqualStrings("sysink", packet[14..20]);
}

test "buildConnect sets the credential flags and payload" {
    var buf: [128]u8 = undefined;
    const packet = try buildConnect(&buf, "id", "user", "pass");

    try testing.expectEqual(@as(u8, 0xC2), packet[9]); // username|password|clean

    // client id "id", then "user", then "pass"
    try testing.expectEqualStrings("id", packet[14..16]);
    try testing.expectEqualStrings("user", packet[18..22]);
    try testing.expectEqualStrings("pass", packet[24..28]);
    try testing.expectEqual(@as(usize, 28), packet.len);
}

test "buildConnect rejects an oversized client id" {
    var buf: [32]u8 = undefined;
    const long_id = "x" ** 64;
    try testing.expectError(error.PacketTooLarge, buildConnect(&buf, long_id, null, null));
}

test "interpretConnack accepts success and maps refusals" {
    try interpretConnack(.{ 0x20, 0x02, 0x00, 0x00 });

    try testing.expectError(error.UnacceptableProtocol, interpretConnack(.{ 0x20, 0x02, 0x00, 1 }));
    try testing.expectError(error.IdentifierRejected, interpretConnack(.{ 0x20, 0x02, 0x00, 2 }));
    try testing.expectError(error.ServerUnavailable, interpretConnack(.{ 0x20, 0x02, 0x00, 3 }));
    try testing.expectError(error.BadCredentials, interpretConnack(.{ 0x20, 0x02, 0x00, 4 }));
    try testing.expectError(error.NotAuthorized, interpretConnack(.{ 0x20, 0x02, 0x00, 5 }));
    try testing.expectError(error.ConnectionRefused, interpretConnack(.{ 0x20, 0x02, 0x00, 99 }));
}

test "interpretConnack rejects a non-CONNACK packet" {
    // PUBLISH where CONNACK was expected.
    try testing.expectError(error.UnexpectedPacket, interpretConnack(.{ 0x30, 0x02, 0x00, 0x00 }));
}

test "publishing on a dropped connection does not reconnect behind the caller" {
    // `io` is left undefined on purpose: any attempt to resolve, connect or read
    // the clock would trip over it. Reconnecting is `connect`'s job only.
    var client = MqttClient.init(testing.allocator, undefined, .{});
    defer client.deinit();

    try testing.expectError(error.NotConnected, client.publish("cpu_load", "1", false));
    try testing.expectEqual(@as(u32, 0), client.consecutive_failures);
}

fn sensorById(id: []const u8) Sensor {
    for (sensors) |s| if (std.mem.eql(u8, s.id, id)) return s;
    unreachable;
}

test "the default client id keeps the discovery identity every release used" {
    // An existing installation must not see its entities duplicated.
    var buf: [max_node_id_len]u8 = undefined;
    const node_id = nodeId(&buf, "sysink");

    var topic_buf: [160]u8 = undefined;
    try testing.expectEqualStrings(
        "homeassistant/sensor/sysink/cpu_load/config",
        try discoveryTopic(&topic_buf, sensorById("cpu_load"), node_id),
    );

    var payload_buf: [discovery_payload_max]u8 = undefined;
    const payload = try discoveryPayload(&payload_buf, sensorById("cpu_load"), .{
        .node_id = node_id,
        .topic_prefix = "sysink",
        .expire_after = 90,
    });
    try testing.expect(std.mem.indexOf(u8, payload, "\"unique_id\":\"sysink_cpu_load\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"identifiers\":[\"sysink\"],\"name\":\"SysInk\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"state_topic\":\"sysink/cpu_load\"") != null);
}

test "a second device gets its own identity from its client id" {
    // Two panels on one broker used to publish the same discovery topics and
    // unique ids, so the second overwrote the first in Home Assistant.
    var buf: [max_node_id_len]u8 = undefined;
    const node_id = nodeId(&buf, "office.pi");
    try testing.expectEqualStrings("office_pi", node_id);

    var topic_buf: [160]u8 = undefined;
    try testing.expectEqualStrings(
        "homeassistant/binary_sensor/office_pi/internet/config",
        try discoveryTopic(&topic_buf, sensorById("internet"), node_id),
    );

    var payload_buf: [discovery_payload_max]u8 = undefined;
    const payload = try discoveryPayload(&payload_buf, sensorById("internet"), .{
        .node_id = node_id,
        .topic_prefix = "office.pi",
        .expire_after = 90,
    });
    try testing.expect(std.mem.indexOf(u8, payload, "\"unique_id\":\"office_pi_internet\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"SysInk office_pi\"") != null);
}

test "nodeId keeps only what a discovery topic accepts" {
    var buf: [max_node_id_len]u8 = undefined;
    try testing.expectEqualStrings("a-b_c", nodeId(&buf, "a-b_c"));
    try testing.expectEqualStrings("pi_4_home_", nodeId(&buf, "pi/4 home#"));
    try testing.expectEqualStrings(default_node_id, nodeId(&buf, ""));
    try testing.expectEqual(@as(usize, max_node_id_len), nodeId(&buf, "x" ** 100).len);
}

test "every discovery payload is valid JSON carrying expiry and state class" {
    var buf: [max_node_id_len]u8 = undefined;
    const node_id = nodeId(&buf, "sysink");

    for (sensors) |sensor| {
        var payload_buf: [discovery_payload_max]u8 = undefined;
        // A prefix with characters JSON must escape.
        const payload = try discoveryPayload(&payload_buf, sensor, .{
            .node_id = node_id,
            .topic_prefix = "odd\"prefix\\",
            .expire_after = 90,
        });

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        try testing.expectEqual(@as(i64, 90), obj.get("expire_after").?.integer);
        var expected_buf: [64]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected_buf, "odd\"prefix\\/{s}", .{sensor.id}),
            obj.get("state_topic").?.string,
        );
        if (sensor.state_class) |sc| {
            try testing.expectEqualStrings(sc, obj.get("state_class").?.string);
        } else {
            try testing.expect(obj.get("state_class") == null);
        }
    }
}

test "numeric sensors keep statistics and the rest do not" {
    for (sensors) |sensor| {
        const numeric = sensor.component == .sensor and !std.mem.eql(u8, sensor.id, "ip_address");
        try testing.expectEqual(numeric, sensor.state_class != null);
    }
}

test "the topic prefix follows the client id unless set" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expectEqualStrings("sysink", MqttConfig.fromEnv(&env).topic_prefix);

    try env.put("MQTT_CLIENT_ID", "office");
    try testing.expectEqualStrings("office", MqttConfig.fromEnv(&env).topic_prefix);

    try env.put("MQTT_TOPIC_PREFIX", "custom");
    try testing.expectEqualStrings("custom", MqttConfig.fromEnv(&env).topic_prefix);
}

test "sensor ids are unique" {
    for (sensors, 0..) |a, i| {
        for (sensors[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
    }
}
