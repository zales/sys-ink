//! Test root.
//!
//! Pulls in every module that carries unit tests. The root is this file rather
//! than `main.zig` so that the suite runs on any host: `main` is Linux-only,
//! and is type-checked by `zig build check` instead. What is left in it is the
//! wiring: the daemon's tasks are `app.zig` and what they decide is
//! `app_logic.zig`, both tested here.
//!
//! The modules that read the machine are here too, despite reading procfs and
//! sysfs: `system_ops` and `network_ops` take the directory those are read
//! under, so their tests give them a tree of fixtures (`sysroot.zig`). The
//! parsing itself lives in `parse.zig`, free of I/O.
//!
//! The notice pipe and the daemon's HTTP server are Linux-only, but need no
//! hardware: their tests run against a real pipe and a real loopback socket,
//! on Linux — which is where CI runs — and are left out elsewhere.
//!
//! The panel driver and the state machine above it are here despite talking to
//! hardware: both are generic over the transport, so their command sequences
//! are asserted against a recorder. The renderer needs neither. Of the real
//! transport, `epdconfig` and `gpio_native`, only what can be known without a
//! panel is tested: the ioctl request numbers, and that nothing is driven
//! before it is brought up.

const builtin = @import("builtin");

test {
    _ = @import("parse.zig");
    _ = @import("reading.zig");
    _ = @import("notice.zig");
    _ = @import("syscall.zig");
    _ = @import("bounded_connect.zig");
    _ = @import("scheduler.zig");
    _ = @import("config.zig");
    _ = @import("logger.zig");
    _ = @import("graphics.zig");
    _ = @import("bmp.zig");
    _ = @import("mqtt.zig");
    _ = @import("waveshare_epd/epd2in9.zig");
    _ = @import("waveshare_epd/epdconfig.zig");
    _ = @import("gpio_native.zig");
    _ = @import("ioctl.zig");
    _ = @import("panel.zig");
    _ = @import("display_config.zig");
    _ = @import("display_renderer.zig");
    _ = @import("sim_frame.zig");
    _ = @import("frame_server.zig");
    _ = @import("http_request.zig");
    _ = @import("api.zig");
    _ = @import("app_logic.zig");
    _ = @import("app.zig");
    _ = @import("sysroot.zig");
    _ = @import("system_ops.zig");
    _ = @import("network_ops.zig");

    if (builtin.target.os.tag == .linux) {
        _ = @import("notice_fifo.zig");
        _ = @import("web_preview.zig");
    }
}
