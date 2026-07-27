//! Native macOS window showing the rendered panel.
//!
//! The renderer is generic over its transport, so the whole drawing path runs on
//! a development machine against the recorder. This puts the resulting frame in
//! an NSWindow and refreshes it, with no server and no browser in between.
//!
//!     zig build sim
//!
//! Only the window is platform-specific; `sim_frame.zig` holds everything about
//! what is drawn, and `sim_web.zig` is the portable fallback for other hosts.
//!
//! Objective-C is called through `objc_msgSend` directly rather than through a
//! binding library, to keep the simulator dependency-free. Every call goes
//! through `send`, which casts the dispatcher to the exact signature of the
//! method being invoked — the variadic declaration must never be called as
//! variadic, because on AArch64 variadic and regular arguments use different
//! registers and the call would read its arguments from the wrong places.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const sim_frame = @import("sim_frame.zig");
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

comptime {
    if (builtin.target.os.tag != .macos) {
        @compileError("sim_native is macOS-only; other hosts use sim_web.zig");
    }
}

/// Magnification of the 296x128 panel in the window.
const scale = 3;
const refresh_ms = 200;

// ----------------------------------------------------------------------------
// Objective-C runtime
// ----------------------------------------------------------------------------

const Id = ?*anyopaque;
const Sel = *anyopaque;
const Class = ?*anyopaque;

extern fn objc_getClass(name: [*:0]const u8) Class;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;

/// Message-send signatures, spelled out.
///
/// `objc_msgSend` is declared without parameters and must be cast to the exact
/// signature of the method being sent. On AArch64 this is not a formality:
/// variadic and ordinary arguments are passed in different places, so a
/// variadic declaration called with ordinary arguments reads them from the
/// wrong registers. Zig 0.16 has no `@Type`, so the shapes are named here
/// instead of derived — which also means the compiler checks each call site.
const Msg = struct {
    const Ret = fn (Id, Sel) callconv(.c) Id;
    const Void = fn (Id, Sel) callconv(.c) void;
    const Bool = fn (Id, Sel) callconv(.c) u8;
    const VoidId = fn (Id, Sel, Id) callconv(.c) void;
    const VoidBool = fn (Id, Sel, u8) callconv(.c) void;
    const VoidUint = fn (Id, Sel, usize) callconv(.c) void;
    const BoolInt = fn (Id, Sel, isize) callconv(.c) u8;
    const RetCString = fn (Id, Sel, [*:0]const u8) callconv(.c) Id;
    const RetRect = fn (Id, Sel, Rect) callconv(.c) Id;
    const RetSize = fn (Id, Sel, Size) callconv(.c) Id;
    const InitWindow = fn (Id, Sel, Rect, usize, usize, u8) callconv(.c) Id;
    const NextEvent = fn (Id, Sel, usize, Id, Id, u8) callconv(.c) Id;
    const InitBitmap = fn (Id, Sel, [*][*]u8, isize, isize, isize, isize, u8, u8, Id, isize, isize) callconv(.c) Id;
};

fn send(comptime Fn: type, receiver: Id, comptime selector: [:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    const dispatch: *const Fn = @ptrCast(&objc_msgSend);
    return @call(.auto, dispatch, .{ receiver, sel_registerName(selector) } ++ args);
}

fn class(comptime name: [:0]const u8) Id {
    return objc_getClass(name) orelse @panic("Objective-C class not found: " ++ name);
}

fn nsString(text: [:0]const u8) Id {
    return send(Msg.RetCString, class("NSString"), "stringWithUTF8String:", .{text.ptr});
}

// Geometry, laid out as the C structs so it passes in the right registers.
const Point = extern struct { x: f64 = 0, y: f64 = 0 };
const Size = extern struct { width: f64, height: f64 };
const Rect = extern struct { origin: Point = .{}, size: Size };

// AppKit constants.
const style_titled = 1 << 0;
const style_closable = 1 << 1;
const style_miniaturizable = 1 << 2;
const backing_buffered = 2;
const activation_policy_regular = 0;
const image_scale_none = 3;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    // The renderer packs its 1-bit frame during the BMP export, inside the
    // window where the fault overlay is applied, so reading `bmp_buffer`
    // afterwards yields exactly what would reach the glass.
    config.Config.export_bmp = true;
    config.Config.bmp_export_path = "/tmp/sys-ink-sim.bmp";

    var transport = FakeTransport.init(allocator);
    defer transport.deinit();

    var renderer = try sim_frame.SimRenderer.init(allocator, io, &transport);
    defer renderer.deinit();
    try renderer.startup();
    renderer.renderGrid();

    const view_width = sim_frame.width * scale;
    const view_height = sim_frame.height * scale;

    const pixels = try allocator.alloc(u8, view_width * view_height);
    defer allocator.free(pixels);
    @memset(pixels, 255);

    // --- window ---------------------------------------------------------------

    const app = send(Msg.Ret, class("NSApplication"), "sharedApplication", .{});
    _ = send(Msg.BoolInt, app, "setActivationPolicy:", .{@as(isize, activation_policy_regular)});

    const frame: Rect = .{ .size = .{
        .width = @floatFromInt(view_width),
        .height = @floatFromInt(view_height),
    } };

    const window = send(Msg.InitWindow, send(Msg.Ret, class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
        frame,
        @as(usize, style_titled | style_closable | style_miniaturizable),
        @as(usize, backing_buffered),
        @as(u8, 0),
    });
    _ = send(Msg.VoidId, window, "setTitle:", .{nsString("SysInk — Waveshare 2.9\" V2")});
    _ = send(Msg.Void, window, "center", .{});

    const image_view = send(Msg.RetRect, send(Msg.Ret, class("NSImageView"), "alloc", .{}), "initWithFrame:", .{frame});
    // Show the frame at its true size; magnification already happened in `expand`.
    _ = send(Msg.VoidUint, image_view, "setImageScaling:", .{@as(usize, image_scale_none)});
    _ = send(Msg.VoidId, window, "setContentView:", .{image_view});
    _ = send(Msg.VoidId, window, "makeKeyAndOrderFront:", .{@as(Id, null)});
    _ = send(Msg.VoidBool, app, "activateIgnoringOtherApps:", .{@as(u8, 1)});

    // --- loop -----------------------------------------------------------------

    const started = std.Io.Timestamp.now(io, .awake).toSeconds();
    const distant_past = send(Msg.Ret, class("NSDate"), "distantPast", .{});
    const run_loop_mode = nsString("kCFRunLoopDefaultMode");

    while (send(Msg.Bool, window, "isVisible", .{}) != 0) {
        const now = std.Io.Timestamp.now(io, .awake);
        const seconds = now.toSeconds();
        sim_frame.draw(&renderer, @floatFromInt(seconds), @intCast(seconds - started));
        try renderer.updateDisplay(true);

        sim_frame.expand(renderer.bmp_buffer, pixels, scale);
        setImage(image_view, pixels.ptr, view_width, view_height);

        // Drain the queue so the window stays responsive without [NSApp run],
        // which would take over the thread and need a delegate to get it back.
        while (true) {
            const event = send(Msg.NextEvent, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
                @as(usize, std.math.maxInt(usize)),
                distant_past,
                run_loop_mode,
                @as(u8, 1),
            });
            if (event == null) break;
            _ = send(Msg.VoidId, app, "sendEvent:", .{event});
        }
        _ = send(Msg.Void, app, "updateWindows", .{});

        std.Io.sleep(io, .fromMilliseconds(refresh_ms), .awake) catch break;
    }

    return 0;
}

/// Wrap `pixels` in an NSImage and hand it to the view.
///
/// 8 bits per sample, one sample per pixel, no alpha: the greyscale buffer maps
/// straight onto a device-white bitmap with no conversion.
fn setImage(image_view: Id, pixels: [*]u8, w: usize, h: usize) void {
    var planes: [1][*]u8 = .{pixels};

    const rep = send(Msg.InitBitmap, send(Msg.Ret, class("NSBitmapImageRep"), "alloc", .{}), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
        @as([*][*]u8, &planes),
        @as(isize, @intCast(w)),
        @as(isize, @intCast(h)),
        @as(isize, 8),
        @as(isize, 1),
        @as(u8, 0),
        @as(u8, 0),
        nsString("NSDeviceWhiteColorSpace"),
        @as(isize, @intCast(w)),
        @as(isize, 8),
    });
    defer _ = send(Msg.Void, rep, "release", .{});

    const image = send(Msg.RetSize, send(Msg.Ret, class("NSImage"), "alloc", .{}), "initWithSize:", .{
        Size{ .width = @floatFromInt(w), .height = @floatFromInt(h) },
    });
    defer _ = send(Msg.Void, image, "release", .{});

    _ = send(Msg.VoidId, image, "addRepresentation:", .{rep});
    _ = send(Msg.VoidId, image_view, "setImage:", .{image});
}
