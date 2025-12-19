const std = @import("std");
const EPD = @import("waveshare_epd/epd2in9.zig").EPD;
const EpdConfig = @import("waveshare_epd/epdconfig.zig").EpdConfig;
const display_config = @import("display_config.zig");
const config = @import("config.zig");
const Graphics = @import("graphics.zig");
const Bitmap = Graphics.Bitmap;
const FontType = Graphics.Bitmap.FontType;
const BmpExporter = @import("bmp.zig").BmpExporter;

/// Display renderer that manages Bitmap and EPD
pub const DisplayRenderer = struct {
    bitmap: Bitmap,
    epd: EPD,
    epd_config: *EpdConfig,
    epd_buffer: []u8,
    allocator: std.mem.Allocator,
    bmp_exporter: BmpExporter,
    grid_cached: bool = false,

    pub fn init(allocator: std.mem.Allocator) !DisplayRenderer {
        const bitmap = try Bitmap.init(allocator, display_config.DISPLAY_WIDTH, display_config.DISPLAY_HEIGHT);

        const epd_cfg = try allocator.create(EpdConfig);
        epd_cfg.* = EpdConfig.init(allocator);

        const epd = EPD.init(allocator, epd_cfg);

        // Allocate buffer for EPD (128x296 portrait = 4736 bytes)
        const epd_buffer = try allocator.alloc(u8, (128 / 8) * 296);

        return .{
            .bitmap = bitmap,
            .epd = epd,
            .epd_config = epd_cfg,
            .epd_buffer = epd_buffer,
            .allocator = allocator,
            .bmp_exporter = BmpExporter.init(allocator),
        };
    }

    pub fn deinit(self: *DisplayRenderer) void {
        self.bitmap.deinit();
        self.allocator.free(self.epd_buffer);
        self.epd_config.moduleExit();
        self.allocator.destroy(self.epd_config);
    }

    /// Initialize display
    pub fn startup(self: *DisplayRenderer) !void {
        try self.epd.initDisplay();
        try self.epd.clear(0xFF);
    }

    /// Render grid layout
    pub fn renderGrid(self: *DisplayRenderer) void {
        if (self.grid_cached) return;

        self.bitmap.clear(.White);

        const v_line1: i32 = display_config.VERTICAL_LINE_1;
        const v_line2: i32 = display_config.VERTICAL_LINE_2;
        const h_line_main: i32 = display_config.HORIZONTAL_LINE_MAIN;
        const display_w: i32 = display_config.DISPLAY_WIDTH;

        // Draw vertical divider lines
        self.bitmap.drawLine(v_line1, display_config.CPU_LINE_Y, v_line1, h_line_main, .Black);
        self.bitmap.drawLine(v_line2, display_config.CPU_LINE_Y, v_line2, h_line_main, .Black);

        // Draw main horizontal divider
        self.bitmap.drawLine(0, h_line_main, display_w, h_line_main, .Black);

        // CPU section
        const cpu_line_y: i32 = display_config.CPU_LINE_Y;
        self.bitmap.drawLine(26, cpu_line_y, 99, cpu_line_y, .Black);
        self.drawText(1, display_config.CPU_LABEL_Y, "cpu", .Ubuntu14, false);
        self.drawText(display_config.CPU_ICON_X, display_config.CPU_ICON_Y_LOAD, display_config.ICON_CPU, .Material24, false);
        self.drawText(display_config.CPU_ICON_X, display_config.CPU_ICON_Y_TEMP, display_config.ICON_TEMPERATURE, .Material24, false);

        // APT section
        const apt_line_y: i32 = display_config.APT_LINE_Y;
        self.drawText(display_config.APT_LABEL_X, display_config.APT_LABEL_Y, "apt", .Ubuntu14, false);
        self.bitmap.drawLine(226, apt_line_y, 248, apt_line_y, .Black);

        // NET section
        const net_line_x: i32 = display_config.NET_LINE_X;
        const net_line_y: i32 = display_config.NET_LINE_Y;
        self.drawText(display_config.NET_LABEL_X, display_config.NET_LABEL_Y, "net", .Ubuntu14, false);
        self.bitmap.drawLine(net_line_x, net_line_y, net_line_x, h_line_main, .Black);
        self.bitmap.drawLine(272, net_line_y, display_w, net_line_y, .Black);

        // MEM section
        const mem_line_y: i32 = display_config.MEM_LINE_Y;
        const cpu_right: i32 = display_config.SECTION_CPU_RIGHT;
        self.drawText(display_config.MEM_LABEL_X, display_config.MEM_LABEL_Y, "mem", .Ubuntu14, false);
        self.bitmap.drawLine(34, mem_line_y, cpu_right, mem_line_y, .Black);
        self.drawText(display_config.MEM_ICON_X, display_config.MEM_ICON_Y, display_config.ICON_MEMORY, .Material24, false);

        // NVME section
        const nvme_line_y: i32 = display_config.NVME_LINE_Y;
        const nvme_right: i32 = display_config.SECTION_NVME_RIGHT;
        self.drawText(display_config.NVME_LABEL_X, display_config.NVME_LABEL_Y, "nvme", .Ubuntu14, false);
        self.bitmap.drawLine(140, nvme_line_y, nvme_right, nvme_line_y, .Black);
        self.drawText(display_config.NVME_ICON_X, display_config.NVME_ICON_Y_DISK, display_config.ICON_HARD_DRIVE, .Material24, false);
        self.drawText(display_config.NVME_ICON_X, display_config.NVME_ICON_Y_TEMP, display_config.ICON_TEMPERATURE, .Material24, false);

        // FAN section
        const fan_line_y: i32 = display_config.FAN_LINE_Y;
        self.drawText(display_config.FAN_LABEL_X, display_config.FAN_LABEL_Y, "fan", .Ubuntu14, false);
        self.bitmap.drawLine(124, fan_line_y, nvme_right, fan_line_y, .Black);
        self.drawText(display_config.FAN_ICON_X, display_config.FAN_ICON_Y, display_config.ICON_FAN, .Material24, false);

        // Traffic section
        const down_line_y: i32 = display_config.TRAFFIC_DOWN_LINE_Y;
        self.drawText(display_config.TRAFFIC_DOWN_LABEL_X, display_config.TRAFFIC_DOWN_LABEL_Y, "down", .Ubuntu14, false);
        self.bitmap.drawLine(242, down_line_y, 261, down_line_y, .Black);
        self.drawText(display_config.TRAFFIC_DOWN_ICON_X, display_config.TRAFFIC_DOWN_ICON_Y, display_config.ICON_DOWNLOAD, .Material24, false);

        const up_line_y: i32 = display_config.TRAFFIC_UP_LINE_Y;
        self.drawText(display_config.TRAFFIC_UP_LABEL_X, display_config.TRAFFIC_UP_LABEL_Y, "up", .Ubuntu14, false);
        self.bitmap.drawLine(222, up_line_y, 261, up_line_y, .Black);
        self.drawText(display_config.TRAFFIC_UP_ICON_X, display_config.TRAFFIC_UP_ICON_Y, display_config.ICON_UPLOAD, .Material24, false);

        // Status bar icons
        self.drawText(display_config.IP_ICON_X, display_config.IP_ICON_Y, display_config.ICON_NETWORK, .Material14, false);
        self.drawText(display_config.UPTIME_ICON_X, display_config.UPTIME_ICON_Y, display_config.ICON_UPTIME, .Material14, false);

        self.grid_cached = true;
    }

    fn drawText(self: *DisplayRenderer, x: i32, y: i32, text: []const u8, font: FontType, inverted: bool) void {
        const color: Graphics.Color = if (inverted) .White else .Black;

        if (inverted) {
            // Draw black background
            const w = self.bitmap.measureText(text, font);
            // Height is approximate based on font name, or we can get it from font data
            // Let's use a safe height
            const h: u32 = switch (font) {
                .Ubuntu14 => 16,
                .Ubuntu20 => 22,
                .Ubuntu24 => 26,
                .Ubuntu26 => 28,
                .Ubuntu34 => 36,
                else => 20,
            };

            // Adjust Y for background (Y is baseline)
            const bg_y = y - @as(i32, @intCast(h)) + 4; // Approximate
            self.bitmap.fillRect(x - 2, bg_y, w + 4, h + 2, .Black);
        }

        self.bitmap.drawTextFont(x, y, text, font, color);
    }

    /// Update display
    pub fn updateDisplay(self: *DisplayRenderer, partial: bool) !void {
        std.log.info("updateDisplay: START (Native)", .{});

        // Convert Bitmap to 1-bit
        self.convertTo1Bit(self.epd_buffer);

        if (partial) {
            try self.epd.displayPartial(self.epd_buffer);
        } else {
            try self.epd.display(self.epd_buffer);
        }

        std.log.info("updateDisplay: EPD done", .{});

        self.exportBmp() catch |err| {
            std.log.err("Failed to export BMP: {}", .{err});
        };
    }

    /// Convert Bitmap to 1-bit packed format for EPD (with rotation)
    pub fn convertTo1Bit(self: *DisplayRenderer, output: []u8) void {
        // Clear output buffer (white = 0xFF)
        @memset(output, 0xFF);

        var y: u32 = 0;
        while (y < self.bitmap.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.bitmap.width) : (x += 1) {
                const idx = y * self.bitmap.stride + x;
                const val = self.bitmap.data[idx];
                const is_black = val < 128;

                if (is_black) {
                    // Rotate 90° clockwise: (x,y) logical -> (y, 295-x) hardware
                    const hw_x = y;
                    const hw_y = (self.bitmap.width - 1) - x;
                    const hw_width: u32 = 128;

                    const byte_idx = (hw_y * (hw_width / 8)) + (hw_x / 8);
                    const bit_idx: u3 = @intCast(hw_x % 8);

                    output[byte_idx] &= ~(@as(u8, 0x80) >> bit_idx);
                }
            }
        }
    }

    /// Export as BMP
    pub fn exportBmp(self: *DisplayRenderer) !void {
        if (!config.Config.export_bmp) return;

        const width = self.bitmap.width;
        const height = self.bitmap.height;

        // Convert to 1-bit without rotation
        const buffer_size = (height * ((width + 7) / 8));
        const buffer = try self.allocator.alloc(u8, buffer_size);
        defer self.allocator.free(buffer);
        @memset(buffer, 0xFF);

        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const idx = y * self.bitmap.stride + x;
                if (self.bitmap.data[idx] < 128) {
                    const byte_idx = (y * ((width + 7) / 8)) + (x / 8);
                    const bit_idx: u3 = @intCast(x % 8);
                    buffer[byte_idx] &= ~(@as(u8, 0x80) >> bit_idx);
                }
            }
        }

        try self.bmp_exporter.save(buffer, @intCast(width), @intCast(height), config.Config.bmp_export_path);
    }

    /// Render CPU load and temperature
    pub fn renderCpuLoad(self: *DisplayRenderer, load: u8, temp: u32) void {
        const is_load_critical = load >= config.Config.threshold_cpu_critical;
        const is_temp_critical = temp >= config.Config.threshold_temp_critical;

        const x: i32 = display_config.CPU_VALUE_X;
        const y_load: i32 = display_config.CPU_VALUE_Y_LOAD;
        const y_temp: i32 = display_config.CPU_VALUE_Y_TEMP;

        const ascent = self.bitmap.getFontAscent(.Ubuntu24);
        self.bitmap.fillRect(x, y_load - ascent, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, .White);
        self.bitmap.fillRect(x, y_temp - ascent, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, .White);

        var buf1: [16]u8 = undefined;
        const load_text = std.fmt.bufPrint(&buf1, "{d}%", .{load}) catch "?";
        self.drawText(x, y_load, load_text, .Ubuntu24, is_load_critical);

        var buf2: [16]u8 = undefined;
        const temp_text = std.fmt.bufPrint(&buf2, "{d}C", .{temp}) catch "?";
        self.drawText(x, y_temp, temp_text, .Ubuntu24, is_temp_critical);
    }

    /// Render memory usage
    pub fn renderMemory(self: *DisplayRenderer, usage: u8) void {
        const is_critical = usage >= config.Config.threshold_mem_critical;
        const x: i32 = display_config.MEM_VALUE_X;
        const y: i32 = display_config.MEM_VALUE_Y;

        const ascent = self.bitmap.getFontAscent(.Ubuntu26);
        self.bitmap.fillRect(x, y - ascent, display_config.TEXT_AREA_MEM.width, display_config.TEXT_AREA_MEM.height, .White);

        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}%", .{usage}) catch "?";
        self.drawText(x, y, text, .Ubuntu26, is_critical);
    }

    /// Render NVMe stats
    pub fn renderNvmeStats(self: *DisplayRenderer, usage: u8, temp: u32) void {
        const is_usage_critical = usage >= config.Config.threshold_disk_critical;
        const is_temp_critical = temp >= config.Config.threshold_temp_critical;

        const x: i32 = display_config.NVME_VALUE_X;
        const y_disk: i32 = display_config.NVME_VALUE_Y_DISK;
        const y_temp: i32 = display_config.NVME_VALUE_Y_TEMP;

        const ascent = self.bitmap.getFontAscent(.Ubuntu26);
        self.bitmap.fillRect(x, y_disk - ascent, display_config.TEXT_AREA_NVME.width, display_config.TEXT_AREA_NVME.height, .White);
        self.bitmap.fillRect(x, y_temp - ascent, display_config.TEXT_AREA_NVME.width, display_config.TEXT_AREA_NVME.height, .White);

        var buf1: [16]u8 = undefined;
        const usage_text = std.fmt.bufPrint(&buf1, "{d}%", .{usage}) catch "?";
        self.drawText(x, y_disk, usage_text, .Ubuntu26, is_usage_critical);

        var buf2: [16]u8 = undefined;
        const temp_text = std.fmt.bufPrint(&buf2, "{d}C", .{temp}) catch "?";
        self.drawText(x, y_temp, temp_text, .Ubuntu26, is_temp_critical);
    }

    /// Render fan speed
    pub fn renderFanSpeed(self: *DisplayRenderer, rpm: u32) void {
        const x: i32 = display_config.FAN_VALUE_X;
        const y: i32 = display_config.FAN_VALUE_Y;

        const ascent = self.bitmap.getFontAscent(.Ubuntu24);
        self.bitmap.fillRect(x, y - ascent, display_config.TEXT_AREA_FAN.width, display_config.TEXT_AREA_FAN.height, .White);

        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{rpm}) catch "?";
        self.drawText(x, y, text, .Ubuntu24, false);
    }

    /// Render IP address
    pub fn renderIpAddress(self: *DisplayRenderer, ip: []const u8) void {
        const x: i32 = display_config.IP_VALUE_X;
        const y: i32 = display_config.IP_VALUE_Y;

        const ascent = self.bitmap.getFontAscent(.Ubuntu14);
        self.bitmap.fillRect(x, y - ascent, display_config.TEXT_AREA_IP.width, display_config.TEXT_AREA_IP.height, .White);
        const display_ip = if (ip.len > 15) ip[0..15] else ip;
        self.drawText(x, y, display_ip, .Ubuntu14, false);
    }

    /// Render uptime
    pub fn renderUptime(self: *DisplayRenderer, days: u32, hours: u32, minutes: u32) void {
        const x: i32 = display_config.UPTIME_VALUE_X;
        const y: i32 = display_config.UPTIME_VALUE_Y;

        const ascent = self.bitmap.getFontAscent(.Ubuntu14);
        self.bitmap.fillRect(x, y - ascent, display_config.TEXT_AREA_UPTIME.width, display_config.TEXT_AREA_UPTIME.height, .White);

        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}d {d}h {d}m", .{ days, hours, minutes }) catch "?";
        self.drawText(x, y, text, .Ubuntu14, false);
    }

    /// Render signal strength
    pub fn renderSignalStrength(self: *DisplayRenderer, signal: ?i32) void {
        const val_x: i32 = display_config.SIGNAL_VALUE_X;
        const val_y: i32 = display_config.SIGNAL_VALUE_Y;
        const icon_x: i32 = display_config.SIGNAL_ICON_X;
        const icon_y: i32 = display_config.SIGNAL_ICON_Y;

        const ascent = self.bitmap.getFontAscent(.Ubuntu14);
        self.bitmap.fillRect(val_x - 20, val_y - ascent, display_config.TEXT_AREA_SIGNAL.width, display_config.TEXT_AREA_SIGNAL.height, .White);

        // Draw WiFi icon
        const icon = if (signal != null) display_config.ICON_WIFI_SIGNAL else display_config.ICON_WIFI_NO_SIGNAL;
        self.drawText(icon_x, icon_y, icon, .Material14, false);

        var buf: [16]u8 = undefined;
        const text = if (signal) |s|
            std.fmt.bufPrint(&buf, "{d} dBm", .{s}) catch "?"
        else
            "N/A";
        self.drawText(val_x, val_y, text, .Ubuntu14, false);
    }

    /// Render network traffic
    pub fn renderTraffic(self: *DisplayRenderer, download_speed: f64, download_unit: []const u8, upload_speed: f64, upload_unit: []const u8) void {
        const down_val_x: i32 = display_config.TRAFFIC_DOWN_VALUE_X;
        const down_val_y: i32 = display_config.TRAFFIC_DOWN_VALUE_Y;
        const down_unit_x: i32 = display_config.TRAFFIC_DOWN_UNIT_X;
        const down_unit_y: i32 = display_config.TRAFFIC_DOWN_UNIT_Y;

        const up_val_x: i32 = display_config.TRAFFIC_UP_VALUE_X;
        const up_val_y: i32 = display_config.TRAFFIC_UP_VALUE_Y;
        const up_unit_x: i32 = display_config.TRAFFIC_UP_UNIT_X;
        const up_unit_y: i32 = display_config.TRAFFIC_UP_UNIT_Y;

        const ascent20 = self.bitmap.getFontAscent(.Ubuntu20);
        const ascent14 = self.bitmap.getFontAscent(.Ubuntu14);

        // Clear value and unit areas
        self.bitmap.fillRect(down_val_x, down_val_y - ascent20, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, .White);
        self.bitmap.fillRect(down_unit_x, down_unit_y - ascent14, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, .White);

        var buf1: [16]u8 = undefined;
        const down_text = std.fmt.bufPrint(&buf1, "{d:.2}", .{download_speed}) catch "?";
        self.drawText(down_val_x, down_val_y, down_text, .Ubuntu20, false);

        var unit_buf1: [16]u8 = undefined;
        const down_unit_text = std.fmt.bufPrint(&unit_buf1, "{s}/s", .{download_unit}) catch "?";
        self.drawText(down_unit_x, down_unit_y, down_unit_text, .Ubuntu14, false);

        // Clear upload areas
        self.bitmap.fillRect(up_val_x, up_val_y - ascent20, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, .White);
        self.bitmap.fillRect(up_unit_x, up_unit_y - ascent14, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, .White);

        var buf2: [16]u8 = undefined;
        const up_text = std.fmt.bufPrint(&buf2, "{d:.2}", .{upload_speed}) catch "?";
        self.drawText(up_val_x, up_val_y, up_text, .Ubuntu20, false);

        var unit_buf2: [16]u8 = undefined;
        const up_unit_text = std.fmt.bufPrint(&unit_buf2, "{s}/s", .{upload_unit}) catch "?";
        self.drawText(up_unit_x, up_unit_y, up_unit_text, .Ubuntu14, false);
    }

    /// Render APT updates count
    pub fn renderAptUpdates(self: *DisplayRenderer, count: u32) void {
        const x: i32 = display_config.APT_VALUE_X;
        const y: i32 = display_config.APT_VALUE_Y;

        const ascent = self.bitmap.getFontAscent(.Ubuntu24);
        self.bitmap.fillRect(x, y - ascent, display_config.TEXT_AREA_APT.width, display_config.TEXT_AREA_APT.height, .White);

        if (count == 0) {
            // Show checkmark icon
            self.drawText(x, y, display_config.ICON_CHECK, .Material24, false);
        } else {
            // Show number
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "?";
            self.drawText(x, y, text, .Ubuntu24, false);
        }
    }

    /// Render internet connection status
    pub fn renderInternetStatus(self: *DisplayRenderer, connected: bool) void {
        const x: i32 = display_config.NET_ICON_X;
        const y: i32 = display_config.NET_ICON_Y;

        const ascent = self.bitmap.getFontAscent(.Material24);
        self.bitmap.fillRect(x, y - ascent, display_config.TEXT_AREA_NET.width, display_config.TEXT_AREA_NET.height, .White);

        // Show WiFi OK or WiFi OFF icon
        const icon = if (connected) display_config.ICON_WIFI_OK else display_config.ICON_WIFI_OFF;
        self.drawText(x, y, icon, .Material24, false);
    }

    /// Go to sleep
    pub fn goToSleep(self: *DisplayRenderer) !void {
        // Clear to black
        self.bitmap.clear(.Black);

        // Draw white vertical line
        const line_x: i32 = display_config.SLEEP_LINE_X;
        const line_y: i32 = display_config.SLEEP_LINE_Y;
        const line_w: u32 = display_config.SLEEP_LINE_W;
        const line_h: u32 = display_config.HORIZONTAL_LINE_MAIN - display_config.SLEEP_LINE_Y;
        self.bitmap.fillRect(line_x, line_y, line_w, line_h, .White);

        // Draw white network icon
        const icon_x: i32 = display_config.SLEEP_ICON_X;
        const icon_y: i32 = display_config.SLEEP_ICON_Y;
        self.drawText(icon_x, icon_y, display_config.ICON_SLEEP_NET, .Material50, true);

        // Draw white "ZlsNas" text
        const title_x: i32 = display_config.SLEEP_TEXT_TITLE_X;
        const title_y: i32 = display_config.SLEEP_TEXT_TITLE_Y;
        self.drawText(title_x, title_y, "ZlsNas", .Ubuntu34, true);

        // Draw white "Sleeping..." text
        const sub_x: i32 = display_config.SLEEP_TEXT_SUB_X;
        const sub_y: i32 = display_config.SLEEP_TEXT_SUB_Y;
        self.drawText(sub_x, sub_y, "Sleeping...", .Ubuntu14, true);

        // Convert and display
        self.convertTo1Bit(self.epd_buffer);
        try self.epd.display(self.epd_buffer);

        // Export BMP
        self.exportBmp() catch |err| {
            std.log.err("Failed to export sleep screen BMP: {}", .{err});
        };

        try self.epd.sleep();
    }
};
