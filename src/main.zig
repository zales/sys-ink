const std = @import("std");
const config = @import("config.zig");
const Config = config.Config;
const logger = @import("logger.zig");
const syscall = @import("syscall.zig");
const WebPreview = @import("web_preview.zig").WebPreview;
const api = @import("api.zig");
const network_ops = @import("network_ops.zig");
const parse = @import("parse.zig");
const SystemOps = @import("system_ops.zig").SystemOps;
const NetworkOps = network_ops.NetworkOps;
const TrafficMonitor = network_ops.TrafficMonitor;
const Scheduler = @import("scheduler.zig").Scheduler;
const Renderer = @import("display_renderer.zig").Renderer;
const display_config = @import("display_config.zig");
const EpdConfig = @import("waveshare_epd/epdconfig.zig").EpdConfig;
const Panel = @import("panel.zig").Panel(EpdConfig);
const BmpExporter = @import("bmp.zig").BmpExporter;
const MqttClient = @import("mqtt.zig").MqttClient;
const MqttConfig = @import("mqtt.zig").MqttConfig;
const NoticeFifo = @import("notice_fifo.zig").Fifo;
const notice = @import("notice.zig");

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    // std.log's comptime threshold defaults to .info outside Debug builds, which
    // compiles every log.debug call out of release binaries and makes
    // LOG_LEVEL=DEBUG silently do nothing. Open the comptime gate fully and let
    // the runtime check in logger.logFn apply LOG_LEVEL instead.
    .log_level = .debug,
};

/// A minimal panic handler. The default one pulls ELF/DWARF parsing and
/// stack-trace rendering into the binary — roughly 90 KB that can never produce
/// a useful trace here, because release builds are stripped. Zig 0.17.0's own
/// minimal one, `std.debug.simple_panic`, does not compile (a regression listed
/// in its release notes), so this is the same thing by hand.
pub const panic = std.debug.FullPanic(panicMessage);

fn panicMessage(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_addr;
    const stderr = &std.debug.lockStderr(&.{}).file_writer.interface;
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};
    @trap();
}

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
    options: Options,
    sys: *SystemOps,
    net: *NetworkOps,
    traffic: *TrafficMonitor,
    renderer: *Renderer,
    panel: *Panel,
    bmp_exporter: BmpExporter = .init(),
    mqtt: ?*MqttClient = null,
    preview: ?*WebPreview = null,
    notices: ?*NoticeFifo = null,
    /// Monotonic timestamp of the last full (non-partial) panel refresh.
    last_full_refresh: i64 = 0,
    /// Makes the next display update a full refresh, whatever the timer says.
    full_refresh_due: bool = false,
    /// Monotonic timestamp at which the notice on show is taken down, if one is.
    notice_until: ?i64 = null,
    /// Previous readings, so transitions are logged once rather than every
    /// cycle. Null means the source has not reported yet.
    last_undervoltage: ?bool = null,
    last_nvme_fault: ?bool = null,

    /// What the tasks go by. Plain values, so that nothing here reads the
    /// configuration.
    const Options = struct {
        /// Seconds between full refreshes of the panel, which clear the ghosting
        /// partial ones leave behind.
        interval_full_refresh: u32,
        /// How long a notice stays up when it does not say, in seconds.
        notify_duration: u32,
        /// Where each frame is also written as a BMP. Null: nowhere.
        bmp_export_path: ?[]const u8,
        /// Whether the APT check may refresh the package lists first, which takes
        /// root. Without it the count comes from the lists as they stand.
        may_update_package_lists: bool,
    };

    fn nowSeconds(self: *App) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toSeconds();
    }

    // ------------------------------------------------------------------------
    // Display tasks
    // ------------------------------------------------------------------------

    // Paired readings are taken and drawn independently, so one failing leaves
    // only its own slot stale instead of taking its neighbour down with it.
    //
    // Each slot is drawn from the reading whether or not the attempt worked:
    // that is what lets the panel show a value that could not be refreshed as
    // stale. It used to be skipped on a failure, which left the old value up
    // looking as live as its neighbours.

    fn updateCpu(self: *App) void {
        if (self.sys.getCpuLoad()) |load| {
            log.debug("CPU load: {d}%", .{load});
        } else |err| log.warn("getCpuLoad failed: {t}", .{err});
        self.renderer.renderCpuLoad(self.sys.cpu_load);

        if (self.sys.getCpuTemperature()) |temp| {
            log.debug("CPU temperature: {d}°C", .{temp});
        } else |err| log.warn("getCpuTemperature failed: {t}", .{err});
        self.renderer.renderCpuTemp(self.sys.cpu_temp);
    }

    fn updateMemory(self: *App) void {
        if (self.sys.getMemory()) |mem| {
            log.debug("Memory: {d}%", .{mem});
        } else |err| log.warn("getMemory failed: {t}", .{err});
        self.renderer.renderMemory(self.sys.memory);
    }

    fn updateDisk(self: *App) void {
        if (self.sys.getDiskUsage()) |usage| {
            log.debug("Disk usage: {d}%", .{usage});
        } else |err| log.warn("getDiskUsage failed: {t}", .{err});
        self.renderer.renderDiskUsage(self.sys.disk_usage);

        if (self.sys.getDiskTemp()) |temp| {
            log.debug("Disk temperature: {?d}°C", .{temp});
        } else |err| log.warn("getDiskTemp failed: {t}", .{err});
        self.renderer.renderDiskTemp(self.sys.disk_temp);
    }

    fn updateFan(self: *App) void {
        if (self.sys.getFanSpeed()) |rpm| {
            log.debug("Fan: {?d} RPM", .{rpm});
        } else |err| log.warn("getFanSpeed failed: {t}", .{err});
        self.renderer.renderFanSpeed(self.sys.fan_speed);
    }

    fn updateSignal(self: *App) void {
        // Read even on a cable: MQTT publishes it whenever there is one.
        const signal = self.net.getSignalStrength("wlan0");
        if (signal) |s| log.debug("Signal: {d} dBm", .{s});

        // Relies on the IP task having run first this cycle; see the schedule.
        if (self.net.lastIpIsWired()) {
            self.renderer.renderWired();
        } else {
            self.renderer.renderSignalStrength(signal);
        }
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
        if (self.sys.getUptime()) |uptime| {
            log.debug("Uptime: {d}d {d}h {d}m", .{ uptime.days, uptime.hours, uptime.minutes });
        } else |err| log.warn("getUptime failed: {t}", .{err});
        self.renderer.renderUptime(self.sys.last_uptime);
    }

    fn updateTraffic(self: *App) void {
        if (self.traffic.getCurrentTraffic()) |rates| {
            const down = parse.scaleBytes(rates.rx_bytes_per_sec);
            const up = parse.scaleBytes(rates.tx_bytes_per_sec);
            log.debug("Traffic: {d:.2} {s}/s down / {d:.2} {s}/s up", .{
                down.value, down.unit,
                up.value,   up.unit,
            });
        } else |err| log.warn("getCurrentTraffic failed: {t}", .{err});
        self.renderer.renderTraffic(self.traffic.rates);
    }

    fn updateApt(self: *App) void {
        // Kick off the check in the background; the count below is whatever the
        // previous run produced.
        self.sys.refreshUpdates(self.options.may_update_package_lists, self.net.checkInternetConnection());
    }

    /// Repaint the APT counter from the latest background result.
    fn renderApt(self: *App) void {
        const count = self.sys.aptUpdates();
        log.debug("APT updates: {?d} ({t})", .{ count.value, count.state() });
        self.renderer.renderAptUpdates(count);
    }

    fn updateInternet(self: *App) void {
        const connected = self.net.checkInternetConnection();
        log.debug("Internet: {}", .{connected});
        self.renderer.renderInternetStatus(connected);
    }

    /// Repaint the reachability icon from the latest probe, whoever took it.
    ///
    /// The probe itself runs on the slow interval, and also for MQTT, up to
    /// once a minute. The panel only ever drew the slow one, so with MQTT
    /// enabled it could show "connected" for hours while Home Assistant had
    /// long since been told otherwise.
    fn renderInternet(self: *App) void {
        const connected = self.net.lastInternet() orelse return;
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
            // No sensor on this hardware, or no answer from it this time:
            // nothing new to report, and certainly not a healthy reading.
            // The fault bar goes by what each source last said.
            self.applyFaultState();
            return;
        };

        if (self.last_undervoltage != active) {
            if (active) {
                log.warn("Under-voltage detected: check the power supply and cable", .{});
            } else if (self.last_undervoltage != null) {
                log.info("Under-voltage cleared", .{});
            }
            self.last_undervoltage = active;
        }
        self.applyFaultState();
    }

    /// Poll the drive's SMART / Health page and surface a critical warning.
    ///
    /// The fault bit covers spare exhaustion, temperature excursions, degraded
    /// reliability, read-only fallback and backup failure — the drive's own
    /// declaration that something is wrong, which on a NAS is the single most
    /// important thing this display can show.
    fn updateNvmeHealth(self: *App) void {
        const health = self.sys.getNvmeHealth() orelse {
            self.applyFaultState();
            return;
        };

        log.debug("NVMe SMART: wear {d}%, spare {d}%, {d}°C, warning 0x{x}", .{
            health.percentage_used,
            health.available_spare,
            health.compositeTempCelsius(),
            health.critical_warning,
        });

        const faulted = health.faulted();
        if (self.last_nvme_fault != faulted) {
            if (faulted) {
                var buf: [256]u8 = undefined;
                log.warn("NVMe SMART critical warning (0x{x}): {s}", .{
                    health.critical_warning,
                    parse.nvmeWarningNames(&buf, health.critical_warning),
                });
            } else if (self.last_nvme_fault != null) {
                log.info("NVMe SMART warning cleared", .{});
            }
            self.last_nvme_fault = faulted;
        }
        self.applyFaultState();
    }

    /// The fault bar shows the OR of every source, so one clearing while another
    /// is still active cannot blank it.
    ///
    /// Each source counts as it was last seen, stale or not: failing to read a
    /// sensor is no evidence that the fault it reported has cleared. A source
    /// never read, or absent from this hardware, raises nothing.
    fn applyFaultState(self: *App) void {
        const uv = self.sys.undervoltage.value orelse false;
        const smart = if (self.sys.nvme_health.value) |health| health.faulted() else false;
        self.renderer.setFaultWarning(uv or smart);
    }

    fn updateDisplay(self: *App) void {
        const now = self.nowSeconds();
        const elapsed = now - self.last_full_refresh;

        // Periodic full refresh clears the ghosting that partial updates leave
        // behind. Driven by elapsed time so it does not depend on INTERVAL_FAST.
        const full_refresh = self.full_refresh_due or
            elapsed >= @as(i64, self.options.interval_full_refresh);
        if (full_refresh) {
            self.last_full_refresh = now;
            self.full_refresh_due = false;
        }

        if (self.panel.show(self.renderer.panelFrame(), if (full_refresh) .full else .partial)) {
            self.exportBmp();
        } else |err| {
            log.warn("Failed to update display: {t}", .{err});
        }

        self.publishPreview();
    }

    /// Show the loading screen while the first readings are taken.
    fn showLoading(self: *App) void {
        self.renderer.drawLoadingScreen();
        self.panel.splash(self.renderer.panelFrame()) catch |err| {
            log.err("Failed to show loading screen: {t}", .{err});
            return;
        };
        self.exportBmp();
    }

    /// Push the first frame and establish the reference for later partial updates.
    fn showInitialFrame(self: *App) !void {
        try self.panel.show(self.renderer.panelFrame(), .full);
        self.last_full_refresh = self.nowSeconds();
        self.exportBmp();
    }

    /// Leave the sleep screen on the glass and the controller in deep sleep.
    fn showSleepScreen(self: *App) void {
        log.info("Rendering sleep screen", .{});
        self.renderer.drawSleepScreen();
        self.panel.shutdown(self.renderer.panelFrame()) catch |err| {
            log.err("Failed to show sleep screen: {t}", .{err});
            return;
        };
        self.exportBmp();
    }

    /// Write the frame on show to the BMP file, if that is turned on.
    fn exportBmp(self: *App) void {
        const path = self.options.bmp_export_path orelse return;

        self.bmp_exporter.save(
            self.io,
            self.renderer.packedFrame(),
            display_config.DISPLAY_WIDTH,
            display_config.DISPLAY_HEIGHT,
            path,
        ) catch |err| {
            log.err("Failed to export BMP: {t}", .{err});
        };
    }

    /// Hand the frame just drawn to the preview, if one is running, and the
    /// readings it was drawn from to the API.
    fn publishPreview(self: *App) void {
        const preview = self.preview orelse return;
        preview.publish(self.renderer.packedFrame());
        preview.publishStatus(self.status());
    }

    /// The cached readings, as `/api/status` reports them. Takes no
    /// measurement: the display tasks have just done that.
    ///
    /// A stale reading is reported with the value it last had, and its age
    /// under `stale`; see `api.Status`.
    fn status(self: *App) api.Status {
        const now = self.nowSeconds();
        const sys = self.sys;
        const rates = self.traffic.rates;
        const apt = sys.aptUpdates();
        const nvme_age = sys.nvme_health.staleFor(now);
        return .{
            .cpu_load = sys.cpu_load.value,
            .cpu_temp = sys.cpu_temp.value,
            .memory = sys.memory.value,
            .disk_usage = sys.disk_usage.value,
            .disk_temp = sys.disk_temp.value,
            .fan_speed = sys.fan_speed.value,
            .uptime_minutes = if (sys.last_uptime) |u|
                @as(u64, u.days) * 1440 + @as(u64, u.hours) * 60 + u.minutes
            else
                null,
            .ip_address = self.net.lastIpAddress(),
            .wired = self.net.lastIpIsWired(),
            .signal_strength = self.net.lastSignalStrength(),
            .internet = self.net.lastInternet(),
            .download_bytes_per_second = if (rates.value) |r| wholeBytes(r.rx_bytes_per_sec) else null,
            .upload_bytes_per_second = if (rates.value) |r| wholeBytes(r.tx_bytes_per_sec) else null,
            .apt_updates = apt.value,
            .undervoltage = sys.undervoltage.value,
            .nvme_fault = if (sys.nvme_health.value) |h| h.faulted() else null,
            .ssd_wear = if (sys.nvme_health.value) |h| h.percentage_used else null,
            .stale = .{
                .cpu_load = sys.cpu_load.staleFor(now),
                .cpu_temp = sys.cpu_temp.staleFor(now),
                .memory = sys.memory.staleFor(now),
                .disk_usage = sys.disk_usage.staleFor(now),
                .disk_temp = sys.disk_temp.staleFor(now),
                .fan_speed = sys.fan_speed.staleFor(now),
                .download_bytes_per_second = rates.staleFor(now),
                .upload_bytes_per_second = rates.staleFor(now),
                .apt_updates = apt.staleFor(now),
                .undervoltage = sys.undervoltage.staleFor(now),
                .nvme_fault = nvme_age,
                .ssd_wear = nvme_age,
            },
        };
    }

    fn wholeBytes(rate: f64) u64 {
        return @intFromFloat(@max(0, @round(rate)));
    }

    // ------------------------------------------------------------------------
    // Notices
    // ------------------------------------------------------------------------

    fn receivePipeNotice(self: *App) void {
        const fifo = self.notices orelse return;
        if (fifo.receive()) |raw| self.applyNotice(raw);
    }

    fn receiveMqttNotice(self: *App) void {
        const client = self.mqtt orelse return;
        if (client.receive()) |raw| self.applyNotice(raw);
    }

    fn receiveApiNotice(self: *App) void {
        const preview = self.preview orelse return;
        var buf: [api.max_notice_body]u8 = undefined;
        if (preview.takeNotice(&buf)) |raw| self.applyNotice(raw);
    }

    /// Put a notice on the panel straight away, rather than at the next display
    /// tick, which may be half a minute off. One with no text takes down the
    /// notice on show instead.
    fn applyNotice(self: *App, raw: []const u8) void {
        // Room for the unescaped strings of the largest payload either source
        // delivers, with the JSON parser's own bookkeeping.
        var scratch: [8192]u8 = undefined;
        const n = notice.parse(&scratch, raw) orelse return;

        if (n.text.len == 0) {
            if (self.notice_until == null) return;
            log.info("Notice dismissed", .{});
            self.notice_until = self.nowSeconds();
            self.expireNotice();
            return;
        }

        const duration = n.duration orelse self.options.notify_duration;
        log.info("Notice for {d}s: {s}", .{ duration, n.text });
        self.renderer.showNotice(n.text);
        self.notice_until = self.nowSeconds() + @as(i64, duration);
        self.updateDisplay();
    }

    /// Take the notice down once its time is up.
    fn expireNotice(self: *App) void {
        const until = self.notice_until orelse return;
        if (self.nowSeconds() < until) return;

        self.notice_until = null;
        self.renderer.clearNotice();
        // A partial update from a screen of large text back to the dashboard
        // can leave a faint ghost of it; the full refresh is worth its flash.
        self.full_refresh_due = true;
        self.updateDisplay();
    }

    fn noticeSecondsLeft(self: *App) ?i64 {
        const until = self.notice_until orelse return null;
        return @max(0, until - self.nowSeconds());
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
                switch (err) {
                    error.BackoffActive => log.debug("MQTT reconnect skipped (backoff)", .{}),
                    // The client has said so itself, and it is not a failure.
                    error.StillResolving => {},
                    else => log.warn("MQTT reconnect failed: {t}", .{err}),
                }
                return;
            };
        }

        // Cached readings, populated by the display tasks above — and only
        // the current ones. A reading whose latest attempt failed, or that
        // there is no sensor for, publishes nothing rather than its last value
        // or a zero. Sending the last value on every cycle is what kept Home
        // Assistant showing a disk temperature hours old as live: the entity's
        // `expire_after` counts from the last message, and they never stopped.
        // Withheld, it expires and the entity reads unavailable.
        const sys = self.sys;
        if (sys.cpu_load.current()) |load| publishFmt(client, "cpu_load", "{d}", .{load});
        if (sys.cpu_temp.current()) |temp| publishFmt(client, "cpu_temp", "{d}", .{temp});
        if (sys.memory.current()) |mem| publishFmt(client, "memory", "{d}", .{mem});
        if (sys.disk_usage.current()) |usage| publishFmt(client, "disk_usage", "{d}", .{usage});
        if (sys.disk_temp.current()) |temp| publishFmt(client, "disk_temp", "{d}", .{temp});
        if (sys.fan_speed.current()) |rpm| publishFmt(client, "fan_speed", "{d}", .{rpm});
        if (sys.undervoltage.current()) |active| {
            client.publish("undervoltage", if (active) "ON" else "OFF", false) catch {};
        }
        if (sys.nvme_health.current()) |health| {
            client.publish("nvme_fault", if (health.faulted()) "ON" else "OFF", false) catch {};
            publishFmt(client, "ssd_wear", "{d}", .{health.percentage_used});
        }
        // Withheld until a check has actually run, so Home Assistant is not told
        // "0 updates" on the basis of no data.
        if (sys.aptUpdates().current()) |count| publishFmt(client, "apt_updates", "{d}", .{count});

        // The readings below are the ones the display tasks already took this
        // cycle, not fresh ones. The scheduler runs this task after them, so
        // re-reading /proc/uptime, /proc/net/wireless and the whole interface
        // list — which is what this did — could only ever produce the same
        // numbers at twice the cost, and risked the panel and Home Assistant
        // disagreeing over which sample was "now".
        if (sys.last_uptime) |uptime| {
            publishFmt(client, "uptime_days", "{d}", .{uptime.days});
        }

        if (self.net.lastSignalStrength()) |signal| {
            publishFmt(client, "signal_strength", "{d}", .{signal});
        }

        client.publish("internet", if (self.net.checkInternetConnection()) "ON" else "OFF", false) catch {};

        if (self.net.lastIpAddress()) |ip| client.publish("ip_address", ip, false) catch {};

        // kB/s, decimal, matching both the entity's declared unit and what the
        // panel shows. This divided by 1024 while calling the result kB/s, which
        // disagreed with the display by 2.4%.
        if (self.traffic.rates.current()) |rates| {
            publishFmt(client, "traffic_down", "{d:.2}", .{rates.rx_bytes_per_sec / 1000.0});
            publishFmt(client, "traffic_up", "{d:.2}", .{rates.tx_bytes_per_sec / 1000.0});
        }

        log.debug("MQTT stats published", .{});
    }

    /// Format and publish one value. Failures are logged by the client and never
    /// abort the remaining sensors.
    fn publishFmt(client: *MqttClient, topic: []const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [32]u8 = undefined;
        const payload = std.mem.print(&buf, fmt, args) catch return;
        client.publish(topic, payload, false) catch {};
    }
};

/// Log what reading the settings turned up: each one given a value the daemon
/// could not use, and each name that is not a setting but looks like one.
fn logReport(report: *const config.Report) void {
    for (report.rejected()) |*r| {
        log.warn("Ignoring {s}={s}: expected {s}; using {s}", .{ r.name, r.shown(), r.expected, r.used() });
    }
    for (report.unknown()) |stray| {
        if (stray.meant) |meant| {
            log.warn("Ignoring {s}: not a setting; did you mean {s}?", .{ stray.name, meant });
        } else {
            log.warn("Ignoring {s}: not a setting this daemon has", .{stray.name});
        }
    }
}

fn isRoot() bool {
    return std.os.linux.getuid() == 0;
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var report: config.Report = .{};
    const cfg = Config.fromEnv(init.environ_map, &report);
    var mqtt_config = MqttConfig.fromEnv(init.environ_map, &report);
    // Once everything has been read: what a setting is, is what was asked for.
    report.findUnknown(init.environ_map);
    mqtt_config.notices_enabled = cfg.notify_enabled;
    mqtt_config.publish_interval = cfg.interval_fast;

    logger.init(io, .{
        .level = cfg.log_level.toStd(),
        .file_path = if (cfg.log_to_file) cfg.log_file_path else null,
    });
    defer logger.deinit();

    // Runs unprivileged as long as the user is in the gpio and spi groups.
    installSignalHandlers();

    log.info("SysInk starting", .{});
    // Now, with the logger up: the level and the file are settings themselves.
    logReport(&report);

    var sys_ops = SystemOps.init(allocator, io, init.environ_map);
    defer sys_ops.deinit();
    var net_ops = NetworkOps.init(io, .{ .ip = cfg.internet_check_ip, .port = cfg.internet_check_port });
    var traffic_mon = TrafficMonitor.init(io);

    var renderer = Renderer.init(allocator, .{ .thresholds = cfg.thresholds }) catch |err| {
        log.err("Failed to initialize display: {t}", .{err});
        return 1;
    };
    defer renderer.deinit();

    // The transport outlives the panel, which only borrows it.
    var epd_config = EpdConfig.init(.{ .gpio_chip = cfg.gpio_chip, .spi_device = cfg.spi_device });
    defer epd_config.moduleExit();

    var panel = Panel.init(&epd_config, .{ .sleep_between_updates = cfg.panel_sleep });

    log.info("Initializing display", .{});
    panel.startup() catch |err| {
        log.err("Failed to start display: {t}", .{err});
        log.err("Check GPIO/SPI permissions", .{});
        return 1;
    };

    var app = App{
        .io = io,
        .options = .{
            .interval_full_refresh = cfg.interval_full_refresh,
            .notify_duration = cfg.notify_duration,
            .bmp_export_path = if (cfg.export_bmp) cfg.bmp_export_path else null,
            .may_update_package_lists = isRoot(),
        },
        .sys = &sys_ops,
        .net = &net_ops,
        .traffic = &traffic_mon,
        .renderer = &renderer,
        .panel = &panel,
    };

    app.showLoading();
    renderer.renderGrid();

    var mqtt_client: ?MqttClient = null;
    defer if (mqtt_client) |*client| client.deinit();

    if (mqtt_config.enabled) {
        log.info("MQTT enabled, broker {s}:{d}", .{ mqtt_config.host, mqtt_config.port });
        mqtt_client = MqttClient.init(io, mqtt_config);

        if (mqtt_client) |*client| {
            // A failure here is not fatal: publishMqttStats retries with backoff,
            // and discovery is republished once the broker comes up.
            client.connect() catch |err| switch (err) {
                // The first publish, a moment from now, collects the answer.
                error.StillResolving => {},
                else => log.warn("MQTT connection failed: {t} - will retry later", .{err}),
            };
            app.mqtt = client;
        }
    }

    var scheduler = Scheduler.init(allocator, io);
    defer scheduler.deinit();

    const fast = cfg.interval_fast;
    const slow = cfg.interval_slow;

    try scheduler.every(fast, "cpu", &app, App.updateCpu);
    try scheduler.every(fast, "memory", &app, App.updateMemory);
    try scheduler.every(fast, "disk", &app, App.updateDisk);
    try scheduler.every(fast, "fan", &app, App.updateFan);
    try scheduler.every(fast, "traffic", &app, App.updateTraffic);
    // Before signal: which of the two the signal slot shows depends on the
    // interface the address is on.
    try scheduler.every(fast, "ip", &app, App.updateIp);
    try scheduler.every(fast, "signal", &app, App.updateSignal);
    try scheduler.every(fast, "uptime", &app, App.updateUptime);
    // The APT count is repainted on the fast tick so a background check that
    // finishes mid-cycle shows up promptly.
    try scheduler.every(fast, "apt_render", &app, App.renderApt);
    try scheduler.every(fast, "undervoltage", &app, App.updateUndervoltage);
    try scheduler.every(fast, "nvme_health", &app, App.updateNvmeHealth);
    try scheduler.every(fast, "internet_render", &app, App.renderInternet);

    try scheduler.every(slow, "apt", &app, App.updateApt);
    try scheduler.every(slow, "internet", &app, App.updateInternet);

    if (mqtt_config.enabled) {
        try scheduler.every(fast, "mqtt", &app, App.publishMqttStats);
    }

    // Populate every field before the first frame reaches the panel.
    scheduler.runAll();

    // Seeds the RAM that later partial updates diff against.
    try app.showInitialFrame();

    // Bound and started here, at its final address: `start` hands the runtime a
    // pointer to it, so it must not move afterwards.
    var preview: ?WebPreview = null;
    if (cfg.web_preview) {
        const api_options: api.Options = .{
            .token = cfg.web_api_token,
            .notices_enabled = cfg.notify_enabled,
        };
        preview = WebPreview.init(io, cfg.web_preview_addr, cfg.web_preview_port, api_options) catch |err| blk: {
            log.err("Cannot start the panel preview: {t}", .{err});
            break :blk null;
        };
    }
    defer if (preview) |*p| p.deinit();
    if (preview) |*p| {
        p.start();
        app.preview = p;
        app.publishPreview();
    }

    var notice_fifo: ?NoticeFifo = null;
    if (cfg.notify_enabled) {
        notice_fifo = NoticeFifo.open(io, cfg.notify_fifo, cfg.notify_group) catch |err| blk: {
            log.err("Notices disabled: {t}", .{err});
            break :blk null;
        };
    }
    defer if (notice_fifo) |*f| f.close();
    if (notice_fifo) |*f| {
        app.notices = f;
        log.info("Accepting notices on {s}", .{cfg.notify_fifo});
    }

    // Registered last so it does not run before the base frame exists. Its first
    // tick is a no-op anyway: the frame is unchanged, so the update is skipped.
    try scheduler.every(fast, "display", &app, App.updateDisplay);

    log.info("Starting main loop (Ctrl+C to exit)", .{});
    runLoop(&scheduler, &app);

    log.info("Shutting down gracefully", .{});
    app.showSleepScreen();

    return 0;
}

fn installSignalHandlers() void {
    var fds: [2]i32 = undefined;
    // Close-on-exec, or every command the daemon runs inherits both ends.
    // Non-blocking so the handler's write can never stall, not even on a pipe
    // that nobody drains.
    if (syscall.ok(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }))) {
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
/// once per second, while a signal still stops it immediately. It watches the
/// notice pipe, the MQTT connection and the API's mailbox as well, so a notice
/// goes up the moment it arrives, and wakes for the one on show to come down on
/// time.
fn runLoop(scheduler: *Scheduler, app: *App) void {
    const max_sleep_seconds = 3600;
    const have_pipe = wake_pipe[0] >= 0;

    while (!should_exit.load(.acquire)) {
        scheduler.runPending();
        app.expireNotice();
        if (should_exit.load(.acquire)) break;

        const idle = scheduler.idleSeconds() orelse max_sleep_seconds;
        var seconds = @min(idle, max_sleep_seconds);
        if (app.noticeSecondsLeft()) |left| seconds = @min(seconds, left);

        // Without the pipe there is nothing to interrupt the wait, so fall back
        // to short naps to keep shutdown responsive.
        if (!have_pipe) seconds = @min(seconds, 1);

        // With nothing to watch, poll on zero descriptors degrades to a plain sleep.
        var fds: [4]std.posix.pollfd = undefined;
        var watched: usize = 0;
        if (have_pipe) {
            fds[watched] = .{ .fd = wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }
        const notice_slot = watched;
        if (app.notices) |fifo| {
            fds[watched] = .{ .fd = fifo.fd, .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }
        // Looked up afresh every time round: the socket changes on reconnect.
        const mqtt_slot = watched;
        const mqtt_socket = if (app.mqtt) |client| client.socketHandle() else null;
        if (mqtt_socket) |socket| {
            fds[watched] = .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }

        const api_slot = watched;
        const api_fd = if (app.preview) |preview| preview.noticeFd() else null;
        if (api_fd) |fd| {
            fds[watched] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }

        _ = std.posix.poll(fds[0..watched], @intCast(seconds * 1000)) catch {};

        const ready = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if (app.notices != null and fds[notice_slot].revents & std.posix.POLL.IN != 0) {
            app.receivePipeNotice();
        }
        // A hangup or error is read too, which is how a dropped broker is seen.
        if (mqtt_socket != null and fds[mqtt_slot].revents & ready != 0) {
            app.receiveMqttNotice();
        }
        if (api_fd != null and fds[api_slot].revents & std.posix.POLL.IN != 0) {
            app.receiveApiNotice();
        }
    }
}
