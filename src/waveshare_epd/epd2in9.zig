const std = @import("std");
const EpdConfig = @import("epdconfig.zig").EpdConfig;

const log = std.log.scoped(.epd);

// Display resolution - Portrait (hardware orientation)
pub const EPD_WIDTH = 128;
pub const EPD_HEIGHT = 296;
pub const EPD_BUFFER_SIZE = (EPD_WIDTH / 8) * EPD_HEIGHT; // 4736 bytes

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

pub const EPD = struct {
    config: *EpdConfig,
    allocator: std.mem.Allocator,
    width: u16 = EPD_WIDTH,
    height: u16 = EPD_HEIGHT,

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

    pub fn init(allocator: std.mem.Allocator, config: *EpdConfig) EPD {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Hardware reset - V2 uses 10ms delays
    fn reset(self: *EPD) !void {
        try self.config.digitalWrite(EpdConfig.RST_PIN, 1);
        EpdConfig.delayMs(10);
        try self.config.digitalWrite(EpdConfig.RST_PIN, 0);
        EpdConfig.delayMs(2);
        try self.config.digitalWrite(EpdConfig.RST_PIN, 1);
        EpdConfig.delayMs(10);
    }

    /// Send command byte
    fn sendCommand(self: *EPD, command: Command) !void {
        try self.config.digitalWrite(EpdConfig.DC_PIN, 0);
        try self.config.digitalWrite(EpdConfig.CS_PIN, 0);
        try self.config.spiWrite(&[_]u8{@intFromEnum(command)});
        try self.config.digitalWrite(EpdConfig.CS_PIN, 1);
    }

    /// Optimization: Send command with arguments in one CS transaction
    fn sendCommandArgs(self: *EPD, command: Command, args: []const u8) !void {
        try self.config.digitalWrite(EpdConfig.DC_PIN, 0);
        try self.config.digitalWrite(EpdConfig.CS_PIN, 0);
        try self.config.spiWrite(&[_]u8{@intFromEnum(command)});
        // Keep CS low for data phase if possible, but many EPDs require CS toggle between DC change
        // Safest approach: toggle CS.
        try self.config.digitalWrite(EpdConfig.CS_PIN, 1);

        if (args.len > 0) {
            try self.config.digitalWrite(EpdConfig.DC_PIN, 1);
            try self.config.digitalWrite(EpdConfig.CS_PIN, 0);
            try self.config.spiWrite(args);
            try self.config.digitalWrite(EpdConfig.CS_PIN, 1);
        }
    }

    /// Send single data byte
    fn sendData(self: *EPD, data: u8) !void {
        try self.config.digitalWrite(EpdConfig.DC_PIN, 1);
        try self.config.digitalWrite(EpdConfig.CS_PIN, 0);
        try self.config.spiWrite(&[_]u8{data});
        try self.config.digitalWrite(EpdConfig.CS_PIN, 1);
    }

    /// Send multiple data bytes
    fn sendDataSlice(self: *EPD, data: []const u8) !void {
        try self.config.digitalWrite(EpdConfig.DC_PIN, 1);
        try self.config.digitalWrite(EpdConfig.CS_PIN, 0);
        try self.config.spiWrite(data);
        try self.config.digitalWrite(EpdConfig.CS_PIN, 1);
    }

    /// Wait until the busy_pin goes LOW
    /// V2: LOW (0) = IDLE, HIGH (1) = BUSY
    fn readBusy(self: *EPD) !void {
        log.debug("e-Paper busy", .{});

        const timeout_ms: u64 = 5000;
        const start_time = std.time.milliTimestamp();

        // BUSY pin: 1 (HIGH) = busy, 0 (LOW) = idle/ready
        while (try self.config.digitalRead(EpdConfig.BUSY_PIN) == 1) {
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > timeout_ms) {
                log.err("Timeout waiting for e-Paper (busy for {} ms)", .{elapsed});
                return error.EpdBusyTimeout;
            }
            EpdConfig.delayMs(2); // Check more frequently (was 20ms)
        }

        log.debug("e-Paper busy release", .{});
    }

    /// Load LUT (first 153 bytes only) - from C reference
    fn loadLut(self: *EPD, lut: []const u8) !void {
        try self.sendCommand(.WRITE_LUT_REGISTER);
        try self.sendDataSlice(lut[0..153]);
    }

    /// Load LUT with voltage settings - from C reference
    fn loadLutByHost(self: *EPD, lut: []const u8) !void {
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
    fn setWindows(self: *EPD, x_start: u16, y_start: u16, x_end: u16, y_end: u16) !void {
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
    fn setCursor(self: *EPD, x_start: u16, y_start: u16) !void {
        try self.sendCommand(.SET_RAM_X_ADDRESS_COUNTER);
        try self.sendData(@intCast((x_start >> 3) & 0xFF));

        const data_y = [_]u8{
            @intCast(y_start & 0xFF),
            @intCast((y_start >> 8) & 0xFF),
        };
        try self.sendCommandArgs(.SET_RAM_Y_ADDRESS_COUNTER, &data_y);
    }

    /// Turn On Display - V2 uses 0xC7
    fn turnOnDisplay(self: *EPD) !void {
        try self.sendCommandArgs(.DISPLAY_UPDATE_CONTROL_2, &[_]u8{0xC7});
        try self.sendCommand(.MASTER_ACTIVATION);
        try self.readBusy();
    }

    /// Turn On Display Partial - uses 0x0F
    fn turnOnDisplayPartial(self: *EPD) !void {
        try self.sendCommandArgs(.DISPLAY_UPDATE_CONTROL_2, &[_]u8{0x0F});
        try self.sendCommand(.MASTER_ACTIVATION);
        try self.readBusy();
    }

    /// Re-initialize the e-Paper register (without module init)
    pub fn reInit(self: *EPD) !void {
        try self.reset();
        EpdConfig.delayMs(100);

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
    pub fn initDisplay(self: *EPD) !void {
        try self.config.moduleInit();
        try self.reInit();
    }

    /// Clear screen - optimized chunked writer
    pub fn clear(self: *EPD, color: u8) !void {
        var chunk_buf: [128]u8 = undefined;
        @memset(&chunk_buf, color);

        try self.sendCommand(.WRITE_RAM); // black/white
        var remaining: usize = EPD_BUFFER_SIZE;
        while (remaining > 0) {
            const size = @min(remaining, chunk_buf.len);
            try self.sendDataSlice(chunk_buf[0..size]);
            remaining -= size;
        }

        try self.sendCommand(.WRITE_RAM_BASE); // base
        remaining = EPD_BUFFER_SIZE;
        while (remaining > 0) {
            const size = @min(remaining, chunk_buf.len);
            try self.sendDataSlice(chunk_buf[0..size]);
            remaining -= size;
        }

        try self.turnOnDisplay();
    }

    /// Display image buffer (full refresh) - from C reference EPD_2IN9_V2_Display
    pub fn display(self: *EPD, image: []const u8) !void {
        try self.sendCommand(.WRITE_RAM);
        try self.sendDataSlice(image[0..EPD_BUFFER_SIZE]);
        try self.turnOnDisplay();
    }

    /// Display Base (for partial update) - from C reference EPD_2IN9_V2_Display_Base
    pub fn displayBase(self: *EPD, image: []const u8) !void {
        try self.sendCommand(.WRITE_RAM); // Write to black RAM
        try self.sendDataSlice(image[0..EPD_BUFFER_SIZE]);

        try self.sendCommand(.WRITE_RAM_BASE); // Write to base RAM
        try self.sendDataSlice(image[0..EPD_BUFFER_SIZE]);

        try self.turnOnDisplay();
    }

    /// Partial update display - from C reference EPD_2IN9_V2_Display_Partial
    pub fn displayPartial(self: *EPD, image: []const u8) !void {
        // Reset (from C reference - only 1ms delays)
        try self.config.digitalWrite(EpdConfig.RST_PIN, 0);
        EpdConfig.delayMs(1);
        try self.config.digitalWrite(EpdConfig.RST_PIN, 1);
        EpdConfig.delayMs(2);

        // Load partial LUT
        try self.loadLut(&WF_PARTIAL_2IN9);

        // WriteOtpSelection (0x37 in C, not 0x2F!)
        try self.sendCommandArgs(.WRITE_OTP_SELECTION, &[_]u8{
            0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00,
        });

        // Border waveform control
        try self.sendCommandArgs(.BORDER_WAVEFORM_CONTROL, &[_]u8{0x80});

        // Display update control
        try self.sendCommandArgs(.DISPLAY_UPDATE_CONTROL_2, &[_]u8{0xC0});
        try self.sendCommand(.MASTER_ACTIVATION);
        try self.readBusy();

        // Reset window to full frame
        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);
        try self.setCursor(0, 0);

        // Write to RAM (only 0x24, NOT 0x26!)
        try self.sendCommand(.WRITE_RAM);
        try self.sendDataSlice(image[0..EPD_BUFFER_SIZE]);

        try self.turnOnDisplayPartial();
    }

    /// Partial update of specific window area
    /// Based on C reference but with windowing support
    pub fn displayPartialWindow(self: *EPD, image: []const u8, x: u16, y: u16, width: u16, height: u16) !void {
        // Reset (from C reference)
        try self.config.digitalWrite(EpdConfig.RST_PIN, 0);
        EpdConfig.delayMs(1);
        try self.config.digitalWrite(EpdConfig.RST_PIN, 1);
        EpdConfig.delayMs(2);

        // Load partial LUT
        try self.loadLut(&WF_PARTIAL_2IN9);

        // WriteOtpSelection
        try self.sendCommandArgs(.WRITE_OTP_SELECTION, &[_]u8{
            0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00,
        });

        // Border waveform control
        try self.sendCommandArgs(.BORDER_WAVEFORM_CONTROL, &[_]u8{0x80});

        // Display update control
        try self.sendCommandArgs(.DISPLAY_UPDATE_CONTROL_2, &[_]u8{0xC0});
        try self.sendCommand(.MASTER_ACTIVATION);
        try self.readBusy();

        // Set window for partial update
        try self.setWindows(x, y, x + width - 1, y + height - 1);
        try self.setCursor(x, y);

        // Calculate buffer position and size
        const bytes_per_line = EPD_WIDTH / 8; // 16 bytes per line
        const x_byte = x / 8;
        const window_bytes_per_line = (width + 7) / 8;

        // Write to RAM (only window area, only 0x24)
        try self.sendCommand(.WRITE_RAM);
        for (0..height) |row| {
            const src_offset = (y + row) * bytes_per_line + x_byte;
            try self.sendDataSlice(image[src_offset .. src_offset + window_bytes_per_line]);
        }

        try self.turnOnDisplayPartial();

        // Reset window to full frame
        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);
        try self.setCursor(0, 0);
    }

    /// Enter sleep mode - from C reference EPD_2IN9_V2_Sleep
    pub fn sleep(self: *EPD) !void {
        try self.sendCommandArgs(.DEEP_SLEEP_MODE, &[_]u8{0x01});
        EpdConfig.delayMs(100);
    }
};
