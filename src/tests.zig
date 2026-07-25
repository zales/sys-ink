//! Test root.
//!
//! Pulls in every module that carries unit tests. Hardware-facing modules
//! (system_ops, network_ops, display_renderer, waveshare_epd) are Linux-only and
//! deliberately left out — their testable logic lives in `parse.zig`, which is
//! free of I/O and runs anywhere. Those modules are type-checked by the
//! cross-compile build instead.

test {
    _ = @import("parse.zig");
    _ = @import("scheduler.zig");
    _ = @import("config.zig");
    _ = @import("graphics.zig");
    _ = @import("bmp.zig");
    _ = @import("mqtt.zig");
}
