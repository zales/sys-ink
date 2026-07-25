//! A transport that records what the driver puts on the wire, instead of driving
//! real hardware.
//!
//! Test-only, but it lives in a normal source file so both the driver's own
//! tests and the renderer's can share it. Nothing outside a test block
//! references it, so it is never analysed into the binary.

const std = @import("std");
const testing = std.testing;

pub const FakeTransport = struct {
    pub const RST_PIN: u32 = 17;
    pub const DC_PIN: u32 = 25;
    pub const BUSY_PIN: u32 = 24;
    pub const PWR_PIN: u32 = 18;

    pub const Event = union(enum) {
        pin: struct { pin: u32, value: u8 },
        /// Owned copy: the driver often passes a temporary.
        spi: struct { dc: u8, bytes: []const u8 },
    };

    allocator: std.mem.Allocator,
    events: std.array_list.Managed(Event),
    dc: u8 = 0,
    /// Number of reads that report BUSY before the line drops.
    busy_reads_remaining: u32 = 0,
    busy_reads_total: u32 = 0,
    /// Advanced by delayMs, so timeouts are exercised without real waiting.
    clock_ms: u64 = 0,
    module_init_calls: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) FakeTransport {
        return .{ .allocator = allocator, .events = std.array_list.Managed(Event).init(allocator) };
    }

    pub fn deinit(self: *FakeTransport) void {
        for (self.events.items) |event| {
            if (event == .spi) self.allocator.free(event.spi.bytes);
        }
        self.events.deinit();
    }

    pub fn delayMs(self: *FakeTransport, millis: u64) void {
        self.clock_ms += millis;
    }

    pub fn monotonicMillis(self: *FakeTransport) u64 {
        return self.clock_ms;
    }

    pub fn moduleInit(self: *FakeTransport) !void {
        self.module_init_calls += 1;
    }

    pub fn digitalWrite(self: *FakeTransport, pin: u32, value: u8) !void {
        if (pin == DC_PIN) self.dc = value;
        try self.events.append(.{ .pin = .{ .pin = pin, .value = value } });
    }

    pub fn digitalRead(self: *FakeTransport, pin: u32) !u8 {
        try testing.expectEqual(BUSY_PIN, pin);
        self.busy_reads_total += 1;
        if (self.busy_reads_remaining == 0) return 0;
        self.busy_reads_remaining -= 1;
        return 1;
    }

    pub fn spiWrite(self: *FakeTransport, data: []const u8) !void {
        try self.events.append(.{ .spi = .{ .dc = self.dc, .bytes = try self.allocator.dupe(u8, data) } });
    }

    // --- assertions ---------------------------------------------------------

    pub fn resetLog(self: *FakeTransport) void {
        for (self.events.items) |event| {
            if (event == .spi) self.allocator.free(event.spi.bytes);
        }
        self.events.clearRetainingCapacity();
    }

    /// Command bytes (DC low, single byte) in the order they were sent.
    pub fn commands(self: *FakeTransport, buf: []u8) []const u8 {
        var n: usize = 0;
        for (self.events.items) |event| {
            if (event == .spi and event.spi.dc == 0 and event.spi.bytes.len == 1) {
                buf[n] = event.spi.bytes[0];
                n += 1;
            }
        }
        return buf[0..n];
    }

    pub fn sentCommand(self: *FakeTransport, cmd: u8) bool {
        var buf: [64]u8 = undefined;
        return std.mem.indexOfScalar(u8, self.commands(&buf), cmd) != null;
    }

    /// Payload following the *last* occurrence of `cmd`.
    ///
    /// A partial update sends 0x22 twice — first to power the analog stage up,
    /// then to select the waveform — so asserting on the first occurrence checks
    /// the wrong one.
    pub fn lastArgsAfter(self: *FakeTransport, cmd: u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.events.items, 0..) |event, i| {
            if (event != .spi or event.spi.dc != 0) continue;
            if (event.spi.bytes.len != 1 or event.spi.bytes[0] != cmd) continue;

            for (self.events.items[i + 1 ..]) |next| {
                if (next != .spi) continue;
                if (next.spi.dc == 1) found = next.spi.bytes;
                break;
            }
        }
        return found;
    }

    /// Payload of the transfer immediately following the first `cmd`.
    pub fn argsAfter(self: *FakeTransport, cmd: u8) ?[]const u8 {
        for (self.events.items, 0..) |event, i| {
            if (event != .spi or event.spi.dc != 0) continue;
            if (event.spi.bytes.len != 1 or event.spi.bytes[0] != cmd) continue;

            for (self.events.items[i + 1 ..]) |next| {
                if (next != .spi) continue;
                return if (next.spi.dc == 1) next.spi.bytes else null;
            }
        }
        return null;
    }
};
