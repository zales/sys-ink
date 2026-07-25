const std = @import("std");
const EpdConfig = @import("epdconfig.zig").EpdConfig;

const log = std.log.scoped(.epd);

// Display resolution - Portrait (hardware orientation)
pub const EPD_WIDTH = 128;
pub const EPD_HEIGHT = 296;
pub const EPD_BUFFER_SIZE = (EPD_WIDTH / 8) * EPD_HEIGHT; // 4736 bytes

/// One full panel frame, 1 bit per pixel. Taking this by pointer rather than as
/// a slice makes the length a compile-time guarantee: a short buffer used to be
/// sliced to EPD_BUFFER_SIZE unchecked, which reads past the end in release
/// builds and clocks the result out over SPI.
pub const Frame = [EPD_BUFFER_SIZE]u8;

// Partial update LUT for V2 (159 bytes) - from C reference
const WF_PARTIAL_2IN9 = [_]u8{
    0x0,  0x40, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x80, 0x80, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x40, 0x40, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x80, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0A, 0x0,  0x0,  0x0,  0x0,  0x0,  0x2, 0x1, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x1,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0, 0x0,  0x0,  0x0,
    0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x0, 0x0, 0x0, 0x22, 0x17, 0x41,
    0xB0, 0x32, 0x36,
};

// Full update LUT for V2 (159 bytes) - from C reference
const WS_20_30 = [_]u8{
    0x80, 0x66, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x40, 0x0,  0x0,  0x0,
    0x10, 0x66, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x20, 0x0,  0x0,  0x0,
    0x80, 0x66, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x40, 0x0,  0x0,  0x0,
    0x10, 0x66, 0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x20, 0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0,  0x0,  0x0,  0x0,
    0x14, 0x8,  0x0,  0x0,  0x0,  0x0,  0x1, 0xA, 0xA,  0x0,  0xA,  0xA,
    0x0,  0x1,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0,  0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0,  0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0,  0x0,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x14, 0x8,  0x0,  0x1,
    0x0,  0x0,  0x1,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0,  0x1,  0x0,  0x0,
    0x0,  0x0,  0x0,  0x0,  0x0,  0x0,  0x0, 0x0, 0x0,  0x0,  0x0,  0x0,
    0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x0, 0x0, 0x0,  0x22, 0x17, 0x41,
    0x0,  0x32, 0x36,
};

/// The panel driver, parameterised by its transport so tests can substitute a
/// recorder for the real SPI/GPIO path. `EPD` below is the production instance.
///
/// The contract is checked at comptime, so a transport missing a declaration
/// fails with a direct message instead of an error deep inside a call.
pub fn Epd(comptime Transport: type) type {
    comptime verifyTransport(Transport);

    return struct {
    const Self = @This();

    config: *Transport,

    /// Argument to DISPLAY_UPDATE_CONTROL_2, which selects what the next
    /// MASTER_ACTIVATION actually does.
    ///
    /// Left as opaque values on purpose: 0x22 is a bitfield in the SSD1680, but
    /// the published bit assignments disagree between sources and these three
    /// values are the ones Waveshare's reference uses and that are verified
    /// working on this panel. Naming individual bits from guesswork would read
    /// as authoritative while being wrong.
    const DisplayUpdate = enum(u8) {
        /// Full waveform: repaints every pixel, which is what makes it flash.
        full = 0xC7,
        /// Weak waveform, applied only where the frame differs from the
        /// reference in the base RAM.
        partial = 0x0F,
        /// Clock and analog on, without activating an update — so it cannot
        /// disturb the glass.
        power_on = 0xC0,
    };

    // Command sets as strict Enum
    const Command = enum(u8) {
        DRIVER_OUTPUT_CONTROL = 0x01,
        DEEP_SLEEP_MODE = 0x10,
        DATA_ENTRY_MODE = 0x11,
        SW_RESET = 0x12,
        MASTER_ACTIVATION = 0x20,
        DISPLAY_UPDATE_CONTROL_1 = 0x21,
        DISPLAY_UPDATE_CONTROL_2 = 0x22,
        WRITE_RAM = 0x24,
        WRITE_RAM_BASE = 0x26,
        WRITE_VCOM_REGISTER = 0x2C,
        WRITE_LUT_REGISTER = 0x32,
        WRITE_OTP_SELECTION = 0x37,
        BORDER_WAVEFORM_CONTROL = 0x3C,
        SET_RAM_X_ADDRESS_START_END_POSITION = 0x44,
        SET_RAM_Y_ADDRESS_START_END_POSITION = 0x45,
        SET_RAM_X_ADDRESS_COUNTER = 0x4E,
        SET_RAM_Y_ADDRESS_COUNTER = 0x4F,
        GATE_DRIVING_VOLTAGE_CONTROL = 0x03,
        SOURCE_DRIVING_VOLTAGE_CONTROL = 0x04,
        // 0x3F is often undocumented or specific LUT/Power setting
        WRITE_VCOM_REGISTER_OPT = 0x3F,
        NOP = 0x7F,
    };

    pub fn init(config: *Transport) Self {
        return .{ .config = config };
    }

    /// Hardware reset - V2 uses 10ms delays
    fn reset(self: *Self) !void {
        try self.config.digitalWrite(Transport.RST_PIN, 1);
        self.config.delayMs(10);
        try self.config.digitalWrite(Transport.RST_PIN, 0);
        self.config.delayMs(2);
        try self.config.digitalWrite(Transport.RST_PIN, 1);
        self.config.delayMs(10);
    }

    // Each spiWrite is one write() to /dev/spidev, and the kernel frames every
    // write with its own chip-select assertion. DC therefore only has to be
    // correct before the call; the driver never touches CS itself.

    /// Send command byte
    fn sendCommand(self: *Self, command: Command) !void {
        try self.config.digitalWrite(Transport.DC_PIN, 0);
        try self.config.spiWrite(&[_]u8{@intFromEnum(command)});
    }

    /// Send a command followed by its arguments, as two framed transfers.
    fn sendCommandArgs(self: *Self, command: Command, args: []const u8) !void {
        try self.config.digitalWrite(Transport.DC_PIN, 0);
        try self.config.spiWrite(&[_]u8{@intFromEnum(command)});

        if (args.len > 0) {
            try self.config.digitalWrite(Transport.DC_PIN, 1);
            try self.config.spiWrite(args);
        }
    }

    /// Send single data byte
    fn sendData(self: *Self, data: u8) !void {
        try self.config.digitalWrite(Transport.DC_PIN, 1);
        try self.config.spiWrite(&[_]u8{data});
    }

    /// Send multiple data bytes
    fn sendDataSlice(self: *Self, data: []const u8) !void {
        try self.config.digitalWrite(Transport.DC_PIN, 1);
        try self.config.spiWrite(data);
    }

    /// Longest a refresh may keep BUSY asserted before we give up on the panel.
    pub const busy_timeout_ms: u64 = 5000;
    /// Interval between BUSY samples while waiting.
    const busy_poll_ms: u64 = 2;

    /// Wait until the BUSY line goes LOW.
    /// V2: LOW (0) = IDLE, HIGH (1) = BUSY.
    ///
    /// Polled rather than waited on. The chardev ABI can deliver a falling-edge
    /// event instead, replacing roughly a thousand ioctls per full refresh with
    /// one poll; the obvious race (the edge passing between arming the event and
    /// blocking on it) is avoidable by sampling the level once after arming.
    /// It stays polled because at a 30-second cadence this averages a few dozen
    /// ioctls per second, and switching would change the behaviour of working
    /// hardware for no measurable gain.
    fn readBusy(self: *Self) !void {
        log.debug("e-Paper busy", .{});

        const start_ms = self.config.monotonicMillis();

        while (try self.config.digitalRead(Transport.BUSY_PIN) == 1) {
            // Reported, not logged: the caller decides how loudly to complain,
            // and the elapsed time is always just over the timeout anyway.
            if (self.config.monotonicMillis() -| start_ms > busy_timeout_ms) {
                return error.EpdBusyTimeout;
            }
            self.config.delayMs(busy_poll_ms);
        }

        log.debug("e-Paper busy release", .{});
    }

    /// Load LUT (first 153 bytes only) - from C reference
    fn loadLut(self: *Self, lut: []const u8) !void {
        try self.sendCommand(.WRITE_LUT_REGISTER);
        try self.sendDataSlice(lut[0..153]);
    }

    /// Load LUT with voltage settings - from C reference
    fn loadLutByHost(self: *Self, lut: []const u8) !void {
        try self.loadLut(lut);

        try self.sendCommand(.WRITE_VCOM_REGISTER_OPT); // 0x3f
        try self.sendData(lut[153]);

        try self.sendCommand(.GATE_DRIVING_VOLTAGE_CONTROL); // 0x03
        try self.sendData(lut[154]);

        try self.sendCommand(.SOURCE_DRIVING_VOLTAGE_CONTROL); // 0x04
        try self.sendData(lut[155]); // VSH
        try self.sendData(lut[156]); // VSH2
        try self.sendData(lut[157]); // VSL

        try self.sendCommand(.WRITE_VCOM_REGISTER);
        try self.sendData(lut[158]);
    }

    /// Setting the display window
    fn setWindows(self: *Self, x_start: u16, y_start: u16, x_end: u16, y_end: u16) !void {
        const data = [_]u8{
            @intCast((x_start >> 3) & 0xFF),
            @intCast((x_end >> 3) & 0xFF),
        };
        try self.sendCommandArgs(.SET_RAM_X_ADDRESS_START_END_POSITION, &data);

        const data_y = [_]u8{
            @intCast(y_start & 0xFF),
            @intCast((y_start >> 8) & 0xFF),
            @intCast(y_end & 0xFF),
            @intCast((y_end >> 8) & 0xFF),
        };
        try self.sendCommandArgs(.SET_RAM_Y_ADDRESS_START_END_POSITION, &data_y);
    }

    /// Set Cursor
    fn setCursor(self: *Self, x_start: u16, y_start: u16) !void {
        try self.sendCommand(.SET_RAM_X_ADDRESS_COUNTER);
        try self.sendData(@intCast((x_start >> 3) & 0xFF));

        const data_y = [_]u8{
            @intCast(y_start & 0xFF),
            @intCast((y_start >> 8) & 0xFF),
        };
        try self.sendCommandArgs(.SET_RAM_Y_ADDRESS_COUNTER, &data_y);
    }

    /// Select what the next MASTER_ACTIVATION will do.
    fn setDisplayUpdate(self: *Self, mode: DisplayUpdate) !void {
        try self.sendCommandArgs(.DISPLAY_UPDATE_CONTROL_2, &[_]u8{@intFromEnum(mode)});
    }

    /// Drive a full refresh: every pixel is repainted with the full waveform,
    /// which is what makes it flash.
    fn turnOnDisplay(self: *Self) !void {
        try self.setDisplayUpdate(.full);
        try self.sendCommand(.MASTER_ACTIVATION);
        try self.readBusy();
    }

    /// Drive a partial refresh: only pixels differing from the reference frame
    /// are touched, with a waveform weak enough not to flash.
    fn turnOnDisplayPartial(self: *Self) !void {
        try self.setDisplayUpdate(.partial);
        try self.sendCommand(.MASTER_ACTIVATION);
        try self.readBusy();
    }

    /// Re-initialize the e-Paper register (without module init)
    pub fn reInit(self: *Self) !void {
        try self.reset();
        self.config.delayMs(100);

        try self.readBusy();

        try self.sendCommand(.SW_RESET);
        try self.readBusy();

        try self.sendCommandArgs(.DRIVER_OUTPUT_CONTROL, &[_]u8{ 0x27, 0x01, 0x00 });
        try self.sendCommandArgs(.DATA_ENTRY_MODE, &[_]u8{0x03});

        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);

        try self.sendCommandArgs(.DISPLAY_UPDATE_CONTROL_1, &[_]u8{ 0x00, 0x80 });

        try self.setCursor(0, 0);
        try self.readBusy();

        try self.loadLutByHost(&WS_20_30);
    }

    /// Initialize the e-Paper register - from C reference EPD_2IN9_V2_Init
    pub fn initDisplay(self: *Self) !void {
        try self.config.moduleInit();
        try self.reInit();
    }

    /// Fill both RAM banks with `color` and refresh.
    ///
    /// Written in one go per bank: spiWrite already splits at the spidev
    /// transfer limit, so the old 128-byte loop just multiplied the syscalls.
    pub fn clear(self: *Self, color: u8) !void {
        var frame: Frame = undefined;
        @memset(&frame, color);

        try self.sendCommand(.WRITE_RAM);
        try self.sendDataSlice(&frame);

        try self.sendCommand(.WRITE_RAM_BASE);
        try self.sendDataSlice(&frame);

        try self.turnOnDisplay();
    }

    /// Display image buffer (full refresh) - from C reference EPD_2IN9_V2_Display
    pub fn display(self: *Self, image: *const Frame) !void {
        try self.sendCommand(.WRITE_RAM);
        try self.sendDataSlice(image);
        try self.turnOnDisplay();
    }

    /// Display Base (for partial update) - from C reference EPD_2IN9_V2_Display_Base
    pub fn displayBase(self: *Self, image: *const Frame) !void {
        try self.sendCommand(.WRITE_RAM); // Write to black RAM
        try self.sendDataSlice(image);

        try self.sendCommand(.WRITE_RAM_BASE); // Write to base RAM
        try self.sendDataSlice(image);

        try self.turnOnDisplay();
    }

    /// Soft-reset and arm the panel for a partial update: partial LUT, border
    /// waveform and analog power-up. Drives nothing, so it cannot flicker.
    ///
    /// The RST pulse resets the registers but leaves both RAM banks intact —
    /// which is why partial updates work at all, given this runs before each one.
    fn beginPartial(self: *Self) !void {
        // Reset (from C reference - only 1ms delays)
        try self.config.digitalWrite(Transport.RST_PIN, 0);
        self.config.delayMs(1);
        try self.config.digitalWrite(Transport.RST_PIN, 1);
        self.config.delayMs(2);

        // Load partial LUT
        try self.loadLut(&WF_PARTIAL_2IN9);

        // WriteOtpSelection (0x37 in C, not 0x2F!)
        try self.sendCommandArgs(.WRITE_OTP_SELECTION, &[_]u8{
            0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00,
        });

        // Border waveform control
        try self.sendCommandArgs(.BORDER_WAVEFORM_CONTROL, &[_]u8{0x80});

        // Display update control: clock and analog on, no display activation.
        try self.setDisplayUpdate(.power_on);
        try self.sendCommand(.MASTER_ACTIVATION);
        try self.readBusy();
    }

    /// Overwrite the base RAM (0x26) with `image` without driving the panel.
    ///
    /// Partial updates render the difference between the new frame in 0x24 and
    /// this reference. Deep sleep loses it, so it has to be restored from the
    /// frame the caller knows is on the panel — otherwise the next partial
    /// update tries to repaint everything with a waveform too weak for it, and
    /// smears the old content instead.
    ///
    /// Must be called straight after `reInit`, before any partial update begins:
    /// once that sequence powers up the analog stage (0x22 = 0xC0 followed by
    /// MASTER_ACTIVATION) the reference is latched and a later write is ignored.
    /// Verified on a 2.9" V2 panel — priming afterwards smears.
    pub fn primeBase(self: *Self, image: *const Frame) !void {
        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);
        try self.setCursor(0, 0);
        try self.sendCommand(.WRITE_RAM_BASE);
        try self.sendDataSlice(image);
    }

    /// Partial update display - from C reference EPD_2IN9_V2_Display_Partial
    pub fn displayPartial(self: *Self, image: *const Frame) !void {
        try self.beginPartial();

        // Reset window to full frame
        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);
        try self.setCursor(0, 0);

        // Write to RAM (only 0x24, NOT 0x26!)
        try self.sendCommand(.WRITE_RAM);
        try self.sendDataSlice(image);

        try self.turnOnDisplayPartial();
    }

    /// Enter deep sleep - from C reference EPD_2IN9_V2_Sleep.
    ///
    /// Waveshare requires this before cutting power; leaving the panel driven at
    /// high voltage shortens its life. Waking up afterwards needs a full
    /// `initDisplay`, so this is a shutdown-only call.
    pub fn sleep(self: *Self) !void {
        try self.sendCommandArgs(.DEEP_SLEEP_MODE, &[_]u8{deep_sleep_mode_1});
        self.config.delayMs(100);
    }
    };
}

/// Deep Sleep Mode 1. Mode 2 (0x03) additionally drops RAM, which would make
/// the reference-frame restore in primeBase pointless.
const deep_sleep_mode_1 = 0x01;

/// Everything `Epd` needs from its transport. PWR is deliberately absent: the
/// panel's power rail is brought up by the transport's own moduleInit, and the
/// driver never touches it.
fn verifyTransport(comptime T: type) void {
    const required = [_][]const u8{
        "RST_PIN",     "DC_PIN",          "BUSY_PIN",
        "delayMs",     "monotonicMillis", "moduleInit",
        "digitalWrite", "digitalRead",    "spiWrite",
    };
    for (required) |name| {
        if (!@hasDecl(T, name)) @compileError(
            "transport '" ++ @typeName(T) ++ "' is missing '" ++ name ++ "'",
        );
    }
}

/// The driver as used in production.
pub const EPD = Epd(EpdConfig);

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

/// Records what the driver would have put on the wire, so command sequences can
/// be asserted without a panel.
const FakeTransport = struct {
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

    fn init(allocator: std.mem.Allocator) FakeTransport {
        return .{ .allocator = allocator, .events = std.array_list.Managed(Event).init(allocator) };
    }

    fn deinit(self: *FakeTransport) void {
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

    fn reset_log(self: *FakeTransport) void {
        for (self.events.items) |event| {
            if (event == .spi) self.allocator.free(event.spi.bytes);
        }
        self.events.clearRetainingCapacity();
    }

    /// Command bytes (DC low, single byte) in the order they were sent.
    fn commands(self: *FakeTransport, buf: []u8) []const u8 {
        var n: usize = 0;
        for (self.events.items) |event| {
            if (event == .spi and event.spi.dc == 0 and event.spi.bytes.len == 1) {
                buf[n] = event.spi.bytes[0];
                n += 1;
            }
        }
        return buf[0..n];
    }

    fn sentCommand(self: *FakeTransport, cmd: u8) bool {
        var buf: [64]u8 = undefined;
        return std.mem.indexOfScalar(u8, self.commands(&buf), cmd) != null;
    }

    /// Payload of the transfer immediately following command `cmd`.
    fn argsAfter(self: *FakeTransport, cmd: u8) ?[]const u8 {
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

const TestEpd = Epd(FakeTransport);

fn testEpd(fake: *FakeTransport) TestEpd {
    return TestEpd.init(fake);
}

test "sendCommandArgs frames the command and its payload separately" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    try epd.sendCommandArgs(.BORDER_WAVEFORM_CONTROL, &[_]u8{0x80});

    // DC low for the command byte, DC high for the argument.
    try testing.expectEqual(@as(usize, 4), fake.events.items.len);
    try testing.expectEqual(@as(u8, 0), fake.events.items[0].pin.value);
    try testing.expectEqualSlices(u8, &.{0x3C}, fake.events.items[1].spi.bytes);
    try testing.expectEqual(@as(u8, 1), fake.events.items[2].pin.value);
    try testing.expectEqualSlices(u8, &.{0x80}, fake.events.items[3].spi.bytes);
}

test "the driver never drives chip select itself" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    try epd.reInit();

    // spidev frames every write() with its own CS assertion; a stray GPIO write
    // here would fight it. Only RST and DC may be touched.
    for (fake.events.items) |event| {
        if (event == .pin) {
            try testing.expect(event.pin.pin == FakeTransport.RST_PIN or
                event.pin.pin == FakeTransport.DC_PIN);
        }
    }
}

test "reInit resets, configures and loads the full LUT without refreshing" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    try epd.reInit();

    // Hardware reset pulse: high, low, high.
    try testing.expectEqual(@as(u8, 1), fake.events.items[0].pin.value);
    try testing.expectEqual(@as(u8, 0), fake.events.items[1].pin.value);
    try testing.expectEqual(@as(u8, 1), fake.events.items[2].pin.value);

    try testing.expect(fake.sentCommand(0x12)); // SW_RESET
    try testing.expectEqualSlices(u8, &.{ 0x27, 0x01, 0x00 }, fake.argsAfter(0x01).?);
    try testing.expectEqualSlices(u8, &.{0x03}, fake.argsAfter(0x11).?); // data entry
    try testing.expectEqualSlices(u8, WS_20_30[0..153], fake.argsAfter(0x32).?);

    // Waking must not disturb the glass: no display activation anywhere.
    try testing.expect(!fake.sentCommand(0x20));
}

test "primeBase rewrites the reference frame without activating the display" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    var frame: Frame = @splat(0xAB);
    try epd.primeBase(&frame);

    // This is what makes waking from deep sleep invisible. If a MASTER_ACTIVATION
    // ever crept in here it would flash the panel on every refresh.
    try testing.expect(!fake.sentCommand(0x20));

    try testing.expect(fake.sentCommand(0x26)); // WRITE_RAM_BASE
    try testing.expect(!fake.sentCommand(0x24)); // and only the reference bank
    try testing.expectEqual(@as(usize, EPD_BUFFER_SIZE), fake.argsAfter(0x26).?.len);
}

test "displayBase writes both banks and refreshes with the full waveform" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    var frame: Frame = @splat(0x00);
    try epd.displayBase(&frame);

    try testing.expectEqual(@as(usize, EPD_BUFFER_SIZE), fake.argsAfter(0x24).?.len);
    try testing.expectEqual(@as(usize, EPD_BUFFER_SIZE), fake.argsAfter(0x26).?.len);
    try testing.expectEqualSlices(u8, &.{0xC7}, fake.argsAfter(0x22).?);
    try testing.expect(fake.sentCommand(0x20));
}

test "display refreshes fully but leaves the reference bank alone" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    var frame: Frame = @splat(0x00);
    try epd.display(&frame);

    try testing.expect(fake.sentCommand(0x24));
    try testing.expect(!fake.sentCommand(0x26));
    try testing.expectEqualSlices(u8, &.{0xC7}, fake.argsAfter(0x22).?);
}

test "displayPartial loads the partial LUT and uses the weak waveform" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    var frame: Frame = @splat(0x0F);
    try epd.displayPartial(&frame);

    try testing.expectEqualSlices(u8, WF_PARTIAL_2IN9[0..153], fake.argsAfter(0x32).?);
    try testing.expectEqualSlices(u8, &.{0x80}, fake.argsAfter(0x3C).?);
    // Only the working bank; the reference must survive to diff against.
    try testing.expectEqual(@as(usize, EPD_BUFFER_SIZE), fake.argsAfter(0x24).?.len);
    try testing.expect(!fake.sentCommand(0x26));

    // 0xC0 powers the analog stage up, 0x0F is the partial refresh itself.
    var buf: [64]u8 = undefined;
    const cmds = fake.commands(&buf);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, cmds, &.{0x20}));
}

test "sleep enters deep sleep mode 1, which retains RAM" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    try epd.sleep();

    // Mode 2 (0x03) would drop the RAM and make primeBase pointless.
    try testing.expectEqualSlices(u8, &.{0x01}, fake.argsAfter(0x10).?);
}

test "clear fills both banks in one transfer each" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    try epd.clear(0xFF);

    // Used to be chunked into 128-byte pieces, which multiplied the syscalls.
    const ram = fake.argsAfter(0x24).?;
    try testing.expectEqual(@as(usize, EPD_BUFFER_SIZE), ram.len);
    try testing.expectEqual(@as(u8, 0xFF), ram[0]);
    try testing.expectEqual(@as(usize, EPD_BUFFER_SIZE), fake.argsAfter(0x26).?.len);
}

test "readBusy waits for the line to drop" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    fake.busy_reads_remaining = 3;
    try epd.readBusy();

    // Three busy samples plus the one that saw it idle.
    try testing.expectEqual(@as(u32, 4), fake.busy_reads_total);
}

test "readBusy gives up on a panel that never releases" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    fake.busy_reads_remaining = std.math.maxInt(u32);
    try testing.expectError(error.EpdBusyTimeout, epd.readBusy());
    try testing.expect(fake.clock_ms > TestEpd.busy_timeout_ms);
}

test "initDisplay brings the transport up before talking to the panel" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    try epd.initDisplay();
    try testing.expectEqual(@as(u32, 1), fake.module_init_calls);
    try testing.expect(fake.sentCommand(0x12)); // SW_RESET, so reInit ran too
}
