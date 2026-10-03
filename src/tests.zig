//! Test root.
//!
//! Pulls in every module that carries unit tests. The remaining hardware-facing
//! modules (system_ops, network_ops) are Linux-only and deliberately left out — their testable logic lives in `parse.zig`, which is
//! free of I/O and runs anywhere. Those are type-checked by `zig build check`
//! instead.
//!
//! The notice pipe and the daemon's HTTP server are Linux-only as well, but
//! need no hardware: their tests run against a real pipe and a real loopback
//! socket, on Linux — which is where CI runs — and are left out elsewhere.
//!
//! The panel driver and the renderer are here despite talking to hardware: both
//! are generic over the transport, so command sequences and the rendered frame
//! are asserted against a recorder.

const builtin = @import("builtin");

test {
    _ = @import("parse.zig");
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
    _ = @import("display_renderer.zig");
    _ = @import("sim_frame.zig");
    _ = @import("frame_server.zig");
    _ = @import("http_request.zig");
    _ = @import("api.zig");

    if (builtin.os.tag == .linux) {
        _ = @import("notice_fifo.zig");
        _ = @import("web_preview.zig");
    }
}
