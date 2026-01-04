const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const SystemOps = @import("system_ops.zig").SystemOps;
const NetworkOps = @import("network_ops.zig").NetworkOps;
const TrafficMonitor = @import("network_ops.zig").TrafficMonitor;
const Scheduler = @import("scheduler.zig").Scheduler;
const DisplayRenderer = @import("display_renderer.zig").DisplayRenderer;
const MqttClient = @import("mqtt.zig").MqttClient;
const MqttConfig = @import("mqtt.zig").MqttConfig;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
};

// Global state - atomic for signal handler thread-safety
var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_sys_ops: ?*SystemOps = null;
var g_net_ops: ?*NetworkOps = null;
var g_traffic_mon: ?*TrafficMonitor = null;
var g_renderer: ?*DisplayRenderer = null;
var g_mqtt: ?*MqttClient = null;
var g_full_refresh_counter: u32 = 0; // Counter for periodic full refresh

fn signalHandler(_: c_int) callconv(.c) void {
    should_exit.store(true, .release);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            log.warn("Memory leak detected on exit", .{});
        }
    }
    const allocator = gpa.allocator();

    // Load configuration from environment
    config.Config.load();

    // Initialize logger
    try logger.init();
    defer logger.deinit();

    // Root check removed to allow running as non-root user with proper permissions (gpio/spi groups)
    // if (!config.Config.isRoot()) { ... }

    // Install signal handlers
    const c = @cImport({
        @cInclude("signal.h");
    });
    _ = c.signal(c.SIGINT, signalHandler);
    _ = c.signal(c.SIGTERM, signalHandler);
    _ = c.signal(c.SIGHUP, signalHandler);

    log.info("SysInk starting", .{});

    // Initialize modules
    var sys_ops = SystemOps.init(allocator);
    defer sys_ops.deinit();
    var net_ops = NetworkOps.init(allocator);
    var traffic_mon = TrafficMonitor.init(allocator);

    // Set global pointers for scheduler callbacks
    g_sys_ops = &sys_ops;
    g_net_ops = &net_ops;
    g_traffic_mon = &traffic_mon;

    // Initialize display renderer
    var renderer = DisplayRenderer.init(allocator) catch |err| {
        log.err("Failed to initialize display: {}", .{err});
        log.err("Check GPIO/SPI permissions", .{});
        return 1;
    };
    defer renderer.deinit();
    g_renderer = &renderer;

    log.info("Initializing display", .{});
    renderer.startup() catch |err| {
        log.err("Failed to start display: {}", .{err});
        return 1;
    };

    log.info("Showing loading screen", .{});
    renderer.showLoading() catch |err| {
        log.err("Failed to show loading screen: {}", .{err});
    };

    log.info("Rendering grid", .{});
    renderer.renderGrid();

    // Initialize MQTT client if enabled
    const mqtt_config = MqttConfig.load();
    var mqtt_client: ?MqttClient = null;
    if (mqtt_config.enabled) {
        log.info("MQTT enabled, connecting to {s}:{d}", .{ mqtt_config.host, mqtt_config.port });
        mqtt_client = MqttClient.init(
            allocator,
            mqtt_config.host,
            mqtt_config.port,
            mqtt_config.client_id,
            mqtt_config.username,
            mqtt_config.password,
            mqtt_config.topic_prefix,
        );

        if (mqtt_client) |*client| {
            client.connect() catch |err| {
                log.warn("MQTT connection failed: {} - will retry later", .{err});
            };

            // Publish Home Assistant auto-discovery configs
            if (mqtt_config.discovery_enabled and client.connected) {
                publishHADiscoveryConfigs(client);
            }

            g_mqtt = client;
        }
    }
    defer if (mqtt_client) |*client| client.deinit();

    // Initialize scheduler
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    // Schedule rendering tasks

    // Fast updates (CPU, RAM, etc.)
    try scheduler.every(config.Config.interval_fast, "cpu", updateCpu);
    try scheduler.every(config.Config.interval_fast, "memory", updateMemory);
    try scheduler.every(config.Config.interval_fast, "disk", updateDisk);
    try scheduler.every(config.Config.interval_fast, "fan", updateFan);
    try scheduler.every(config.Config.interval_fast, "traffic", updateTraffic);
    try scheduler.every(config.Config.interval_fast, "signal", updateSignal);
    try scheduler.every(config.Config.interval_fast, "uptime", updateUptime);

    // Slow updates (Network info, APT updates, Internet check)
    try scheduler.every(config.Config.interval_slow, "ip", updateIp);
    try scheduler.every(config.Config.interval_slow, "apt", updateApt);
    try scheduler.every(config.Config.interval_slow, "internet", updateInternet);

    // MQTT updates (every fast interval if enabled)
    if (mqtt_config.enabled) {
        try scheduler.every(config.Config.interval_fast, "mqtt", publishMqttStats);
    }

    // Run once to fill all stats before first display update
    scheduler.runAll();

    // First update - use displayBase to set base image for partial updates with populated stats
    renderer.convertTo1Bit(renderer.epd_buffer);
    try renderer.epd.displayBase(renderer.epd_buffer);

    // Export initial BMP (before display updates)
    log.info("Exporting initial BMP", .{});
    renderer.exportBmp() catch |err| {
        log.err("Failed to export initial BMP: {}", .{err});
    };

    // Display update (matches fast refresh rate)
    try scheduler.every(config.Config.interval_fast, "display", updateDisplayPartial);

    log.info("Starting main loop (Ctrl+C to exit)", .{});

    // Run all tasks immediately
    scheduler.runAll();

    // Main event loop
    while (!should_exit.load(.acquire)) {
        scheduler.runPending();

        // Sleep until next task or max 1 second
        const idle = scheduler.idleSeconds();
        const sleep_time = if (idle) |i| @min(i, 1) else 1;
        std.Thread.sleep(@intCast(sleep_time * std.time.ns_per_s));
    }

    log.info("Shutting down gracefully", .{});

    if (g_renderer) |r| {
        r.goToSleep() catch |err| {
            log.err("Failed to show sleep screen: {}", .{err});
        };
    }

    scheduler.clear();

    return 0;
}

// Scheduler callback functions
fn updateCpu() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const load = g_sys_ops.?.getCpuLoad() catch |err| {
        log.warn("getCpuLoad failed: {}", .{err});
        return;
    };
    const temp = g_sys_ops.?.getCpuTemperature() catch |err| {
        log.warn("getCpuTemperature failed: {}", .{err});
        return;
    };

    g_renderer.?.renderCpuLoad(load, temp);
    log.debug("CPU: {}% / {}°C", .{ load, temp });
}

fn updateMemory() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const mem = g_sys_ops.?.getMemory() catch |err| {
        log.warn("getMemory failed: {}", .{err});
        return;
    };
    g_renderer.?.renderMemory(mem);
    log.debug("Memory: {}%", .{mem});
}

fn updateDisk() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const usage = g_sys_ops.?.getDiskUsage() catch |err| {
        log.warn("getDiskUsage failed: {}", .{err});
        return;
    };
    const temp = g_sys_ops.?.getDiskTemp() catch |err| {
        log.warn("getDiskTemp failed: {}", .{err});
        return;
    };

    g_renderer.?.renderDiskStats(usage, temp);
    log.debug("Disk: {}% / {}°C", .{ usage, temp });
}

fn updateFan() void {
    if (g_sys_ops == null or g_renderer == null) return;

    const rpm = g_sys_ops.?.getFanSpeed() catch |err| {
        log.warn("getFanSpeed failed: {}", .{err});
        return;
    };
    g_renderer.?.renderFanSpeed(rpm);
    log.debug("Fan: {} RPM", .{rpm});
}

fn updateSignal() void {
    if (g_net_ops == null or g_renderer == null) return;

    const signal = g_net_ops.?.getSignalStrength("wlan0") catch null;
    g_renderer.?.renderSignalStrength(signal);

    if (signal) |s| {
        log.debug("Signal: {} dBm", .{s});
    }
}

fn updateIp() void {
    if (g_net_ops == null or g_renderer == null) return;

    if (g_net_ops.?.getAnyIpAddress()) |ip_opt| {
        if (ip_opt) |ip| {
            defer g_net_ops.?.allocator.free(ip);
            g_renderer.?.renderIpAddress(ip);
            log.debug("IP: {s}", .{ip});
        } else {
            g_renderer.?.renderIpAddress("No IP");
            log.debug("IP: No IP address found", .{});
        }
    } else |_| {
        g_renderer.?.renderIpAddress("Error");
    }
}

fn updateUptime() void {
    if (g_sys_ops == null or g_renderer == null) return;

    if (g_sys_ops.?.getUptime()) |uptime| {
        g_renderer.?.renderUptime(uptime.days, uptime.hours, uptime.minutes);
        log.debug("Uptime: {}d {}h {}m", .{ uptime.days, uptime.hours, uptime.minutes });
    } else |err| {
        log.warn("getUptime failed: {}", .{err});
    }
}

fn updateTraffic() void {
    if (g_traffic_mon == null or g_renderer == null) return;

    const traffic = g_traffic_mon.?.getCurrentTraffic() catch |err| {
        log.warn("getCurrentTraffic failed: {}", .{err});
        return;
    };
    log.debug("Traffic: {d:.2} {s}/s down / {d:.2} {s}/s up", .{
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

    log.debug("Display refresh #{} (partial={})", .{ g_full_refresh_counter, use_partial });

    g_renderer.?.updateDisplay(use_partial) catch |err| {
        log.warn("Failed to update display: {}", .{err});
    };
}

fn updateApt() void {
    if (g_sys_ops == null or g_net_ops == null or g_renderer == null) return;

    const is_root = config.Config.isRoot();
    const has_internet = g_net_ops.?.checkInternetConnection();

    const count = g_sys_ops.?.checkUpdates(is_root, has_internet);
    log.debug("APT updates: {}", .{count});

    g_renderer.?.renderAptUpdates(count);
}

fn updateInternet() void {
    if (g_net_ops == null or g_renderer == null) return;

    const connected = g_net_ops.?.checkInternetConnection();
    log.debug("Internet: {}", .{connected});

    g_renderer.?.renderInternetStatus(connected);
}

// MQTT Functions
fn publishHADiscoveryConfigs(client: *MqttClient) void {
    log.info("Publishing Home Assistant discovery configs", .{});

    // CPU sensors
    client.publishHADiscovery("cpu_load", "CPU Load", "%", null, "mdi:cpu-64-bit") catch {};
    client.publishHADiscovery("cpu_temp", "CPU Temperature", "°C", "temperature", "mdi:thermometer") catch {};

    // Memory
    client.publishHADiscovery("memory", "Memory Usage", "%", null, "mdi:memory") catch {};

    // Disk
    client.publishHADiscovery("disk_usage", "Disk Usage", "%", null, "mdi:harddisk") catch {};
    client.publishHADiscovery("disk_temp", "Disk Temperature", "°C", "temperature", "mdi:thermometer") catch {};

    // Fan
    client.publishHADiscovery("fan_speed", "Fan Speed", "RPM", null, "mdi:fan") catch {};

    // Network
    client.publishHADiscovery("signal_strength", "WiFi Signal", "dBm", "signal_strength", "mdi:wifi") catch {};
    client.publishHADiscovery("ip_address", "IP Address", null, null, "mdi:ip-network") catch {};
    client.publishHADiscovery("internet", "Internet Connected", null, null, "mdi:web") catch {};

    // Traffic
    client.publishHADiscovery("traffic_down", "Download Speed", "KB/s", null, "mdi:download") catch {};
    client.publishHADiscovery("traffic_up", "Upload Speed", "KB/s", null, "mdi:upload") catch {};

    // System
    client.publishHADiscovery("uptime_days", "Uptime Days", "d", null, "mdi:clock-outline") catch {};
    client.publishHADiscovery("apt_updates", "APT Updates", null, null, "mdi:package-up") catch {};

    log.info("Home Assistant discovery configs published", .{});
}

fn publishMqttStats() void {
    const client = g_mqtt orelse return;

    // Reconnect if needed
    if (!client.connected) {
        client.connect() catch |err| {
            log.debug("MQTT reconnect failed: {}", .{err});
            return;
        };
    }

    var buf: [32]u8 = undefined;

    // CPU
    if (g_sys_ops) |ops| {
        if (ops.getCpuLoad()) |load| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{load}) catch return;
            client.publish("cpu_load", payload, false) catch {};
        } else |_| {}

        if (ops.getCpuTemperature()) |temp| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{temp}) catch return;
            client.publish("cpu_temp", payload, false) catch {};
        } else |_| {}

        // Memory
        if (ops.getMemory()) |mem| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{mem}) catch return;
            client.publish("memory", payload, false) catch {};
        } else |_| {}

        // Disk
        if (ops.getDiskUsage()) |usage| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{usage}) catch return;
            client.publish("disk_usage", payload, false) catch {};
        } else |_| {}

        if (ops.getDiskTemp()) |temp| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{temp}) catch return;
            client.publish("disk_temp", payload, false) catch {};
        } else |_| {}

        // Fan
        if (ops.getFanSpeed()) |rpm| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{rpm}) catch return;
            client.publish("fan_speed", payload, false) catch {};
        } else |_| {}

        // Uptime
        if (ops.getUptime()) |uptime| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{uptime.days}) catch return;
            client.publish("uptime_days", payload, false) catch {};
        } else |_| {}

        // APT updates
        const apt_count = ops.apt_updates_count.load(.monotonic);
        const payload = std.fmt.bufPrint(&buf, "{d}", .{apt_count}) catch return;
        client.publish("apt_updates", payload, false) catch {};
    }

    // Network
    if (g_net_ops) |ops| {
        // Signal strength
        if (ops.getSignalStrength("wlan0") catch null) |signal| {
            const payload = std.fmt.bufPrint(&buf, "{d}", .{signal}) catch return;
            client.publish("signal_strength", payload, false) catch {};
        }

        // Internet status
        const connected = ops.checkInternetConnection();
        const payload = if (connected) "ON" else "OFF";
        client.publish("internet", payload, false) catch {};

        // IP address
        if (ops.getAnyIpAddress()) |ip_opt| {
            if (ip_opt) |ip| {
                defer ops.allocator.free(ip);
                client.publish("ip_address", ip, false) catch {};
            }
        } else |_| {}
    }

    // Traffic
    if (g_traffic_mon) |mon| {
        if (mon.getCurrentTraffic()) |stats| {
            var down_buf: [32]u8 = undefined;
            const down_payload = std.fmt.bufPrint(&down_buf, "{d:.1}", .{stats.download_speed}) catch return;
            client.publish("traffic_down", down_payload, false) catch {};

            var up_buf: [32]u8 = undefined;
            const up_payload = std.fmt.bufPrint(&up_buf, "{d:.1}", .{stats.upload_speed}) catch return;
            client.publish("traffic_up", up_payload, false) catch {};
        } else |_| {}
    }

    log.debug("MQTT stats published", .{});
}
