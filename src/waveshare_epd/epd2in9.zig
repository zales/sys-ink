const std = @import("std");
const EpdConfig = @import("epdconfig.zig").EpdConfig;

// Display resolution - Portrait (hardware orientation)
pub const EPD_WIDTH = 128;
pub const EPD_HEIGHT = 296;

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

    // Command constants
    const DRIVER_OUTPUT_CONTROL: u8 = 0x01;
    const DEEP_SLEEP_MODE: u8 = 0x10;
    const DATA_ENTRY_MODE: u8 = 0x11;
    const SW_RESET: u8 = 0x12;
    const MASTER_ACTIVATION: u8 = 0x20;
    const DISPLAY_UPDATE_CONTROL_1: u8 = 0x21;
    const DISPLAY_UPDATE_CONTROL_2: u8 = 0x22;
    const WRITE_RAM: u8 = 0x24;
    const WRITE_RAM_BASE: u8 = 0x26;
    const WRITE_VCOM_REGISTER: u8 = 0x2C;
    const WRITE_LUT_REGISTER: u8 = 0x32;
    const WRITE_OTP_SELECTION: u8 = 0x37;
    const BORDER_WAVEFORM_CONTROL: u8 = 0x3C;
    const SET_RAM_X_ADDRESS_START_END_POSITION: u8 = 0x44;
    const SET_RAM_Y_ADDRESS_START_END_POSITION: u8 = 0x45;
    const SET_RAM_X_ADDRESS_COUNTER: u8 = 0x4E;
    const SET_RAM_Y_ADDRESS_COUNTER: u8 = 0x4F;

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
    fn sendCommand(self: *EPD, command: u8) !void {
        try self.config.digitalWrite(EpdConfig.DC_PIN, 0);
        try self.config.digitalWrite(EpdConfig.CS_PIN, 0);
        try self.config.spiWrite(&[_]u8{command});
        try self.config.digitalWrite(EpdConfig.CS_PIN, 1);
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
        std.log.debug("e-Paper busy", .{});

        const timeout_ms: u64 = 5000;
        const start_time = std.time.milliTimestamp();

        // BUSY pin: 1 (HIGH) = busy, 0 (LOW) = idle/ready
        while (try self.config.digitalRead(EpdConfig.BUSY_PIN) == 1) {
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > timeout_ms) {
                std.log.err("Timeout waiting for e-Paper (busy for {} ms)", .{elapsed});
                return error.EpdBusyTimeout;
            }
            EpdConfig.delayMs(20);
        }

        std.log.debug("e-Paper busy release", .{});
    }

    /// Load LUT (first 153 bytes only) - from C reference
    fn loadLut(self: *EPD, lut: []const u8) !void {
        try self.sendCommand(WRITE_LUT_REGISTER);
        for (lut[0..153]) |byte| {
            try self.sendData(byte);
        }
    }

    /// Load LUT with voltage settings - from C reference
    fn loadLutByHost(self: *EPD, lut: []const u8) !void {
        try self.loadLut(lut);

        try self.sendCommand(0x3f);
        try self.sendData(lut[153]);

        try self.sendCommand(0x03); // gate voltage
        try self.sendData(lut[154]);

        try self.sendCommand(0x04); // source voltage
        try self.sendData(lut[155]); // VSH
        try self.sendData(lut[156]); // VSH2
        try self.sendData(lut[157]); // VSL

        try self.sendCommand(WRITE_VCOM_REGISTER);
        try self.sendData(lut[158]);
    }

    /// Setting the display window
    fn setWindows(self: *EPD, x_start: u16, y_start: u16, x_end: u16, y_end: u16) !void {
        try self.sendCommand(SET_RAM_X_ADDRESS_START_END_POSITION);
        try self.sendData(@intCast((x_start >> 3) & 0xFF));
        try self.sendData(@intCast((x_end >> 3) & 0xFF));

        try self.sendCommand(SET_RAM_Y_ADDRESS_START_END_POSITION);
        try self.sendData(@intCast(y_start & 0xFF));
        try self.sendData(@intCast((y_start >> 8) & 0xFF));
        try self.sendData(@intCast(y_end & 0xFF));
        try self.sendData(@intCast((y_end >> 8) & 0xFF));
    }

    /// Set Cursor
    fn setCursor(self: *EPD, x_start: u16, y_start: u16) !void {
        try self.sendCommand(SET_RAM_X_ADDRESS_COUNTER);
        try self.sendData(@intCast((x_start >> 3) & 0xFF));

        try self.sendCommand(SET_RAM_Y_ADDRESS_COUNTER);
        try self.sendData(@intCast(y_start & 0xFF));
        try self.sendData(@intCast((y_start >> 8) & 0xFF));
    }

    /// Turn On Display - V2 uses 0xC7
    fn turnOnDisplay(self: *EPD) !void {
        try self.sendCommand(DISPLAY_UPDATE_CONTROL_2);
        try self.sendData(0xC7);
        try self.sendCommand(MASTER_ACTIVATION);
        try self.readBusy();
    }

    /// Turn On Display Partial - uses 0x0F
    fn turnOnDisplayPartial(self: *EPD) !void {
        try self.sendCommand(DISPLAY_UPDATE_CONTROL_2);
        try self.sendData(0x0F);
        try self.sendCommand(MASTER_ACTIVATION);
        try self.readBusy();
    }

    /// Initialize the e-Paper register - from C reference EPD_2IN9_V2_Init
    pub fn initDisplay(self: *EPD) !void {
        try self.config.moduleInit();
        try self.reset();
        EpdConfig.delayMs(100);

        try self.readBusy();

        try self.sendCommand(SW_RESET);
        try self.readBusy();

        try self.sendCommand(DRIVER_OUTPUT_CONTROL);
        try self.sendData(0x27);
        try self.sendData(0x01);
        try self.sendData(0x00);

        try self.sendCommand(DATA_ENTRY_MODE);
        try self.sendData(0x03);

        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);

        try self.sendCommand(DISPLAY_UPDATE_CONTROL_1);
        try self.sendData(0x00);
        try self.sendData(0x80);

        try self.setCursor(0, 0);
        try self.readBusy();

        try self.loadLutByHost(&WS_20_30);
    }

    /// Clear screen - from C reference EPD_2IN9_V2_Clear
    pub fn clear(self: *EPD, color: u8) !void {
        try self.sendCommand(WRITE_RAM); // black/white
        for (0..4736) |_| {
            try self.sendData(color);
        }

        try self.sendCommand(WRITE_RAM_BASE); // base
        for (0..4736) |_| {
            try self.sendData(color);
        }

        try self.turnOnDisplay();
    }

    /// Display image buffer (full refresh) - from C reference EPD_2IN9_V2_Display
    pub fn display(self: *EPD, image: []const u8) !void {
        try self.sendCommand(WRITE_RAM);
        for (0..4736) |i| {
            try self.sendData(image[i]);
        }
        try self.turnOnDisplay();
    }

    /// Display Base (for partial update) - from C reference EPD_2IN9_V2_Display_Base
    pub fn displayBase(self: *EPD, image: []const u8) !void {
        try self.sendCommand(WRITE_RAM); // Write to black RAM
        for (0..4736) |i| {
            try self.sendData(image[i]);
        }

        try self.sendCommand(WRITE_RAM_BASE); // Write to base RAM
        for (0..4736) |i| {
            try self.sendData(image[i]);
        }

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
        try self.sendCommand(WRITE_OTP_SELECTION);
        try self.sendDataSlice(&[_]u8{
            0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00,
        });

        // Border waveform control
        try self.sendCommand(BORDER_WAVEFORM_CONTROL);
        try self.sendData(0x80);

        // Display update control
        try self.sendCommand(DISPLAY_UPDATE_CONTROL_2);
        try self.sendData(0xC0);
        try self.sendCommand(MASTER_ACTIVATION);
        try self.readBusy();

        // Reset window to full frame
        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);
        try self.setCursor(0, 0);

        // Write to RAM (only 0x24, NOT 0x26!)
        try self.sendCommand(WRITE_RAM);
        for (0..4736) |i| {
            try self.sendData(image[i]);
        }

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
        try self.sendCommand(WRITE_OTP_SELECTION);
        try self.sendDataSlice(&[_]u8{
            0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00,
        });

        // Border waveform control
        try self.sendCommand(BORDER_WAVEFORM_CONTROL);
        try self.sendData(0x80);

        // Display update control
        try self.sendCommand(DISPLAY_UPDATE_CONTROL_2);
        try self.sendData(0xC0);
        try self.sendCommand(MASTER_ACTIVATION);
        try self.readBusy();

        // Set window for partial update
        try self.setWindows(x, y, x + width - 1, y + height - 1);
        try self.setCursor(x, y);

        // Calculate buffer position and size
        const bytes_per_line = EPD_WIDTH / 8; // 16 bytes per line
        const x_byte = x / 8;
        const window_bytes_per_line = (width + 7) / 8;

        // Write to RAM (only window area, only 0x24)
        try self.sendCommand(WRITE_RAM);
        for (0..height) |row| {
            const src_offset = (y + row) * bytes_per_line + x_byte;
            for (0..window_bytes_per_line) |col| {
                try self.sendData(image[src_offset + col]);
            }
        }

        try self.turnOnDisplayPartial();

        // Reset window to full frame
        try self.setWindows(0, 0, EPD_WIDTH - 1, EPD_HEIGHT - 1);
        try self.setCursor(0, 0);
    }

    /// Enter sleep mode - from C reference EPD_2IN9_V2_Sleep
    pub fn sleep(self: *EPD) !void {
        try self.sendCommand(DEEP_SLEEP_MODE);
        try self.sendData(0x01);
        EpdConfig.delayMs(100);
    }
};
