const std = @import("std");
const config = @import("config.zig");
const SystemOps = @import("system_ops.zig").SystemOps;
const NetworkOps = @import("network_ops.zig").NetworkOps;
const TrafficMonitor = @import("network_ops.zig").TrafficMonitor;
const Scheduler = @import("scheduler.zig").Scheduler;
const DisplayRenderer = @import("display_renderer.zig").DisplayRenderer;

// Global state
var should_exit = false;
var g_sys_ops: ?*SystemOps = null;
var g_net_ops: ?*NetworkOps = null;
var g_traffic_mon: ?*TrafficMonitor = null;
var g_renderer: ?*DisplayRenderer = null;
var g_full_refresh_counter: u32 = 0; // Counter for periodic full refresh

fn signalHandler(_: c_int) callconv(.c) void {
    should_exit = true;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.warn("Memory leak detected on exit!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Load configuration from environment
    config.Config.load();

    // Root check removed to allow running as non-root user with proper permissions (gpio/spi groups)
    // if (!config.Config.isRoot()) { ... }

    // Install signal handlers
    const c = @cImport({
        @cInclude("signal.h");
    });
    _ = c.signal(c.SIGINT, signalHandler);
    _ = c.signal(c.SIGTERM, signalHandler);
    _ = c.signal(c.SIGHUP, signalHandler);

    std.log.info("ZlsNasDisplay Zig starting...", .{});

    // Initialize modules
    var sys_ops = SystemOps.init(allocator);
    var net_ops = NetworkOps.init(allocator);
    var traffic_mon = TrafficMonitor.init(allocator);

    // Set global pointers for scheduler callbacks
    g_sys_ops = &sys_ops;
    g_net_ops = &net_ops;
    g_traffic_mon = &traffic_mon;

    // Initialize display renderer
    var renderer = DisplayRenderer.init(allocator) catch |err| {
        std.log.err("Failed to initialize display: {}", .{err});
        std.log.err("Make sure you are running as root and the display is connected", .{});
        return 1;
    };
    defer renderer.deinit();
    g_renderer = &renderer;

    std.log.info("Initializing display...", .{});
    renderer.startup() catch |err| {
        std.log.err("Failed to start display: {}", .{err});
        return 1;
    };

    std.log.info("Rendering grid...", .{});
    renderer.renderGrid();

    // First update - use displayBase to set base image for partial updates
    renderer.convertTo1Bit(renderer.epd_buffer);
    try renderer.epd.displayBase(renderer.epd_buffer);

    // Export initial BMP (before display updates)
    std.log.info("Exporting initial BMP...", .{});
    renderer.exportBmp() catch |err| {
        std.log.err("Failed to export initial BMP: {}", .{err});
    };

    // Initialize scheduler
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    // Schedule rendering tasks

    // Fast updates (CPU, RAM, etc.)
    try scheduler.every(config.Config.interval_fast, "cpu", updateCpu);
    try scheduler.every(config.Config.interval_fast, "memory", updateMemory);
    try scheduler.every(config.Config.interval_fast, "nvme", updateNvme);
    try scheduler.every(config.Config.interval_fast, "fan", updateFan);
    try scheduler.every(config.Config.interval_fast, "traffic", updateTraffic);
    try scheduler.every(config.Config.interval_fast, "signal", updateSignal);
    try scheduler.every(config.Config.interval_fast, "uptime", updateUptime);

    // Slow updates (Network info, APT updates, Internet check)
    try scheduler.every(config.Config.interval_slow, "ip", updateIp);
    try scheduler.every(config.Config.interval_slow, "apt", updateApt);
    try scheduler.every(config.Config.interval_slow, "internet", updateInternet);

    // Display update (matches fast refresh rate)
    try scheduler.every(config.Config.interval_fast, "display", updateDisplayPartial);

    std.log.info("Starting main loop (Ctrl+C to exit)", .{});

    // Run all tasks immediately
    scheduler.runAll();

    // Main event loop
    while (!should_exit) {
        scheduler.runPending();

        // Sleep until next task or max 1 second
        const idle = scheduler.idleSeconds();
        const sleep_time = if (idle) |i| @min(i, 1) else 1;
        std.Thread.sleep(@intCast(sleep_time * std.time.ns_per_s));
    }

    std.log.info("Shutting down gracefully...", .{});

    // Display sleep screen
    if (g_renderer) |r| {
        r.goToSleep() catch {};
    }

    scheduler.clear();

    return 0;
}

// Scheduler callback functions
fn updateCpu() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const load = g_sys_ops.?.getCpuLoad() catch 0;
    const temp = g_sys_ops.?.getCpuTemperature() catch 0;

    g_renderer.?.renderCpuLoad(load, temp);
    std.log.debug("CPU: {}% / {}°C", .{ load, temp });
}

fn updateMemory() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const mem = g_sys_ops.?.getMemory() catch 0;
    g_renderer.?.renderMemory(mem);
    std.log.debug("Memory: {}%", .{mem});
}

fn updateNvme() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const usage = g_sys_ops.?.getNvmeUsage() catch 0;
    const temp = g_sys_ops.?.getNvmeTemp() catch 0;

    g_renderer.?.renderNvmeStats(usage, temp);
    std.log.debug("NVMe: {}% / {}°C", .{ usage, temp });
}

fn updateFan() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const rpm = g_sys_ops.?.getFanSpeed() catch 0;
    g_renderer.?.renderFanSpeed(rpm);
    std.log.debug("Fan: {} RPM", .{rpm});
}

fn updateSignal() void {
    if (g_net_ops == null or g_renderer == null) return;

    const signal = g_net_ops.?.getSignalStrength("wlan0") catch null;
    g_renderer.?.renderSignalStrength(signal);

    if (signal) |s| {
        std.log.debug("Signal: {} dBm", .{s});
    }
}

fn updateIp() void {
    if (g_net_ops == null or g_renderer == null) return;

    if (g_net_ops.?.getAnyIpAddress()) |ip_opt| {
        if (ip_opt) |ip| {
            defer g_net_ops.?.allocator.free(ip);
            g_renderer.?.renderIpAddress(ip);
            std.log.debug("IP: {s}", .{ip});
        } else {
            g_renderer.?.renderIpAddress("No IP");
            std.log.debug("IP: No IP address found", .{});
        }
    } else |_| {
        g_renderer.?.renderIpAddress("Error");
    }
}

fn updateUptime() void {
    if (g_sys_ops == null or g_renderer == null) return;

    if (g_sys_ops.?.getUptime()) |uptime| {
        g_renderer.?.renderUptime(uptime.days, uptime.hours, uptime.minutes);
        std.log.debug("Uptime: {}d {}h {}m", .{ uptime.days, uptime.hours, uptime.minutes });
    } else |_| {}
}

fn updateTraffic() void {
    if (g_traffic_mon == null or g_renderer == null) return;

    const traffic = g_traffic_mon.?.getCurrentTraffic() catch return;
    std.log.debug("Traffic: {d:.2} {s}/s down / {d:.2} {s}/s up", .{
        traffic.download_speed,
        traffic.download_unit,
        traffic.upload_speed,
        traffic.upload_unit,
    });

    g_renderer.?.renderTraffic(
        traffic.download_speed,
        traffic.download_unit,
        traffic.upload_speed,
        traffic.upload_unit,
    );
}

fn updateDisplayPartial() void {
    if (g_renderer == null) return;

    g_full_refresh_counter += 1;

    // Perform full refresh every 20 updates (approx 10 minutes) to clear artifacts
    const perform_full_refresh = (g_full_refresh_counter % 20 == 0);
    const use_partial = !perform_full_refresh;

    std.log.debug("Display refresh #{} (partial={})", .{ g_full_refresh_counter, use_partial });

    g_renderer.?.updateDisplay(use_partial) catch |err| {
        std.log.warn("Failed to update display: {}", .{err});
    };
}

fn updateDisplayFull() void {
    if (g_renderer == null) return;

    g_renderer.?.updateDisplay(false) catch |err| {
        std.log.warn("Failed to update display: {}", .{err});
    };
}

fn exportBmp() void {
    if (g_renderer == null) return;

    g_renderer.?.exportBmp() catch |err| {
        std.log.warn("Failed to export BMP: {}", .{err});
    };
}

fn updateApt() void {
    if (g_sys_ops == null or g_net_ops == null or g_renderer == null) return;

    const is_root = config.Config.isRoot();
    const has_internet = g_net_ops.?.checkInternetConnection();

    const count = g_sys_ops.?.checkUpdates(is_root, has_internet);
    std.log.debug("APT updates: {}", .{count});

    g_renderer.?.renderAptUpdates(count);
}

fn updateInternet() void {
    if (g_net_ops == null or g_renderer == null) return;

    const connected = g_net_ops.?.checkInternetConnection();
    std.log.debug("Internet: {}", .{connected});

    g_renderer.?.renderInternetStatus(connected);
}
