//! The panel as the rest of the daemon sees it: something that shows frames.
//!
//! The driver underneath knows how to send a frame; this knows when it may. An
//! e-paper panel carries state the driver cannot see — which frame is on the
//! glass, whether the controller is in deep sleep, whether the reference RAM
//! that partial updates diff against still matches — and getting any of it
//! wrong smears the picture rather than failing. All of that lives here, apart
//! from what is drawn: a frame arrives already packed, and nothing in this file
//! knows what is on it.

const std = @import("std");
const epd2in9 = @import("waveshare_epd/epd2in9.zig");

const log = std.log.scoped(.panel);

/// One full panel frame, in the controller's own format.
pub const Frame = epd2in9.Frame;

/// How a frame is put on the glass.
pub const Refresh = enum {
    /// Only what differs from the frame already there, with a waveform weak
    /// enough not to flash. Leaves ghosting behind as these accumulate.
    partial,
    /// Every pixel, which flashes and clears the ghosting.
    full,
};

pub const Options = struct {
    /// Park the controller in deep sleep between visible updates.
    sleep_between_updates: bool = true,
};

/// Generic over the transport, as the driver is, so the whole state machine can
/// be driven against a recorder.
pub fn Panel(comptime Transport: type) type {
    return struct {
        const Self = @This();
        const Epd = epd2in9.Epd(Transport);

        epd: Epd,
        sleep_between_updates: bool,
        /// The frame on the glass, once `has_last_frame` says there is one.
        last_frame: Frame = undefined,
        has_last_frame: bool = false,
        /// True while the panel controller sits in deep sleep.
        asleep: bool = false,
        /// Set when the glass may no longer match the reference frame, as after
        /// an update that failed partway through. The next update must be a
        /// full refresh, because a partial one would diff against a reference
        /// that is not what is showing.
        state_unknown: bool = false,

        /// `transport` is borrowed, not owned: the caller outlives the panel and
        /// is responsible for tearing it down.
        pub fn init(transport: *Transport, options: Options) Self {
            return .{
                .epd = Epd.init(transport),
                .sleep_between_updates = options.sleep_between_updates,
            };
        }

        /// Bring the transport and the controller up, and blank the glass.
        pub fn startup(self: *Self) !void {
            try self.epd.initDisplay();
            try self.epd.clear(0xFF);
        }

        /// Show `frame` with a full refresh, without making it the reference.
        ///
        /// For a screen that is only passing through, like the loading one. The
        /// reference bank keeps what it had, so the glass stops matching it and
        /// whatever follows is a full refresh as well. The controller is left
        /// awake for that.
        pub fn splash(self: *Self, frame: *const Frame) !void {
            try self.wake();
            self.state_unknown = true;
            try self.epd.display(frame);
        }

        /// Put `frame` on the glass.
        ///
        /// A partial refresh of a frame that is already there does nothing at
        /// all, and one that cannot be trusted to come out clean is promoted to
        /// a full refresh.
        pub fn show(self: *Self, frame: *const Frame, refresh: Refresh) !void {
            const partial_requested = refresh == .partial;
            log.debug("show: START (partial requested={})", .{partial_requested});

            // Skip unchanged frames only on partial updates. A full refresh must always go
            // through to clear ghosting/artifacts accumulated by partial updates, and so
            // must any update while the glass contents are in doubt.
            // A skipped frame also leaves a sleeping panel undisturbed.
            const unchanged = self.has_last_frame and std.mem.eql(u8, frame, &self.last_frame);
            if (partial_requested and unchanged and !self.state_unknown) {
                log.debug("show: skipped unchanged partial frame", .{});
                return;
            }

            try self.wake();

            // Decided only after waking: restoring the reference frame can itself
            // fail, and that rules a partial update out.
            const partial = partial_requested and !self.state_unknown;

            {
                // Any failure below leaves the glass in an unknown state.
                errdefer self.state_unknown = true;

                if (partial) {
                    try self.epd.displayPartial(frame);
                } else {
                    // displayBase, not display: it refreshes fully *and* rewrites the
                    // reference RAM, keeping later partial updates diffing against
                    // what is actually on the glass.
                    try self.epd.displayBase(frame);
                }
            }

            self.remember(frame);
            self.state_unknown = false;
            self.park();

            log.debug("show: EPD done (partial={})", .{partial});
        }

        /// Leave `frame` on the glass and the controller in deep sleep, ready
        /// for power to be cut.
        pub fn shutdown(self: *Self, frame: *const Frame) !void {
            // Re-initialize display to ensure Full LUT is loaded (needed after partial
            // updates) and to wake the controller if it was parked between refreshes.
            self.epd.reInit() catch |err| {
                log.err("Failed to re-init display for sleep: {t}", .{err});
            };
            self.asleep = false;

            // displayBase also resets the base RAM used by partial updates.
            try self.epd.displayBase(frame);
            self.remember(frame);

            // Unconditional, unlike park: Waveshare requires deep sleep before
            // power is cut, whatever `sleep_between_updates` is set to.
            self.epd.sleep() catch |err| {
                log.err("Failed to put panel into deep sleep: {t}", .{err});
            };
            self.asleep = true;

            log.info("Display parked in deep sleep", .{});
        }

        /// Bring the controller out of deep sleep, if it is in it.
        ///
        /// Deep sleep drops the reference frame that partial updates diff against,
        /// so it has to be restored from the frame we know is on the glass — before
        /// the partial sequence powers the analog stage up, or the write is ignored.
        fn wake(self: *Self) !void {
            if (!self.asleep) return;

            log.debug("waking from deep sleep", .{});
            try self.epd.reInit();
            if (self.has_last_frame) {
                self.epd.primeBase(&self.last_frame) catch |err| {
                    // Without a reference a partial update would smear, so fall back
                    // to a full refresh instead.
                    log.warn("Failed to restore panel reference frame: {t}", .{err});
                    self.state_unknown = true;
                };
            } else {
                self.state_unknown = true;
            }

            self.asleep = false;
        }

        /// Park the controller in deep sleep until the next visible update.
        fn park(self: *Self) void {
            if (!self.sleep_between_updates or self.asleep) return;

            self.epd.sleep() catch |err| {
                log.warn("Failed to park panel in deep sleep: {t}", .{err});
                return;
            };
            self.asleep = true;
            log.debug("parked in deep sleep", .{});
        }

        fn remember(self: *Self, frame: *const Frame) void {
            self.last_frame = frame.*;
            self.has_last_frame = true;
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

const TestPanel = Panel(FakeTransport);

// What is on a frame is of no interest here, only whether two of them differ.
const first: Frame = @splat(0xFF);
const second: Frame = @splat(0xA5);

test "an unchanged frame leaves a sleeping panel alone" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{});

    try panel.show(&first, .full);
    try testing.expect(panel.asleep);

    transport.resetLog();
    try panel.show(&first, .partial);

    // The whole point of parking the panel: an idle cycle costs nothing.
    try testing.expectEqual(@as(usize, 0), transport.events.items.len);
    try testing.expect(panel.asleep);
}

test "an unchanged frame costs nothing on a panel kept awake either" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{ .sleep_between_updates = false });

    try panel.show(&first, .full);

    transport.resetLog();
    try panel.show(&second, .partial);
    try testing.expect(transport.events.items.len > 0);

    transport.resetLog();
    try panel.show(&second, .partial);
    try testing.expectEqual(@as(usize, 0), transport.events.items.len);
}

test "a changed frame wakes the panel, restores the reference and parks it again" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{});

    try panel.show(&first, .full);

    transport.resetLog();
    try panel.show(&second, .partial);

    // Reference frame restored before the partial update, or it would smear:
    // the frame that was on the glass, not the one coming.
    try testing.expectEqualSlices(u8, &first, transport.argsAfter(0x26).?);
    try testing.expectEqualSlices(u8, &second, transport.argsAfter(0x24).?);
    // Partial waveform, not the full one. The last 0x22 is the one that selects
    // it; the first powers the analog stage up.
    try testing.expectEqualSlices(u8, &.{0x0F}, transport.lastArgsAfter(0x22).?);
    // Deep sleep mode 1 on the way out.
    try testing.expectEqualSlices(u8, &.{0x01}, transport.argsAfter(0x10).?);
    try testing.expect(panel.asleep);
}

test "sleep_between_updates = false keeps the controller powered" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{ .sleep_between_updates = false });

    try panel.show(&first, .full);

    try testing.expect(!panel.asleep);
    try testing.expect(!transport.sentCommand(0x10)); // never told to sleep
}

test "a full refresh rewrites the reference bank" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{});

    try panel.show(&first, .full);

    transport.resetLog();
    try panel.show(&second, .full);

    // displayBase, not display: leaving the reference stale would make the
    // following partial updates diff against something that is not on the glass.
    try testing.expectEqualSlices(u8, &second, transport.lastArgsAfter(0x26).?);
    try testing.expectEqualSlices(u8, &.{0xC7}, transport.lastArgsAfter(0x22).?);
}

test "a full refresh goes through even when the frame is unchanged" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{});

    try panel.show(&first, .full);

    // This is what clears the ghosting partial updates leave behind; skipping
    // it because nothing changed would defeat the periodic full refresh.
    transport.resetLog();
    try panel.show(&first, .full);
    try testing.expectEqualSlices(u8, &.{0xC7}, transport.lastArgsAfter(0x22).?);
}

test "a failed update forces the next one to be a full refresh" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    // Awake throughout, so the failure lands in the update itself rather than in
    // the wake that precedes it.
    var panel = TestPanel.init(&transport, .{ .sleep_between_updates = false });

    try panel.show(&first, .full);

    // Panel stops releasing BUSY, so the update dies partway through and the
    // glass no longer matches the reference frame.
    transport.busy_reads_remaining = std.math.maxInt(u32);
    try testing.expectError(error.EpdBusyTimeout, panel.show(&second, .partial));
    try testing.expect(panel.state_unknown);

    // A partial update would now smear, so it must be promoted to a full one.
    transport.busy_reads_remaining = 0;
    transport.resetLog();
    try panel.show(&second, .partial);

    try testing.expectEqualSlices(u8, &.{0xC7}, transport.lastArgsAfter(0x22).?);
    try testing.expect(!panel.state_unknown);
}

test "a failed wake leaves the panel marked asleep and the glass trusted" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{});

    try panel.show(&first, .full);
    try testing.expect(panel.asleep);

    // reInit fails, so the wake never completes.
    transport.busy_reads_remaining = std.math.maxInt(u32);
    try testing.expectError(error.EpdBusyTimeout, panel.show(&second, .partial));

    // reInit drives nothing, so the glass still matches the reference and the
    // next update may still be partial. The panel stays marked asleep, which is
    // what makes the next attempt retry the wake.
    try testing.expect(!panel.state_unknown);
    try testing.expect(panel.asleep);

    // And it does recover on its own once the panel responds again.
    transport.busy_reads_remaining = 0;
    transport.resetLog();
    try panel.show(&second, .partial);
    try testing.expectEqualSlices(u8, &first, transport.argsAfter(0x26).?); // reference restored
    try testing.expectEqualSlices(u8, &.{0x0F}, transport.lastArgsAfter(0x22).?);
    try testing.expect(panel.asleep);
}

test "a splash leaves the reference bank alone, so the next update is a full refresh" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{});

    try panel.splash(&first);
    try testing.expect(transport.sentCommand(0x24));
    try testing.expect(!transport.sentCommand(0x26));
    try testing.expectEqualSlices(u8, &.{0xC7}, transport.argsAfter(0x22).?);
    // Awake, for the frame that follows.
    try testing.expect(!panel.asleep);

    // The reference is not what the glass shows, so a partial update of it
    // would smear.
    transport.resetLog();
    try panel.show(&second, .partial);
    try testing.expectEqualSlices(u8, &second, transport.argsAfter(0x26).?);
    try testing.expectEqualSlices(u8, &.{0xC7}, transport.lastArgsAfter(0x22).?);
}

test "shutdown sleeps the controller whatever the options say" {
    var transport = FakeTransport.init(testing.allocator);
    defer transport.deinit();
    var panel = TestPanel.init(&transport, .{ .sleep_between_updates = false });

    try panel.show(&first, .full);
    try panel.show(&second, .partial);

    transport.resetLog();
    try panel.shutdown(&first);

    // The full LUT is back before the last frame goes up: the partial one that
    // the update above loaded cannot drive a full refresh.
    try testing.expect(transport.sentCommand(0x12)); // SW_RESET, so reInit ran
    try testing.expectEqualSlices(u8, &first, transport.argsAfter(0x24).?);
    try testing.expectEqualSlices(u8, &first, transport.argsAfter(0x26).?);
    try testing.expectEqualSlices(u8, &.{0xC7}, transport.lastArgsAfter(0x22).?);
    try testing.expectEqualSlices(u8, &.{0x01}, transport.argsAfter(0x10).?);
    try testing.expect(panel.asleep);
}
