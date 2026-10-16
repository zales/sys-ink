//! WebSocket (RFC 6455), the client's half, free of I/O.
//!
//! Spotify pushes what is playing over a WebSocket, so the daemon needs a
//! client for one, and std has none. This is the protocol alone: the opening
//! handshake, and frames going out and coming in, written to an
//! `std.Io.Writer` and read from an `std.Io.Reader`. What carries them is the
//! caller's business, which lets the tests here run on fixed buffers.
//!
//! Only what a client needs is here. Every frame it sends is final and
//! masked, as the RFC has a client's be; frames coming in may be fragmented,
//! and are joined into the message they make up.

const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    fn isControl(op: Opcode) bool {
        return @backingInt(op) >= 0x8;
    }
};

/// The value of `Sec-WebSocket-Key` for 16 random bytes.
pub fn makeKey(random: [16]u8) [24]u8 {
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &random);
    return key;
}

/// What a server answers `key` with in `Sec-WebSocket-Accept`.
pub fn acceptFor(key: []const u8) [28]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

/// The request that asks `host` to upgrade the connection to a WebSocket for
/// `target`, the path and query.
pub fn writeHandshake(w: *std.Io.Writer, host: []const u8, target: []const u8, key: []const u8) std.Io.Writer.Error!void {
    try w.print(
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ target, host, key },
    );
}

pub const HandshakeError = error{
    /// The server answered, but not by switching protocols.
    Refused,
    /// It switched, but did not prove it read the key.
    BadAccept,
};

/// Whether the response head `head` completes the handshake begun with `key`:
/// 101, and the key's accept value.
pub fn checkHandshake(status: std.http.Status, head: []const u8, key: []const u8) HandshakeError!void {
    if (status != .switching_protocols) return error.Refused;
    const expected = acceptFor(key);
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, value, &expected)) return;
        return error.BadAccept;
    }
    return error.BadAccept;
}

/// Write one final frame of `payload`, masked with `mask`.
pub fn writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8, mask: [4]u8) std.Io.Writer.Error!void {
    var header: [14]u8 = undefined;
    header[0] = 0x80 | @as(u8, @backingInt(opcode));
    var len: usize = 2;
    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        len = 10;
    }
    @memcpy(header[len..][0..4], &mask);
    len += 4;
    try w.writeAll(header[0..len]);

    // Masked a chunk at a time, so the payload itself is left as it was.
    var chunk: [256]u8 = undefined;
    var done: usize = 0;
    while (done < payload.len) {
        const n = @min(chunk.len, payload.len - done);
        for (chunk[0..n], payload[done..][0..n], done..) |*out, byte, i| out.* = byte ^ mask[i % 4];
        try w.writeAll(chunk[0..n]);
        done += n;
    }
}

pub const Message = struct {
    opcode: Opcode,
    /// Borrowed from the receiver: valid until it is asked for the next.
    payload: []const u8,
};

pub const ReadError = std.Io.Reader.Error || error{
    /// A frame the RFC does not allow: masked by the server, a control frame
    /// that is long or fragmented, a continuation of nothing, a reserved bit
    /// set.
    ProtocolError,
    /// A message longer than the receiver's buffer. It has been read past, so
    /// the connection can carry on.
    MessageTooLarge,
};

/// Reads messages: a data message whole, however many frames it came in, and
/// a control frame as soon as it arrives, which the RFC allows in the middle
/// of a fragmented message.
pub const Receiver = struct {
    /// Where data messages are put together. Its length is the longest
    /// message taken.
    buf: []u8,
    len: usize = 0,
    /// The opcode of the message whose fragments are coming in, if one is.
    fragmented: ?Opcode = null,
    /// Set while the fragments of a message too long for `buf` are read past.
    overflowed: bool = false,
    control: [125]u8 = undefined,

    pub fn init(buf: []u8) Receiver {
        return .{ .buf = buf };
    }

    pub fn next(self: *Receiver, r: *std.Io.Reader) ReadError!Message {
        while (true) {
            const head = try r.takeArray(2);
            const fin = head[0] & 0x80 != 0;
            if (head[0] & 0x70 != 0) return error.ProtocolError;
            const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @intCast(head[0] & 0x0F))));
            if (head[1] & 0x80 != 0) return error.ProtocolError;

            const len: u64 = switch (head[1] & 0x7F) {
                126 => std.mem.readInt(u16, try r.takeArray(2), .big),
                127 => std.mem.readInt(u64, try r.takeArray(8), .big),
                else => |short| short,
            };

            if (opcode.isControl()) {
                if (!fin or len > self.control.len) return error.ProtocolError;
                const payload = self.control[0..@intCast(len)];
                try r.readSliceAll(payload);
                return .{ .opcode = opcode, .payload = payload };
            }

            switch (opcode) {
                .continuation => if (self.fragmented == null) return error.ProtocolError,
                .text, .binary => {
                    if (self.fragmented != null) return error.ProtocolError;
                    self.fragmented = opcode;
                    self.len = 0;
                    self.overflowed = false;
                },
                else => return error.ProtocolError,
            }

            if (self.overflowed or len > self.buf.len - self.len) {
                self.overflowed = true;
                try r.discardAll64(len);
            } else {
                try r.readSliceAll(self.buf[self.len..][0..@intCast(len)]);
                self.len += @intCast(len);
            }

            if (!fin) continue;
            const whole = self.fragmented.?;
            self.fragmented = null;
            if (self.overflowed) {
                self.overflowed = false;
                return error.MessageTooLarge;
            }
            return .{ .opcode = whole, .payload = self.buf[0..self.len] };
        }
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "the accept value is the one the RFC works out for its sample key" {
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptFor("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "the handshake asks for an upgrade with the key" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHandshake(&w, "dealer.example", "/?access_token=abc", "dGhlIHNhbXBsZSBub25jZQ==");
    const request = w.buffered();
    try testing.expect(std.mem.startsWith(u8, request, "GET /?access_token=abc HTTP/1.1\r\nHost: dealer.example\r\n"));
    try testing.expect(std.mem.indexOf(u8, request, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, request, "\r\n\r\n"));
}

test "a handshake completes only with 101 and the right accept value" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const good = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nsec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try checkHandshake(.switching_protocols, good, key);
    try testing.expectError(error.Refused, checkHandshake(.unauthorized, "HTTP/1.1 401 Unauthorized\r\n\r\n", key));
    const forged = "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n\r\n";
    try testing.expectError(error.BadAccept, checkHandshake(.switching_protocols, forged, key));
    try testing.expectError(error.BadAccept, checkHandshake(.switching_protocols, "HTTP/1.1 101 OK\r\n\r\n", key));
}

/// A frame as a server sends it: final, unmasked.
fn serverFrame(buf: []u8, fin: bool, opcode: Opcode, payload: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeByte(@as(u8, if (fin) 0x80 else 0) | @backingInt(opcode)) catch unreachable;
    if (payload.len < 126) {
        w.writeByte(@intCast(payload.len)) catch unreachable;
    } else {
        w.writeByte(126) catch unreachable;
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(payload.len), .big);
        w.writeAll(&len) catch unreachable;
    }
    w.writeAll(payload) catch unreachable;
    return w.buffered();
}

test "a frame the client writes is masked, and unmasks to what was sent" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    try writeFrame(&w, .text, "{\"type\":\"ping\"}", mask);
    const frame = w.buffered();

    try testing.expectEqual(@as(u8, 0x81), frame[0]);
    try testing.expectEqual(@as(u8, 0x80 | 15), frame[1]);
    try testing.expectEqualSlices(u8, &mask, frame[2..6]);
    var unmasked: [15]u8 = undefined;
    for (&unmasked, frame[6..21], 0..) |*out, byte, i| out.* = byte ^ mask[i % 4];
    try testing.expectEqualStrings("{\"type\":\"ping\"}", &unmasked);
}

test "a long payload takes the 16-bit length" {
    var buf: [600]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const payload: [300]u8 = @splat('x');
    try writeFrame(&w, .binary, &payload, @splat(0));
    const frame = w.buffered();
    try testing.expectEqual(@as(u8, 0x80 | 126), frame[1]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, frame[2..4], .big));
    try testing.expectEqual(@as(usize, 4 + 4 + 300), frame.len);
}

test "fragments come out as one message, with a ping between them on its own" {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    var part: [64]u8 = undefined;
    for ([_][]const u8{
        serverFrame(&part, false, .text, "{\"a\":"),
        serverFrame(part[16..], true, .ping, "hi"),
        serverFrame(part[32..], true, .continuation, "1}"),
    }) |frame| {
        @memcpy(buf[n..][0..frame.len], frame);
        n += frame.len;
    }

    var r: std.Io.Reader = .fixed(buf[0..n]);
    var storage: [64]u8 = undefined;
    var receiver: Receiver = .init(&storage);

    const ping = try receiver.next(&r);
    try testing.expectEqual(Opcode.ping, ping.opcode);
    try testing.expectEqualStrings("hi", ping.payload);

    const message = try receiver.next(&r);
    try testing.expectEqual(Opcode.text, message.opcode);
    try testing.expectEqualStrings("{\"a\":1}", message.payload);
}

test "a message too long for the buffer is read past, and the next one still comes through" {
    var buf: [512]u8 = undefined;
    var part_a: [300]u8 = undefined;
    var part_b: [32]u8 = undefined;
    const long: [200]u8 = @splat('y');
    const a = serverFrame(&part_a, true, .text, &long);
    const b = serverFrame(&part_b, true, .text, "short");
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);

    var r: std.Io.Reader = .fixed(buf[0 .. a.len + b.len]);
    var storage: [64]u8 = undefined;
    var receiver: Receiver = .init(&storage);

    try testing.expectError(error.MessageTooLarge, receiver.next(&r));
    try testing.expectEqualStrings("short", (try receiver.next(&r)).payload);
}

test "frames a server must not send are protocol errors" {
    var storage: [64]u8 = undefined;

    // Masked.
    var receiver: Receiver = .init(&storage);
    var r: std.Io.Reader = .fixed(&.{ 0x81, 0x81, 1, 2, 3, 4, 'x' });
    try testing.expectError(error.ProtocolError, receiver.next(&r));

    // A continuation of nothing.
    receiver = .init(&storage);
    r = .fixed(&.{ 0x80, 0x01, 'x' });
    try testing.expectError(error.ProtocolError, receiver.next(&r));

    // A fragmented ping.
    receiver = .init(&storage);
    r = .fixed(&.{ 0x09, 0x00 });
    try testing.expectError(error.ProtocolError, receiver.next(&r));
}

test "a stream that ends mid-frame says so" {
    var storage: [64]u8 = undefined;
    var receiver: Receiver = .init(&storage);
    var r: std.Io.Reader = .fixed(&.{ 0x81, 0x05, 'a', 'b' });
    try testing.expectError(error.EndOfStream, receiver.next(&r));
}
