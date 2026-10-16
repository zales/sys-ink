//! What Spotify or Kodi is playing, and when the panel shows it.
//!
//! Each client (`spotify_client.zig`, `kodi_client.zig`) runs on a task of
//! its own and hands the main loop a `Snapshot`: the newest of everything it
//! knows. From those, `Screen` decides what the panel shows and when it is
//! redrawn: the music screen while something plays, for a while after it
//! pauses, the code to link the panel with while one is waiting to be
//! entered, and the dashboard otherwise. What plays on one source is shown
//! over what is paused on the other, and of two playing at once, the one
//! that started last.
//!
//! Free of I/O, and of the clock: every decision takes the time as an
//! argument, in milliseconds of the monotonic clock, which the client stamps
//! what it receives with too.

const std = @import("std");
const layout = @import("display_config.zig");

/// The cover as the client hands it over: greyscale, scaled to the size it
/// is drawn at. A poster takes the first `Shape.poster.len()` bytes.
pub const cover_side = layout.music.cover.width;
pub const cover_len = cover_side * cover_side;

/// The shape of the picture beside the text, and where it goes.
pub const Shape = enum {
    /// An album's cover, or anything else with no shape of its own.
    square,
    /// A film's or a series' poster, two by three.
    poster,

    pub fn rect(self: Shape) layout.Rect {
        return switch (self) {
            .square => layout.music.cover,
            .poster => layout.music.poster,
        };
    }

    pub fn len(self: Shape) usize {
        const r = self.rect();
        return @as(usize, r.width) * r.height;
    }
};

/// Where a snapshot comes from.
pub const Source = enum { spotify, kodi };

/// Bytes of a title, an artist or an album kept. More than the panel can
/// show in any font; what is cut is cut at a whole character.
pub const max_text = 200;

/// A piece of UTF-8 kept by value, so a snapshot can be copied whole.
pub const Text = struct {
    buf: [max_text]u8 = undefined,
    len: u8 = 0,

    pub fn init(text: []const u8) Text {
        var t: Text = .{};
        t.set(text);
        return t;
    }

    pub fn set(self: *Text, text: []const u8) void {
        var len = @min(text.len, max_text);
        // Back to the start of a character, if the cut fell inside one.
        if (len < text.len) {
            while (len > 0 and text[len] & 0xC0 == 0x80) len -= 1;
        }
        @memcpy(self.buf[0..len], text[0..len]);
        self.len = @intCast(len);
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(self: *const Text, other: *const Text) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// What a track or an episode is called, by whom, and on what.
pub const Track = struct {
    /// `spotify:track:...`, `spotify:episode:...`, or what Kodi's client
    /// makes of what it plays; what the playback it describes is matched by.
    uri: Text = .{},
    title: Text = .{},
    /// The artists, or the show an episode is from.
    artist: Text = .{},
    album: Text = .{},
};

/// Where playback stood when the client last heard.
pub const Playback = struct {
    uri: Text = .{},
    /// Playing, rather than paused or stopped.
    playing: bool = false,
    /// Into the track at `at_ms`, in milliseconds.
    position_ms: i64 = 0,
    /// Monotonic milliseconds at which `position_ms` held.
    at_ms: i64 = 0,
    duration_ms: i64 = 0,
    /// How fast the position moves: 1 normally, 0 while a track loads.
    speed: f64 = 1,
    /// A live stream, which has no length: the position is how long it has
    /// been watched, and `duration_ms` is 0.
    live: bool = false,

    /// The position at `now_ms`, carried forward from the last report while
    /// playing, and never past either end of the track.
    pub fn positionAt(self: *const Playback, now_ms: i64) i64 {
        var position = self.position_ms;
        if (self.playing and now_ms > self.at_ms) {
            const elapsed: f64 = @floatFromInt(now_ms - self.at_ms);
            position += @intFromFloat(@min(elapsed * std.math.clamp(self.speed, 0, 4), 1e12));
        }
        if (self.live) return @max(position, 0);
        return std.math.clamp(position, 0, @max(self.duration_ms, 0));
    }
};

/// A code waiting to be entered at spotify.com/pair, which links the panel
/// to an account.
pub const Pairing = struct {
    code: Text = .{},
    /// Monotonic milliseconds after which it is no use.
    expires_ms: i64 = 0,
};

/// The newest of everything the client knows, as the main loop takes it.
pub const Snapshot = struct {
    pairing: ?Pairing = null,
    /// Null when nothing is playing anywhere on the account.
    playback: ?Playback = null,
    /// What `playback` is playing, once the client has looked it up.
    track: ?Track = null,
    /// The cover of `track`, while `cover_valid`, in the shape of
    /// `cover_shape`.
    cover: [cover_len]u8 = @splat(0xFF),
    cover_valid: bool = false,
    /// The picture's shape, and so where the text goes, whether or not there
    /// is a picture.
    cover_shape: Shape = .square,
    /// Counts the covers handed over, so a new one can be told from the old.
    cover_serial: u32 = 0,
};

/// What the music screen shows. Borrowed from the screen: valid until it is
/// next updated.
pub const View = union(enum) {
    pairing: struct { code: []const u8 },
    track: TrackView,
};

pub const TrackView = struct {
    title: []const u8,
    artist: []const u8,
    elapsed_s: u32,
    /// 0 when not known, and for a live stream.
    duration_s: u32,
    playing: bool,
    /// The first `shape.len()` bytes are the picture.
    cover: ?*const [cover_len]u8,
    shape: Shape = .square,
    live: bool = false,
};

pub const Options = struct {
    /// How long the music screen stays up once playback has paused, in
    /// seconds.
    hold_paused: u32 = 30,
    /// Seconds between redraws while playing, which move the progress bar.
    tick: u32 = 5,
};

/// Least time between two redraws, however fast updates come. Spotify sends
/// two or three for one change of track, and each redraw is a refresh of the
/// panel.
const min_redraw_ms = 1000;

/// What the caller is to do to the panel.
pub const Step = union(enum) {
    /// Draw this on the music screen and put it up.
    show: struct {
        view: View,
        /// A full refresh rather than a partial one: the screen has just
        /// come up, or its picture has changed, and a partial update would
        /// leave a ghost of what was there.
        full: bool,
    },
    /// Back to the dashboard, with a full refresh for the same reason.
    hide,
};

pub const Screen = struct {
    options: Options = .{},
    /// What each source last handed over, and what is known of it beyond.
    sources: std.EnumArray(Source, Held) = .initFill(.{}),
    /// What the last step put up, while the music screen is up.
    shown: ?Shown = null,
    /// Something has arrived since the last redraw.
    dirty: bool = false,
    last_drawn: i64 = 0,

    const Kind = enum { pairing, track };

    const Held = struct {
        latest: Snapshot = .{},
        /// Monotonic milliseconds at which playback was first seen paused,
        /// while it is.
        paused_since: ?i64 = null,
        /// Monotonic milliseconds at which what plays started, or started
        /// again after a pause.
        started: i64 = 0,
    };

    const Shown = struct {
        kind: Kind,
        source: Source,
        cover_serial: u32,
    };

    const Wanted = struct {
        kind: Kind,
        source: Source,
    };

    /// Take in what `source`'s client has just handed over, at `now_ms`.
    pub fn update(self: *Screen, source: Source, snapshot: *const Snapshot, now_ms: i64) void {
        const held = self.sources.getPtr(source);
        const previous = held.latest.playback;
        const was_playing = if (previous) |p| p.playing else false;
        held.latest = snapshot.*;
        self.dirty = true;

        const p = snapshot.playback orelse {
            // A device that pauses and then leaves the account's playback, as a
            // phone that locks does, leaves nothing playing: the pause still
            // runs its time, as it would have had the device stayed.
            if (held.paused_since != null) {
                held.latest.playback = previous;
                return;
            }
            held.paused_since = null;
            return;
        };
        if (p.playing) {
            held.paused_since = null;
            const same = if (previous) |before| before.uri.eql(&p.uri) else false;
            if (!was_playing or !same) held.started = now_ms;
        } else if (was_playing or held.paused_since == null) {
            // From when the pause was first seen. A client may report the same
            // pause again, and its time must not start over each time.
            held.paused_since = now_ms;
        }
    }

    /// What to do to the panel at `now_ms`, if anything. `blocked` holds the
    /// music screen off whatever is playing: the dashboard has a fault to
    /// show.
    pub fn step(self: *Screen, now_ms: i64, blocked: bool) ?Step {
        const want = (if (blocked) null else self.wanted(now_ms)) orelse {
            if (self.shown == null) return null;
            self.shown = null;
            self.dirty = false;
            return .hide;
        };

        const cover_serial = self.sources.get(want.source).latest.cover_serial;
        const full = if (self.shown) |shown|
            shown.kind != want.kind or shown.source != want.source or
                (want.kind == .track and shown.cover_serial != cover_serial)
        else
            true;
        const due = full or self.redrawDue(want.source, now_ms);
        if (!due) return null;

        self.shown = .{ .kind = want.kind, .source = want.source, .cover_serial = cover_serial };
        self.dirty = false;
        self.last_drawn = now_ms;
        return .{ .show = .{ .view = self.view(want, now_ms), .full = full } };
    }

    /// Milliseconds until `step` has something to do without anything new
    /// arriving: the next tick of the progress bar, a pause running out, a
    /// code expiring. Null when there is nothing to wake for.
    pub fn msLeft(self: *const Screen, now_ms: i64) ?i64 {
        var left: ?i64 = null;
        if (self.dirty and self.shown != null) left = @max(0, self.last_drawn + min_redraw_ms - now_ms);

        // Only what lies ahead: a deadline already passed has been acted on,
        // and counting it would have the loop spin on it.
        for (std.enums.values(Source)) |source| {
            const held = self.sources.get(source);
            if (held.latest.pairing) |pairing| {
                if (pairing.expires_ms > now_ms) left = minOpt(left, pairing.expires_ms - now_ms);
            }
            const p = held.latest.playback orelse continue;
            const shown_here = if (self.shown) |shown| shown.kind == .track and shown.source == source else false;
            if (p.playing and shown_here) {
                left = minOpt(left, @max(0, self.last_drawn + self.tickMs() - now_ms));
            }
            if (held.paused_since) |since| {
                const until = since + self.holdMs();
                if (until > now_ms) left = minOpt(left, until - now_ms);
            }
        }
        return left;
    }

    /// What should be up at `now_ms`: a code to enter, ahead of everything;
    /// else what plays, or failing that what paused within the hold; of two,
    /// the one that started last.
    fn wanted(self: *const Screen, now_ms: i64) ?Wanted {
        for (std.enums.values(Source)) |source| {
            const pairing = self.sources.get(source).latest.pairing orelse continue;
            if (now_ms < pairing.expires_ms) return .{ .kind = .pairing, .source = source };
        }

        var best: ?Source = null;
        var best_playing = false;
        var best_started: i64 = 0;
        for (std.enums.values(Source)) |source| {
            const held = self.sources.get(source);
            const p = held.latest.playback orelse continue;
            if (!p.playing) {
                const since = held.paused_since orelse continue;
                if (now_ms >= since + self.holdMs()) continue;
            }
            const better = if (best == null)
                true
            else if (p.playing != best_playing)
                p.playing
            else
                held.started > best_started;
            if (better) {
                best = source;
                best_playing = p.playing;
                best_started = held.started;
            }
        }
        return .{ .kind = .track, .source = best orelse return null };
    }

    fn redrawDue(self: *const Screen, source: Source, now_ms: i64) bool {
        if (now_ms - self.last_drawn < min_redraw_ms) return false;
        if (self.dirty) return true;
        const p = self.sources.get(source).latest.playback orelse return false;
        return p.playing and now_ms - self.last_drawn >= self.tickMs();
    }

    fn view(self: *const Screen, want: Wanted, now_ms: i64) View {
        const latest = &self.sources.getPtrConst(want.source).latest;
        if (want.kind == .pairing) return .{ .pairing = .{ .code = latest.pairing.?.code.slice() } };

        const p = &latest.playback.?;
        // Only the description of what is playing: one of the track before
        // would put the wrong name over the right progress.
        const track: ?*const Track = if (latest.track) |*t| (if (t.uri.eql(&p.uri)) t else null) else null;
        return .{ .track = .{
            .title = if (track) |t| t.title.slice() else "",
            .artist = if (track) |t| t.artist.slice() else "",
            .elapsed_s = seconds(p.positionAt(now_ms)),
            .duration_s = if (p.live) 0 else seconds(p.duration_ms),
            .playing = p.playing,
            .cover = if (track != null and latest.cover_valid) &latest.cover else null,
            .shape = latest.cover_shape,
            .live = p.live,
        } };
    }

    fn tickMs(self: *const Screen) i64 {
        return @as(i64, self.options.tick) * 1000;
    }

    fn holdMs(self: *const Screen) i64 {
        return @as(i64, self.options.hold_paused) * 1000;
    }
};

fn seconds(ms: i64) u32 {
    return std.math.lossyCast(u32, @divFloor(@max(ms, 0), 1000));
}

fn minOpt(a: ?i64, b: i64) i64 {
    return if (a) |x| @min(x, b) else b;
}

/// `m:ss`, or `h:mm:ss` from an hour up, as a player shows a time.
pub fn formatTime(buf: []u8, total_s: u32) []const u8 {
    const h = total_s / 3600;
    const m = (total_s / 60) % 60;
    const s = total_s % 60;
    if (h > 0) return std.mem.print(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "?";
    return std.mem.print(buf, "{d}:{d:0>2}", .{ m, s }) catch "?";
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn playing(uri: []const u8, position_ms: i64, at_ms: i64) Snapshot {
    var snapshot: Snapshot = .{
        .playback = .{
            .uri = .init(uri),
            .playing = true,
            .position_ms = position_ms,
            .at_ms = at_ms,
            .duration_ms = 200_000,
        },
        .track = .{
            .uri = .init(uri),
            .title = .init("Jednou"),
            .artist = .init("Vladimir Misik"),
            .album = .init("Jednou te potkam"),
        },
        .cover_valid = true,
        .cover_serial = 1,
    };
    snapshot.cover[0] = 0;
    return snapshot;
}

fn paused(uri: []const u8, position_ms: i64, at_ms: i64) Snapshot {
    var snapshot = playing(uri, position_ms, at_ms);
    snapshot.playback.?.playing = false;
    return snapshot;
}

test "the position runs on from the last report while playing, and stops at either end" {
    const p: Playback = .{ .playing = true, .position_ms = 10_000, .at_ms = 1_000, .duration_ms = 60_000 };
    try testing.expectEqual(@as(i64, 10_000), p.positionAt(1_000));
    try testing.expectEqual(@as(i64, 15_000), p.positionAt(6_000));
    try testing.expectEqual(@as(i64, 60_000), p.positionAt(1_000_000));

    var stopped = p;
    stopped.playing = false;
    try testing.expectEqual(@as(i64, 10_000), stopped.positionAt(6_000));

    var loading = p;
    loading.speed = 0;
    try testing.expectEqual(@as(i64, 10_000), loading.positionAt(6_000));
}

test "the music screen comes up in full when something starts playing, and redraws on its tick" {
    var screen: Screen = .{};
    try testing.expectEqual(@as(?Step, null), screen.step(0, false));

    screen.update(.spotify, &playing("spotify:track:a", 0, 1_000), 1_000);
    const first = screen.step(1_000, false).?.show;
    try testing.expect(first.full);
    try testing.expectEqualStrings("Jednou", first.view.track.title);
    try testing.expectEqual(@as(u32, 0), first.view.track.elapsed_s);

    // Nothing to do before the tick.
    try testing.expectEqual(@as(?Step, null), screen.step(3_000, false));
    try testing.expectEqual(@as(?i64, 3_000), screen.msLeft(3_000));

    const tick = screen.step(6_000, false).?.show;
    try testing.expect(!tick.full);
    try testing.expectEqual(@as(u32, 5), tick.view.track.elapsed_s);
}

test "a new cover is put up in full, a new position over the old one partially" {
    var screen: Screen = .{};
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);

    // Seeked: same track, same cover.
    screen.update(.spotify, &playing("spotify:track:a", 90_000, 2_000), 2_000);
    const seek = screen.step(2_000, false).?.show;
    try testing.expect(!seek.full);
    try testing.expectEqual(@as(u32, 90), seek.view.track.elapsed_s);

    var next = playing("spotify:track:b", 0, 4_000);
    next.cover_serial = 2;
    screen.update(.spotify, &next, 4_000);
    try testing.expect(screen.step(4_000, false).?.show.full);
}

test "updates that come in a burst are drawn once, a second after the last redraw" {
    var screen: Screen = .{};
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);

    screen.update(.spotify, &playing("spotify:track:a", 300, 300), 300);
    try testing.expectEqual(@as(?Step, null), screen.step(300, false));
    try testing.expectEqual(@as(?i64, 700), screen.msLeft(300));
    try testing.expect(screen.step(1_000, false) != null);
}

test "a pause holds the screen for its time, without ticks, then gives way to the dashboard" {
    var screen: Screen = .{ .options = .{ .hold_paused = 30 } };
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);

    screen.update(.spotify, &paused("spotify:track:a", 10_000, 10_000), 10_000);
    const pause = screen.step(10_000, false).?.show;
    try testing.expect(!pause.view.track.playing);
    try testing.expectEqual(@as(u32, 10), pause.view.track.elapsed_s);

    // No ticks while paused: the bar does not move.
    try testing.expectEqual(@as(?Step, null), screen.step(20_000, false));
    try testing.expectEqual(@as(?i64, 20_000), screen.msLeft(20_000));

    try testing.expectEqual(Step.hide, screen.step(40_000, false).?);
    try testing.expectEqual(@as(?Step, null), screen.step(41_000, false));
}

test "the same pause reported again does not start its time over" {
    var screen: Screen = .{ .options = .{ .hold_paused = 30 } };
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);
    screen.update(.spotify, &paused("spotify:track:a", 10_000, 10_000), 10_000);
    _ = screen.step(10_000, false);
    screen.update(.spotify, &paused("spotify:track:a", 10_000, 25_000), 25_000);
    _ = screen.step(25_000, false);

    try testing.expectEqual(Step.hide, screen.step(40_000, false).?);
}

test "music that was paused before the daemon heard of it is not put up" {
    var screen: Screen = .{ .options = .{ .hold_paused = 30 } };
    screen.update(.spotify, &paused("spotify:track:a", 10_000, 0), 0);
    _ = screen.step(0, false);
    // Shown for the hold, as a pause just seen is.
    try testing.expectEqual(Step.hide, screen.step(30_000, false).?);

    // Reported again later, paused all along: nothing.
    screen.update(.spotify, &paused("spotify:track:a", 10_000, 60_000), 60_000);
    try testing.expectEqual(@as(?Step, null), screen.step(60_000, false));
}

test "a paused device that leaves the account's playback still holds the screen for the pause" {
    var screen: Screen = .{ .options = .{ .hold_paused = 30 } };
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);
    screen.update(.spotify, &paused("spotify:track:a", 10_000, 10_000), 10_000);
    _ = screen.step(10_000, false);

    screen.update(.spotify, &.{}, 12_000);
    const still = screen.step(13_000, false).?.show;
    try testing.expect(!still.view.track.playing);
    try testing.expectEqual(Step.hide, screen.step(40_000, false).?);
}

test "nothing playing anywhere takes the screen down at once" {
    var screen: Screen = .{};
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);

    screen.update(.spotify, &.{}, 5_000);
    try testing.expectEqual(Step.hide, screen.step(5_000, false).?);
}

test "a fault on the dashboard keeps the music screen down, and it comes back once cleared" {
    var screen: Screen = .{};
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);

    try testing.expectEqual(Step.hide, screen.step(2_000, true).?);
    try testing.expectEqual(@as(?Step, null), screen.step(3_000, true));
    try testing.expect(screen.step(4_000, false).?.show.full);
}

test "a description of another track is not put over this one's progress" {
    var screen: Screen = .{};
    var snapshot = playing("spotify:track:b", 0, 0);
    snapshot.track.?.uri = .init("spotify:track:a");
    screen.update(.spotify, &snapshot, 0);
    const view = screen.step(0, false).?.show.view.track;
    try testing.expectEqualStrings("", view.title);
    try testing.expect(view.cover == null);
}

test "a code to enter is shown until it expires, ahead of the music" {
    var screen: Screen = .{};
    var snapshot = playing("spotify:track:a", 0, 0);
    snapshot.pairing = .{ .code = .init("ABC123"), .expires_ms = 60_000 };
    screen.update(.spotify, &snapshot, 0);

    const shown = screen.step(0, false).?.show;
    try testing.expect(shown.full);
    try testing.expectEqualStrings("ABC123", shown.view.pairing.code);

    // Expired: on to what is playing, in full, since the picture changes.
    const after = screen.step(60_000, false).?.show;
    try testing.expect(after.full);
    try testing.expectEqualStrings("Jednou", after.view.track.title);
}

test "a live stream's position runs on from when it was first seen, without end" {
    const p: Playback = .{ .playing = true, .position_ms = 0, .at_ms = 1_000, .duration_ms = 0, .live = true };
    try testing.expectEqual(@as(i64, 3_600_000), p.positionAt(3_601_000));
}

test "what plays on one source is shown over what is paused on the other" {
    var screen: Screen = .{ .options = .{ .hold_paused = 30 } };
    screen.update(.spotify, &playing("spotify:track:a", 0, 0), 0);
    _ = screen.step(0, false);

    // Spotify pauses, and a moment later Kodi plays: Kodi, in full.
    screen.update(.spotify, &paused("spotify:track:a", 5_000, 5_000), 5_000);
    var film = playing("kodi:film", 0, 6_000);
    film.track.?.title = .init("Film");
    film.cover_serial = 1;
    screen.update(.kodi, &film, 6_000);
    const kodi = screen.step(6_000, false).?.show;
    try testing.expect(kodi.full);
    try testing.expectEqualStrings("Film", kodi.view.track.title);

    // Kodi pauses while Spotify plays again: Spotify, in full.
    screen.update(.kodi, &paused("kodi:film", 9_000, 9_000), 9_000);
    screen.update(.spotify, &playing("spotify:track:a", 5_000, 10_000), 10_000);
    const back = screen.step(10_000, false).?.show;
    try testing.expect(back.full);
    try testing.expectEqualStrings("Jednou", back.view.track.title);
}

test "of two sources playing at once, the one that started last is shown" {
    var screen: Screen = .{};
    var film = playing("kodi:film", 0, 0);
    film.track.?.title = .init("Film");
    screen.update(.kodi, &film, 0);
    screen.update(.spotify, &playing("spotify:track:a", 0, 2_000), 2_000);
    try testing.expectEqualStrings("Jednou", screen.step(2_000, false).?.show.view.track.title);

    // The same film reported on, still playing, is no new start.
    screen.update(.kodi, &playing("kodi:film", 4_000, 4_000), 4_000);
    try testing.expectEqualStrings("Jednou", screen.step(4_000, false).?.show.view.track.title);

    // Something new on Kodi is.
    var next = playing("kodi:next", 0, 6_000);
    next.track.?.title = .init("Next");
    screen.update(.kodi, &next, 6_000);
    try testing.expectEqualStrings("Next", screen.step(6_000, false).?.show.view.track.title);
}

test "a source paused long ago is not brought back when the other stops" {
    var screen: Screen = .{ .options = .{ .hold_paused = 30 } };
    screen.update(.spotify, &paused("spotify:track:a", 10_000, 0), 0);
    screen.update(.kodi, &playing("kodi:film", 0, 60_000), 60_000);
    _ = screen.step(60_000, false);

    screen.update(.kodi, &.{}, 100_000);
    try testing.expectEqual(Step.hide, screen.step(100_000, false).?);
}

test "a poster and a live stream reach the view as they are" {
    var screen: Screen = .{};
    var stream = playing("kodi:stream", 0, 0);
    stream.cover_shape = .poster;
    stream.playback.?.live = true;
    stream.playback.?.duration_ms = 0;
    screen.update(.kodi, &stream, 0);
    const view = screen.step(5_000, false).?.show.view.track;
    try testing.expectEqual(Shape.poster, view.shape);
    try testing.expect(view.live);
    try testing.expectEqual(@as(u32, 0), view.duration_s);
    try testing.expectEqual(@as(u32, 5), view.elapsed_s);
}

test "text is cut at a whole character" {
    // One byte, then two-byte letters: the limit falls inside one of them.
    var long: [301]u8 = undefined;
    long[0] = 'a';
    for (0..150) |i| @memcpy(long[1 + 2 * i ..][0..2], "ž");
    const t: Text = .init(&long);
    try testing.expectEqual(@as(usize, max_text - 1), t.slice().len);
    try testing.expect(std.unicode.utf8ValidateSlice(t.slice()));
}

test "times read as a player shows them" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0:05", formatTime(&buf, 5));
    try testing.expectEqualStrings("3:52", formatTime(&buf, 232));
    try testing.expectEqualStrings("1:00:00", formatTime(&buf, 3600));
    try testing.expectEqualStrings("53:10", formatTime(&buf, 3190));
}
