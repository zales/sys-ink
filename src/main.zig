const std = @import("std");
const config = @import("config.zig");
const Config = config.Config;
const logger = @import("logger.zig");
const syscall = @import("syscall.zig");
const app = @import("app.zig");
const WebPreview = @import("web_preview.zig").WebPreview;
const api = @import("api.zig");
const network_ops = @import("network_ops.zig");
const Root = @import("sysroot.zig").Root;
const SystemOps = @import("system_ops.zig").SystemOps;
const NetworkOps = network_ops.NetworkOps;
const TrafficMonitor = network_ops.TrafficMonitor;
const Scheduler = @import("scheduler.zig").Scheduler;
const Renderer = @import("display_renderer.zig").Renderer;
const EpdConfig = @import("waveshare_epd/epdconfig.zig").EpdConfig;
const App = app.App(EpdConfig);
const Panel = App.Panel;
const MqttClient = @import("mqtt.zig").MqttClient;
const MqttConfig = @import("mqtt.zig").MqttConfig;
const NoticeFifo = @import("notice_fifo.zig").Fifo;
const SpotifyClient = @import("spotify_client.zig").Client;
const KodiClient = @import("kodi_client.zig").Client;
const now_playing = @import("now_playing.zig");

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

    const root = Root.system(io) catch |err| {
        log.err("Cannot open the root directory: {t}", .{err});
        return 1;
    };
    defer root.close();

    var sys_ops = SystemOps.init(allocator, io, root, init.environ_map);
    defer sys_ops.deinit();
    var net_ops = NetworkOps.init(io, root, .{ .ip = cfg.internet_check_ip, .port = cfg.internet_check_port });
    var traffic_mon = TrafficMonitor.init(io, root);

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

    var daemon = App.init(io, .{
        .interval_full_refresh = cfg.interval_full_refresh,
        .notify_duration = cfg.notify_duration,
        .bmp_export_path = if (cfg.export_bmp) cfg.bmp_export_path else null,
        .may_update_package_lists = isRoot(),
        .music = if (cfg.spotify_enabled or cfg.kodi_enabled) .{
            .hold_paused = cfg.spotify_pause_hold,
            .tick = cfg.spotify_interval,
        } else null,
    }, .{
        .sys = &sys_ops,
        .net = &net_ops,
        .traffic = &traffic_mon,
        .renderer = &renderer,
        .panel = &panel,
    });

    daemon.showLoading();
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
            daemon.mqtt = client;
        }
    }

    var scheduler = Scheduler.init(allocator, io);
    defer scheduler.deinit();

    const fast = cfg.interval_fast;
    try daemon.scheduleReadings(&scheduler, fast, cfg.interval_slow);

    // Populate every field before the first frame reaches the panel.
    scheduler.runAll();

    // Seeds the RAM that later partial updates diff against.
    try daemon.showInitialFrame();

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
        daemon.frame_sink = .{ .ctx = p, .publish = publishToPreview };
        daemon.publishFrame();
    }

    var notice_fifo: ?NoticeFifo = null;
    if (cfg.notify_enabled) {
        notice_fifo = NoticeFifo.open(io, cfg.notify_fifo, cfg.notify_group) catch |err| blk: {
            log.err("Notices disabled: {t}", .{err});
            break :blk null;
        };
    }
    defer if (notice_fifo) |*f| f.close();
    if (notice_fifo != null) log.info("Accepting notices on {s}", .{cfg.notify_fifo});

    // Started here, at its final address, as the preview is: its task holds a
    // pointer to it.
    var spotify_client: ?SpotifyClient = null;
    if (cfg.spotify_enabled) {
        spotify_client = SpotifyClient.init(io, allocator, .{ .state_path = cfg.spotify_state_file }) catch |err| blk: {
            log.err("Spotify disabled: {t}", .{err});
            break :blk null;
        };
    }
    defer if (spotify_client) |*client| client.deinit();
    if (spotify_client) |*client| {
        client.start();
        log.info("Showing what Spotify plays", .{});
    }
    var kodi_client: ?KodiClient = null;
    if (cfg.kodi_enabled) {
        kodi_client = KodiClient.init(io, allocator, .{ .host = cfg.kodi_host, .port = cfg.kodi_port }) catch |err| blk: {
            log.err("Kodi disabled: {t}", .{err});
            break :blk null;
        };
    }
    defer if (kodi_client) |*client| client.deinit();
    if (kodi_client) |*client| {
        client.start();
        log.info("Showing what Kodi at {s}:{d} plays", .{ cfg.kodi_host, cfg.kodi_port });
    }
    // Where what a client hands over is put: too large for the loop's stack
    // frame to want a copy of its own.
    var music_snapshot: now_playing.Snapshot = .{};

    // Only now that the first frame is up; see `scheduleDisplay`.
    try daemon.scheduleDisplay(&scheduler, fast);

    log.info("Starting main loop (Ctrl+C to exit)", .{});
    runLoop(io, &scheduler, &daemon, .{
        .pipe = if (notice_fifo) |*f| f else null,
        .preview = if (preview) |*p| p else null,
    }, .{
        .spotify = if (spotify_client) |*client| client else null,
        .kodi = if (kodi_client) |*client| client else null,
        .snapshot = &music_snapshot,
    });

    log.info("Shutting down gracefully", .{});
    daemon.showSleepScreen();

    return 0;
}

/// Hand a frame to the preview, and the readings it was drawn from to the API.
fn publishToPreview(ctx: *anyopaque, packed_frame: []const u8, status: api.Status) void {
    const preview: *WebPreview = @ptrCast(@alignCast(ctx));
    preview.publish(packed_frame);
    preview.publishStatus(status);
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

/// Where notices arrive from, besides the broker, which the app holds itself.
const NoticeSources = struct {
    pipe: ?*NoticeFifo,
    preview: ?*WebPreview,
};

/// The clients of what plays, and where what they hand over is put.
const MusicSources = struct {
    spotify: ?*SpotifyClient,
    kodi: ?*KodiClient,
    snapshot: *now_playing.Snapshot,
};

/// After a wait that failed, how long to stand still before trying again.
const failed_wait_pause_ms = 1000;

/// Run scheduled tasks until a signal arrives.
///
/// Between ticks the loop blocks on the wake pipe for exactly as long as the
/// next task is away, so an idle daemon wakes once per interval rather than
/// once per second, while a signal still stops it immediately. It watches the
/// notice pipe, the MQTT connection and the API's mailbox as well, so a notice
/// goes up the moment it arrives, and wakes for the one on show to come down on
/// time, or for one that had to wait its turn to go up. The mailboxes of the
/// clients of Spotify and Kodi likewise, and the music screen's next redraw.
fn runLoop(io: std.Io, scheduler: *Scheduler, daemon: *App, sources: NoticeSources, music: MusicSources) void {
    const max_sleep_seconds = 3600;
    const have_pipe = wake_pipe[0] >= 0;
    // So that a wait which keeps failing is reported when it starts and when
    // it stops, not once a second in between.
    var wait_failing = false;

    while (!should_exit.load(.acquire)) {
        scheduler.runPending();
        daemon.stepNotices();
        daemon.stepMusic();
        if (should_exit.load(.acquire)) break;

        const idle = scheduler.idleSeconds() orelse max_sleep_seconds;
        var seconds = @min(idle, max_sleep_seconds);
        if (daemon.noticeSecondsLeft()) |left| seconds = @min(seconds, left);
        if (daemon.musicSecondsLeft()) |left| seconds = @min(seconds, left);

        // Without the pipe there is nothing to interrupt the wait, so fall back
        // to short naps to keep shutdown responsive.
        if (!have_pipe) seconds = @min(seconds, 1);

        // With nothing to watch, poll on zero descriptors degrades to a plain sleep.
        var fds: [6]std.posix.pollfd = undefined;
        var watched: usize = 0;
        if (have_pipe) {
            fds[watched] = .{ .fd = wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }
        const pipe_slot = watched;
        if (sources.pipe) |fifo| {
            fds[watched] = .{ .fd = fifo.fd, .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }
        // Looked up afresh every time round: the socket changes on reconnect.
        const mqtt_slot = watched;
        const mqtt_socket = if (daemon.mqtt) |client| client.socketHandle() else null;
        if (mqtt_socket) |socket| {
            fds[watched] = .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }

        const api_slot = watched;
        const api_fd = if (sources.preview) |preview| preview.noticeFd() else null;
        if (api_fd) |fd| {
            fds[watched] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }

        const spotify_slot = watched;
        if (music.spotify) |client| {
            fds[watched] = .{ .fd = client.readyFd(), .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }
        const kodi_slot = watched;
        if (music.kodi) |client| {
            fds[watched] = .{ .fd = client.readyFd(), .events = std.posix.POLL.IN, .revents = 0 };
            watched += 1;
        }

        _ = std.posix.poll(fds[0..watched], @intCast(seconds * 1000)) catch |err| {
            // An interrupted wait is retried inside `poll`; what gets here is
            // the kernel out of memory, or worse. Nothing was waited for, so
            // going straight round again would spin a core for as long as it
            // lasts: stand still for a moment instead. A signal is still seen
            // within that moment, at the top of the loop.
            if (!wait_failing) log.warn("Cannot wait for events: {t}; checking once a second instead", .{err});
            wait_failing = true;
            std.Io.sleep(io, .fromMilliseconds(failed_wait_pause_ms), .awake) catch {};
            continue;
        };
        if (wait_failing) {
            log.info("Waiting for events works again", .{});
            wait_failing = false;
        }

        const ready = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if (sources.pipe) |fifo| {
            if (fds[pipe_slot].revents & std.posix.POLL.IN != 0) {
                if (fifo.receive()) |raw| daemon.applyNotice(raw);
            }
        }
        // A hangup or error is read too, which is how a dropped broker is seen.
        if (mqtt_socket != null and fds[mqtt_slot].revents & ready != 0) {
            daemon.receiveMqttNotice();
        }
        if (api_fd != null and fds[api_slot].revents & std.posix.POLL.IN != 0) {
            var buf: [api.max_notice_body]u8 = undefined;
            if (sources.preview.?.takeNotice(&buf)) |raw| daemon.applyNotice(raw);
        }
        if (music.spotify) |client| {
            if (fds[spotify_slot].revents & std.posix.POLL.IN != 0 and client.take(music.snapshot)) {
                daemon.applyMusic(.spotify, music.snapshot);
            }
        }
        if (music.kodi) |client| {
            if (fds[kodi_slot].revents & std.posix.POLL.IN != 0 and client.take(music.snapshot)) {
                daemon.applyMusic(.kodi, music.snapshot);
            }
        }
    }
}
