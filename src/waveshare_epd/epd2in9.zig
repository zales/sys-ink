const std = @import("std");

const log = std.log.scoped(.epd);

/// Everything about the driver that is specific to a particular panel.
///
/// This makes the panel a parameter instead of a set of module-level constants,
/// so a second one is a spec rather than a fork of this file. Only the panel
/// below is provided, because it is the only one that can be verified here — a
/// spec written from a datasheet and never run would look like support while
/// being a guess.
///
/// Note what this does *not* buy: the renderer above is equally specific, since
/// `display_config.zig` is 296x128 pixel coordinates throughout. A different
/// panel size needs that layout redone as well.
pub const PanelSpec = struct {
    /// Short side, in pixels. Must be a multiple of 8: one byte of RAM covers
    /// eight pixels along it.
    width: u16,
    /// Long side, in pixels.
    height: u16,
    /// Full-refresh waveform, 159 bytes: 153 of LUT plus six voltage settings.
    lut_full: *const [lut_len]u8,
    /// Partial-refresh waveform, same layout.
    lut_partial: *const [lut_len]u8,
    /// Four-grey full-refresh waveform, same layout; null for a panel that
    /// cannot show grey.
    lut_gray4: ?*const [lut_len]u8 = null,
    /// Gate scan configuration for DRIVER_OUTPUT_CONTROL. The first two bytes
    /// are the gate line count minus one, little endian; the third selects the
    /// scan order.
    gate_scan_order: u8 = 0x00,

    pub fn bufferSize(self: PanelSpec) usize {
        return (self.width / 8) * @as(usize, self.height);
    }

    /// DRIVER_OUTPUT_CONTROL argument, derived rather than written out: the
    /// leading 0x27 0x01 in the vendor reference is just 295, the panel's gate
    /// line count minus one.
    pub fn driverOutputControl(self: PanelSpec) [3]u8 {
        const lines = self.height - 1;
        return .{ @truncate(lines), @truncate(lines >> 8), self.gate_scan_order };
    }
};

/// Length of a waveform table: 153 LUT bytes plus six voltage settings.
const lut_len = 159;

/// How an update the panel was told to make is recognised on the wire: the
/// command that selects what the next activation does, and its argument for
/// each kind of refresh. Named here, outside the driver type, for the recorder
/// that tests above the driver read their updates from; the driver's own
/// enums take their values from these.
pub const update_select = struct {
    pub const command = 0x22;
    pub const full = 0xC7;
    pub const partial = 0x0F;
};

/// Waveshare 2.9inch e-Paper Module (B/W) V2, the panel this project targets and
/// the only one verified on hardware.
pub const waveshare_2in9_v2: PanelSpec = .{
    .width = 128,
    .height = 296,
    .lut_full = &ws_20_30,
    .lut_partial = &wf_partial_2in9,
    .lut_gray4 = &gray4_2in9,
};

// Kept for the production instance's users.
pub const epd_width = waveshare_2in9_v2.width;
pub const epd_height = waveshare_2in9_v2.height;
pub const epd_buffer_size = waveshare_2in9_v2.bufferSize(); // 4736 bytes

/// One full panel frame, 1 bit per pixel. Taking this by pointer rather than as
/// a slice makes the length a compile-time guarantee: a short buffer used to be
/// sliced to epd_buffer_size unchecked, which reads past the end in release
/// builds and clocks the result out over SPI.
pub const Frame = [epd_buffer_size]u8;

// Partial update LUT for V2 (159 bytes) - from C reference
const wf_partial_2in9 = [_]u8{
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

/// The partial waveform less its hold pulses: of its four rows, the first and
/// the last drive the pixels a frame leaves as they were, one frame towards
/// black or towards white, to keep them there. Zeroed here, which leaves those
/// pixels alone. Used while a grey picture is on the glass, which the pulses
/// would push a little nearer black and white with every update.
const wf_partial_still: [lut_len]u8 = stillOf(&wf_partial_2in9);

/// Four-grey update LUT for V2 (159 bytes), Waveshare's `Gray4`. A full
/// refresh, driven by two bits a pixel: one from each RAM bank.
pub const gray4_2in9 = [_]u8{
    0x00, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x20, 0x60, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x28, 0x60, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x2A, 0x60, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x02, 0x00, 0x05, 0x14, 0x00, 0x00, 0x1E, 0x1E, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x02, 0x00, 0x05, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x24, 0x22, 0x22, 0x22, 0x23, 0x32, 0x00, 0x00, 0x00, 0x22, 0x17, 0x41,
    0xAE, 0x32, 0x28,
};

/// The four greys a pixel can have in a grey refresh, by the bit each RAM
/// bank holds for it: (0x24, 0x26). As Waveshare's `display_4Gray` maps them;
/// note that white is 0 in both, where in black and white it is 1.
pub const Gray = enum(u2) {
    black = 0b11,
    dark = 0b01,
    light = 0b10,
    white = 0b00,

    /// The bit for this grey in the bank written by 0x24.
    pub fn ram(self: Gray) u1 {
        return @intCast(@backingInt(self) >> 1);
    }

    /// The bit for this grey in the bank written by 0x26.
    pub fn base(self: Gray) u1 {
        return @intCast(@backingInt(self) & 1);
    }
};

// Full update LUT for V2 (159 bytes) - from C reference
const ws_20_30 = [_]u8{
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
/// recorder for the real SPI/GPIO path. The daemon instantiates it on
/// `EpdConfig`, through `panel.zig`.
///
/// The contract is checked at comptime, so a transport missing a declaration
/// fails with a direct message instead of an error deep inside a call.
pub fn Epd(comptime Transport: type) type {
    return EpdPanel(Transport, waveshare_2in9_v2);
}

/// As `Epd`, but for an explicit panel.
pub fn EpdPanel(comptime Transport: type, comptime panel: PanelSpec) type {
    comptime verifyTransport(Transport);
    comptime std.debug.assert(panel.width % 8 == 0);

    return struct {
        const Self = @This();

        /// One frame for this panel. Sized from the spec, so a buffer of the wrong
        /// length cannot be passed in.
        pub const PanelFrame = [panel.bufferSize()]u8;
        /// A frame in four greys: the bank written by 0x24 and the one written
        /// by 0x26, a bit a pixel each, laid out as `PanelFrame` is.
        pub const GrayPlanes = [2]PanelFrame;

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
            full = update_select.full,
            /// Weak waveform, applied only where the frame differs from the
            /// reference in the base RAM.
            partial = update_select.partial,
            /// Clock and analog on, without activating an update — so it cannot
            /// disturb the glass.
            power_on = 0xC0,
        };

        // Command sets as strict Enum
        const Command = enum(u8) {
            driver_output_control = 0x01,
            deep_sleep_mode = 0x10,
            data_entry_mode = 0x11,
            sw_reset = 0x12,
            master_activation = 0x20,
            display_update_control_1 = 0x21,
            display_update_control_2 = update_select.command,
            write_ram = 0x24,
            write_ram_base = 0x26,
            write_vcom_register = 0x2C,
            write_lut_register = 0x32,
            write_otp_selection = 0x37,
            border_waveform_control = 0x3C,
            set_ram_x_address_start_end_position = 0x44,
            set_ram_y_address_start_end_position = 0x45,
            set_ram_x_address_counter = 0x4E,
            set_ram_y_address_counter = 0x4F,
            gate_driving_voltage_control = 0x03,
            source_driving_voltage_control = 0x04,
            // 0x3F is often undocumented or specific LUT/Power setting
            write_vcom_register_opt = 0x3F,
            nop = 0x7F,
        };

        pub fn init(config: *Transport) Self {
            return .{ .config = config };
        }

        /// Hardware reset - V2 uses 10ms delays
        fn reset(self: *Self) !void {
            try self.config.digitalWrite(Transport.rst_pin, 1);
            self.config.delayMs(10);
            try self.config.digitalWrite(Transport.rst_pin, 0);
            self.config.delayMs(2);
            try self.config.digitalWrite(Transport.rst_pin, 1);
            self.config.delayMs(10);
        }

        // Each spiWrite is one write() to /dev/spidev, and the kernel frames every
        // write with its own chip-select assertion. DC therefore only has to be
        // correct before the call; the driver never touches CS itself.

        /// Send command byte
        fn sendCommand(self: *Self, command: Command) !void {
            try self.config.digitalWrite(Transport.dc_pin, 0);
            try self.config.spiWrite(&[_]u8{@backingInt(command)});
        }

        /// Send a command followed by its arguments, as two framed transfers.
        fn sendCommandArgs(self: *Self, command: Command, args: []const u8) !void {
            try self.config.digitalWrite(Transport.dc_pin, 0);
            try self.config.spiWrite(&[_]u8{@backingInt(command)});

            if (args.len > 0) {
                try self.config.digitalWrite(Transport.dc_pin, 1);
                try self.config.spiWrite(args);
            }
        }

        /// Send single data byte
        fn sendData(self: *Self, data: u8) !void {
            try self.config.digitalWrite(Transport.dc_pin, 1);
            try self.config.spiWrite(&[_]u8{data});
        }

        /// Send multiple data bytes
        fn sendDataSlice(self: *Self, data: []const u8) !void {
            try self.config.digitalWrite(Transport.dc_pin, 1);
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

            while (try self.config.digitalRead(Transport.busy_pin) == 1) {
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
            try self.sendCommand(.write_lut_register);
            try self.sendDataSlice(lut[0..153]);
        }

        /// Load LUT with voltage settings - from C reference
        fn loadLutByHost(self: *Self, lut: []const u8) !void {
            try self.loadLut(lut);

            try self.sendCommand(.write_vcom_register_opt); // 0x3f
            try self.sendData(lut[153]);

            try self.sendCommand(.gate_driving_voltage_control); // 0x03
            try self.sendData(lut[154]);

            try self.sendCommand(.source_driving_voltage_control); // 0x04
            try self.sendData(lut[155]); // VSH
            try self.sendData(lut[156]); // VSH2
            try self.sendData(lut[157]); // VSL

            try self.sendCommand(.write_vcom_register);
            try self.sendData(lut[158]);
        }

        /// Setting the display window
        fn setWindows(self: *Self, x_start: u16, y_start: u16, x_end: u16, y_end: u16) !void {
            const data = [_]u8{
                @intCast((x_start >> 3) & 0xFF),
                @intCast((x_end >> 3) & 0xFF),
            };
            try self.sendCommandArgs(.set_ram_x_address_start_end_position, &data);

            const data_y = [_]u8{
                @intCast(y_start & 0xFF),
                @intCast((y_start >> 8) & 0xFF),
                @intCast(y_end & 0xFF),
                @intCast((y_end >> 8) & 0xFF),
            };
            try self.sendCommandArgs(.set_ram_y_address_start_end_position, &data_y);
        }

        /// Set Cursor
        fn setCursor(self: *Self, x_start: u16, y_start: u16) !void {
            try self.sendCommand(.set_ram_x_address_counter);
            try self.sendData(@intCast((x_start >> 3) & 0xFF));

            const data_y = [_]u8{
                @intCast(y_start & 0xFF),
                @intCast((y_start >> 8) & 0xFF),
            };
            try self.sendCommandArgs(.set_ram_y_address_counter, &data_y);
        }

        /// Select what the next MASTER_ACTIVATION will do.
        fn setDisplayUpdate(self: *Self, mode: DisplayUpdate) !void {
            try self.sendCommandArgs(.display_update_control_2, &[_]u8{@backingInt(mode)});
        }

        /// Drive a full refresh: every pixel is repainted with the full waveform,
        /// which is what makes it flash.
        fn turnOnDisplay(self: *Self) !void {
            try self.setDisplayUpdate(.full);
            try self.sendCommand(.master_activation);
            try self.readBusy();
        }

        /// Drive a partial refresh: only pixels differing from the reference frame
        /// are touched, with a waveform weak enough not to flash.
        fn turnOnDisplayPartial(self: *Self) !void {
            try self.setDisplayUpdate(.partial);
            try self.sendCommand(.master_activation);
            try self.readBusy();
        }

        /// Re-initialize the e-Paper register (without module init)
        pub fn reInit(self: *Self) !void {
            try self.reset();
            self.config.delayMs(100);

            try self.readBusy();

            try self.sendCommand(.sw_reset);
            try self.readBusy();

            try self.sendCommandArgs(.driver_output_control, &panel.driverOutputControl());
            try self.sendCommandArgs(.data_entry_mode, &[_]u8{0x03});

            try self.setWindows(0, 0, panel.width - 1, panel.height - 1);

            try self.sendCommandArgs(.display_update_control_1, &[_]u8{ 0x00, 0x80 });

            try self.setCursor(0, 0);
            try self.readBusy();

            try self.loadLutByHost(panel.lut_full);
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
            var frame: PanelFrame = undefined;
            @memset(&frame, color);

            try self.sendCommand(.write_ram);
            try self.sendDataSlice(&frame);

            try self.sendCommand(.write_ram_base);
            try self.sendDataSlice(&frame);

            try self.turnOnDisplay();
        }

        /// Display image buffer (full refresh) - from C reference EPD_2IN9_V2_Display
        pub fn display(self: *Self, image: *const PanelFrame) !void {
            try self.sendCommand(.write_ram);
            try self.sendDataSlice(image);
            try self.turnOnDisplay();
        }

        /// Display Base (for partial update) - from C reference EPD_2IN9_V2_Display_Base
        pub fn displayBase(self: *Self, image: *const PanelFrame) !void {
            try self.sendCommand(.write_ram); // Write to black RAM
            try self.sendDataSlice(image);

            try self.sendCommand(.write_ram_base); // Write to base RAM
            try self.sendDataSlice(image);

            try self.turnOnDisplay();
        }

        /// Refresh fully in four greys, as Waveshare's `Init_4Gray` and
        /// `display_4Gray` do: the controller is reset and set up for it, and
        /// each bank is given one of the two bits of every pixel; see `Gray`.
        ///
        /// Leaves the controller set up for grey and both banks holding grey
        /// planes. A partial update cannot follow until `reInit` and `primeBase`
        /// have put back a black-and-white reference: `panel.zig` sees to that.
        pub fn displayGray(self: *Self, planes: *const GrayPlanes) !void {
            const lut = panel.lut_gray4 orelse @compileError("this panel shows no grey");

            try self.reset();
            self.config.delayMs(100);
            try self.readBusy();

            try self.sendCommand(.sw_reset);
            try self.readBusy();

            try self.sendCommandArgs(.driver_output_control, &panel.driverOutputControl());
            try self.sendCommandArgs(.data_entry_mode, &[_]u8{0x03});
            // One RAM column on from black and white, as in Waveshare's grey
            // mode, which leaves DISPLAY_UPDATE_CONTROL_1 at its default and so
            // drives all the sources rather than S8 onwards.
            try self.setWindows(8, 0, panel.width, panel.height - 1);
            try self.sendCommandArgs(.border_waveform_control, &[_]u8{0x04});
            try self.setCursor(8, 0);
            try self.readBusy();

            try self.loadLutByHost(lut);

            try self.sendCommand(.write_ram);
            try self.sendDataSlice(&planes[0]);
            try self.sendCommand(.write_ram_base);
            try self.sendDataSlice(&planes[1]);

            try self.turnOnDisplay();
        }

        /// Soft-reset and arm the panel for a partial update: partial LUT, border
        /// waveform and analog power-up. Drives nothing, so it cannot flicker.
        ///
        /// The RST pulse resets the registers but leaves both RAM banks intact —
        /// which is why partial updates work at all, given this runs before each one.
        fn beginPartial(self: *Self, lut: *const [lut_len]u8) !void {
            // Reset (from C reference - only 1ms delays)
            try self.config.digitalWrite(Transport.rst_pin, 0);
            self.config.delayMs(1);
            try self.config.digitalWrite(Transport.rst_pin, 1);
            self.config.delayMs(2);

            // Load partial LUT
            try self.loadLut(lut);

            // WriteOtpSelection (0x37 in C, not 0x2F!)
            try self.sendCommandArgs(.write_otp_selection, &[_]u8{
                0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00,
            });

            // Border waveform control
            try self.sendCommandArgs(.border_waveform_control, &[_]u8{0x80});

            // Display update control: clock and analog on, no display activation.
            try self.setDisplayUpdate(.power_on);
            try self.sendCommand(.master_activation);
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
        pub fn primeBase(self: *Self, image: *const PanelFrame) !void {
            try self.setWindows(0, 0, panel.width - 1, panel.height - 1);
            try self.setCursor(0, 0);
            try self.sendCommand(.write_ram_base);
            try self.sendDataSlice(image);
        }

        /// Partial update display - from C reference EPD_2IN9_V2_Display_Partial
        pub fn displayPartial(self: *Self, image: *const PanelFrame) !void {
            try self.partialWith(image, panel.lut_partial);
        }

        /// As `displayPartial`, but the pixels the frame leaves as they were are
        /// not driven at all; see `wf_partial_still`. For a grey picture on the
        /// glass, which the usual waveform would wear down to black and white.
        pub fn displayPartialStill(self: *Self, image: *const PanelFrame) !void {
            const still = comptime stillOf(panel.lut_partial);
            try self.partialWith(image, &still);
        }

        fn partialWith(self: *Self, image: *const PanelFrame, lut: *const [lut_len]u8) !void {
            try self.beginPartial(lut);

            // Reset window to full frame
            try self.setWindows(0, 0, panel.width - 1, panel.height - 1);
            try self.setCursor(0, 0);

            // Write to RAM (only 0x24, NOT 0x26!)
            try self.sendCommand(.write_ram);
            try self.sendDataSlice(image);

            try self.turnOnDisplayPartial();
        }

        /// Enter deep sleep - from C reference EPD_2IN9_V2_Sleep.
        ///
        /// Waveshare requires this before cutting power; leaving the panel driven at
        /// high voltage shortens its life. With PANEL_SLEEP on it also runs after
        /// every visible update. Waking takes `reInit`, not a full `initDisplay`,
        /// and the partial-update reference must then be restored with
        /// `primeBase` before anything else; see there.
        pub fn sleep(self: *Self) !void {
            try self.sendCommandArgs(.deep_sleep_mode, &[_]u8{deep_sleep_mode_1});
            self.config.delayMs(100);
        }
    };
}

/// `lut`, a partial waveform, less the hold pulses of its first and last rows.
fn stillOf(lut: *const [lut_len]u8) [lut_len]u8 {
    var still = lut.*;
    @memset(still[0..12], 0);
    @memset(still[36..48], 0);
    return still;
}

/// Deep Sleep Mode 1. Mode 2 (0x03) additionally drops RAM, which would make
/// the reference-frame restore in primeBase pointless.
const deep_sleep_mode_1 = 0x01;

/// Everything `Epd` needs from its transport. PWR is deliberately absent: the
/// panel's power rail is brought up by the transport's own moduleInit, and the
/// driver never touches it.
fn verifyTransport(comptime T: type) void {
    const required = [_][]const u8{
        "rst_pin",      "dc_pin",          "busy_pin",
        "delayMs",      "monotonicMillis", "moduleInit",
        "digitalWrite", "digitalRead",     "spiWrite",
    };
    for (required) |name| {
        if (!@hasDecl(T, name)) @compileError(
            "transport '" ++ @typeName(T) ++ "' is missing '" ++ name ++ "'",
        );
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

const FakeTransport = @import("fake_transport.zig").FakeTransport;

const TestEpd = Epd(FakeTransport);

fn testEpd(fake: *FakeTransport) TestEpd {
    return TestEpd.init(fake);
}

test "the 2.9in V2 spec reproduces the vendor's literals exactly" {
    // These bytes used to be written out by hand. Deriving them is only an
    // improvement if the derivation agrees with what the panel has always been
    // sent, so pin that rather than trusting the arithmetic.
    const panel = waveshare_2in9_v2;

    // Vendor reference: { 0x27, 0x01, 0x00 }. 0x0127 = 295 = height - 1.
    try testing.expectEqual([3]u8{ 0x27, 0x01, 0x00 }, panel.driverOutputControl());
    try testing.expectEqual(@as(usize, 4736), panel.bufferSize());
    try testing.expectEqual(@as(usize, 4736), @sizeOf(Frame));
    try testing.expectEqual(@as(u16, 128), panel.width);
    try testing.expectEqual(@as(u16, 296), panel.height);
}

test "a hypothetical other panel derives its own gate count" {
    // The point of the spec: nothing above is hardcoded to 296 lines.
    const other: PanelSpec = .{
        .width = 122,
        .height = 250,
        .lut_full = &ws_20_30,
        .lut_partial = &wf_partial_2in9,
    };
    // 249 = 0x00F9
    try testing.expectEqual([3]u8{ 0xF9, 0x00, 0x00 }, other.driverOutputControl());
}

test "sendCommandArgs frames the command and its payload separately" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    try epd.sendCommandArgs(.border_waveform_control, &[_]u8{0x80});

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
            try testing.expect(event.pin.pin == FakeTransport.rst_pin or
                event.pin.pin == FakeTransport.dc_pin);
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
    try testing.expectEqualSlices(u8, ws_20_30[0..153], fake.argsAfter(0x32).?);

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
    try testing.expectEqual(@as(usize, epd_buffer_size), fake.argsAfter(0x26).?.len);
}

test "displayBase writes both banks and refreshes with the full waveform" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    var frame: Frame = @splat(0x00);
    try epd.displayBase(&frame);

    try testing.expectEqual(@as(usize, epd_buffer_size), fake.argsAfter(0x24).?.len);
    try testing.expectEqual(@as(usize, epd_buffer_size), fake.argsAfter(0x26).?.len);
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

    try testing.expectEqualSlices(u8, wf_partial_2in9[0..153], fake.argsAfter(0x32).?);
    try testing.expectEqualSlices(u8, &.{0x80}, fake.argsAfter(0x3C).?);
    // Only the working bank; the reference must survive to diff against.
    try testing.expectEqual(@as(usize, epd_buffer_size), fake.argsAfter(0x24).?.len);
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
    try testing.expectEqual(@as(usize, epd_buffer_size), ram.len);
    try testing.expectEqual(@as(u8, 0xFF), ram[0]);
    try testing.expectEqual(@as(usize, epd_buffer_size), fake.argsAfter(0x26).?.len);
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

test "the grey waveform is Waveshare's, 159 bytes ending in its voltages" {
    try testing.expectEqual(@as(usize, lut_len), gray4_2in9.len);
    try testing.expectEqualSlices(u8, &.{ 0x22, 0x17, 0x41, 0xAE, 0x32, 0x28 }, gray4_2in9[153..]);
}

test "the four greys take the bits Waveshare gives them, white 0 in both banks" {
    try testing.expectEqual(@as(u1, 0), Gray.white.ram());
    try testing.expectEqual(@as(u1, 0), Gray.white.base());
    try testing.expectEqual(@as(u1, 1), Gray.light.ram());
    try testing.expectEqual(@as(u1, 0), Gray.light.base());
    try testing.expectEqual(@as(u1, 0), Gray.dark.ram());
    try testing.expectEqual(@as(u1, 1), Gray.dark.base());
    try testing.expectEqual(@as(u1, 1), Gray.black.ram());
    try testing.expectEqual(@as(u1, 1), Gray.black.base());
}

test "displayGray writes a plane to each bank with the grey waveform and refreshes fully" {
    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);

    const planes: TestEpd.GrayPlanes = .{ @splat(0x0F), @splat(0xF0) };
    try epd.displayGray(&planes);

    try testing.expect(fake.sentCommand(0x12)); // SW_RESET
    try testing.expectEqualSlices(u8, gray4_2in9[0..153], fake.argsAfter(0x32).?);
    try testing.expectEqualSlices(u8, &.{0x28}, fake.argsAfter(0x2C).?); // its VCOM, not the full one's
    // Waveshare's window and border for grey.
    try testing.expectEqualSlices(u8, &.{ 1, 16 }, fake.argsAfter(0x44).?);
    try testing.expectEqualSlices(u8, &.{1}, fake.argsAfter(0x4E).?);
    try testing.expectEqualSlices(u8, &.{0x04}, fake.argsAfter(0x3C).?);
    // No source range set, unlike black and white.
    try testing.expect(!fake.sentCommand(0x21));

    try testing.expectEqualSlices(u8, &planes[0], fake.argsAfter(0x24).?);
    try testing.expectEqualSlices(u8, &planes[1], fake.argsAfter(0x26).?);
    try testing.expectEqualSlices(u8, &.{0xC7}, fake.lastArgsAfter(0x22).?);
}

test "the still partial waveform drives changed pixels as the partial one does, and the rest not at all" {
    // Rows 1 and 2 are the changes; 0 and 3, the hold pulses, are gone.
    try testing.expectEqualSlices(u8, wf_partial_2in9[12..36], wf_partial_still[12..36]);
    try testing.expectEqualSlices(u8, wf_partial_2in9[48..], wf_partial_still[48..]);
    for (wf_partial_still[0..12]) |b| try testing.expectEqual(@as(u8, 0), b);
    for (wf_partial_still[36..48]) |b| try testing.expectEqual(@as(u8, 0), b);

    var fake = FakeTransport.init(testing.allocator);
    defer fake.deinit();
    var epd = testEpd(&fake);
    var frame: Frame = @splat(0x0F);
    try epd.displayPartialStill(&frame);
    try testing.expectEqualSlices(u8, wf_partial_still[0..153], fake.argsAfter(0x32).?);
    try testing.expectEqualSlices(u8, &.{0x0F}, fake.lastArgsAfter(0x22).?);
}
