//! The daemon at work: the tasks that take the readings, draw them, put the
//! frame on the panel and pass the readings on.
//!
//! It is generic over the panel's transport, as the panel is, so a recorder
//! stands in for the glass. The readings come through `SystemOps` and
//! `NetworkOps`, which read a tree of fixtures as readily as the machine; a
//! broker can be the other end of a socket pair; and whatever depends on the
//! time has a form that takes it as an argument. That puts most of this under
//! test. What decides — which refresh, which fault, what goes to the broker —
//! is `app_logic.zig`, and when a notice goes up and comes down is the pacer in
//! `notice.zig`; this is where those decisions meet the parts they are
//! about.
//!
//! What the tests here leave to the device is what only a machine can answer,
//! or what reaches outside it: the address (`updateIp`), the SMART page
//! (`updateNvmeHealth`), the reachability probe and the check for updates
//! (`updateInternet`, `updateApt`), and connecting to a broker that is not
//! connected yet.
//!
//! What cannot exist off Linux at all stays in `main.zig` and reaches this
//! through two narrow doors: the notice pipe and the HTTP server hand what
//! they receive to `applyNotice`, and the server is given each frame through
//! `frame_sink`.

const std = @import("std");
const api = @import("api.zig");
const app_logic = @import("app_logic.zig");
const parse = @import("parse.zig");
const notice = @import("notice.zig");
const now_playing = @import("now_playing.zig");
const network_ops = @import("network_ops.zig");
const panel_mod = @import("panel.zig");
const layout = @import("display_config.zig");
const SystemOps = @import("system_ops.zig").SystemOps;
const NetworkOps = network_ops.NetworkOps;
const TrafficMonitor = network_ops.TrafficMonitor;
const Renderer = @import("display_renderer.zig").Renderer;
const BmpExporter = @import("bmp.zig").BmpExporter;
const MqttClient = @import("mqtt.zig").MqttClient;
const Scheduler = @import("scheduler.zig").Scheduler;

// The scope these lines have always been logged under.
const log = std.log.scoped(.main);

pub const Options = struct {
    /// Seconds between full refreshes of the panel, which clear the ghosting
    /// partial ones leave behind.
    interval_full_refresh: u32 = 600,
    /// How long a notice stays up when it does not say, in seconds.
    notify_duration: u32 = 30,
    /// Where each frame is also written as a BMP. Null: nowhere.
    bmp_export_path: ?[]const u8 = null,
    /// Whether the APT check may refresh the package lists first, which takes
    /// root. Without it the count comes from the lists as they stand.
    may_update_package_lists: bool = false,
    /// When the music screen shows, with Spotify on. Null: never.
    music: ?now_playing.Options = null,
};

/// Whoever else shows the frame: given each one as it goes up, with the
/// readings it was drawn from. Both are borrowed for the length of the call.
pub const FrameSink = struct {
    ctx: *anyopaque,
    publish: *const fn (ctx: *anyopaque, packed_frame: []const u8, status: api.Status) void,
};

pub fn App(comptime Transport: type) type {
    return struct {
        const Self = @This();

        pub const Panel = panel_mod.Panel(Transport);

        /// What the tasks work on. All borrowed: the caller keeps them
        /// where they are for as long as the app runs.
        pub const Parts = struct {
            sys: *SystemOps,
            net: *NetworkOps,
            traffic: *TrafficMonitor,
            renderer: *Renderer,
            panel: *Panel,
        };

        io: std.Io,
        options: Options,
        sys: *SystemOps,
        net: *NetworkOps,
        traffic: *TrafficMonitor,
        renderer: *Renderer,
        panel: *Panel,
        bmp_exporter: BmpExporter = .init(),
        /// The broker connection, while MQTT is on.
        mqtt: ?*MqttClient = null,
        frame_sink: ?FrameSink = null,
        /// When to do what; see `app_logic.zig`, where each of these is tested.
        refresh: app_logic.RefreshClock,
        /// When notices go up and when they come down.
        pacer: notice.Pacer = .{},
        /// When the music screen goes up, comes down and is redrawn. Null
        /// with Spotify off.
        music: ?now_playing.Screen = null,
        /// Which faults have been announced, so each is logged once. What the
        /// faults are is in the readings; see `showFaults`.
        fault_log: app_logic.FaultLog = .{},

        pub fn init(io: std.Io, options: Options, parts: Parts) Self {
            return .{
                .io = io,
                .options = options,
                .sys = parts.sys,
                .net = parts.net,
                .traffic = parts.traffic,
                .renderer = parts.renderer,
                .panel = parts.panel,
                .refresh = .{ .interval = options.interval_full_refresh },
                .music = if (options.music) |music| .{ .options = music } else null,
            };
        }

        /// Register the tasks that take the readings and draw them, in the
        /// order they have to run in. The one that puts the frame on the
        /// panel is `scheduleDisplay`, registered apart and after.
        pub fn scheduleReadings(self: *Self, scheduler: *Scheduler, fast: u32, slow: u32) !void {
            try scheduler.every(fast, "cpu", self, updateCpu);
            try scheduler.every(fast, "memory", self, updateMemory);
            try scheduler.every(fast, "disk", self, updateDisk);
            try scheduler.every(fast, "fan", self, updateFan);
            try scheduler.every(fast, "traffic", self, updateTraffic);
            // Before signal: which of the two the signal slot shows, and which
            // interface the reading is taken from, depend on the interface
            // the address is on.
            try scheduler.every(fast, "ip", self, updateIp);
            try scheduler.every(fast, "signal", self, updateSignal);
            try scheduler.every(fast, "uptime", self, updateUptime);
            // The APT count is repainted on the fast tick so a background check
            // that finishes mid-cycle shows up promptly.
            try scheduler.every(fast, "apt_render", self, renderApt);
            try scheduler.every(fast, "undervoltage", self, updateUndervoltage);
            try scheduler.every(fast, "nvme_health", self, updateNvmeHealth);
            try scheduler.every(fast, "internet_render", self, renderInternet);

            try scheduler.every(slow, "apt", self, updateApt);
            try scheduler.every(slow, "internet", self, updateInternet);

            // After everything it publishes: it takes no reading of its own.
            if (self.mqtt != null) try scheduler.every(fast, "mqtt", self, publishMqttStats);
        }

        /// Register the task that puts the frame on the panel. Last, so that
        /// each cycle it shows what that cycle read, and not before the first
        /// frame has gone up by `showInitialFrame`. Its first tick is a no-op
        /// anyway: the frame is unchanged, so the update is skipped.
        pub fn scheduleDisplay(self: *Self, scheduler: *Scheduler, fast: u32) !void {
            try scheduler.every(fast, "display", self, updateDisplay);
        }

        fn nowSeconds(self: *Self) i64 {
            return std.Io.Timestamp.now(self.io, .awake).toSeconds();
        }

        /// The same clock in milliseconds, which the Spotify client stamps
        /// what it receives with.
        fn nowMs(self: *Self) i64 {
            return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
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

        pub fn updateCpu(self: *Self) void {
            if (self.sys.getCpuLoad()) |load| {
                log.debug("CPU load: {d}%", .{load});
            } else |err| log.warn("getCpuLoad failed: {t}", .{err});
            self.renderer.renderCpuLoad(self.sys.cpu_load);

            if (self.sys.getCpuTemperature()) |temp| {
                log.debug("CPU temperature: {d}°C", .{temp});
            } else |err| log.warn("getCpuTemperature failed: {t}", .{err});
            self.renderer.renderCpuTemp(self.sys.cpu_temp);
        }

        pub fn updateMemory(self: *Self) void {
            if (self.sys.getMemory()) |mem| {
                log.debug("Memory: {d}%", .{mem});
            } else |err| log.warn("getMemory failed: {t}", .{err});
            self.renderer.renderMemory(self.sys.memory);
        }

        pub fn updateDisk(self: *Self) void {
            if (self.sys.getDiskUsage()) |usage| {
                log.debug("Disk usage: {d}%", .{usage});
            } else |err| log.warn("getDiskUsage failed: {t}", .{err});
            self.renderer.renderDiskUsage(self.sys.disk_usage);

            if (self.sys.getDiskTemp()) |temp| {
                log.debug("Disk temperature: {?d}°C", .{temp});
            } else |err| log.warn("getDiskTemp failed: {t}", .{err});
            self.renderer.renderDiskTemp(self.sys.disk_temp);
        }

        pub fn updateFan(self: *Self) void {
            if (self.sys.getFanSpeed()) |rpm| {
                log.debug("Fan: {?d} RPM", .{rpm});
            } else |err| log.warn("getFanSpeed failed: {t}", .{err});
            self.renderer.renderFanSpeed(self.sys.fan_speed);
        }

        pub fn updateSignal(self: *Self) void {
            // Read even on a cable: MQTT publishes it whenever there is one.
            // Both this and the choice of slot below rely on the IP task having
            // run first this cycle: the reading is taken from the interface the
            // address is on, when that one is wireless. See `scheduleReadings`.
            const signal = self.net.getSignalStrength();
            if (signal) |s| log.debug("Signal: {d} dBm", .{s});

            if (self.net.lastIpIsWired()) {
                self.renderer.renderWired();
            } else {
                self.renderer.renderSignalStrength(signal);
            }
        }

        pub fn updateIp(self: *Self) void {
            var buf: [network_ops.max_ip_len]u8 = undefined;

            const ip = self.net.getAnyIpAddress(&buf) catch |err| {
                log.warn("getAnyIpAddress failed: {t}", .{err});
                self.renderer.renderIpAddress("Error");
                return;
            };

            self.renderer.renderIpAddress(ip orelse "No IP");
            log.debug("IP: {s}", .{ip orelse "none"});
        }

        pub fn updateUptime(self: *Self) void {
            if (self.sys.getUptime()) |uptime| {
                log.debug("Uptime: {d}d {d}h {d}m", .{ uptime.days, uptime.hours, uptime.minutes });
            } else |err| log.warn("getUptime failed: {t}", .{err});
            self.renderer.renderUptime(self.sys.last_uptime);
        }

        pub fn updateTraffic(self: *Self) void {
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

        pub fn updateApt(self: *Self) void {
            // Kick off the check in the background; the count below is whatever the
            // previous run produced.
            self.sys.refreshUpdates(self.options.may_update_package_lists, self.net.checkInternetConnection());
        }

        /// Repaint the APT counter from the latest background result.
        pub fn renderApt(self: *Self) void {
            const count = self.sys.aptUpdates();
            log.debug("APT updates: {?d} ({t})", .{ count.value, count.state() });
            self.renderer.renderAptUpdates(count);
        }

        pub fn updateInternet(self: *Self) void {
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
        pub fn renderInternet(self: *Self) void {
            const connected = self.net.lastInternet() orelse return;
            self.renderer.renderInternetStatus(connected);
        }

        /// Read the firmware's under-voltage flag and surface it.
        ///
        /// Sustained under-voltage on a Pi with an NVMe drive risks corrupting
        /// storage, so it is worth more than a log line: the status bar is drawn
        /// inverted and the state is published to MQTT as a problem, where an
        /// automation can turn it into an actual notification.
        pub fn updateUndervoltage(self: *Self) void {
            // No sensor on this hardware, or no answer from it this time, is
            // nothing new to report, and certainly not a healthy reading.
            _ = self.sys.getUndervoltage();

            switch (self.fault_log.note(.undervoltage, self.sys.undervoltage.value)) {
                .raised => log.warn("Under-voltage detected: check the power supply and cable", .{}),
                .cleared => log.info("Under-voltage cleared", .{}),
                .none => {},
            }
            self.showFaults();
        }

        /// Poll the drive's SMART / Health page and surface a critical warning.
        ///
        /// The fault bit covers spare exhaustion, temperature excursions, degraded
        /// reliability, read-only fallback and backup failure — the drive's own
        /// declaration that something is wrong, which on a NAS is the single most
        /// important thing this display can show.
        pub fn updateNvmeHealth(self: *Self) void {
            if (self.sys.getNvmeHealth()) |health| {
                log.debug("NVMe SMART: wear {d}%, spare {d}%, {d}°C, warning 0x{x}", .{
                    health.percentage_used,
                    health.available_spare,
                    health.compositeTempCelsius(),
                    health.critical_warning,
                });
            }

            switch (self.fault_log.note(.nvme, self.nvmeFaulted())) {
                .raised => {
                    // Raised only by a page that was read, so there is one.
                    var buf: [256]u8 = undefined;
                    const warning = self.sys.nvme_health.value.?.critical_warning;
                    const names = parse.nvmeWarningNames(&buf, warning);
                    log.warn("NVMe SMART critical warning (0x{x}): {s}", .{ warning, names });
                },
                .cleared => log.info("NVMe SMART warning cleared", .{}),
                .none => {},
            }
            self.showFaults();
        }

        /// Whether the drive was last seen to report a fault. Null if its
        /// SMART page has never been read.
        fn nvmeFaulted(self: *Self) ?bool {
            return if (self.sys.nvme_health.value) |health| health.faulted() else null;
        }

        /// Invert the status bar while any source was last seen faulted. From
        /// the readings, which is also where `/api/status` has its faults
        /// from: there is one place a fault is kept.
        fn showFaults(self: *Self) void {
            self.renderer.setFaultWarning(app_logic.faultWarning(self.sys.undervoltage.value, self.nvmeFaulted()));
        }

        /// Put the frame as it stands on the panel.
        pub fn updateDisplay(self: *Self) void {
            self.updateDisplayAt(self.nowSeconds());
        }

        /// `updateDisplay` at an explicit time, which decides between a partial
        /// and a full refresh.
        pub fn updateDisplayAt(self: *Self, now: i64) void {
            const refresh = self.refresh.next(now);

            // A picture in grey goes up in full by a grey refresh; partial
            // updates over it leave its grey alone.
            const shown = if (refresh == .full and self.renderer.grayShown())
                self.panel.showGray(self.renderer.panelGrayPlanes(), self.renderer.panelFrame())
            else
                self.panel.show(self.renderer.panelFrame(), refresh);

            if (shown) {
                self.exportBmp();
            } else |err| {
                log.warn("Failed to update display: {t}", .{err});
            }

            self.publishFrame();
        }

        /// Show the loading screen while the first readings are taken.
        pub fn showLoading(self: *Self) void {
            self.renderer.drawLoadingScreen();
            self.panel.splash(self.renderer.panelFrame()) catch |err| {
                log.err("Failed to show loading screen: {t}", .{err});
                return;
            };
            self.exportBmp();
        }

        /// Push the first frame and establish the reference for later partial updates.
        pub fn showInitialFrame(self: *Self) !void {
            try self.showInitialFrameAt(self.nowSeconds());
        }

        /// `showInitialFrame` at an explicit time, from which the interval to the
        /// next full refresh runs.
        pub fn showInitialFrameAt(self: *Self, now: i64) !void {
            try self.panel.show(self.renderer.panelFrame(), .full);
            self.refresh.tookFull(now);
            self.exportBmp();
        }

        /// Leave the sleep screen on the glass and the controller in deep sleep.
        pub fn showSleepScreen(self: *Self) void {
            log.info("Rendering sleep screen", .{});
            self.renderer.drawSleepScreen();
            self.panel.shutdown(self.renderer.panelFrame()) catch |err| {
                log.err("Failed to show sleep screen: {t}", .{err});
                return;
            };
            self.exportBmp();
        }

        /// Write the frame on show to the BMP file, if that is turned on.
        fn exportBmp(self: *Self) void {
            const path = self.options.bmp_export_path orelse return;

            self.bmp_exporter.save(
                self.io,
                self.renderer.packedFrame(),
                layout.display_width,
                layout.display_height,
                path,
            ) catch |err| {
                log.err("Failed to export BMP: {t}", .{err});
            };
        }

        /// Hand the frame as it stands to whoever else shows it, with the
        /// readings it was drawn from.
        pub fn publishFrame(self: *Self) void {
            const sink = self.frame_sink orelse return;
            sink.publish(sink.ctx, self.renderer.packedFrame(), self.status());
        }

        /// The cached readings, as `/api/status` reports them. Takes no
        /// measurement: the display tasks have just done that.
        ///
        /// A stale reading is reported with the value it last had, and its age
        /// under `stale`; see `api.Status`.
        pub fn status(self: *Self) api.Status {
            return self.statusAt(self.nowSeconds());
        }

        /// `status` at an explicit time, which the ages of stale readings are
        /// counted to.
        pub fn statusAt(self: *Self, now: i64) api.Status {
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
                .uptime_minutes = if (sys.last_uptime) |uptime| uptime.totalMinutes() else null,
                .ip_address = self.net.lastIpAddress(),
                .wired = self.net.lastIpIsWired(),
                .signal_strength = self.net.lastSignalStrength(),
                .internet = self.net.lastInternet(),
                .download_bytes_per_second = if (rates.value) |r| app_logic.wholeBytesPerSecond(r.rx_bytes_per_sec) else null,
                .upload_bytes_per_second = if (rates.value) |r| app_logic.wholeBytesPerSecond(r.tx_bytes_per_sec) else null,
                .apt_updates = apt.value,
                .undervoltage = sys.undervoltage.value,
                .nvme_fault = self.nvmeFaulted(),
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

        // ------------------------------------------------------------------------
        // Notices
        // ------------------------------------------------------------------------

        /// Read whatever the broker has sent, and put up a notice if one came.
        pub fn receiveMqttNotice(self: *Self) void {
            const client = self.mqtt orelse return;
            if (client.receive()) |raw| self.applyNotice(raw);
        }

        /// Put a notice on the panel straight away, rather than at the next display
        /// tick, which may be half a minute off. One with no text takes down the
        /// notice on show instead. `raw` is as it arrived, from whichever source.
        ///
        /// Straight away unless the panel has only just changed: the pacer
        /// decides, and nothing is drawn or logged here for a notice it holds
        /// back. A sender in a loop gets through this thousands of times a second.
        pub fn applyNotice(self: *Self, raw: []const u8) void {
            if (self.offerNotice(raw)) self.stepNotices();
        }

        /// `applyNotice` at an explicit time, from which the notice's own runs.
        pub fn applyNoticeAt(self: *Self, raw: []const u8, now: i64) void {
            if (self.offerNotice(raw)) _ = self.stepNoticesAt(now);
        }

        /// Hand what arrived to the pacer. False when it was not a notice.
        fn offerNotice(self: *Self, raw: []const u8) bool {
            // Room for the unescaped strings of the largest payload either source
            // delivers, with the JSON parser's own bookkeeping.
            var scratch: [8192]u8 = undefined;
            const n = notice.parse(&scratch, raw) orelse return false;

            self.pacer.offer(n, self.options.notify_duration);
            return true;
        }

        /// Do to the panel what the notices call for by now: put up the one whose
        /// turn has come, or take down the one whose time is up. Asked every time
        /// round the main loop, and whenever a notice arrives.
        pub fn stepNotices(self: *Self) void {
            if (!self.stepNoticesAt(self.nowSeconds())) return;
            // A full refresh takes a couple of seconds, and the interval between
            // changes is counted from the end of one: counted from its start, it
            // would be over before the panel had rested.
            self.pacer.settle(self.nowSeconds());
        }

        /// `stepNotices` at an explicit time. True when the panel was changed.
        pub fn stepNoticesAt(self: *Self, now: i64) bool {
            const step = self.pacer.next(now) orelse return false;

            switch (step) {
                .show => |shown| {
                    if (shown.repeat) {
                        // Already on the glass, so there is nothing to draw, and a
                        // sender repeating itself is not worth a line each time.
                        log.debug("Notice repeated, for another {d}s", .{shown.duration});
                        return false;
                    }
                    log.info("Notice for {d}s: {s}", .{ shown.duration, shown.text });
                    self.renderer.showNotice(shown.text);
                },
                .dismissed, .expired => {
                    if (step == .dismissed) log.info("Notice dismissed", .{});
                    self.renderer.clearNotice();
                    // A partial update from a screen of large text back to the
                    // dashboard can leave a faint ghost of it; the full refresh is
                    // worth its flash.
                    self.refresh.force();
                },
            }

            self.updateDisplayAt(now);
            return true;
        }

        /// Seconds until the notices next call for something, for the main loop
        /// to wake on time: the one on show coming down, or one that had to wait
        /// its turn going up. Null when there is nothing to wake for.
        pub fn noticeSecondsLeft(self: *Self) ?i64 {
            return self.pacer.secondsLeft(self.nowSeconds());
        }

        // ------------------------------------------------------------------------
        // Music
        // ------------------------------------------------------------------------

        /// Take in what the Spotify client has just handed over, and put it on
        /// the panel if it calls for that.
        pub fn applySpotify(self: *Self, snapshot: *const now_playing.Snapshot) void {
            self.applySpotifyAt(snapshot, self.nowMs());
        }

        /// `applySpotify` at an explicit time, in milliseconds.
        pub fn applySpotifyAt(self: *Self, snapshot: *const now_playing.Snapshot, now_ms: i64) void {
            const screen = if (self.music) |*m| m else return;
            screen.update(snapshot, now_ms);
            _ = self.stepMusicAt(now_ms);
        }

        /// Do to the panel what the music calls for by now: put the screen up,
        /// move its progress bar, or take it down. Asked every time round the
        /// main loop, and whenever the client hands something over.
        pub fn stepMusic(self: *Self) void {
            _ = self.stepMusicAt(self.nowMs());
        }

        /// `stepMusic` at an explicit time, in milliseconds. True when the
        /// panel was changed.
        pub fn stepMusicAt(self: *Self, now_ms: i64) bool {
            const screen = if (self.music) |*m| m else return false;
            // The dashboard has a fault to show on its status bar, which the
            // music screen does not have.
            const step = screen.step(now_ms, self.renderer.warn_fault) orelse return false;

            // Under a notice the screen is drawn all the same, for when the
            // notice comes down, which is a full refresh of its own.
            const visible = !self.renderer.notice_shown;
            switch (step) {
                .show => |shown| {
                    self.renderer.showMusic(shown.view);
                    // A new picture over an old one by a partial update would
                    // leave a ghost of the old.
                    if (shown.full and visible) self.refresh.force();
                },
                .hide => {
                    self.renderer.clearMusic();
                    if (visible) self.refresh.force();
                },
            }
            if (!visible) return false;
            self.updateDisplayAt(@divFloor(now_ms, 1000));
            return true;
        }

        /// Seconds until the music next calls for something without the client
        /// handing anything over, rounded up, for the main loop to wake on time.
        /// Null when there is nothing to wake for.
        pub fn musicSecondsLeft(self: *Self) ?i64 {
            const screen = if (self.music) |*m| m else return null;
            const ms = screen.msLeft(self.nowMs()) orelse return null;
            return @divCeil(ms, 1000);
        }

        // ------------------------------------------------------------------------
        // MQTT
        // ------------------------------------------------------------------------

        pub fn publishMqttStats(self: *Self) void {
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

            // Probed here too, at most once a minute, so that Home Assistant
            // hears of lost connectivity sooner than the slow interval would tell.
            _ = self.net.checkInternetConnection();

            // Everything else is what the display tasks already took this cycle,
            // not a fresh look. The scheduler runs this task after them, so
            // re-reading /proc/uptime, /proc/net/wireless and the whole interface
            // list — which is what this did — could only ever produce the same
            // numbers at twice the cost, and risked the panel and Home Assistant
            // disagreeing over which sample was "now".
            //
            // And only the current ones: see `app_logic.mqttReadings` for why a
            // stale reading is withheld.
            const readings = app_logic.mqttReadings(self.status(), self.traffic.rates.current());
            for (0..readings.len) |index| {
                const reading = readings.at(index);
                // Failures are logged by the client and never abort the rest.
                client.publish(reading.topic, reading.payload, false) catch {};
            }

            log.debug("MQTT stats published", .{});
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
//
// The whole app on a bench: fixtures for the machine, a recorder for the
// panel, and the time passed in. Nothing here reaches the network. The
// reachability probe and the APT check are left to the device, and what goes
// to the broker is tested in `app_logic.zig`.

const testing = std.testing;
const Fixture = @import("sysroot.zig").Fixture;
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;
const LoopbackClient = @import("mqtt.zig").LoopbackClient;

const TestApp = App(FakeTransport);
const Waveform = FakeTransport.Waveform;

const Bench = struct {
    fixture: Fixture,
    sys: SystemOps,
    net: NetworkOps,
    traffic: TrafficMonitor,
    renderer: Renderer,
    transport: FakeTransport,
    panel: TestApp.Panel,
    app: TestApp,
    /// A sensor that fails is warned about, which is right for the daemon and
    /// noise in a test that takes sensors away on purpose.
    saved_log_level: std.log.Level,

    /// Set up in place: the parts point at one another.
    fn init(self: *Bench, options: Options) !void {
        self.fixture = Fixture.init();
        errdefer self.fixture.deinit();
        const root = self.fixture.root();

        self.sys = SystemOps.init(testing.allocator, testing.io, root, null);
        self.net = NetworkOps.init(testing.io, root, .{});
        self.traffic = TrafficMonitor.init(testing.io, root);
        self.renderer = try Renderer.init(testing.allocator, .{});
        self.renderer.renderGrid();
        self.transport = FakeTransport.init(testing.allocator);
        // Kept awake, so that what one update sends is that update alone.
        self.panel = TestApp.Panel.init(&self.transport, .{ .sleep_between_updates = false });
        self.app = TestApp.init(testing.io, options, .{
            .sys = &self.sys,
            .net = &self.net,
            .traffic = &self.traffic,
            .renderer = &self.renderer,
            .panel = &self.panel,
        });

        self.saved_log_level = testing.log_level;
        testing.log_level = .err;
    }

    fn deinit(self: *Bench) void {
        testing.log_level = self.saved_log_level;
        self.transport.deinit();
        self.renderer.deinit();
        self.sys.deinit();
        self.fixture.deinit();
    }

    /// How the panel was last refreshed since the log was cleared, or null
    /// if it was not.
    fn refreshed(self: *Bench) ?Waveform {
        return self.transport.lastWaveform();
    }

    /// Whether anything at all reached the panel since the log was cleared.
    fn panelTouched(self: *const Bench) bool {
        return self.transport.events.items.len > 0;
    }

    /// Two readings of /proc/stat a known load apart: half the time busy.
    fn loadCpuHalfBusy(self: *Bench) !void {
        try self.fixture.put("/proc/stat", "cpu  100 0 100 800 0 0 0 0 0 0\n");
        self.app.updateCpu();
        try self.fixture.put("/proc/stat", "cpu  150 0 150 900 0 0 0 0 0 0\n");
        self.app.updateCpu();
    }
};

test "each reading goes into its own slot, and one that fails leaves its neighbour alone" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.renderGrid();

    // A machine with no thermal zone still shows its load, and a dash where
    // the temperature would be: not an empty slot, and not 0 °C.
    try bench.loadCpuHalfBusy();
    expected.renderCpuLoad(.of(50));
    expected.renderCpuTemp(.{});
    try testing.expectEqualSlices(u8, expected.bitmap.data, bench.renderer.bitmap.data);

    // One whose load can no longer be read still shows its temperature. The
    // load stays as it was last read, drawn as what it now is: stale.
    try bench.fixture.remove("/proc/stat");
    try bench.fixture.put("/sys/class/thermal/thermal_zone0/temp", "48000\n");
    bench.app.updateCpu();
    expected.renderCpuLoad(.staleOf(50));
    expected.renderCpuTemp(.of(48));
    try testing.expectEqualSlices(u8, expected.bitmap.data, bench.renderer.bitmap.data);

    // And when it can be read again, nothing of that is left.
    try bench.fixture.put("/proc/stat", "cpu  250 0 150 1000 0 0 0 0 0 0\n");
    bench.app.updateCpu();
    expected.renderCpuLoad(.of(50));
    try testing.expectEqualSlices(u8, expected.bitmap.data, bench.renderer.bitmap.data);
}

test "the status carries what the tasks read, and null where there was nothing to read" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    try bench.fixture.put("/sys/class/thermal/thermal_zone0/temp", "48000\n");
    try bench.fixture.put("/proc/meminfo", "MemTotal: 8000000 kB\nMemAvailable: 6000000 kB\n");
    try bench.fixture.put("/proc/uptime", "350735.47 234388.90\n");

    try bench.loadCpuHalfBusy();
    bench.app.updateMemory();
    bench.app.updateUptime();
    // None of these has anything behind it on the bench.
    bench.app.updateFan();
    bench.app.updateTraffic();
    bench.app.updateUndervoltage();
    bench.app.renderApt();
    bench.app.renderInternet();

    const status = bench.app.status();
    try testing.expectEqual(@as(?u8, 50), status.cpu_load);
    try testing.expectEqual(@as(?u32, 48), status.cpu_temp);
    try testing.expectEqual(@as(?u8, 25), status.memory);
    try testing.expectEqual(@as(?u64, 4 * 24 * 60 + 60 + 25), status.uptime_minutes);

    try testing.expectEqual(@as(?u8, null), status.disk_usage);
    try testing.expectEqual(@as(?u32, null), status.fan_speed);
    try testing.expectEqual(@as(?u32, null), status.disk_temp);
    try testing.expectEqual(@as(?u64, null), status.download_bytes_per_second);
    try testing.expectEqual(@as(?bool, null), status.undervoltage);
    try testing.expectEqual(@as(?bool, null), status.nvme_fault);
    try testing.expectEqual(@as(?u32, null), status.apt_updates);
    try testing.expectEqual(@as(?bool, null), status.internet);
    try testing.expectEqual(@as(?i32, null), status.signal_strength);
    try testing.expect(status.ip_address == null);
    try testing.expect(!status.wired);

    // Everything that was read was read just now.
    try testing.expectEqual(api.Stale{}, status.stale);
}

test "a reading that stops answering is reported with its last value and its age, and withheld from the broker" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    try bench.fixture.put("/sys/class/thermal/thermal_zone0/temp", "48000\n");
    try bench.loadCpuHalfBusy();
    const measured_at = bench.sys.cpu_temp.taken_at;

    try bench.fixture.remove("/sys/class/thermal/thermal_zone0/temp");
    bench.app.updateCpu();

    const status = bench.app.statusAt(measured_at + 90);
    try testing.expectEqual(@as(?u32, 48), status.cpu_temp);
    try testing.expectEqual(@as(?u64, 90), status.stale.cpu_temp);
    // Its neighbour, read in the same call, is as current as ever.
    try testing.expectEqual(@as(?u64, null), status.stale.cpu_load);

    const published = app_logic.mqttReadings(status, bench.traffic.rates.current());
    try testing.expectEqual(@as(usize, 1), published.len);
    try testing.expectEqualStrings("cpu_load", published.at(0).topic);
}

test "what one cycle publishes reaches the broker, and a stale reading does not" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    var broker = try LoopbackClient.init();
    defer broker.deinit();
    bench.app.mqtt = &broker.client;

    // Publishing asks whether the internet is reachable, and the probe would
    // reach outside the machine: answer for it, as one taken a moment ago.
    bench.net.cached_internet = true;
    bench.net.cached_internet_at = std.Io.Timestamp.now(testing.io, .awake).toSeconds();

    // A load of one half, and a temperature whose sensor has gone quiet since
    // it was last read.
    try bench.fixture.put("/sys/class/thermal/thermal_zone0/temp", "48000\n");
    try bench.loadCpuHalfBusy();
    try bench.fixture.remove("/sys/class/thermal/thermal_zone0/temp");
    try bench.fixture.put("/proc/stat", "cpu  250 0 150 1000 0 0 0 0 0 0\n");
    bench.app.updateCpu();

    bench.app.publishMqttStats();

    var saw_load = false;
    var saw_temperature = false;
    var saw_internet = false;
    var count: usize = 0;
    while (broker.nextPublished()) |message| : (count += 1) {
        // Under the client's prefix, each with what its entity expects.
        if (std.mem.eql(u8, message.topic, "sysink/cpu_load")) {
            try testing.expectEqualStrings("50", message.payload);
            saw_load = true;
        }
        if (std.mem.eql(u8, message.topic, "sysink/internet")) {
            try testing.expectEqualStrings("ON", message.payload);
            saw_internet = true;
        }
        if (std.mem.eql(u8, message.topic, "sysink/cpu_temp")) saw_temperature = true;
    }

    try testing.expect(saw_load);
    try testing.expect(saw_internet);
    // Nothing for the sensor that went quiet, and nothing else besides.
    try testing.expect(!saw_temperature);
    try testing.expectEqual(@as(usize, 2), count);
}

test "the signal slot shows the cable when the address is on one, and the signal when it is not" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();
    try bench.fixture.put("/proc/net/wireless",
        \\Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE
        \\ face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22
        \\ wlan0: 0000   55.  -62.  -256        0      0      0      0      0        0
        \\
    );

    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.renderGrid();

    // On a cable the slot says so. The signal is read all the same: the
    // broker is told it whenever there is one.
    bench.net.rememberAddress("192.168.1.20", "end0");
    bench.app.updateSignal();
    expected.renderWired();
    try testing.expectEqualSlices(u8, expected.bitmap.data, bench.renderer.bitmap.data);
    try testing.expectEqual(@as(?i32, -62), bench.app.status().signal_strength);

    bench.net.rememberAddress("192.168.1.21", "wlan0");
    bench.app.updateSignal();
    expected.renderSignalStrength(-62);
    try testing.expectEqualSlices(u8, expected.bitmap.data, bench.renderer.bitmap.data);

    // Wi-Fi with nothing to read is no signal, not the last one.
    try bench.fixture.remove("/proc/net/wireless");
    bench.app.updateSignal();
    expected.renderSignalStrength(null);
    try testing.expectEqualSlices(u8, expected.bitmap.data, bench.renderer.bitmap.data);
    try testing.expectEqual(@as(?i32, null), bench.app.status().signal_strength);
}

test "the disk's two slots are drawn from the filesystem and from the drive's sensor" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();
    try bench.fixture.put("/sys/class/hwmon/hwmon2/name", "nvme\n");
    try bench.fixture.put("/sys/class/hwmon/hwmon2/temp1_input", "36850\n");

    bench.app.updateDisk();

    // How full the root filesystem is belongs to the machine the test runs
    // on; that it was read, and drawn as read, does not.
    try testing.expect(bench.sys.disk_usage.current() != null);
    try testing.expectEqual(@as(?u32, 36), bench.sys.disk_temp.current());

    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.renderGrid();
    expected.renderDiskUsage(bench.sys.disk_usage);
    expected.renderDiskTemp(.of(36));
    try testing.expectEqualSlices(u8, expected.bitmap.data, bench.renderer.bitmap.data);
}

test "the loading screen leaves the panel owing a full refresh, and the sleep screen leaves it asleep" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    bench.app.showLoading();
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
    // Not the reference for what follows: the first frame has to be full too.
    try testing.expect(bench.panel.state_unknown);

    bench.renderer.renderGrid();
    try bench.app.showInitialFrameAt(0);
    try testing.expect(!bench.panel.state_unknown);

    bench.transport.resetLog();
    bench.app.showSleepScreen();
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
    try testing.expect(bench.panel.asleep);
}

test "the frame on show is written to a file only when a path for it is given" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();
    const root = bench.fixture.root();

    try bench.app.showInitialFrameAt(0);
    try testing.expect(!root.exists("/frame.bmp"));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    bench.app.options.bmp_export_path = try bench.fixture.realPath(&path_buf, "/frame.bmp");
    bench.app.updateDisplayAt(10);

    var head: [2]u8 = undefined;
    try testing.expectEqualStrings("BM", try root.read("/frame.bmp", &head));
}

test "a hardware fault inverts the status bar, and clears with the sensor" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    try bench.fixture.put("/sys/class/hwmon/hwmon1/name", "rpi_volt\n");
    try bench.fixture.put("/sys/class/hwmon/hwmon1/in0_lcrit_alarm", "1\n");
    bench.app.updateUndervoltage();
    try testing.expect(bench.renderer.warn_fault);
    try testing.expectEqual(@as(?bool, true), bench.app.status().undervoltage);

    try bench.fixture.put("/sys/class/hwmon/hwmon1/in0_lcrit_alarm", "0\n");
    bench.app.updateUndervoltage();
    try testing.expect(!bench.renderer.warn_fault);
    try testing.expectEqual(@as(?bool, false), bench.app.status().undervoltage);
}

test "the panel is refreshed partially as readings change, and in full once the interval is up" {
    var bench: Bench = undefined;
    try bench.init(.{ .interval_full_refresh = 600 });
    defer bench.deinit();

    try bench.app.showInitialFrameAt(0);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);

    bench.renderer.renderCpuLoad(.of(5));
    bench.transport.resetLog();
    bench.app.updateDisplayAt(10);
    try testing.expectEqual(Waveform.partial, bench.refreshed().?);

    // A cycle in which nothing changed costs the panel nothing.
    bench.transport.resetLog();
    bench.app.updateDisplayAt(20);
    try testing.expect(!bench.panelTouched());

    bench.renderer.renderCpuLoad(.of(6));
    bench.transport.resetLog();
    bench.app.updateDisplayAt(600);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
}

test "a notice goes up at once, and the dashboard comes back with a full refresh when its time is up" {
    var bench: Bench = undefined;
    try bench.init(.{ .notify_duration = 30 });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    // Not at the next display tick: now, as a partial update.
    bench.transport.resetLog();
    bench.app.applyNoticeAt("Backup finished", 1010);
    try testing.expect(bench.renderer.notice_shown);
    try testing.expectEqual(Waveform.partial, bench.refreshed().?);
    try testing.expectEqual(@as(?i64, 30), bench.app.pacer.secondsLeft(1010));

    bench.transport.resetLog();
    _ = bench.app.stepNoticesAt(1039);
    try testing.expect(bench.renderer.notice_shown);
    try testing.expect(!bench.panelTouched());

    try testing.expect(bench.app.stepNoticesAt(1040));
    try testing.expect(!bench.renderer.notice_shown);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);

    // Down already: its time passing again does nothing.
    bench.transport.resetLog();
    try testing.expect(!bench.app.stepNoticesAt(1041));
    try testing.expect(!bench.panelTouched());
}

test "a notice may say how long it stays, and can be taken down early" {
    var bench: Bench = undefined;
    try bench.init(.{ .notify_duration = 30 });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    bench.app.applyNoticeAt("{\"text\": \"Deploy running\", \"duration\": 120}", 1000);
    try testing.expectEqual(@as(?i64, 120), bench.app.pacer.secondsLeft(1000));

    bench.transport.resetLog();
    bench.app.applyNoticeAt("{\"text\": \"\"}", 1010);
    try testing.expect(!bench.renderer.notice_shown);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
    try testing.expect(bench.app.pacer.secondsLeft(1010) == null);

    // With nothing up, a dismissal and a notice with nothing to show both
    // leave the panel alone.
    bench.transport.resetLog();
    bench.app.applyNoticeAt("{\"text\": \"\"}", 1020);
    bench.app.applyNoticeAt(" \n\t ", 1020);
    try testing.expect(!bench.renderer.notice_shown);
    try testing.expect(!bench.panelTouched());
}

test "notices that come faster than the panel should change wait their turn, and only the latest goes up" {
    var bench: Bench = undefined;
    try bench.init(.{ .notify_duration = 30 });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    bench.app.applyNoticeAt("first", 1010);
    try testing.expect(bench.renderer.notice_shown);

    // A second on: too soon. Neither is drawn, and the first stays up.
    bench.transport.resetLog();
    bench.app.applyNoticeAt("second", 1011);
    bench.app.applyNoticeAt("third", 1011);
    try testing.expect(!bench.panelTouched());
    // The loop is told to come back when the wait is over, not in half a minute.
    try testing.expectEqual(@as(?i64, 1), bench.app.pacer.secondsLeft(1011));

    // Its turn: the latest, once, as a partial update. The second never shows.
    try testing.expect(bench.app.stepNoticesAt(1012));
    try testing.expectEqual(Waveform.partial, bench.refreshed().?);
    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.showNotice("third");
    try testing.expectEqualSlices(u8, expected.notice.data, bench.renderer.notice.data);
    try testing.expectEqual(@as(?i64, 30), bench.app.pacer.secondsLeft(1012));
}

test "the notice on show sent again is not drawn again, and stays up longer" {
    var bench: Bench = undefined;
    try bench.init(.{ .notify_duration = 30 });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    bench.app.applyNoticeAt("Backup running", 1010);
    try testing.expect(bench.renderer.notice_shown);

    bench.transport.resetLog();
    bench.app.applyNoticeAt("Backup running", 1025);
    try testing.expect(!bench.panelTouched());
    // From the repeat, not from when it first went up.
    try testing.expectEqual(@as(?i64, 30), bench.app.pacer.secondsLeft(1025));
}

fn playingSnapshot(uri: []const u8, position_ms: i64, at_ms: i64) now_playing.Snapshot {
    return .{
        .playback = .{
            .uri = .init(uri),
            .playing = true,
            .position_ms = position_ms,
            .at_ms = at_ms,
            .duration_ms = 200_000,
        },
        .track = .{ .uri = .init(uri), .title = .init("Jednou"), .artist = .init("Vladimir Misik") },
    };
}

test "music goes up with a full refresh, moves on its tick by partial ones, and comes down with a full one" {
    var bench: Bench = undefined;
    try bench.init(.{ .music = .{ .hold_paused = 30, .tick = 5 } });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    bench.transport.resetLog();
    bench.app.applySpotifyAt(&playingSnapshot("spotify:track:a", 0, 1_000_000), 1_000_000);
    try testing.expect(bench.renderer.music_shown);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
    try testing.expectEqual(@as(?i64, 5), @divTrunc(bench.app.music.?.msLeft(1_000_000).?, 1000));

    bench.transport.resetLog();
    try testing.expect(bench.app.stepMusicAt(1_005_000));
    try testing.expectEqual(Waveform.partial, bench.refreshed().?);

    var paused = playingSnapshot("spotify:track:a", 6_000, 1_006_000);
    paused.playback.?.playing = false;
    bench.app.applySpotifyAt(&paused, 1_006_000);

    bench.transport.resetLog();
    try testing.expect(bench.app.stepMusicAt(1_036_000));
    try testing.expect(!bench.renderer.music_shown);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
}

test "a cover goes up in grey, the bar moves on by partial updates, and the dashboard comes back in black and white" {
    var bench: Bench = undefined;
    try bench.init(.{ .music = .{ .hold_paused = 0, .tick = 5 } });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    var snapshot = playingSnapshot("spotify:track:a", 0, 1_000_000);
    snapshot.cover_valid = true;
    snapshot.cover_serial = 1;
    snapshot.cover = @splat(128);

    bench.transport.resetLog();
    bench.app.applySpotifyAt(&snapshot, 1_000_000);
    try testing.expectEqual(Waveform.gray, bench.refreshed().?);

    bench.transport.resetLog();
    try testing.expect(bench.app.stepMusicAt(1_005_000));
    try testing.expectEqual(Waveform.partial, bench.refreshed().?);

    // With no hold, a pause takes the screen down at once.
    snapshot.playback.?.playing = false;
    bench.transport.resetLog();
    bench.app.applySpotifyAt(&snapshot, 1_006_000);
    try testing.expect(!bench.renderer.music_shown);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
}

test "under a notice the music is drawn without touching the panel, and shows once the notice is down" {
    var bench: Bench = undefined;
    try bench.init(.{ .notify_duration = 30, .music = .{} });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    bench.app.applySpotifyAt(&playingSnapshot("spotify:track:a", 0, 1_000_000), 1_000_000);
    bench.app.applyNoticeAt("Backup finished", 1010);
    try testing.expect(bench.renderer.notice_shown);

    // A new track with a new cover under the notice: no refresh, full or not.
    var next = playingSnapshot("spotify:track:b", 0, 1_012_000);
    next.cover_serial = 1;
    bench.transport.resetLog();
    bench.app.applySpotifyAt(&next, 1_012_000);
    try testing.expect(!bench.panelTouched());

    // The notice's time is up: the music, in full, as it was drawn under it.
    try testing.expect(bench.app.stepNoticesAt(1040));
    try testing.expectEqual(Waveform.full, bench.refreshed().?);
    try testing.expect(bench.renderer.music_shown and !bench.renderer.notice_shown);
    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.showMusic(.{ .track = .{
        .title = "Jednou",
        .artist = "Vladimir Misik",
        .elapsed_s = 0,
        .duration_s = 200,
        .playing = true,
        .cover = null,
    } });
    try testing.expectEqualSlices(u8, expected.music.data, bench.renderer.music.data);
}

test "a hardware fault takes the music screen down, and it comes back once cleared" {
    var bench: Bench = undefined;
    try bench.init(.{ .music = .{} });
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    bench.app.applySpotifyAt(&playingSnapshot("spotify:track:a", 0, 1_000_000), 1_000_000);
    try testing.expect(bench.renderer.music_shown);

    bench.renderer.setFaultWarning(true);
    bench.transport.resetLog();
    try testing.expect(bench.app.stepMusicAt(1_002_000));
    try testing.expect(!bench.renderer.music_shown);
    try testing.expectEqual(Waveform.full, bench.refreshed().?);

    bench.renderer.setFaultWarning(false);
    try testing.expect(bench.app.stepMusicAt(1_003_000));
    try testing.expect(bench.renderer.music_shown);
}

test "with Spotify off, nothing it could send changes the panel" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();
    try bench.app.showInitialFrameAt(1000);

    bench.transport.resetLog();
    bench.app.applySpotifyAt(&playingSnapshot("spotify:track:a", 0, 1_000_000), 1_000_000);
    try testing.expect(!bench.app.stepMusicAt(1_005_000));
    try testing.expect(!bench.panelTouched());
    try testing.expect(bench.app.musicSecondsLeft() == null);
}

const Collector = struct {
    frames: u32 = 0,
    last_len: usize = 0,
    last_cpu_load: ?u8 = null,

    fn publish(ctx: *anyopaque, packed_frame: []const u8, status: api.Status) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.frames += 1;
        self.last_len = packed_frame.len;
        self.last_cpu_load = status.cpu_load;
    }
};

test "every display update hands the frame on, with the readings it was drawn from" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    var collector: Collector = .{};
    bench.app.frame_sink = .{ .ctx = &collector, .publish = Collector.publish };

    try bench.loadCpuHalfBusy();
    try bench.app.showInitialFrameAt(0);
    bench.app.updateDisplayAt(10);

    try testing.expectEqual(@as(u32, 1), collector.frames);
    try testing.expectEqual(@as(usize, @divCeil(layout.display_width, 8) * layout.display_height), collector.last_len);
    try testing.expectEqual(@as(?u8, 50), collector.last_cpu_load);

    // On request too, which is how a preview that has just started gets its
    // first frame without waiting for a tick.
    bench.app.publishFrame();
    try testing.expectEqual(@as(u32, 2), collector.frames);
}

fn taskIndex(scheduler: *const Scheduler, name: []const u8) ?usize {
    for (scheduler.tasks.items, 0..) |task, i| {
        if (std.mem.eql(u8, task.name, name)) return i;
    }
    return null;
}

test "the tasks are scheduled in the order they depend on" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    var scheduler = Scheduler.init(testing.allocator, testing.io);
    defer scheduler.deinit();
    try bench.app.scheduleReadings(&scheduler, 30, 10800);
    try bench.app.scheduleDisplay(&scheduler, 30);

    const tasks = scheduler.tasks.items;
    // The signal slot is drawn from what the address task found.
    try testing.expect(taskIndex(&scheduler, "ip").? < taskIndex(&scheduler, "signal").?);
    // The frame goes up after everything that draws into it.
    try testing.expectEqualStrings("display", tasks[tasks.len - 1].name);
    // Without a broker there is nothing to publish.
    try testing.expect(taskIndex(&scheduler, "mqtt") == null);

    // The two that reach outside the machine run on the slow interval.
    try testing.expectEqual(@as(u64, 10800), tasks[taskIndex(&scheduler, "apt").?].interval_seconds);
    try testing.expectEqual(@as(u64, 10800), tasks[taskIndex(&scheduler, "internet").?].interval_seconds);
    try testing.expectEqual(@as(u64, 30), tasks[taskIndex(&scheduler, "cpu").?].interval_seconds);
    try testing.expectEqual(@as(u64, 30), tasks[taskIndex(&scheduler, "display").?].interval_seconds);
}

test "with a broker, publishing comes after the readings and before the frame" {
    var bench: Bench = undefined;
    try bench.init(.{});
    defer bench.deinit();

    // Never connected, so no clock or socket is touched.
    var client = MqttClient.init(undefined, .{});
    defer client.deinit();
    bench.app.mqtt = &client;

    var scheduler = Scheduler.init(testing.allocator, testing.io);
    defer scheduler.deinit();
    try bench.app.scheduleReadings(&scheduler, 30, 10800);
    try bench.app.scheduleDisplay(&scheduler, 30);

    const mqtt_at = taskIndex(&scheduler, "mqtt").?;
    for ([_][]const u8{ "cpu", "memory", "disk", "fan", "traffic", "ip", "signal", "uptime", "undervoltage", "nvme_health" }) |reading| {
        try testing.expect(taskIndex(&scheduler, reading).? < mqtt_at);
    }
    try testing.expect(mqtt_at < taskIndex(&scheduler, "display").?);
}
