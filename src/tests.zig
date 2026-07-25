//! Test root.
//!
//! Pulls in every module that carries unit tests. The remaining hardware-facing
//! modules (system_ops, network_ops, display_renderer) are Linux-only and
//! deliberately left out — their testable logic lives in `parse.zig`, which is
//! free of I/O and runs anywhere. Those are type-checked by `zig build check`
//! instead.
//!
//! The panel driver is here despite talking to hardware: it is generic over its
//! transport, so its command sequences are asserted against a recorder.

test {
    _ = @import("parse.zig");
    _ = @import("scheduler.zig");
    _ = @import("config.zig");
    _ = @import("graphics.zig");
    _ = @import("bmp.zig");
    _ = @import("mqtt.zig");
    _ = @import("waveshare_epd/epd2in9.zig");
}
