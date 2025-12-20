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

    /// Show a transient loading screen while metrics initialize
    pub fn showLoading(self: *DisplayRenderer) !void {
        self.bitmap.clear(.White);

        const cx: i32 = @intCast(display_config.DISPLAY_WIDTH / 2);
        const cy: i32 = @intCast(display_config.DISPLAY_HEIGHT / 2);
        const right_cx: i32 = cx + @as(i32, @intCast(display_config.DISPLAY_WIDTH / 4));

        // Centered vertical line
        const line_w: u32 = display_config.SLEEP_LINE_W;
        const line_h: u32 = display_config.HORIZONTAL_LINE_MAIN - display_config.SLEEP_LINE_Y;
        const line_x: i32 = cx - @as(i32, @intCast(line_w / 2));
        self.bitmap.fillRect(line_x, display_config.SLEEP_LINE_Y, line_w, line_h, .Black);

        // Icon centered horizontally, left of center line
        const icon = display_config.ICON_SLEEP_NET;
        const icon_w = self.bitmap.measureText(icon, .Material50);
        const icon_x: i32 = cx - @as(i32, @intCast(icon_w / 2)) - 42;
        const icon_y: i32 = cy + 18;
        self.bitmap.drawTextFont(icon_x, icon_y, icon, .Material50, .Black);

        // Title centered on the right side
        const title = "SysInk";
        const title_w = self.bitmap.measureText(title, .Ubuntu34);
        const title_x: i32 = right_cx - @as(i32, @intCast(title_w / 2));
        const title_y: i32 = cy - 4;
        self.bitmap.drawTextFont(title_x, title_y, title, .Ubuntu34, .Black);

        // Subtitle
        const subtitle = "Loading...";
        const sub_y: i32 = cy + 18;
        self.bitmap.drawTextFont(title_x, sub_y, subtitle, .Ubuntu14, .Black);

        self.convertTo1Bit(self.epd_buffer);
        try self.epd.display(self.epd_buffer);

        self.exportBmp() catch |err| {
            std.log.err("Failed to export loading BMP: {}", .{err});
        };
    }

    /// Render grid layout
    pub fn renderGrid(self: *DisplayRenderer) void {
        if (self.grid_cached) return;

        self.bitmap.clear(.White);

        // Draw vertical divider lines
        self.bitmap.drawLine(display_config.VERTICAL_LINE_1, display_config.CPU_LINE_Y, display_config.VERTICAL_LINE_1, display_config.HORIZONTAL_LINE_MAIN, .Black);
        self.bitmap.drawLine(display_config.VERTICAL_LINE_2, display_config.CPU_LINE_Y, display_config.VERTICAL_LINE_2, display_config.HORIZONTAL_LINE_MAIN, .Black);

        // Draw main horizontal divider
        self.bitmap.drawLine(0, display_config.HORIZONTAL_LINE_MAIN, display_config.DISPLAY_WIDTH, display_config.HORIZONTAL_LINE_MAIN, .Black);

        // CPU section
        self.bitmap.drawLine(26, display_config.CPU_LINE_Y, 99, display_config.CPU_LINE_Y, .Black);
        self.bitmap.drawTextFont(1, display_config.CPU_LABEL_Y, "cpu", .Ubuntu14, .Black);
        self.bitmap.drawTextFont(display_config.CPU_ICON_X, display_config.CPU_ICON_Y_LOAD, display_config.ICON_CPU, .Material24, .Black);
        self.bitmap.drawTextFont(display_config.CPU_ICON_X, display_config.CPU_ICON_Y_TEMP, display_config.ICON_TEMPERATURE, .Material24, .Black);

        // APT section
        self.bitmap.drawTextFont(display_config.APT_LABEL_X, display_config.APT_LABEL_Y, "apt", .Ubuntu14, .Black);
        self.bitmap.drawLine(226, display_config.APT_LINE_Y, 248, display_config.APT_LINE_Y, .Black);

        // NET section
        self.bitmap.drawTextFont(display_config.NET_LABEL_X, display_config.NET_LABEL_Y, "net", .Ubuntu14, .Black);
        self.bitmap.drawLine(display_config.NET_LINE_X, display_config.NET_LINE_Y, display_config.NET_LINE_X, display_config.HORIZONTAL_LINE_MAIN, .Black);
        self.bitmap.drawLine(272, display_config.NET_LINE_Y, display_config.DISPLAY_WIDTH, display_config.NET_LINE_Y, .Black);

        // MEM section
        self.bitmap.drawTextFont(display_config.MEM_LABEL_X, display_config.MEM_LABEL_Y, "mem", .Ubuntu14, .Black);
        self.bitmap.drawLine(34, display_config.MEM_LINE_Y, display_config.SECTION_CPU_RIGHT, display_config.MEM_LINE_Y, .Black);
        self.bitmap.drawTextFont(display_config.MEM_ICON_X, display_config.MEM_ICON_Y, display_config.ICON_MEMORY, .Material24, .Black);

        // NVME section
        self.bitmap.drawTextFont(display_config.NVME_LABEL_X, display_config.NVME_LABEL_Y, "nvme", .Ubuntu14, .Black);
        self.bitmap.drawLine(140, display_config.NVME_LINE_Y, display_config.SECTION_NVME_RIGHT, display_config.NVME_LINE_Y, .Black);
        self.bitmap.drawTextFont(display_config.NVME_ICON_X, display_config.NVME_ICON_Y_DISK, display_config.ICON_HARD_DRIVE, .Material24, .Black);
        self.bitmap.drawTextFont(display_config.NVME_ICON_X, display_config.NVME_ICON_Y_TEMP, display_config.ICON_TEMPERATURE, .Material24, .Black);

        // FAN section
        self.bitmap.drawTextFont(display_config.FAN_LABEL_X, display_config.FAN_LABEL_Y, "fan", .Ubuntu14, .Black);
        self.bitmap.drawLine(124, display_config.FAN_LINE_Y, display_config.SECTION_NVME_RIGHT, display_config.FAN_LINE_Y, .Black);
        self.bitmap.drawTextFont(display_config.FAN_ICON_X, display_config.FAN_ICON_Y, display_config.ICON_FAN, .Material24, .Black);

        // Traffic section
        self.bitmap.drawTextFont(display_config.TRAFFIC_DOWN_LABEL_X, display_config.TRAFFIC_DOWN_LABEL_Y, "down", .Ubuntu14, .Black);
        self.bitmap.drawLine(242, display_config.TRAFFIC_DOWN_LINE_Y, 261, display_config.TRAFFIC_DOWN_LINE_Y, .Black);
        self.bitmap.drawTextFont(display_config.TRAFFIC_DOWN_ICON_X, display_config.TRAFFIC_DOWN_ICON_Y, display_config.ICON_DOWNLOAD, .Material24, .Black);

        self.bitmap.drawTextFont(display_config.TRAFFIC_UP_LABEL_X, display_config.TRAFFIC_UP_LABEL_Y, "up", .Ubuntu14, .Black);
        self.bitmap.drawLine(222, display_config.TRAFFIC_UP_LINE_Y, 261, display_config.TRAFFIC_UP_LINE_Y, .Black);
        self.bitmap.drawTextFont(display_config.TRAFFIC_UP_ICON_X, display_config.TRAFFIC_UP_ICON_Y, display_config.ICON_UPLOAD, .Material24, .Black);

        // Status bar icons
        self.bitmap.drawTextFont(display_config.IP_ICON_X, display_config.IP_ICON_Y, display_config.ICON_NETWORK, .Material14, .Black);
        self.bitmap.drawTextFont(display_config.UPTIME_ICON_X, display_config.UPTIME_ICON_Y, display_config.ICON_UPTIME, .Material14, .Black);

        self.grid_cached = true;
    }

    /// Simple unified text rendering in a defined area with optional inversion
    fn drawTextInArea(self: *DisplayRenderer, text: []const u8, font: FontType, text_x: i32, text_y: i32, area_x: i32, area_y: i32, area_w: u32, area_h: u32, invert: bool) void {
        // Clear the area
        self.bitmap.fillRect(area_x, area_y, area_w, area_h, .White);

        // Draw text
        self.bitmap.drawTextFont(text_x, text_y, text, font, .Black);

        // Invert if critical
        if (invert) {
            self.bitmap.invertRect(area_x, area_y, area_w, area_h);
        }
    }

    /// Update display
    pub fn updateDisplay(self: *DisplayRenderer, partial: bool) !void {
        std.log.info("updateDisplay: START (Native)", .{});

        if (display_config.DEBUG_TEXT_AREAS) {
            self.drawTextAreaFrames();
        }

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

    fn drawTextAreaFrames(self: *DisplayRenderer) void {
        const color: Graphics.Color = .Black;

        // CPU
        self.bitmap.drawRect(display_config.CPU_AREA_X, display_config.CPU_AREA_Y_LOAD, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, color);
        self.bitmap.drawRect(display_config.CPU_AREA_X, display_config.CPU_AREA_Y_TEMP, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, color);

        // MEM
        self.bitmap.drawRect(display_config.MEM_AREA_X, display_config.MEM_AREA_Y, display_config.TEXT_AREA_MEM.width, display_config.TEXT_AREA_MEM.height, color);

        // NVMe
        self.bitmap.drawRect(display_config.NVME_AREA_X, display_config.NVME_AREA_Y_DISK, display_config.TEXT_AREA_NVME.width, display_config.TEXT_AREA_NVME.height, color);
        self.bitmap.drawRect(display_config.NVME_AREA_X, display_config.NVME_AREA_Y_TEMP, display_config.TEXT_AREA_NVME.width, display_config.TEXT_AREA_NVME.height, color);

        // FAN
        const ascent_fan = self.bitmap.getFontAscent(.Ubuntu24);
        self.bitmap.drawRect(display_config.FAN_VALUE_X, display_config.FAN_VALUE_Y - ascent_fan, display_config.TEXT_AREA_FAN.width, display_config.TEXT_AREA_FAN.height, color);

        // APT
        const ascent_apt = self.bitmap.getFontAscent(.Ubuntu24);
        self.bitmap.drawRect(display_config.APT_VALUE_X, display_config.APT_VALUE_Y - ascent_apt, display_config.TEXT_AREA_APT.width, display_config.TEXT_AREA_APT.height, color);

        // NET icon/state
        const ascent_net = self.bitmap.getFontAscent(.Material24);
        self.bitmap.drawRect(display_config.NET_ICON_X, display_config.NET_ICON_Y - ascent_net, display_config.TEXT_AREA_NET.width, display_config.TEXT_AREA_NET.height, color);

        // IP
        self.bitmap.drawRect(display_config.IP_VALUE_X, display_config.IP_AREA_Y, display_config.TEXT_AREA_IP.width, display_config.TEXT_AREA_IP.height, color);

        // UPTIME
        self.bitmap.drawRect(display_config.UPTIME_VALUE_X, display_config.UPTIME_AREA_Y, display_config.TEXT_AREA_UPTIME.width, display_config.TEXT_AREA_UPTIME.height, color);

        // SIGNAL
        self.bitmap.drawRect(display_config.SIGNAL_VALUE_X - 20, display_config.SIGNAL_AREA_Y, display_config.TEXT_AREA_SIGNAL.width, display_config.TEXT_AREA_SIGNAL.height, color);

        // Traffic down
        self.bitmap.drawRect(display_config.TRAFFIC_DOWN_VALUE_X, display_config.TRAFFIC_DOWN_AREA_Y, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, color);
        self.bitmap.drawRect(display_config.TRAFFIC_DOWN_UNIT_X, display_config.TRAFFIC_DOWN_UNIT_AREA_Y, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, color);

        // Traffic up
        self.bitmap.drawRect(display_config.TRAFFIC_UP_VALUE_X, display_config.TRAFFIC_UP_AREA_Y, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, color);
        self.bitmap.drawRect(display_config.TRAFFIC_UP_UNIT_X, display_config.TRAFFIC_UP_UNIT_AREA_Y, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, color);
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

        var buf1: [16]u8 = undefined;
        const load_text = std.fmt.bufPrint(&buf1, "{d}%", .{load}) catch "?";
        self.drawTextInArea(load_text, .Ubuntu24, display_config.CPU_VALUE_X, display_config.CPU_VALUE_Y_LOAD, display_config.CPU_AREA_X, display_config.CPU_AREA_Y_LOAD, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, is_load_critical);

        var buf2: [16]u8 = undefined;
        const temp_text = std.fmt.bufPrint(&buf2, "{d}C", .{temp}) catch "?";
        self.drawTextInArea(temp_text, .Ubuntu24, display_config.CPU_VALUE_X, display_config.CPU_VALUE_Y_TEMP, display_config.CPU_AREA_X, display_config.CPU_AREA_Y_TEMP, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, is_temp_critical);
    }

    /// Render memory usage
    pub fn renderMemory(self: *DisplayRenderer, usage: u8) void {
        const is_critical = usage >= config.Config.threshold_mem_critical;

        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}%", .{usage}) catch "?";
        self.drawTextInArea(text, .Ubuntu26, display_config.MEM_VALUE_X, display_config.MEM_VALUE_Y, display_config.MEM_AREA_X, display_config.MEM_AREA_Y, display_config.TEXT_AREA_MEM.width, display_config.TEXT_AREA_MEM.height, is_critical);
    }

    /// Render NVMe stats
    pub fn renderNvmeStats(self: *DisplayRenderer, usage: u8, temp: u32) void {
        const is_usage_critical = usage >= config.Config.threshold_disk_critical;
        const is_temp_critical = temp >= config.Config.threshold_temp_critical;

        var buf1: [16]u8 = undefined;
        const usage_text = std.fmt.bufPrint(&buf1, "{d}%", .{usage}) catch "?";
        self.drawTextInArea(usage_text, .Ubuntu26, display_config.NVME_VALUE_X, display_config.NVME_VALUE_Y_DISK, display_config.NVME_AREA_X, display_config.NVME_AREA_Y_DISK, display_config.TEXT_AREA_NVME.width, display_config.TEXT_AREA_NVME.height, is_usage_critical);

        var buf2: [16]u8 = undefined;
        const temp_text = std.fmt.bufPrint(&buf2, "{d}C", .{temp}) catch "?";
        self.drawTextInArea(temp_text, .Ubuntu26, display_config.NVME_VALUE_X, display_config.NVME_VALUE_Y_TEMP, display_config.NVME_AREA_X, display_config.NVME_AREA_Y_TEMP, display_config.TEXT_AREA_NVME.width, display_config.TEXT_AREA_NVME.height, is_temp_critical);
    }

    /// Render fan speed
    pub fn renderFanSpeed(self: *DisplayRenderer, rpm: u32) void {
        const ascent = self.bitmap.getFontAscent(.Ubuntu24);
        self.bitmap.fillRect(display_config.FAN_VALUE_X, display_config.FAN_VALUE_Y - ascent, display_config.TEXT_AREA_FAN.width, display_config.TEXT_AREA_FAN.height, .White);

        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{rpm}) catch "?";
        self.bitmap.drawTextFont(display_config.FAN_VALUE_X, display_config.FAN_VALUE_Y, text, .Ubuntu24, .Black);
    }

    /// Render IP address
    pub fn renderIpAddress(self: *DisplayRenderer, ip: []const u8) void {
        self.bitmap.fillRect(display_config.IP_VALUE_X, display_config.IP_AREA_Y, display_config.TEXT_AREA_IP.width, display_config.TEXT_AREA_IP.height, .White);

        const display_ip = if (ip.len > 15) ip[0..15] else ip;
        self.bitmap.drawTextFont(display_config.IP_VALUE_X, display_config.IP_VALUE_Y, display_ip, .Ubuntu14, .Black);
    }

    /// Render uptime
    pub fn renderUptime(self: *DisplayRenderer, days: u32, hours: u32, minutes: u32) void {
        self.bitmap.fillRect(display_config.UPTIME_VALUE_X, display_config.UPTIME_AREA_Y, display_config.TEXT_AREA_UPTIME.width, display_config.TEXT_AREA_UPTIME.height, .White);

        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}d {d}h {d}m", .{ days, hours, minutes }) catch "?";
        self.bitmap.drawTextFont(display_config.UPTIME_VALUE_X, display_config.UPTIME_VALUE_Y, text, .Ubuntu14, .Black);
    }

    /// Render signal strength
    pub fn renderSignalStrength(self: *DisplayRenderer, signal: ?i32) void {
        self.bitmap.fillRect(display_config.SIGNAL_VALUE_X - 20, display_config.SIGNAL_AREA_Y, display_config.TEXT_AREA_SIGNAL.width, display_config.TEXT_AREA_SIGNAL.height, .White);

        const icon = if (signal != null) display_config.ICON_WIFI_SIGNAL else display_config.ICON_WIFI_NO_SIGNAL;
        self.bitmap.drawTextFont(display_config.SIGNAL_ICON_X, display_config.SIGNAL_ICON_Y, icon, .Material14, .Black);

        var buf: [16]u8 = undefined;
        const text = if (signal) |s| std.fmt.bufPrint(&buf, "{d} dBm", .{s}) catch "?" else "N/A";
        self.bitmap.drawTextFont(display_config.SIGNAL_VALUE_X, display_config.SIGNAL_VALUE_Y, text, .Ubuntu14, .Black);
    }

    /// Render network traffic
    pub fn renderTraffic(self: *DisplayRenderer, download_speed: f64, download_unit: []const u8, upload_speed: f64, upload_unit: []const u8) void {
        // Download
        self.bitmap.fillRect(display_config.TRAFFIC_DOWN_VALUE_X, display_config.TRAFFIC_DOWN_AREA_Y, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, .White);
        self.bitmap.fillRect(display_config.TRAFFIC_DOWN_UNIT_X, display_config.TRAFFIC_DOWN_UNIT_AREA_Y, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, .White);

        var buf1: [16]u8 = undefined;
        const down_text = std.fmt.bufPrint(&buf1, "{d:.2}", .{download_speed}) catch "?";
        self.bitmap.drawTextFont(display_config.TRAFFIC_DOWN_VALUE_X, display_config.TRAFFIC_DOWN_VALUE_Y, down_text, .Ubuntu20, .Black);

        var unit_buf1: [16]u8 = undefined;
        const down_unit_text = std.fmt.bufPrint(&unit_buf1, "{s}/s", .{download_unit}) catch "?";
        self.bitmap.drawTextFont(display_config.TRAFFIC_DOWN_UNIT_X, display_config.TRAFFIC_DOWN_UNIT_Y, down_unit_text, .Ubuntu14, .Black);

        // Upload
        self.bitmap.fillRect(display_config.TRAFFIC_UP_VALUE_X, display_config.TRAFFIC_UP_AREA_Y, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, .White);
        self.bitmap.fillRect(display_config.TRAFFIC_UP_UNIT_X, display_config.TRAFFIC_UP_UNIT_AREA_Y, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, .White);

        var buf2: [16]u8 = undefined;
        const up_text = std.fmt.bufPrint(&buf2, "{d:.2}", .{upload_speed}) catch "?";
        self.bitmap.drawTextFont(display_config.TRAFFIC_UP_VALUE_X, display_config.TRAFFIC_UP_VALUE_Y, up_text, .Ubuntu20, .Black);

        var unit_buf2: [16]u8 = undefined;
        const up_unit_text = std.fmt.bufPrint(&unit_buf2, "{s}/s", .{upload_unit}) catch "?";
        self.bitmap.drawTextFont(display_config.TRAFFIC_UP_UNIT_X, display_config.TRAFFIC_UP_UNIT_Y, up_unit_text, .Ubuntu14, .Black);
    }

    /// Render APT updates count
    pub fn renderAptUpdates(self: *DisplayRenderer, count: u32) void {
        const ascent = self.bitmap.getFontAscent(.Ubuntu24);
        self.bitmap.fillRect(display_config.APT_VALUE_X, display_config.APT_VALUE_Y - ascent, display_config.TEXT_AREA_APT.width, display_config.TEXT_AREA_APT.height, .White);

        if (count == 0) {
            self.bitmap.drawTextFont(display_config.APT_VALUE_X, display_config.APT_VALUE_Y, display_config.ICON_CHECK, .Material24, .Black);
        } else {
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "?";
            self.bitmap.drawTextFont(display_config.APT_VALUE_X, display_config.APT_VALUE_Y, text, .Ubuntu24, .Black);
        }
    }

    /// Render internet connection status
    pub fn renderInternetStatus(self: *DisplayRenderer, connected: bool) void {
        const ascent = self.bitmap.getFontAscent(.Material24);
        self.bitmap.fillRect(display_config.NET_ICON_X, display_config.NET_ICON_Y - ascent, display_config.TEXT_AREA_NET.width, display_config.TEXT_AREA_NET.height, .White);

        const icon = if (connected) display_config.ICON_WIFI_OK else display_config.ICON_WIFI_OFF;
        self.bitmap.drawTextFont(display_config.NET_ICON_X, display_config.NET_ICON_Y, icon, .Material24, .Black);
    }

    /// Go to sleep
    pub fn goToSleep(self: *DisplayRenderer) !void {
        self.bitmap.clear(.Black);

        const cx: i32 = @intCast(display_config.DISPLAY_WIDTH / 2);
        const cy: i32 = @intCast(display_config.DISPLAY_HEIGHT / 2);
        const right_cx: i32 = cx + @as(i32, @intCast(display_config.DISPLAY_WIDTH / 4));

        // Centered white vertical line
        const line_w: u32 = display_config.SLEEP_LINE_W;
        const line_h: u32 = display_config.HORIZONTAL_LINE_MAIN - display_config.SLEEP_LINE_Y;
        const line_x: i32 = cx - @as(i32, @intCast(line_w / 2));
        self.bitmap.fillRect(line_x, display_config.SLEEP_LINE_Y, line_w, line_h, .White);

        // Icon centered horizontally, left of center line
        const icon = display_config.ICON_SLEEP_NET;
        const icon_w = self.bitmap.measureText(icon, .Material50);
        const icon_x: i32 = cx - @as(i32, @intCast(icon_w / 2)) - 42;
        const icon_y: i32 = cy + 18;
        self.bitmap.drawTextFont(icon_x, icon_y, icon, .Material50, .White);

        // Title centered on the right side
        const title = "SysInk";
        const title_w = self.bitmap.measureText(title, .Ubuntu34);
        const title_x: i32 = right_cx - @as(i32, @intCast(title_w / 2));
        const title_y: i32 = cy - 4;
        self.bitmap.drawTextFont(title_x, title_y, title, .Ubuntu34, .White);

        // Subtitle
        const subtitle = "Sleeping...";
        const sub_y: i32 = cy + 18;
        self.bitmap.drawTextFont(title_x, sub_y, subtitle, .Ubuntu14, .White);

        self.convertTo1Bit(self.epd_buffer);
        try self.epd.display(self.epd_buffer);

        self.exportBmp() catch |err| {
            std.log.err("Failed to export sleep screen BMP: {}", .{err});
        };

        try self.epd.sleep();
    }
};
