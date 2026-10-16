//! Notices: short messages from other programs, shown on the panel for a while
//! in place of the dashboard.
//!
//! This module is the I/O-free half: reading what arrived, turning it into
//! text the panel can draw, and deciding when it goes up and comes down — see
//! `Pacer`. Receiving it is `notice_fifo.zig` for the local pipe, `mqtt.zig`
//! for the broker and `web_preview.zig` for the HTTP API.
//!
//! All three carry the same thing: plain text, or a JSON object for when a
//! notice needs more than that — see `parse`.

const std = @import("std");
const font_data = @import("font_data.zig");
const CodepointIterator = @import("graphics.zig").CodepointIterator;

/// Longest notice kept, in bytes after folding. Six lines of the smallest font
/// hold some 280 characters, and a letter with a diacritic takes two bytes;
/// anything longer would be cut off on the glass anyway.
pub const max_len = 2 * 280;

/// Longest a notice may ask to stay up, in seconds: a day. Anything meant to
/// stay longer is not a notice.
pub const max_duration = 24 * 60 * 60;

pub const Notice = struct {
    /// Empty means take down the notice on show, if there is one. Only a JSON
    /// notice can ask for that: `{"text": ""}`.
    text: []const u8,
    /// Seconds to stay up; null for the configured default.
    duration: ?u32 = null,
};

/// Read a notice as it was sent: plain text, or a JSON object
///
///     {"text": "Backup finished", "duration": 120}
///
/// where `message` is accepted for `text`, and `duration` is optional. Text
/// that only looks like JSON is shown as it is. `scratch` holds the unescaped
/// strings of a JSON notice, and the result may borrow from it.
///
/// Null when there is nothing to do: plain text with nothing visible in it,
/// such as control characters, which would otherwise blank the panel, or take
/// down a notice nobody meant to.
pub fn parse(scratch: []u8, raw: []const u8) ?Notice {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    if (trimmed.len > 0 and trimmed[0] == '{') {
        if (parseJson(scratch, trimmed)) |notice| return notice;
    }
    const text = visible(trimmed);
    if (text.len == 0) return null;
    return .{ .text = text };
}

/// A JSON notice, or null when `text` is not one and should be shown as sent.
fn parseJson(scratch: []u8, text: []const u8) ?Notice {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), text, .{}) catch return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const body: []const u8 = if (obj.get("text") orelse obj.get("message")) |field| switch (field) {
        .string => |str| str,
        else => return null,
    } else "";

    return .{
        .text = visible(body),
        .duration = if (obj.get("duration")) |d| durationOf(d) else null,
    };
}

/// Seconds from a JSON `duration`, however a template happened to write it:
/// an integer, a fraction, or a number in a string. Zero, negative and
/// unreadable values mean the default, which is what a sender writing 0 wants.
fn durationOf(value: std.json.Value) ?u32 {
    const seconds: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |str| std.fmt.parseFloat(f64, std.mem.trim(u8, str, " ")) catch return null,
        else => return null,
    };
    // Also false for NaN.
    if (!(seconds >= 1)) return null;
    return @intFromFloat(@round(@min(seconds, max_duration)));
}

/// `text` trimmed, or empty when nothing in it would be drawn.
fn visible(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var it = CodepointIterator{ .text = trimmed };
    while (it.next()) |cp| {
        if (!isSpace(cp)) return trimmed;
    }
    return "";
}

/// `text` as the panel draws it.
///
/// The fonts have ASCII, the degree sign, and the Latin letters with
/// diacritics, so `Příliš žluťoučký kůň` stays as it is. Whitespace of any kind
/// collapses to single spaces, typographic punctuation becomes its ASCII
/// lookalike, and whatever else is left becomes '?', which says more than the
/// blank gap a missing glyph is drawn as.
///
/// Stops at `out.len`, never mid-character.
pub fn foldToFont(out: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    // Starts true so leading whitespace is dropped.
    var after_space = true;

    var it = CodepointIterator{ .text = text };
    while (it.next()) |cp| {
        var utf8: [4]u8 = undefined;
        const folded: []const u8 = if (isSpace(cp)) " " else fold(cp, &utf8);

        if (std.mem.eql(u8, folded, " ")) {
            if (after_space) continue;
            after_space = true;
        } else {
            after_space = false;
        }

        if (len + folded.len > out.len) break;
        @memcpy(out[len..][0..folded.len], folded);
        len += folded.len;
    }

    return std.mem.trimEnd(u8, out[0..len], " ");
}

fn isFormatting(cp: u32) bool {
    return switch (cp) {
        0x80...0x9F, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFEFF, 0xFFF0...0xFFFF => true,
        else => false,
    };
}

fn isSpace(cp: u32) bool {
    return switch (cp) {
        // Every C0 control, tab and CR included, and DEL.
        0...0x20, 0x7F => true,
        // NBSP, the fixed-width spaces, narrow NBSP.
        0xA0, 0x2000...0x200A, 0x202F => true,
        else => false,
    };
}

/// One non-space codepoint as the panel can draw it. `buf` backs a character
/// kept as it was.
fn fold(cp: u32, buf: *[4]u8) []const u8 {
    // Never kept, whatever the fonts are given: the C1 controls, CSI among
    // them, and the marks that break or reorder a line would let a notice
    // forge lines in the log, or turn one round.
    if (isFormatting(cp)) return "?";
    // Every size has the same characters; the tests in graphics.zig hold
    // them to it.
    if (font_data.ubuntu_14.get(cp) != null) {
        const len = std.unicode.utf8Encode(@intCast(cp), buf) catch return "?";
        return buf[0..len];
    }
    return switch (cp) {
        0x2018, 0x2019, 0x201A, 0x2032 => "'",
        0x201C, 0x201D, 0x201E, 0x2033, 0xAB, 0xBB => "\"",
        0x2010...0x2015, 0x2212 => "-",
        0x2026 => "...",
        0x2022, 0xB7 => "*",
        else => "?",
    };
}

/// The notice in what was read from the pipe in one go: its last non-blank
/// line, or all of it when it is a JSON object spread over several lines.
///
/// A line ends at a newline or at the end of the data, so `printf` without one
/// works as well as `echo`. Several notices arriving together replace one
/// another as they would have one at a time, so only the last is worth showing.
pub fn pipeMessage(data: []const u8) ?[]const u8 {
    const last = lastMessage(data) orelse return null;
    if (last[0] == '{') return last;

    // Pretty-printed JSON ends in a line of its own closing brace.
    const whole = std.mem.trim(u8, data, " \t\r\n");
    if (whole[0] == '{' and whole[whole.len - 1] == '}') return whole;
    return last;
}

/// The last non-blank line of `chunk`, trimmed.
pub fn lastMessage(chunk: []const u8) ?[]const u8 {
    var it = std.mem.splitBackwardsScalar(u8, chunk, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

/// Least time a sender must leave the panel alone between two changes to it,
/// in seconds.
///
/// Every refresh wears the e-paper a little and takes a moment of its own, and
/// a notice replaced sooner than this was never read anyway. The clock is read
/// in whole seconds, so the real gap is anywhere between one second and two.
pub const min_interval = 2;

/// Decides when notices go up and when they come down.
///
/// A notice goes up at once, unless the panel changed within the last
/// `min_interval`: then it waits out the rest of that, and a newer one arriving
/// meanwhile takes its place, as it would have on the panel. So however fast a
/// sender writes, the panel changes once per interval and the log gains one
/// line. Every notice used to be drawn and logged as it arrived, which a sender
/// stuck in a loop turned into thousands of log lines a second — enough for
/// journald to drop the daemon's other messages — and, between two texts, into
/// a panel that never stopped refreshing.
///
/// Free of I/O, the clock included: the time is passed in, as it is to
/// `Scheduler.runPendingAt`, so all of it is tested on any host.
pub const Pacer = struct {
    /// The notice on show, kept to tell a repeat of it by.
    shown: Request = .{},
    /// Monotonic second at which the notice on show comes down; null with
    /// none up.
    until: ?i64 = null,
    /// The latest notice to arrive that has not been acted on yet.
    waiting: ?Request = null,
    /// Monotonic second of the last change to the panel; null before the first.
    changed: ?i64 = null,

    const Request = struct {
        /// Folded, as the panel draws it. Empty asks for the notice on show to
        /// come down.
        buf: [max_len]u8 = undefined,
        len: usize = 0,
        duration: u32 = 0,

        fn text(self: *const Request) []const u8 {
            return self.buf[0..self.len];
        }
    };

    /// What the caller is to do to the panel.
    pub const Step = union(enum) {
        show: Show,
        /// Back to the dashboard, because a sender asked.
        dismissed,
        /// Back to the dashboard, because the notice's time is up.
        expired,
    };

    pub const Show = struct {
        /// As the panel draws it, which also makes it fit for a log line:
        /// folding leaves no newline or escape sequence for a sender to forge
        /// one with. Borrowed: valid until the pacer is asked again.
        text: []const u8,
        duration: u32,
        /// The notice already on show, sent again: nothing to draw, it only
        /// stays up longer.
        repeat: bool,
    };

    /// Take in a notice that has just arrived, in place of any still waiting.
    /// `next` then says what to do about it, which may be nothing yet.
    pub fn offer(self: *Pacer, n: Notice, default_duration: u32) void {
        self.waiting = .{ .duration = n.duration orelse default_duration };
        const w = &self.waiting.?;
        w.len = foldToFont(&w.buf, n.text).len;
    }

    /// What to do to the panel now, if anything. Ask after every `offer` and
    /// every time round the loop.
    pub fn next(self: *Pacer, now: i64) ?Step {
        const on_show = self.until != null;

        if (self.waiting) |w| {
            const dismissal = w.len == 0;
            if (dismissal and !on_show) {
                // Nothing to take down, so nothing to wait for either.
                self.waiting = null;
            } else if (self.restLeft(now) == 0) {
                self.waiting = null;
                self.changed = now;
                if (dismissal) {
                    self.until = null;
                    return .dismissed;
                }
                const repeat = on_show and w.duration == self.shown.duration and
                    std.mem.eql(u8, w.text(), self.shown.text());
                self.shown = w;
                self.until = now + @as(i64, w.duration);
                return .{ .show = .{ .text = self.shown.text(), .duration = w.duration, .repeat = repeat } };
            } else if (!dismissal) {
                // The one on show stays until this one replaces it, even past
                // its time: going back to the dashboard for a second in
                // between would cost two refreshes, one of them full.
                return null;
            }
        }

        const until = self.until orelse return null;
        if (now < until) return null;
        self.until = null;
        self.changed = now;
        return .expired;
    }

    /// The panel has finished the change `next` asked for. A full refresh
    /// takes a couple of seconds, so the interval is counted from its end:
    /// counted from its start, it would be over before the panel had rested.
    pub fn settle(self: *Pacer, now: i64) void {
        self.changed = now;
    }

    /// Seconds until `next` has something to do without another notice
    /// arriving, which is how long the loop may sleep. Null when there is
    /// nothing to wake for.
    pub fn secondsLeft(self: *const Pacer, now: i64) ?i64 {
        const expiry: ?i64 = if (self.until) |until| @max(0, until - now) else null;
        const waiting = if (self.waiting) |*request| request else return expiry;
        const rest = self.restLeft(now);
        // As in `next`: a notice waiting to go up holds the one on show, and
        // a dismissal has only the one on show to wait for.
        if (waiting.len > 0) return rest;
        return @min(rest, expiry orelse return null);
    }

    /// Seconds a sender still has to leave the panel alone.
    fn restLeft(self: *const Pacer, now: i64) i64 {
        const changed = self.changed orelse return 0;
        return @max(0, changed + min_interval - now);
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn expectFold(expected: []const u8, input: []const u8) !void {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(expected, foldToFont(&buf, input));
}

test "Czech, and every other Latin letter with a diacritic, stays as it is" {
    try expectFold("Příliš žluťoučký kůň úpěl ďábelské ódy", "Příliš žluťoučký kůň úpěl ďábelské ódy");
    try expectFold("PŘÍLIŠ ŽLUŤOUČKÝ KŮŇ ÚPĚL ĎÁBELSKÉ ÓDY", "PŘÍLIŠ ŽLUŤOUČKÝ KŮŇ ÚPĚL ĎÁBELSKÉ ÓDY");
    try expectFold("Straße Müller Łódź Œuvre", "Straße Müller Łódź Œuvre");
}

test "typographic punctuation becomes its ASCII lookalike" {
    try expectFold("\"Hotovo\" - za 5 min...", "„Hotovo“ – za 5 min…");
    try expectFold("it's", "it’s");
}

test "the degree sign survives, since the fonts have it" {
    try expectFold("22\u{B0}C", "22°C");
}

test "whitespace collapses and is trimmed" {
    try expectFold("a b c", "  a\t\tb \r\n c  ");
    try expectFold("1 000", "1\u{A0}000");
}

test "what the fonts have not becomes a question mark" {
    try expectFold("? hi", "😀 hi");
    try expectFold("?", "\xff");
    try expectFold("?", "中");
    try expectFold("??? ???", "Ωμέ Жук");
}

test "controls and marks that would forge or reorder a log line never get through" {
    try expectFold("a?b", "a\u{9B}b");
    try expectFold("a?b", "a\u{2028}b");
    try expectFold("a?b", "a\u{202E}b");
    try expectFold("a b", "a\u{1B}b");
}

test "folding stops at the buffer, never mid-character" {
    var buf: [5]u8 = undefined;
    // "ß" would need a sixth byte.
    try testing.expectEqualStrings("abcd", foldToFont(&buf, "abcdß"));
}

test "plain text is a notice as it stands" {
    var scratch: [8192]u8 = undefined;
    const n = parse(&scratch, "  Backup finished\n").?;
    try testing.expectEqualStrings("Backup finished", n.text);
    try testing.expectEqual(@as(?u32, null), n.duration);
}

test "a JSON notice carries its own duration" {
    var scratch: [8192]u8 = undefined;
    const n = parse(&scratch, "{\"text\": \"Pra\\u010dka hotov\u{e1}\", \"duration\": 120, \"extra\": true}").?;
    try testing.expectEqualStrings("Pračka hotová", n.text);
    try testing.expectEqual(@as(?u32, 120), n.duration);

    try testing.expectEqualStrings("hi", parse(&scratch, "{\"message\": \"hi\"}").?.text);
}

test "a JSON duration is kept within reason" {
    var scratch: [8192]u8 = undefined;
    try testing.expectEqual(@as(?u32, max_duration), parse(&scratch, "{\"text\": \"x\", \"duration\": 99999999}").?.duration);
    try testing.expectEqual(@as(?u32, max_duration), parse(&scratch, "{\"text\": \"x\", \"duration\": 1e300}").?.duration);
}

test "a JSON duration may be a fraction or a string" {
    var scratch: [8192]u8 = undefined;
    try testing.expectEqual(@as(?u32, 2), parse(&scratch, "{\"text\": \"x\", \"duration\": 1.5}").?.duration);
    try testing.expectEqual(@as(?u32, 60), parse(&scratch, "{\"text\": \"x\", \"duration\": \"60\"}").?.duration);
    try testing.expectEqualStrings("x", parse(&scratch, "{\"text\": \"x\", \"duration\": \"60\"}").?.text);
}

test "zero, negative or unreadable durations mean the default" {
    var scratch: [8192]u8 = undefined;
    for ([_][]const u8{ "0", "-5", "0.4", "\"soon\"", "null", "[]" }) |d| {
        var buf: [64]u8 = undefined;
        const raw = try std.mem.print(&buf, "{{\"text\": \"x\", \"duration\": {s}}}", .{d});
        const n = parse(&scratch, raw).?;
        try testing.expectEqualStrings("x", n.text);
        try testing.expectEqual(@as(?u32, null), n.duration);
    }
}

test "plain text with nothing visible in it is ignored, not a dismissal" {
    var scratch: [8192]u8 = undefined;
    try testing.expect(parse(&scratch, "") == null);
    try testing.expect(parse(&scratch, "\x0b") == null);
    try testing.expect(parse(&scratch, "\x01\u{A0}\x7f") == null);
    try testing.expectEqualStrings("\x01a", parse(&scratch, "\x01a").?.text);
}

test "a long JSON notice fits the scratch the daemon gives it" {
    var scratch: [8192]u8 = undefined;
    const raw = "{\"text\": \"" ++ @as([2000]u8, @splat('x')) ++ "\", \"duration\": 5}";
    const n = parse(&scratch, raw).?;
    try testing.expectEqual(@as(usize, 2000), n.text.len);
    try testing.expectEqual(@as(?u32, 5), n.duration);
}

test "empty text asks for the notice to come down" {
    var scratch: [8192]u8 = undefined;
    try testing.expectEqualStrings("", parse(&scratch, "{\"text\": \"\\u000b\"}").?.text);
    try testing.expectEqualStrings("", parse(&scratch, "{\"text\": \"  \"}").?.text);
    try testing.expectEqualStrings("", parse(&scratch, "{}").?.text);
}

test "text that only looks like JSON is shown as sent" {
    var scratch: [8192]u8 = undefined;
    try testing.expectEqualStrings("{not json", parse(&scratch, "{not json").?.text);
    try testing.expectEqualStrings("{\"text\": 5}", parse(&scratch, "{\"text\": 5}").?.text);
}

test "a JSON notice spread over lines arrives whole" {
    const pretty =
        \\{
        \\  "text": "Backup finished",
        \\  "duration": 120
        \\}
        \\
    ;
    const message = pipeMessage(pretty).?;
    var scratch: [8192]u8 = undefined;
    const n = parse(&scratch, message).?;
    try testing.expectEqualStrings("Backup finished", n.text);
    try testing.expectEqual(@as(?u32, 120), n.duration);
}

test "one-line notices arriving together leave the last" {
    try testing.expectEqualStrings("{\"text\": \"b\"}", pipeMessage("{\"text\": \"a\"}\n{\"text\": \"b\"}\n").?);
    try testing.expectEqualStrings("second", pipeMessage("first\nsecond\n").?);
    try testing.expect(pipeMessage("\n\n") == null);
}

test "a notice is the last non-blank line of the chunk" {
    try testing.expectEqualStrings("hello", lastMessage("hello\n").?);
    try testing.expectEqualStrings("hello", lastMessage("hello").?);
    try testing.expectEqualStrings("second", lastMessage("first\nsecond\n\n").?);
    try testing.expectEqualStrings("x", lastMessage("  x \r\n").?);
    try testing.expect(lastMessage("\n \n") == null);
    try testing.expect(lastMessage("") == null);
}

test "folding what is already folded changes nothing" {
    // The pacer hands the renderer folded text, which the renderer folds again.
    var once_buf: [max_len]u8 = undefined;
    var twice_buf: [max_len]u8 = undefined;
    // More of each than fits, so that the cut at `max_len` is folded twice too.
    const sharp_s: *const [max_len * "ß".len]u8 = comptime sharp_s: {
        const copies: [max_len]["ß".len]u8 = @splat("ß".*);
        break :sharp_s @ptrCast(&copies);
    };
    const degrees: *const [max_len * "° ".len]u8 = comptime degrees: {
        const copies: [max_len]["° ".len]u8 = @splat("° ".*);
        break :degrees @ptrCast(&copies);
    };
    for ([_][]const u8{
        "  Příliš žluťoučký kůň\n„úpěl“ – 22°C… 😀 ",
        sharp_s,
        degrees,
    }) |text| {
        const once = foldToFont(&once_buf, text);
        try testing.expectEqualStrings(once, foldToFont(&twice_buf, once));
    }
}

/// A notice arriving at `now`, and what the daemon is told to do about it.
fn arrive(p: *Pacer, text: []const u8, now: i64) ?Pacer.Step {
    p.offer(.{ .text = text }, 30);
    return p.next(now);
}

test "the first notice goes up at once and comes down when its time is up" {
    var p: Pacer = .{};
    try testing.expectEqual(@as(?i64, null), p.secondsLeft(100));

    const step = arrive(&p, "Backup finished", 100).?;
    try testing.expectEqualStrings("Backup finished", step.show.text);
    try testing.expectEqual(@as(u32, 30), step.show.duration);
    try testing.expect(!step.show.repeat);

    try testing.expectEqual(@as(?i64, 30), p.secondsLeft(100));
    try testing.expect(p.next(129) == null);
    try testing.expect(p.next(130).? == .expired);
    try testing.expect(p.next(131) == null);
    try testing.expectEqual(@as(?i64, null), p.secondsLeft(131));
}

test "a notice arriving straight after another waits out the interval" {
    var p: Pacer = .{};
    _ = arrive(&p, "first", 100).?;

    try testing.expect(arrive(&p, "second", 100) == null);
    try testing.expectEqual(@as(?i64, 2), p.secondsLeft(100));
    try testing.expect(p.next(101) == null);
    try testing.expectEqual(@as(?i64, 1), p.secondsLeft(101));

    try testing.expectEqualStrings("second", p.next(102).?.show.text);
    // Its time on show runs from when it went up, not from when it arrived.
    try testing.expectEqual(@as(?i64, 30), p.secondsLeft(102));

    // With the panel left alone for the interval, the next is not held up.
    try testing.expectEqualStrings("third", arrive(&p, "third", 104).?.show.text);
}

test "of the notices arriving while one waits, only the latest goes up" {
    var p: Pacer = .{};
    _ = arrive(&p, "first", 100).?;
    try testing.expect(arrive(&p, "second", 100) == null);
    try testing.expect(arrive(&p, "third", 101) == null);
    try testing.expect(arrive(&p, "fourth", 101) == null);

    try testing.expectEqualStrings("fourth", p.next(102).?.show.text);
    try testing.expect(p.next(102) == null);
    try testing.expect(p.next(104) == null);
}

test "a sender that never stops changes the panel once per interval" {
    var p: Pacer = .{};
    var steps: u32 = 0;

    // A thousand notices a second for a minute, no two alike, with the loop
    // coming round between them as it does in the daemon.
    for (0..60_000) |i| {
        const now: i64 = @intCast(100 + i / 1000);
        if (p.next(now) != null) steps += 1;

        var buf: [16]u8 = undefined;
        const text = try std.mem.print(&buf, "notice {d}", .{i});
        if (arrive(&p, text, now)) |step| {
            try testing.expect(!step.show.repeat);
            steps += 1;
        }
    }
    try testing.expectEqual(@as(u32, 60 / min_interval), steps);
}

test "the same notice over and over is drawn once and kept up" {
    var p: Pacer = .{};
    var drawn: u32 = 0;
    var repeats: u32 = 0;

    // `yes > /run/sys-ink/notify`, for a minute.
    for (0..60_000) |i| {
        const now: i64 = @intCast(100 + i / 1000);
        const step = arrive(&p, "y", now) orelse continue;
        if (step.show.repeat) repeats += 1 else drawn += 1;
    }
    try testing.expectEqual(@as(u32, 1), drawn);
    try testing.expectEqual(@as(u32, 60 / min_interval - 1), repeats);

    // The last to arrive is still waiting its turn, and keeps it up as well.
    try testing.expectEqual(@as(?i64, 0), p.secondsLeft(160));
    try testing.expect(p.next(160).?.show.repeat);
    try testing.expectEqual(@as(?i64, 30), p.secondsLeft(160));
}

test "a repeat is told by what the panel shows, and for how long" {
    var p: Pacer = .{};
    try testing.expect(!arrive(&p, "Pračka hotová", 100).?.show.repeat);

    // The panel draws whitespace as single spaces, so this is the same
    // notice again.
    try testing.expect(arrive(&p, "  Pračka\thotová \n", 110).?.show.repeat);
    try testing.expectEqual(@as(?i64, 30), p.secondsLeft(110));

    // The same text for another length of time is a change worth a log line.
    p.offer(.{ .text = "Pračka hotová", .duration = 300 }, 30);
    try testing.expect(!p.next(120).?.show.repeat);

    // And once it has come down, the same notice is a new one.
    try testing.expect(p.next(420).? == .expired);
    p.offer(.{ .text = "Pračka hotová", .duration = 300 }, 30);
    try testing.expect(!p.next(500).?.show.repeat);
}

test "a dismissal takes the notice down, in its turn like any other" {
    var p: Pacer = .{};
    _ = arrive(&p, "Deploy running", 100).?;

    try testing.expect(arrive(&p, "", 101) == null);
    try testing.expectEqual(@as(?i64, 1), p.secondsLeft(101));
    try testing.expect(p.next(102).? == .dismissed);
    try testing.expect(p.next(102) == null);
    try testing.expectEqual(@as(?i64, null), p.secondsLeft(102));

    // At once, when the panel has been left alone for the interval.
    _ = arrive(&p, "Deploy running", 200).?;
    try testing.expect(arrive(&p, "", 210).? == .dismissed);
}

test "a dismissal with nothing on show does nothing, and calls off a notice still waiting" {
    var p: Pacer = .{};
    try testing.expect(arrive(&p, "", 100) == null);
    try testing.expectEqual(@as(?i64, null), p.secondsLeft(100));

    _ = arrive(&p, "first", 100).?;
    try testing.expect(arrive(&p, "", 100) == null);
    try testing.expect(p.next(102).? == .dismissed);

    try testing.expect(arrive(&p, "second", 103) == null);
    try testing.expect(arrive(&p, "", 103) == null);
    try testing.expectEqual(@as(?i64, null), p.secondsLeft(103));
    try testing.expect(p.next(110) == null);
}

test "a notice waiting to go up keeps the one on show from coming down first" {
    var p: Pacer = .{};
    p.offer(.{ .text = "short", .duration = 1 }, 30);
    _ = p.next(100).?;
    try testing.expect(arrive(&p, "next", 100) == null);

    // Its time is up at 101, but the dashboard would only flash by.
    try testing.expect(p.next(101) == null);
    try testing.expectEqual(@as(?i64, 1), p.secondsLeft(101));
    try testing.expectEqualStrings("next", p.next(102).?.show.text);
}

test "a dismissal waiting does not keep a notice past its time" {
    var p: Pacer = .{};
    p.offer(.{ .text = "short", .duration = 1 }, 30);
    _ = p.next(100).?;
    try testing.expect(arrive(&p, "", 100) == null);

    try testing.expectEqual(@as(?i64, 1), p.secondsLeft(100));
    try testing.expect(p.next(101).? == .expired);
    // Which leaves the dismissal nothing to do, and the loop nothing to wake for.
    try testing.expectEqual(@as(?i64, null), p.secondsLeft(101));
    try testing.expect(p.next(103) == null);
}

test "a notice arriving just after one came down waits as well" {
    var p: Pacer = .{};
    _ = arrive(&p, "first", 100).?;
    try testing.expect(p.next(130).? == .expired);

    try testing.expect(arrive(&p, "second", 131) == null);
    try testing.expectEqualStrings("second", p.next(132).?.show.text);
}

test "the interval is counted from when the panel finished changing" {
    var p: Pacer = .{};
    _ = arrive(&p, "first", 100).?;
    // The refresh took until 103.
    p.settle(103);

    try testing.expect(arrive(&p, "second", 103) == null);
    try testing.expectEqual(@as(?i64, 2), p.secondsLeft(103));
    try testing.expect(p.next(104) == null);
    try testing.expectEqualStrings("second", p.next(105).?.show.text);
}

test "a notice cannot write log lines of its own" {
    var p: Pacer = .{};
    const forged = arrive(&p, "Backup done\n[12:00:00] [err] (main) Disk failing\r\x1b[2J\x00", 100).?;
    try testing.expectEqualStrings("Backup done [12:00:00] [err] (main) Disk failing [2J", forged.show.text);
    for (forged.show.text) |byte| try testing.expect(byte >= 0x20 and byte != 0x7F);

    // The controls and line breaks outside ASCII go the same way.
    const wide = arrive(&p, "a\u{85}b\u{2028}c\u{9b}31m", 200).?;
    try testing.expectEqualStrings("a?b?c?31m", wide.show.text);
}
