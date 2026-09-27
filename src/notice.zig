//! Notices: short messages from other programs, shown on the panel for a while
//! in place of the dashboard.
//!
//! This module is the I/O-free half: reading what arrived and turning it into
//! text the panel can draw. Receiving it is `notice_fifo.zig` for the local
//! pipe and `mqtt.zig` for the network.
//!
//! Both carry the same thing: plain text, or a JSON object for when a notice
//! needs more than that — see `parse`.

const std = @import("std");
const CodepointIterator = @import("graphics.zig").CodepointIterator;

/// Longest notice kept, in bytes after folding. Six lines of the smallest font
/// hold about this much; anything longer would be cut off on the glass anyway.
pub const max_len = 280;

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

/// The fonts are generated for printable ASCII and the degree sign only, so
/// anything else would draw as a blank gap. Latin letters with diacritics lose
/// them ("Příliš žluťoučký" becomes "Prilis zlutoucky"), typographic
/// punctuation becomes its ASCII lookalike, whitespace of any kind collapses to
/// single spaces, and whatever is left becomes '?'.
///
/// Stops at `out.len`, never mid-character.
pub fn foldToAscii(out: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    // Starts true so leading whitespace is dropped.
    var after_space = true;

    var it = CodepointIterator{ .text = text };
    while (it.next()) |cp| {
        var one: [1]u8 = undefined;
        const folded: []const u8 = if (isSpace(cp)) " " else fold(cp, &one);

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

fn isSpace(cp: u32) bool {
    return switch (cp) {
        // Every C0 control, tab and CR included, and DEL.
        0...0x20, 0x7F => true,
        // NBSP, the fixed-width spaces, narrow NBSP.
        0xA0, 0x2000...0x200A, 0x202F => true,
        else => false,
    };
}

/// ASCII for one non-space codepoint. `one` backs single-character results.
fn fold(cp: u32, one: *[1]u8) []const u8 {
    if (cp < 0x80) {
        one[0] = @intCast(cp);
        return one;
    }
    return switch (cp) {
        // The one non-ASCII glyph the fonts do have.
        0xB0 => "\u{B0}",
        0xC0...0xFF => latin1[cp - 0xC0],
        0x132 => "IJ",
        0x133 => "ij",
        0x152 => "OE",
        0x153 => "oe",
        0x100...0x131, 0x134...0x151, 0x154...0x17F => blk: {
            one[0] = latin_extended_a[cp - 0x100];
            break :blk one;
        },
        0x2018, 0x2019, 0x201A, 0x2032 => "'",
        0x201C, 0x201D, 0x201E, 0x2033, 0xAB, 0xBB => "\"",
        0x2010...0x2015, 0x2212 => "-",
        0x2026 => "...",
        0x2022, 0xB7 => "*",
        else => "?",
    };
}

/// U+00C0 to U+00FF.
const latin1 = [64][]const u8{
    "A", "A", "A", "A", "A", "A", "AE", "C", "E", "E", "E", "E", "I", "I", "I",  "I",
    "D", "N", "O", "O", "O", "O", "O",  "x", "O", "U", "U", "U", "U", "Y", "Th", "ss",
    "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i",  "i",
    "d", "n", "o", "o", "o", "o", "o",  "/", "o", "u", "u", "u", "u", "y", "th", "y",
};

/// Base letter of each codepoint from U+0100 to U+017F. The four ligatures in
/// the block are handled separately; their entries here are never read.
const latin_extended_a =
    "AaAaAa" ++ "CcCcCcCc" ++ "DdDd" ++ "EeEeEeEeEe" ++ "GgGgGgGg" ++ "HhHh" ++
    "IiIiIiIiIi" ++ "Ii" ++ "Jj" ++ "Kkk" ++ "LlLlLlLlLl" ++ "NnNnNnnNn" ++
    "OoOoOo" ++ "Oo" ++ "RrRrRr" ++ "SsSsSsSs" ++ "TtTtTt" ++ "UuUuUuUuUuUu" ++
    "Ww" ++ "YyY" ++ "ZzZzZz" ++ "s";

comptime {
    std.debug.assert(latin_extended_a.len == 0x80);
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

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn expectFold(expected: []const u8, input: []const u8) !void {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(expected, foldToAscii(&buf, input));
}

test "Czech diacritics fold to their base letters" {
    try expectFold(
        "Prilis zlutoucky kun upel dabelske ody",
        "Příliš žluťoučký kůň úpěl ďábelské ódy",
    );
    try expectFold("PRILIS ZLUTOUCKY KUN UPEL DABELSKE ODY", "PŘÍLIŠ ŽLUŤOUČKÝ KŮŇ ÚPĚL ĎÁBELSKÉ ÓDY");
}

test "other Latin scripts fold too" {
    try expectFold("Strasse Muller", "Straße Müller");
    try expectFold("Lodz", "Łódź");
    try expectFold("OEuvre", "Œuvre");
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

test "what cannot be folded becomes a question mark" {
    try expectFold("? hi", "😀 hi");
    try expectFold("?", "\xff");
}

test "folding stops at the buffer, never mid-expansion" {
    var buf: [5]u8 = undefined;
    // "ss" would need a sixth byte.
    try testing.expectEqualStrings("abcd", foldToAscii(&buf, "abcdß"));
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
        const raw = try std.fmt.bufPrint(&buf, "{{\"text\": \"x\", \"duration\": {s}}}", .{d});
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
    const raw = "{\"text\": \"" ++ "x" ** 2000 ++ "\", \"duration\": 5}";
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
