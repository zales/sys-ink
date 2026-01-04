const std = @import("std");
const net = std.net;

const log = std.log.scoped(.mqtt);

/// Simple MQTT 3.1.1 client for Home Assistant integration
pub const MqttClient = struct {
    allocator: std.mem.Allocator,
    stream: ?net.Stream = null,
    host: []const u8,
    port: u16,
    client_id: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    topic_prefix: []const u8,
    connected: bool = false,

    const Self = @This();

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
        host: []const u8,
        port: u16,
        client_id: []const u8,
        username: ?[]const u8,
        password: ?[]const u8,
        topic_prefix: []const u8,
    ) Self {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .client_id = client_id,
            .username = username,
            .password = password,
            .topic_prefix = topic_prefix,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
    }

    /// Connect to MQTT broker
    pub fn connect(self: *Self) !void {
        if (self.connected) return;

        log.info("Connecting to MQTT broker {s}:{d}", .{ self.host, self.port });

        // Connect with automatic DNS resolution
        self.stream = net.tcpConnectToHost(self.allocator, self.host, self.port) catch |err| {
            log.err("Failed to connect to MQTT broker {s}:{d}: {}", .{ self.host, self.port, err });
            return err;
        };

        // Send CONNECT packet
        try self.sendConnect();

        // Wait for CONNACK
        try self.receiveConnack();

        self.connected = true;
        log.info("Connected to MQTT broker", .{});
    }

    /// Disconnect from MQTT broker
    pub fn disconnect(self: *Self) void {
        if (!self.connected) return;

        if (self.stream) |stream| {
            // Send DISCONNECT packet
            const disconnect_packet = [_]u8{ 0xE0, 0x00 }; // DISCONNECT with 0 remaining length
            stream.writeAll(&disconnect_packet) catch {};
            stream.close();
        }

        self.stream = null;
        self.connected = false;
        log.info("Disconnected from MQTT broker", .{});
    }

    /// Publish a message to a topic
    pub fn publish(self: *Self, topic: []const u8, payload: []const u8, retain: bool) !void {
        if (!self.connected) {
            try self.connect();
        }

        const stream = self.stream orelse return error.NotConnected;

        // Build full topic with prefix
        var full_topic_buf: [256]u8 = undefined;
        const full_topic = std.fmt.bufPrint(&full_topic_buf, "{s}/{s}", .{ self.topic_prefix, topic }) catch {
            log.err("Topic too long", .{});
            return error.TopicTooLong;
        };

        // Calculate remaining length
        const topic_len: u16 = @intCast(full_topic.len);
        const remaining_len = 2 + full_topic.len + payload.len;

        if (remaining_len > 268435455) return error.PayloadTooLarge;

        // Build packet
        var packet_buf: [512]u8 = undefined;
        var pos: usize = 0;

        // Fixed header
        const flags: u8 = if (retain) 0x01 else 0x00;
        packet_buf[pos] = (@as(u8, @intFromEnum(PacketType.PUBLISH)) << 4) | flags;
        pos += 1;

        // Remaining length (variable length encoding)
        pos += encodeRemainingLength(packet_buf[pos..], remaining_len);

        // Topic length (MSB, LSB)
        packet_buf[pos] = @intCast(topic_len >> 8);
        packet_buf[pos + 1] = @intCast(topic_len & 0xFF);
        pos += 2;

        // Topic
        @memcpy(packet_buf[pos..][0..full_topic.len], full_topic);
        pos += full_topic.len;

        // Payload
        if (pos + payload.len > packet_buf.len) return error.PayloadTooLarge;
        @memcpy(packet_buf[pos..][0..payload.len], payload);
        pos += payload.len;

        // Send
        stream.writeAll(packet_buf[0..pos]) catch |err| {
            log.warn("Failed to publish: {}", .{err});
            self.connected = false;
            return err;
        };
    }

    /// Publish Home Assistant auto-discovery config for a sensor
    pub fn publishHADiscovery(
        self: *Self,
        sensor_id: []const u8,
        name: []const u8,
        unit: ?[]const u8,
        device_class: ?[]const u8,
        icon: ?[]const u8,
    ) !void {
        var topic_buf: [128]u8 = undefined;
        const discovery_topic = std.fmt.bufPrint(&topic_buf, "homeassistant/sensor/sysink/{s}/config", .{sensor_id}) catch return;

        var payload_buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&payload_buf);
        const writer = stream.writer();

        try writer.writeAll("{");
        try writer.print("\"name\":\"{s}\"", .{name});
        try writer.print(",\"state_topic\":\"{s}/{s}\"", .{ self.topic_prefix, sensor_id });
        try writer.print(",\"unique_id\":\"sysink_{s}\"", .{sensor_id});

        if (unit) |u| {
            try writer.print(",\"unit_of_measurement\":\"{s}\"", .{u});
        }
        if (device_class) |dc| {
            try writer.print(",\"device_class\":\"{s}\"", .{dc});
        }
        if (icon) |ic| {
            try writer.print(",\"icon\":\"{s}\"", .{ic});
        }

        // Device info
        try writer.writeAll(",\"device\":{");
        try writer.writeAll("\"identifiers\":[\"sysink\"],");
        try writer.writeAll("\"name\":\"SysInk\",");
        try writer.writeAll("\"manufacturer\":\"SysInk\",");
        try writer.writeAll("\"model\":\"E-Paper Monitor\"");
        try writer.writeAll("}}");

        const payload = stream.getWritten();

        // Publish directly without prefix for discovery topic
        try self.publishRaw(discovery_topic, payload, true);
    }

    /// Publish to exact topic (no prefix)
    fn publishRaw(self: *Self, topic: []const u8, payload: []const u8, retain: bool) !void {
        if (!self.connected) {
            try self.connect();
        }

        const stream = self.stream orelse return error.NotConnected;

        const topic_len: u16 = @intCast(topic.len);
        const remaining_len = 2 + topic.len + payload.len;

        if (remaining_len > 268435455) return error.PayloadTooLarge;

        var packet_buf: [1024]u8 = undefined;
        var pos: usize = 0;

        const flags: u8 = if (retain) 0x01 else 0x00;
        packet_buf[pos] = (@as(u8, @intFromEnum(PacketType.PUBLISH)) << 4) | flags;
        pos += 1;

        pos += encodeRemainingLength(packet_buf[pos..], remaining_len);

        packet_buf[pos] = @intCast(topic_len >> 8);
        packet_buf[pos + 1] = @intCast(topic_len & 0xFF);
        pos += 2;

        @memcpy(packet_buf[pos..][0..topic.len], topic);
        pos += topic.len;

        if (pos + payload.len > packet_buf.len) return error.PayloadTooLarge;
        @memcpy(packet_buf[pos..][0..payload.len], payload);
        pos += payload.len;

        stream.writeAll(packet_buf[0..pos]) catch |err| {
            log.warn("Failed to publish: {}", .{err});
            self.connected = false;
            return err;
        };
    }

    /// Send MQTT ping to keep connection alive
    pub fn ping(self: *Self) !void {
        if (!self.connected) return;

        const stream = self.stream orelse return error.NotConnected;
        const ping_packet = [_]u8{ 0xC0, 0x00 }; // PINGREQ
        stream.writeAll(&ping_packet) catch |err| {
            log.warn("Ping failed: {}", .{err});
            self.connected = false;
            return err;
        };
    }

    fn sendConnect(self: *Self) !void {
        const stream = self.stream orelse return error.NotConnected;

        // Calculate variable header + payload length
        const protocol_name = "MQTT";
        const protocol_level: u8 = 4; // MQTT 3.1.1

        var connect_flags: u8 = 0x02; // Clean session
        if (self.username != null) connect_flags |= 0x80;
        if (self.password != null) connect_flags |= 0x40;

        const keepalive: u16 = 60;

        // Calculate remaining length
        var remaining_len: usize = 0;
        remaining_len += 2 + protocol_name.len; // Protocol name
        remaining_len += 1; // Protocol level
        remaining_len += 1; // Connect flags
        remaining_len += 2; // Keepalive
        remaining_len += 2 + self.client_id.len; // Client ID

        if (self.username) |u| {
            remaining_len += 2 + u.len;
        }
        if (self.password) |p| {
            remaining_len += 2 + p.len;
        }

        // Build packet
        var packet_buf: [256]u8 = undefined;
        var pos: usize = 0;

        // Fixed header
        packet_buf[pos] = @as(u8, @intFromEnum(PacketType.CONNECT)) << 4;
        pos += 1;
        pos += encodeRemainingLength(packet_buf[pos..], remaining_len);

        // Variable header
        // Protocol name
        packet_buf[pos] = 0;
        packet_buf[pos + 1] = @intCast(protocol_name.len);
        pos += 2;
        @memcpy(packet_buf[pos..][0..protocol_name.len], protocol_name);
        pos += protocol_name.len;

        // Protocol level
        packet_buf[pos] = protocol_level;
        pos += 1;

        // Connect flags
        packet_buf[pos] = connect_flags;
        pos += 1;

        // Keepalive
        packet_buf[pos] = @intCast(keepalive >> 8);
        packet_buf[pos + 1] = @intCast(keepalive & 0xFF);
        pos += 2;

        // Payload
        // Client ID
        const client_id_len: u16 = @intCast(self.client_id.len);
        packet_buf[pos] = @intCast(client_id_len >> 8);
        packet_buf[pos + 1] = @intCast(client_id_len & 0xFF);
        pos += 2;
        @memcpy(packet_buf[pos..][0..self.client_id.len], self.client_id);
        pos += self.client_id.len;

        // Username
        if (self.username) |username| {
            const username_len: u16 = @intCast(username.len);
            packet_buf[pos] = @intCast(username_len >> 8);
            packet_buf[pos + 1] = @intCast(username_len & 0xFF);
            pos += 2;
            @memcpy(packet_buf[pos..][0..username.len], username);
            pos += username.len;
        }

        // Password
        if (self.password) |password| {
            const password_len: u16 = @intCast(password.len);
            packet_buf[pos] = @intCast(password_len >> 8);
            packet_buf[pos + 1] = @intCast(password_len & 0xFF);
            pos += 2;
            @memcpy(packet_buf[pos..][0..password.len], password);
            pos += password.len;
        }

        try stream.writeAll(packet_buf[0..pos]);
    }

    fn receiveConnack(self: *Self) !void {
        const stream = self.stream orelse return error.NotConnected;

        var buf: [4]u8 = undefined;
        const bytes_read = stream.read(&buf) catch |err| {
            log.err("Failed to read CONNACK: {}", .{err});
            return err;
        };

        if (bytes_read < 4) {
            log.err("CONNACK too short: {} bytes", .{bytes_read});
            return error.InvalidConnack;
        }

        const packet_type = buf[0] >> 4;
        if (packet_type != @intFromEnum(PacketType.CONNACK)) {
            log.err("Expected CONNACK, got packet type {}", .{packet_type});
            return error.UnexpectedPacket;
        }

        const return_code = buf[3];
        if (return_code != 0) {
            log.err("CONNACK error: {}", .{return_code});
            return switch (return_code) {
                1 => error.UnacceptableProtocol,
                2 => error.IdentifierRejected,
                3 => error.ServerUnavailable,
                4 => error.BadCredentials,
                5 => error.NotAuthorized,
                else => error.ConnectionRefused,
            };
        }
    }

    fn encodeRemainingLength(buf: []u8, length: usize) usize {
        var len = length;
        var pos: usize = 0;

        while (true) {
            var encoded_byte: u8 = @intCast(len % 128);
            len = len / 128;
            if (len > 0) {
                encoded_byte |= 0x80;
            }
            buf[pos] = encoded_byte;
            pos += 1;
            if (len == 0) break;
        }

        return pos;
    }
};

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

    pub fn load() MqttConfig {
        var cfg = MqttConfig{};

        if (std.posix.getenv("MQTT_ENABLED")) |val| {
            cfg.enabled = std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
        }
        if (std.posix.getenv("MQTT_HOST")) |val| {
            cfg.host = val;
        }
        if (std.posix.getenv("MQTT_PORT")) |val| {
            cfg.port = std.fmt.parseInt(u16, val, 10) catch 1883;
        }
        if (std.posix.getenv("MQTT_USERNAME")) |val| {
            cfg.username = val;
        }
        if (std.posix.getenv("MQTT_PASSWORD")) |val| {
            cfg.password = val;
        }
        if (std.posix.getenv("MQTT_CLIENT_ID")) |val| {
            cfg.client_id = val;
        }
        if (std.posix.getenv("MQTT_TOPIC_PREFIX")) |val| {
            cfg.topic_prefix = val;
        }
        if (std.posix.getenv("MQTT_DISCOVERY")) |val| {
            cfg.discovery_enabled = std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
        }

        return cfg;
    }
};
