const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const network_ops = @import("network_ops.zig");
const SystemOps = @import("system_ops.zig").SystemOps;
const NetworkOps = network_ops.NetworkOps;
const TrafficMonitor = network_ops.TrafficMonitor;
const Scheduler = @import("scheduler.zig").Scheduler;
const DisplayRenderer = @import("display_renderer.zig").DisplayRenderer;
const EpdConfig = @import("waveshare_epd/epdconfig.zig").EpdConfig;
const MqttClient = @import("mqtt.zig").MqttClient;
const MqttConfig = @import("mqtt.zig").MqttConfig;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    // std.log's comptime threshold defaults to .info outside Debug builds, which
    // compiles every log.debug call out of release binaries and makes
    // LOG_LEVEL=DEBUG silently do nothing. Open the comptime gate fully and let
    // the runtime check in logger.logFn apply LOG_LEVEL instead.
    .log_level = .debug,
};

/// Use the minimal panic handler. The default one pulls ELF/DWARF parsing and
/// stack-trace rendering into the binary — roughly 90 KB that can never produce
/// a useful trace here, because release builds are stripped.
pub const panic = std.debug.simple_panic;

/// Set from the signal handler; read by the main loop.
var should_exit: std.atomic.Value(bool) = .init(false);

/// Self-pipe so a signal interrupts the main loop's poll immediately instead of
/// waiting out the sleep interval.
var wake_pipe: [2]std.posix.fd_t = .{ -1, -1 };

fn signalHandler(_: std.os.linux.SIG) callconv(.c) void {
    should_exit.store(true, .release);

    // write() is async-signal-safe; the payload does not matter.
    if (wake_pipe[1] >= 0) {
        const byte = [_]u8{0};
        _ = std.os.linux.write(wake_pipe[1], &byte, 1);
    }
}

/// Daemon state shared by the scheduled tasks. Passing this as the task context
/// keeps the callbacks off global mutable state.
const App = struct {
    io: std.Io,
    sys: *SystemOps,
    net: *NetworkOps,
    traffic: *TrafficMonitor,
    renderer: *DisplayRenderer,
    mqtt: ?*MqttClient = null,
    /// Monotonic timestamp of the last full (non-partial) panel refresh.
    last_full_refresh: i64 = 0,
    /// Previous under-voltage reading, so the transition is logged once rather
    /// than every cycle.
    last_undervoltage: ?bool = null,

    fn nowSeconds(self: *App) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toSeconds();
    }

    // ------------------------------------------------------------------------
    // Display tasks
    // ------------------------------------------------------------------------

    fn updateCpu(self: *App) void {
        const load = self.sys.getCpuLoad() catch |err| {
            log.warn("getCpuLoad failed: {t}", .{err});
            return;
        };
        const temp = self.sys.getCpuTemperature() catch |err| {
            log.warn("getCpuTemperature failed: {t}", .{err});
            return;
        };

        self.renderer.renderCpuLoad(load, temp);
        log.debug("CPU: {d}% / {d}°C", .{ load, temp });
    }

    fn updateMemory(self: *App) void {
        const mem = self.sys.getMemory() catch |err| {
            log.warn("getMemory failed: {t}", .{err});
            return;
        };
        self.renderer.renderMemory(mem);
        log.debug("Memory: {d}%", .{mem});
    }

    fn updateDisk(self: *App) void {
        const usage = self.sys.getDiskUsage() catch |err| {
            log.warn("getDiskUsage failed: {t}", .{err});
            return;
        };
        const temp = self.sys.getDiskTemp() catch |err| {
            log.warn("getDiskTemp failed: {t}", .{err});
            return;
        };

        self.renderer.renderDiskStats(usage, temp);
        log.debug("Disk: {d}% / {d}°C", .{ usage, temp });
    }

    fn updateFan(self: *App) void {
        const rpm = self.sys.getFanSpeed() catch |err| {
            log.warn("getFanSpeed failed: {t}", .{err});
            return;
        };
        self.renderer.renderFanSpeed(rpm);
        log.debug("Fan: {d} RPM", .{rpm});
    }

    fn updateSignal(self: *App) void {
        const signal = self.net.getSignalStrength("wlan0");
        self.renderer.renderSignalStrength(signal);

        if (signal) |s| log.debug("Signal: {d} dBm", .{s});
    }

    fn updateIp(self: *App) void {
        var buf: [network_ops.max_ip_len]u8 = undefined;

        const ip = self.net.getAnyIpAddress(&buf) catch |err| {
            log.warn("getAnyIpAddress failed: {t}", .{err});
            self.renderer.renderIpAddress("Error");
            return;
        };

        self.renderer.renderIpAddress(ip orelse "No IP");
        log.debug("IP: {s}", .{ip orelse "none"});
    }

    fn updateUptime(self: *App) void {
        const uptime = self.sys.getUptime() catch |err| {
            log.warn("getUptime failed: {t}", .{err});
            return;
        };
        self.renderer.renderUptime(uptime.days, uptime.hours, uptime.minutes);
        log.debug("Uptime: {d}d {d}h {d}m", .{ uptime.days, uptime.hours, uptime.minutes });
    }

    fn updateTraffic(self: *App) void {
        const traffic = self.traffic.getCurrentTraffic() catch |err| {
            log.warn("getCurrentTraffic failed: {t}", .{err});
            return;
        };

        log.debug("Traffic: {d:.2} {s}/s down / {d:.2} {s}/s up", .{
            traffic.download_speed, traffic.download_unit,
            traffic.upload_speed,   traffic.upload_unit,
        });

        self.renderer.renderTraffic(
            traffic.download_speed,
            traffic.download_unit,
            traffic.upload_speed,
            traffic.upload_unit,
        );
    }

    fn updateApt(self: *App) void {
        // Kick off the check in the background; the count below is whatever the
        // previous run produced.
        self.sys.refreshUpdates(config.Config.isRoot(), self.net.checkInternetConnection());
    }

    /// Repaint the APT counter from the latest background result.
    fn renderApt(self: *App) void {
        const count = self.sys.updatesCount();
        log.debug("APT updates: {?d}", .{count});
        self.renderer.renderAptUpdates(count);
    }

    fn updateInternet(self: *App) void {
        const connected = self.net.checkInternetConnection();
        log.debug("Internet: {}", .{connected});
        self.renderer.renderInternetStatus(connected);
    }

    /// Read the firmware's under-voltage flag and surface it.
    ///
    /// Sustained under-voltage on a Pi with an NVMe drive risks corrupting
    /// storage, so it is worth more than a log line: the status bar is drawn
    /// inverted and the state is published to MQTT as a problem, where an
    /// automation can turn it into an actual notification.
    fn updateUndervoltage(self: *App) void {
        const active = self.sys.getUndervoltage() orelse {
            // No sensor on this hardware; leave the indicator off rather than
            // claiming the supply is fine.
            self.renderer.setUndervoltageWarning(false);
            return;
        };

        self.renderer.setUndervoltageWarning(active);

        if (self.last_undervoltage != active) {
            if (active) {
                log.warn("Under-voltage detected: check the power supply and cable", .{});
            } else if (self.last_undervoltage != null) {
                log.info("Under-voltage cleared", .{});
            }
            self.last_undervoltage = active;
        }
    }

    fn updateDisplay(self: *App) void {
        const now = self.nowSeconds();
        const elapsed = now - self.last_full_refresh;

        // Periodic full refresh clears the ghosting that partial updates leave
        // behind. Driven by elapsed time so it does not depend on INTERVAL_FAST.
        const full_refresh = elapsed >= @as(i64, config.Config.interval_full_refresh);
        if (full_refresh) self.last_full_refresh = now;

        self.renderer.updateDisplay(!full_refresh) catch |err| {
            log.warn("Failed to update display: {t}", .{err});
        };
    }

    // ------------------------------------------------------------------------
    // MQTT
    // ------------------------------------------------------------------------

    fn publishMqttStats(self: *App) void {
        const client = self.mqtt orelse return;

        // Backoff is enforced inside connect(); discovery is republished there
        // on every successful (re)connection.
        if (!client.connected) {
            client.connect() catch |err| {
                if (err == error.BackoffActive) {
                    log.debug("MQTT reconnect skipped (backoff)", .{});
                } else {
                    log.warn("MQTT reconnect failed: {t}", .{err});
                }
                return;
            };
        }

        // Cached readings, populated by the display tasks above.
        publishFmt(client, "cpu_load", "{d}", .{self.sys.last_cpu_load});
        publishFmt(client, "cpu_temp", "{d}", .{self.sys.last_cpu_temp});
        publishFmt(client, "memory", "{d}", .{self.sys.last_memory});
        publishFmt(client, "disk_usage", "{d}", .{self.sys.last_disk_usage});
        publishFmt(client, "disk_temp", "{d}", .{self.sys.last_disk_temp});
        publishFmt(client, "fan_speed", "{d}", .{self.sys.last_fan_speed});
        if (self.last_undervoltage) |active| {
            client.publish("undervoltage", if (active) "ON" else "OFF", false) catch {};
        }
        // Withheld until a check has actually run, so Home Assistant is not told
        // "0 updates" on the basis of no data.
        if (self.sys.updatesCount()) |count| publishFmt(client, "apt_updates", "{d}", .{count});

        if (self.sys.getUptime()) |uptime| {
            publishFmt(client, "uptime_days", "{d}", .{uptime.days});
        } else |_| {}

        if (self.net.getSignalStrength("wlan0")) |signal| {
            publishFmt(client, "signal_strength", "{d}", .{signal});
        }

        // Cached, so this does not add another blocking probe.
        client.publish("internet", if (self.net.checkInternetConnection()) "ON" else "OFF", false) catch {};

        var ip_buf: [network_ops.max_ip_len]u8 = undefined;
        if (self.net.getAnyIpAddress(&ip_buf)) |maybe_ip| {
            if (maybe_ip) |ip| client.publish("ip_address", ip, false) catch {};
        } else |_| {}

        // kB/s, decimal, matching both the entity's declared unit and what the
        // panel shows. This divided by 1024 while calling the result kB/s, which
        // disagreed with the display by 2.4%.
        const raw = self.traffic.getRawTraffic();
        publishFmt(client, "traffic_down", "{d:.2}", .{raw.rx_bytes_per_sec / 1000.0});
        publishFmt(client, "traffic_up", "{d:.2}", .{raw.tx_bytes_per_sec / 1000.0});

        log.debug("MQTT stats published", .{});
    }

    /// Format and publish one value. Failures are logged by the client and never
    /// abort the remaining sensors.
    fn publishFmt(client: *MqttClient, topic: []const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [32]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, fmt, args) catch return;
        client.publish(topic, payload, false) catch {};
    }
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    config.Config.load(init);

    try logger.init(io);
    defer logger.deinit();

    // Runs unprivileged as long as the user is in the gpio and spi groups.
    installSignalHandlers();

    log.info("SysInk starting", .{});

    var sys_ops = SystemOps.init(allocator, io);
    defer sys_ops.deinit();
    var net_ops = NetworkOps.init(io);
    var traffic_mon = TrafficMonitor.init(io);

    // The transport outlives the renderer, which only borrows it.
    var epd_config = EpdConfig.init(allocator);
    defer epd_config.moduleExit();

    var renderer = DisplayRenderer.init(allocator, io, &epd_config) catch |err| {
        log.err("Failed to initialize display: {t}", .{err});
        log.err("Check GPIO/SPI permissions", .{});
        return 1;
    };
    defer renderer.deinit();

    log.info("Initializing display", .{});
    renderer.startup() catch |err| {
        log.err("Failed to start display: {t}", .{err});
        return 1;
    };

    renderer.showLoading() catch |err| {
        log.err("Failed to show loading screen: {t}", .{err});
    };
    renderer.renderGrid();

    var app = App{
        .io = io,
        .sys = &sys_ops,
        .net = &net_ops,
        .traffic = &traffic_mon,
        .renderer = &renderer,
    };

    const mqtt_config = MqttConfig.load(init);
    var mqtt_client: ?MqttClient = null;
    defer if (mqtt_client) |*client| client.deinit();

    if (mqtt_config.enabled) {
        log.info("MQTT enabled, broker {s}:{d}", .{ mqtt_config.host, mqtt_config.port });
        mqtt_client = MqttClient.init(allocator, io, mqtt_config);

        if (mqtt_client) |*client| {
            // A failure here is not fatal: publishMqttStats retries with backoff,
            // and discovery is republished once the broker comes up.
            client.connect() catch |err| {
                log.warn("MQTT connection failed: {t} - will retry later", .{err});
            };
            app.mqtt = client;
        }
    }

    var scheduler = Scheduler.init(allocator, io);
    defer scheduler.deinit();

    const fast = config.Config.interval_fast;
    const slow = config.Config.interval_slow;

    try scheduler.every(fast, "cpu", &app, App.updateCpu);
    try scheduler.every(fast, "memory", &app, App.updateMemory);
    try scheduler.every(fast, "disk", &app, App.updateDisk);
    try scheduler.every(fast, "fan", &app, App.updateFan);
    try scheduler.every(fast, "traffic", &app, App.updateTraffic);
    try scheduler.every(fast, "signal", &app, App.updateSignal);
    try scheduler.every(fast, "uptime", &app, App.updateUptime);
    // The APT count is repainted on the fast tick so a background check that
    // finishes mid-cycle shows up promptly.
    try scheduler.every(fast, "apt_render", &app, App.renderApt);
    try scheduler.every(fast, "undervoltage", &app, App.updateUndervoltage);

    try scheduler.every(slow, "ip", &app, App.updateIp);
    try scheduler.every(slow, "apt", &app, App.updateApt);
    try scheduler.every(slow, "internet", &app, App.updateInternet);

    if (mqtt_config.enabled) {
        try scheduler.every(fast, "mqtt", &app, App.publishMqttStats);
    }

    // Populate every field before the first frame reaches the panel.
    scheduler.runAll();

    // Seeds the RAM that later partial updates diff against.
    try renderer.showInitialFrame();
    app.last_full_refresh = app.nowSeconds();

    // Registered last so it does not run before the base frame exists. Its first
    // tick is a no-op anyway: the frame is unchanged, so the update is skipped.
    try scheduler.every(fast, "display", &app, App.updateDisplay);

    log.info("Starting main loop (Ctrl+C to exit)", .{});
    runLoop(&scheduler);

    log.info("Shutting down gracefully", .{});
    renderer.goToSleep() catch |err| {
        log.err("Failed to show sleep screen: {t}", .{err});
    };

    return 0;
}

fn installSignalHandlers() void {
    var fds: [2]i32 = undefined;
    if (std.posix.errno(std.os.linux.pipe(&fds)) == .SUCCESS) {
        wake_pipe = fds;
    } else {
        log.warn("Failed to create wake pipe; shutdown may lag by up to a second", .{});
    }

    // std.posix.sigaction rather than libc signal(): same effect, but the
    // semantics are spelled out instead of inherited from whatever the libc's
    // signal() maps to. SA_RESTART matches musl's signal() behaviour; the main
    // loop does not depend on it either way, since the self-pipe write makes the
    // restarted poll return immediately.
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.HUP, &action, null);
}

/// Run scheduled tasks until a signal arrives.
///
/// Between ticks the loop blocks on the wake pipe for exactly as long as the
/// next task is away, so an idle daemon wakes once per interval rather than
/// once per second, while a signal still stops it immediately.
fn runLoop(scheduler: *Scheduler) void {
    const max_sleep_seconds = 3600;
    const have_pipe = wake_pipe[0] >= 0;

    while (!should_exit.load(.acquire)) {
        scheduler.runPending();
        if (should_exit.load(.acquire)) break;

        const idle = scheduler.idleSeconds() orelse max_sleep_seconds;
        var seconds = @min(idle, max_sleep_seconds);

        // Without the pipe there is nothing to interrupt the wait, so fall back
        // to short naps to keep shutdown responsive.
        if (!have_pipe) seconds = @min(seconds, 1);

        var fds = [_]std.posix.pollfd{.{
            .fd = wake_pipe[0],
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        // With no pipe, poll on zero descriptors degrades to a plain sleep.
        const watched: []std.posix.pollfd = if (have_pipe) fds[0..1] else fds[0..0];

        _ = std.posix.poll(watched, @intCast(seconds * 1000)) catch {};
    }
}
