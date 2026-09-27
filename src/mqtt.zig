const std = @import("std");
const config = @import("config.zig");
const bounded_connect = @import("bounded_connect.zig");
const net = std.Io.net;

const builtin = @import("builtin");

const c = @cImport({
    @cInclude("netdb.h");
    @cInclude("arpa/inet.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
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

/// Topic, under the topic prefix, that says whether the daemon is running.
///
/// The broker sets it to `offline` itself when the connection drops without a
/// DISCONNECT — a crash, SIGKILL, an OOM kill — and the daemon does so before a
/// clean one, so Home Assistant greys the device out at once instead of after
/// `expire_after`. A Pi that loses power closes nothing, and with keepalive off
/// the broker never notices; `expire_after` still covers that case.
const availability_suffix = "status";
/// Home Assistant's default availability payloads, so discovery need not name them.
const payload_online = "online";
const payload_offline = "offline";

fn availabilityTopic(buf: []u8, topic_prefix: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ topic_prefix, availability_suffix });
}

/// Topic, under the topic prefix, that notices are published to. See
/// `notice.parse` for what the payload may be.
const notify_suffix = "notify";

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
    /// Subscribe to the notice topic on every connect.
    notices_enabled: bool,
    notify_topic_buf: [256]u8 = undefined,
    notify_topic_len: usize = 0,
    /// Packets from the broker, reassembled.
    inbound: Inbound = .{},
    /// The latest notice received, kept past the read that found it.
    notice_buf: [Inbound.capacity]u8 = undefined,
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
    /// a broker that has silently vanished fills the send buffer before TCP
    /// gives up on it; an unbounded send would then freeze the render loop.
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
            .notices_enabled = cfg.notices_enabled,
        };
        if (std.fmt.bufPrint(&self.notify_topic_buf, "{s}/{s}", .{ cfg.topic_prefix, notify_suffix })) |topic| {
            self.notify_topic_len = topic.len;
        } else |_| {
            log.warn("MQTT_TOPIC_PREFIX too long; notices over MQTT disabled", .{});
            self.notices_enabled = false;
        }
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
        if (self.stream) |stream| detectDeadPeer(stream.socket.handle);

        self.inbound = .{};
        try self.handshake();

        self.connected = true;
        self.consecutive_failures = 0;
        log.info("Connected to MQTT broker", .{});

        // Retained, and ahead of discovery, so Home Assistant finds it the moment
        // it subscribes. Also overwrites the `offline` a previous run left behind.
        try self.publish(availability_suffix, payload_online, true);

        if (self.discovery_enabled) self.publishDiscovery();
        if (self.notices_enabled and self.connected) self.subscribeNotices();
    }

    fn notifyTopic(self: *const Self) []const u8 {
        return self.notify_topic_buf[0..self.notify_topic_len];
    }

    /// Clean session is set, so the subscription lasts as long as this
    /// connection and is made again on every connect.
    fn subscribeNotices(self: *Self) void {
        var packet_buf: [max_packet_len]u8 = undefined;
        const packet = buildSubscribe(&packet_buf, 1, self.notifyTopic()) catch return;
        self.sendPacket(packet) catch |err| {
            log.warn("MQTT subscribe failed: {t}", .{err});
            self.dropConnection();
            return;
        };
        log.info("Accepting notices on MQTT topic {s}", .{self.notifyTopic()});
    }

    /// Have the kernel notice a broker that vanished without closing the
    /// connection — powered off, or behind a network that dropped — within
    /// about a minute and a half, where TCP left alone takes a quarter of an
    /// hour. MQTT keepalive would do the same job, but it needs PINGREQs on a
    /// timer that this loop does not have.
    ///
    /// Matters because of the notice subscription: until the socket errors,
    /// the daemon waits on a connection nothing will ever arrive on. Once it
    /// does, poll reports it, `receive` drops the connection and the next
    /// publish cycle reconnects and subscribes afresh.
    ///
    /// Probes run while the connection is idle; unacknowledged data is capped
    /// by TCP_USER_TIMEOUT instead, since publishes every cycle keep it busy.
    fn detectDeadPeer(handle: net.Socket.Handle) void {
        if (builtin.os.tag != .linux) return;

        const options = [_]struct { level: c_int, name: c_int, value: c_int }{
            .{ .level = c.SOL_SOCKET, .name = c.SO_KEEPALIVE, .value = 1 },
            .{ .level = c.IPPROTO_TCP, .name = c.TCP_KEEPIDLE, .value = 60 },
            .{ .level = c.IPPROTO_TCP, .name = c.TCP_KEEPINTVL, .value = 10 },
            .{ .level = c.IPPROTO_TCP, .name = c.TCP_KEEPCNT, .value = 3 },
            .{ .level = c.IPPROTO_TCP, .name = c.TCP_USER_TIMEOUT, .value = 90_000 },
        };
        for (options) |opt| {
            if (c.setsockopt(handle, opt.level, opt.name, &opt.value, @sizeOf(c_int)) != 0) {
                log.debug("setsockopt({d}, {d}) failed; a vanished broker is noticed later", .{ opt.level, opt.name });
            }
        }
    }

    /// The socket to wait on for `receive`, while connected.
    pub fn socketHandle(self: *const Self) ?net.Socket.Handle {
        if (!self.connected) return null;
        const stream = self.stream orelse return null;
        return stream.socket.handle;
    }

    /// Read whatever the broker has sent, without waiting, and return the
    /// latest notice in it. Borrowed: valid until the next call.
    ///
    /// Notices a subscription turned up from the retained store are skipped:
    /// they were sent some time ago, perhaps long ago, and showing them again
    /// on every reconnect is not what anyone publishing one meant.
    pub fn receive(self: *Self) ?[]const u8 {
        var latest: ?usize = null;

        while (self.socketHandle()) |handle| {
            const space = self.inbound.free();
            const rc = c.recv(handle, space.ptr, space.len, c.MSG_DONTWAIT);
            if (rc < 0) {
                switch (std.posix.errno(rc)) {
                    .AGAIN => break,
                    .INTR => continue,
                    else => |err| {
                        log.warn("MQTT receive failed: {t}", .{err});
                        self.dropConnection();
                        break;
                    },
                }
            }
            if (rc == 0) {
                log.warn("MQTT broker closed the connection", .{});
                self.dropConnection();
                break;
            }
            self.inbound.commit(@intCast(rc));

            while (true) {
                const packet = (self.inbound.next() catch {
                    log.warn("Malformed packet from the MQTT broker", .{});
                    self.dropConnection();
                    break;
                }) orelse break;
                if (self.handlePacket(packet)) |len| latest = len;
            }
            if (self.inbound.dropped > 0) {
                log.warn("Ignored {d} MQTT message(s) too large to show", .{self.inbound.dropped});
                self.inbound.dropped = 0;
            }
        }

        return if (latest) |len| self.notice_buf[0..len] else null;
    }

    /// Act on one packet from the broker. Returns the length of a notice it
    /// copied into `notice_buf`, if it was one.
    fn handlePacket(self: *Self, packet: Packet) ?usize {
        switch (packet.kind()) {
            @intFromEnum(PacketType.PUBLISH) => {
                const message = parsePublish(packet) catch {
                    log.warn("Malformed PUBLISH from the MQTT broker", .{});
                    return null;
                };
                // Granted QoS 0 means the broker should not send QoS 1, but
                // one that does waits on the ack, and redelivers without it.
                if (message.qos == 1) self.sendPuback(message.packet_id.?);

                if (!std.mem.eql(u8, message.topic, self.notifyTopic())) return null;
                if (message.retain) {
                    log.info("Ignoring a retained notice on {s}", .{message.topic});
                    return null;
                }
                // What clearing a retained message (`mosquitto_pub -r -n`)
                // delivers to everyone subscribed: housekeeping, not a request
                // to take the notice on show down. That takes `{"text": ""}`.
                if (message.payload.len == 0) {
                    log.debug("Ignoring an empty message on {s}", .{message.topic});
                    return null;
                }
                @memcpy(self.notice_buf[0..message.payload.len], message.payload);
                return message.payload.len;
            },
            @intFromEnum(PacketType.SUBACK) => {
                // Packet id, then one return code per filter; 0x80 is refusal.
                if (packet.body.len >= 3 and packet.body[2] == 0x80) {
                    log.warn("MQTT broker refused the subscription to {s}; check its ACL", .{self.notifyTopic()});
                }
            },
            else => {},
        }
        return null;
    }

    fn sendPuback(self: *Self, packet_id: u16) void {
        var packet = [_]u8{ @as(u8, @intFromEnum(PacketType.PUBACK)) << 4, 0x02, 0, 0 };
        std.mem.writeInt(u16, packet[2..4], packet_id, .big);
        self.sendPacket(&packet) catch {};
    }

    /// Give up on the connection; `connect` makes a new one behind the backoff.
    fn dropConnection(self: *Self) void {
        self.connected = false;
        self.closeStream();
        // Counted like a failed connect, so a broker that accepts the
        // connection and then drops it is retried behind the backoff rather
        // than immediately.
        self.recordFailure();
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

        // A clean DISCONNECT makes the broker discard the will, so the daemon
        // has to say it is going away itself.
        self.publish(availability_suffix, payload_offline, true) catch {};

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
            self.dropConnection();
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

        if (self.connected) self.publishNotifyDiscovery() catch |err| {
            log.warn("Discovery publish failed for the notify entity: {t}", .{err});
        };
    }

    /// The notify entity while notices are accepted. Otherwise its config is
    /// cleared — an empty retained message removes a discovered entity — so
    /// turning notices off does not leave Home Assistant a button that does
    /// nothing.
    fn publishNotifyDiscovery(self: *Self) !void {
        var topic_buf: [160]u8 = undefined;
        const topic = try notifyDiscoveryTopic(&topic_buf, self.node());

        if (!self.notices_enabled) return self.publishRaw(topic, "", true);

        var payload_buf: [discovery_payload_max]u8 = undefined;
        const payload = try notifyDiscoveryPayload(&payload_buf, self.node(), self.topic_prefix);
        try self.publishRaw(topic, payload, true);
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
        var will_topic_buf: [256]u8 = undefined;
        const will: Will = .{
            .topic = availabilityTopic(&will_topic_buf, self.topic_prefix) catch return error.TopicTooLong,
            .payload = payload_offline,
        };

        var packet_buf: [max_packet_len]u8 = undefined;
        const packet = try buildConnect(&packet_buf, self.client_id, will, self.username, self.password);

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

    var availability_buf: [320]u8 = undefined;
    try w.writeAll(",\"availability_topic\":");
    try std.json.Stringify.encodeJsonString(try availabilityTopic(&availability_buf, opts.topic_prefix), .{}, w);

    if (sensor.unit) |unit| try w.print(",\"unit_of_measurement\":\"{s}\"", .{unit});
    if (sensor.device_class) |dc| try w.print(",\"device_class\":\"{s}\"", .{dc});
    if (sensor.state_class) |sc| try w.print(",\"state_class\":\"{s}\"", .{sc});
    if (sensor.icon) |icon| try w.print(",\"icon\":\"{s}\"", .{icon});
    try w.print(",\"expire_after\":{d}", .{opts.expire_after});
    try writeDevice(w, opts.node_id);

    return writer.buffered();
}

/// Close a discovery config with the device every entity belongs to.
fn writeDevice(w: *std.Io.Writer, node_id: []const u8) !void {
    // The default device keeps the name it always had; any other gets its node
    // id appended, so two panels do not both appear as "SysInk".
    try w.print(",\"device\":{{\"identifiers\":[\"{s}\"],\"name\":\"SysInk", .{node_id});
    if (!std.mem.eql(u8, node_id, default_node_id)) try w.print(" {s}", .{node_id});
    try w.writeAll(
        \\","manufacturer":"SysInk","model":"E-Paper Monitor"}}
    );
}

/// Object id of the notify entity, in its discovery topic and unique id.
const notify_object_id = "panel";

/// Where Home Assistant looks for the notify entity's discovery config.
fn notifyDiscoveryTopic(buf: []u8, node_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "homeassistant/notify/{s}/{s}/config", .{ node_id, notify_object_id });
}

/// Discovery config for a notify entity that sends to the notice topic, so
/// Home Assistant can put a notice on the panel with `notify.send_message`.
///
/// No expiry: it has no state to go stale. The message is published as it is,
/// which the daemon reads as plain text.
fn notifyDiscoveryPayload(buf: []u8, node_id: []const u8, topic_prefix: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const w = &writer;

    var command_topic_buf: [320]u8 = undefined;
    const command_topic = try std.fmt.bufPrint(&command_topic_buf, "{s}/{s}", .{ topic_prefix, notify_suffix });

    try w.writeAll("{\"name\":\"Panel\",\"command_topic\":");
    try std.json.Stringify.encodeJsonString(command_topic, .{}, w);
    try w.print(",\"unique_id\":\"{s}_{s}\"", .{ node_id, notify_object_id });

    var availability_buf: [320]u8 = undefined;
    try w.writeAll(",\"availability_topic\":");
    try std.json.Stringify.encodeJsonString(try availabilityTopic(&availability_buf, topic_prefix), .{}, w);

    try w.writeAll(",\"icon\":\"mdi:message-text\"");
    try writeDevice(w, node_id);

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

/// Build a SUBSCRIBE for one topic filter at QoS 0 into `buf`.
///
/// QoS 0 because a notice that arrives late is worse than one that does not
/// arrive: the broker then delivers at most once and never waits on an ack.
fn buildSubscribe(buf: []u8, packet_id: u16, topic: []const u8) ![]const u8 {
    if (topic.len > std.math.maxInt(u16)) return error.TopicTooLong;
    // Packet id, topic, requested QoS.
    const remaining_len = 2 + 2 + topic.len + 1;
    if (5 + remaining_len > buf.len) return error.PacketTooLarge;

    var pos: usize = 0;
    // MQTT-3.8.1-1: the reserved flags of SUBSCRIBE are 0b0010.
    buf[pos] = (@as(u8, @intFromEnum(MqttClient.PacketType.SUBSCRIBE)) << 4) | 0x02;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], remaining_len);
    std.mem.writeInt(u16, buf[pos..][0..2], packet_id, .big);
    pos += 2;
    pos += writeString(buf[pos..], topic);
    buf[pos] = 0; // QoS 0
    pos += 1;
    return buf[0..pos];
}

/// One whole packet from the broker. `body` is everything after the fixed
/// header and is borrowed from the `Inbound` it came from.
const Packet = struct {
    header: u8,
    body: []const u8,

    fn kind(self: Packet) u4 {
        return @intCast(self.header >> 4);
    }
};

/// Reassembles packets from the byte stream the broker sends.
///
/// TCP delivers bytes, not packets: one read can end mid-packet or hold
/// several. Bytes go in through `free` and `commit`, whole packets come out of
/// `next`. A packet larger than the buffer is skipped rather than failing the
/// connection, since the only large thing anyone would send here is a notice
/// far too long to show anyway.
const Inbound = struct {
    buf: [capacity]u8 = undefined,
    len: usize = 0,
    /// Start of the bytes `next` has not yet returned.
    start: usize = 0,
    /// Bytes still to come of a packet too large to hold, to be thrown away.
    skip: usize = 0,
    /// Packets thrown away for their size, for the caller to report.
    dropped: u32 = 0,

    const capacity = 2048;

    /// Room to receive into, after the packets already returned are dropped.
    fn free(self: *Inbound) []u8 {
        const pending = self.len - self.start;
        std.mem.copyForwards(u8, self.buf[0..pending], self.buf[self.start..self.len]);
        self.len = pending;
        self.start = 0;
        return self.buf[self.len..];
    }

    /// Account for `n` bytes received into the slice `free` returned.
    fn commit(self: *Inbound, n: usize) void {
        const discard = @min(self.skip, n);
        self.skip -= discard;
        const received = self.buf[self.len..][0..n];
        std.mem.copyForwards(u8, received[0 .. n - discard], received[discard..n]);
        self.len += n - discard;
    }

    /// The next whole packet, or null until more bytes arrive.
    fn next(self: *Inbound) error{MalformedPacket}!?Packet {
        while (true) {
            const avail = self.buf[self.start..self.len];

            // Remaining length: one to four bytes of seven bits each, least
            // significant first (MQTT-2.2.3).
            var remaining: usize = 0;
            var i: usize = 1;
            while (true) : (i += 1) {
                if (i > 4) return error.MalformedPacket;
                if (i >= avail.len) return null;
                remaining |= @as(usize, avail[i] & 0x7F) << @intCast(7 * (i - 1));
                if (avail[i] & 0x80 == 0) break;
            }
            const header_len = i + 1;
            const total = header_len + remaining;

            if (total > capacity) {
                self.skip = total - avail.len;
                self.start = self.len;
                self.dropped +|= 1;
                continue;
            }
            if (avail.len < total) return null;

            self.start += total;
            return .{ .header = avail[0], .body = avail[header_len..total] };
        }
    }
};

const Publish = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    /// Set by the broker on a retained message delivered because we just
    /// subscribed — a message from the past rather than one sent now.
    retain: bool,
    packet_id: ?u16,
};

/// Take apart the variable header and payload of a PUBLISH.
fn parsePublish(packet: Packet) !Publish {
    const body = packet.body;
    if (body.len < 2) return error.MalformedPacket;
    const topic_len = std.mem.readInt(u16, body[0..2], .big);
    if (body.len < 2 + topic_len) return error.MalformedPacket;

    const qos: u2 = @intCast((packet.header >> 1) & 0x03);
    var pos: usize = 2 + topic_len;
    var packet_id: ?u16 = null;
    if (qos > 0) {
        if (body.len < pos + 2) return error.MalformedPacket;
        packet_id = std.mem.readInt(u16, body[pos..][0..2], .big);
        pos += 2;
    }

    return .{
        .topic = body[2..][0..topic_len],
        .payload = body[pos..],
        .qos = qos,
        .retain = packet.header & 0x01 != 0,
        .packet_id = packet_id,
    };
}

/// Last Will: what the broker publishes for us if the connection is lost.
const Will = struct {
    topic: []const u8,
    payload: []const u8,
    /// Retained, so a Home Assistant that restarts later still sees it.
    retain: bool = true,
};

/// Build a CONNECT packet into `buf`.
fn buildConnect(buf: []u8, client_id: []const u8, will: ?Will, username: ?[]const u8, password: ?[]const u8) ![]const u8 {
    const protocol_name = "MQTT";
    const protocol_level: u8 = 4; // MQTT 3.1.1

    // Keep alive 0 disables the broker's inactivity timeout (MQTT-3.1.2-10).
    // Nothing here sends PINGREQ, so with a nonzero keepalive the broker would
    // drop us whenever the publish interval exceeded it. A broker that goes
    // away is noticed by TCP keepalive instead (see `detectDeadPeer`), and
    // the notice subscription is made again on the reconnect that follows.
    const keepalive: u16 = 0;

    var connect_flags: u8 = 0x02; // Clean session
    if (will) |wl| {
        connect_flags |= 0x04; // Will flag, QoS 0
        if (wl.retain) connect_flags |= 0x20;
    }
    if (username != null) connect_flags |= 0x80;
    if (password != null) connect_flags |= 0x40;

    var remaining_len: usize = 2 + protocol_name.len + 1 + 1 + 2 + 2 + client_id.len;
    if (will) |wl| remaining_len += 2 + wl.topic.len + 2 + wl.payload.len;
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
    // MQTT-3.1.3-1: will topic and message come between client id and username.
    if (will) |wl| {
        pos += writeString(buf[pos..], wl.topic);
        pos += writeString(buf[pos..], wl.payload);
    }
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
    /// Set from `NOTIFY_ENABLED` by the caller, which owns that setting.
    notices_enabled: bool = true,

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
    const packet = try buildConnect(&buf, "sysink", null, null, null);

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
    const packet = try buildConnect(&buf, "id", null, "user", "pass");

    try testing.expectEqual(@as(u8, 0xC2), packet[9]); // username|password|clean

    // client id "id", then "user", then "pass"
    try testing.expectEqualStrings("id", packet[14..16]);
    try testing.expectEqualStrings("user", packet[18..22]);
    try testing.expectEqualStrings("pass", packet[24..28]);
    try testing.expectEqual(@as(usize, 28), packet.len);
}

test "buildConnect places the will between client id and credentials" {
    var buf: [128]u8 = undefined;
    const packet = try buildConnect(&buf, "id", .{ .topic = "p/status", .payload = "offline" }, "user", "pass");

    try testing.expectEqual(@as(u8, 0xE6), packet[9]); // username|password|will retain|will|clean

    try testing.expectEqualStrings("id", packet[14..16]);
    try testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, packet[16..18], .big));
    try testing.expectEqualStrings("p/status", packet[18..26]);
    try testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, packet[26..28], .big));
    try testing.expectEqualStrings("offline", packet[28..35]);
    try testing.expectEqualStrings("user", packet[37..41]);
    try testing.expectEqualStrings("pass", packet[43..47]);
    try testing.expectEqual(@as(usize, 47), packet.len);
    try testing.expectEqual(@as(u8, 45), packet[1]); // remaining length
}

test "buildConnect rejects an oversized client id" {
    var buf: [32]u8 = undefined;
    const long_id = "x" ** 64;
    try testing.expectError(error.PacketTooLarge, buildConnect(&buf, long_id, null, null, null));
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
        try testing.expectEqualStrings("odd\"prefix\\/status", obj.get("availability_topic").?.string);
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

test "discovery fits the packet with a long topic prefix" {
    var buf: [max_node_id_len]u8 = undefined;
    const node_id = nodeId(&buf, "x" ** 100);
    const prefix = "p" ** 100;

    for (sensors) |sensor| {
        var topic_buf: [160]u8 = undefined;
        const topic = try discoveryTopic(&topic_buf, sensor, node_id);
        var payload_buf: [discovery_payload_max]u8 = undefined;
        const payload = try discoveryPayload(&payload_buf, sensor, .{
            .node_id = node_id,
            .topic_prefix = prefix,
            .expire_after = 90,
        });
        var packet_buf: [MqttClient.max_packet_len]u8 = undefined;
        _ = try buildPublish(&packet_buf, topic, payload, true);
    }
}

test "the notify entity sends to the notice topic and belongs to the device" {
    var buf: [max_node_id_len]u8 = undefined;
    const node_id = nodeId(&buf, "sysink");

    var topic_buf: [160]u8 = undefined;
    try testing.expectEqualStrings(
        "homeassistant/notify/sysink/panel/config",
        try notifyDiscoveryTopic(&topic_buf, node_id),
    );

    var payload_buf: [discovery_payload_max]u8 = undefined;
    const payload = try notifyDiscoveryPayload(&payload_buf, node_id, "odd\"prefix\\");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("odd\"prefix\\/notify", obj.get("command_topic").?.string);
    try testing.expectEqualStrings("odd\"prefix\\/status", obj.get("availability_topic").?.string);
    try testing.expectEqualStrings("sysink_panel", obj.get("unique_id").?.string);
    try testing.expect(obj.get("expire_after") == null);
    try testing.expect(obj.get("state_topic") == null);
    try testing.expectEqualStrings("sysink", obj.get("device").?.object.get("identifiers").?.array.items[0].string);
}

test "the notify discovery fits the packet with a long topic prefix" {
    var buf: [max_node_id_len]u8 = undefined;
    const node_id = nodeId(&buf, "x" ** 100);

    var topic_buf: [160]u8 = undefined;
    const topic = try notifyDiscoveryTopic(&topic_buf, node_id);
    var payload_buf: [discovery_payload_max]u8 = undefined;
    const payload = try notifyDiscoveryPayload(&payload_buf, node_id, "p" ** 100);
    var packet_buf: [MqttClient.max_packet_len]u8 = undefined;
    _ = try buildPublish(&packet_buf, topic, payload, true);
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
        // A sensor there would share its state topic with the availability one.
        try testing.expect(!std.mem.eql(u8, a.id, availability_suffix));
        for (sensors[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
    }
}

test "buildSubscribe lays out one QoS 0 filter" {
    var buf: [64]u8 = undefined;
    const packet = try buildSubscribe(&buf, 1, "a/b");
    try testing.expectEqualSlices(u8, &.{
        0x82, 0x08, // SUBSCRIBE with its mandatory flags, remaining length 8
        0x00, 0x01, // packet id
        0x00, 0x03, 'a', '/', 'b', // topic filter
        0x00, // requested QoS
    }, packet);
}

/// Append one PUBLISH to the notice topic of the default prefix.
fn notifyPacket(buf: []u8, payload: []const u8, retain: bool) ![]const u8 {
    return buildPublish(buf, "sysink/notify", payload, retain);
}

test "Inbound returns packets however the stream splits them" {
    var pkt_buf: [128]u8 = undefined;
    const one = try notifyPacket(&pkt_buf, "hello", false);

    // Two packets back to back, delivered a byte at a time.
    var stream: [256]u8 = undefined;
    @memcpy(stream[0..one.len], one);
    @memcpy(stream[one.len..][0..one.len], one);
    const bytes = stream[0 .. 2 * one.len];

    var in: Inbound = .{};
    var seen: usize = 0;
    for (bytes) |b| {
        const space = in.free();
        space[0] = b;
        in.commit(1);
        while (try in.next()) |packet| {
            const message = try parsePublish(packet);
            try testing.expectEqualStrings("hello", message.payload);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "Inbound skips a packet too large to hold and carries on" {
    var in: Inbound = .{};

    // A PUBLISH claiming 3000 bytes of body, then a small one after it.
    const big_len = 3000;
    var big: [3 + big_len]u8 = @splat('x');
    big[0] = 0x30;
    _ = encodeRemainingLength(big[1..3], big_len);

    var pkt_buf: [128]u8 = undefined;
    const small = try notifyPacket(&pkt_buf, "after", false);

    var feed: [big.len + 128]u8 = undefined;
    @memcpy(feed[0..big.len], &big);
    @memcpy(feed[big.len..][0..small.len], small);
    var rest: []const u8 = feed[0 .. big.len + small.len];

    var got: ?[]const u8 = null;
    while (rest.len > 0) {
        const space = in.free();
        const n = @min(space.len, rest.len, 500);
        @memcpy(space[0..n], rest[0..n]);
        in.commit(n);
        rest = rest[n..];
        while (try in.next()) |packet| got = (try parsePublish(packet)).payload;
    }

    try testing.expectEqualStrings("after", got.?);
    try testing.expectEqual(@as(u32, 1), in.dropped);
}

test "Inbound rejects a remaining length longer than four bytes" {
    var in: Inbound = .{};
    const garbage = [_]u8{ 0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    @memcpy(in.free()[0..garbage.len], &garbage);
    in.commit(garbage.len);
    try testing.expectError(error.MalformedPacket, in.next());
}

test "parsePublish reads QoS, retain and the packet id" {
    // QoS 1, retained: topic "t", packet id 7, payload "hi".
    const body = [_]u8{ 0x00, 0x01, 't', 0x00, 0x07, 'h', 'i' };
    const message = try parsePublish(.{ .header = 0x33, .body = &body });
    try testing.expectEqualStrings("t", message.topic);
    try testing.expectEqualStrings("hi", message.payload);
    try testing.expectEqual(@as(u2, 1), message.qos);
    try testing.expect(message.retain);
    try testing.expectEqual(@as(?u16, 7), message.packet_id);

    try testing.expectError(error.MalformedPacket, parsePublish(.{ .header = 0x30, .body = &.{ 0x00, 0x09, 't' } }));
}

/// A client whose connection is one end of a socket pair, the other end
/// standing in for the broker.
const LoopbackClient = struct {
    client: MqttClient,
    broker: c_int,

    fn init() !LoopbackClient {
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return error.SocketPairFailed;

        var self: LoopbackClient = .{
            .client = MqttClient.init(testing.allocator, testing.io, .{}),
            .broker = fds[1],
        };
        self.client.stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .loopback(0) } } };
        self.client.connected = true;
        return self;
    }

    fn deinit(self: *LoopbackClient) void {
        // No DISCONNECT: nothing reads it, and a full buffer would block.
        self.client.connected = false;
        self.client.deinit();
        _ = std.c.close(self.broker);
    }

    fn send(self: *LoopbackClient, bytes: []const u8) !void {
        if (std.c.write(self.broker, bytes.ptr, bytes.len) != bytes.len) return error.WriteFailed;
    }
};

test "a notice published to the topic is received" {
    var lb = try LoopbackClient.init();
    defer lb.deinit();

    try testing.expect(lb.client.receive() == null);

    var pkt_buf: [128]u8 = undefined;
    try lb.send(try notifyPacket(&pkt_buf, "first", false));
    try lb.send(try notifyPacket(&pkt_buf, "second", false));
    try lb.send(try buildPublish(&pkt_buf, "sysink/other", "not a notice", false));

    // Several at once: the latest is the one shown.
    try testing.expectEqualStrings("second", lb.client.receive().?);
    try testing.expect(lb.client.connected);
}

test "a retained notice from before the subscription is not shown" {
    var lb = try LoopbackClient.init();
    defer lb.deinit();

    var pkt_buf: [128]u8 = undefined;
    try lb.send(try notifyPacket(&pkt_buf, "stale", true));
    try testing.expect(lb.client.receive() == null);
}

test "an empty message, as clearing a retained notice sends, is not a notice" {
    var lb = try LoopbackClient.init();
    defer lb.deinit();

    var pkt_buf: [128]u8 = undefined;
    try lb.send(try notifyPacket(&pkt_buf, "", false));
    try testing.expect(lb.client.receive() == null);

    // An explicit dismissal still gets through.
    try lb.send(try notifyPacket(&pkt_buf, "{\"text\": \"\"}", false));
    try testing.expectEqualStrings("{\"text\": \"\"}", lb.client.receive().?);
}

test "the broker closing the connection is noticed" {
    var lb = try LoopbackClient.init();
    defer lb.deinit();

    // The warning is expected; keep it out of the test output.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;

    _ = std.c.close(lb.broker);
    lb.broker = -1;
    try testing.expect(lb.client.receive() == null);
    try testing.expect(!lb.client.connected);
    try testing.expect(lb.client.socketHandle() == null);
}
