//! Kodi's side of the conversation, free of I/O: what is asked, and what is
//! made of what comes back.
//!
//! Kodi speaks JSON-RPC on TCP port 9090: replies to requests, and
//! notifications it sends of its own accord the moment playback changes, all
//! as JSON objects one after another with nothing between them. That port
//! asks for no password. A notification says little, so each one has the
//! client ask again: which player is active, what it plays, and how far in.
//!
//! What plays is asked through `XBMC.GetInfoLabels` rather than
//! `Player.GetItem`: for what an add-on plays, GetItem leaves the title and
//! the show empty, where the labels the skin shows have them. Pictures are
//! fetched from where the labels say they are, over HTTPS; Kodi's own copies
//! are behind its web server's password. Checked against Kodi 22 (JSON-RPC
//! 13.11) on 2026-10-16.
//!
//! The connection that carries this is `kodi_client.zig`.

const std = @import("std");
const now_playing = @import("now_playing.zig");

const Value = std.json.Value;

pub const default_port = 9090;

/// Kodi is pinged this often while nothing else is said, so that a TV
/// switched off, which says nothing as it goes, is noticed. While something
/// plays, asking how far it is does for the ping.
pub const ping_interval_s = 30;

/// A position further than this from where the panel has counted on to is
/// put right; nearer, it is left alone rather than redrawn for nothing.
const max_drift_ms = 2000;

/// What a reply answers, by the id its request was sent with.
pub const Asked = enum(u8) {
    players = 1,
    labels = 2,
    properties = 3,
    ping = 4,
};

pub const players_request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Player.GetActivePlayers\"}";
pub const ping_request = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"JSONRPC.Ping\"}";

/// The labels asked for: the field of `Labels` each goes in, and the name
/// Kodi gives it.
const label_names = [_][2][]const u8{
    .{ "video_title", "VideoPlayer.Title" },
    .{ "show", "VideoPlayer.TVShowTitle" },
    .{ "season", "VideoPlayer.Season" },
    .{ "episode", "VideoPlayer.Episode" },
    .{ "year", "VideoPlayer.Year" },
    .{ "channel", "VideoPlayer.ChannelName" },
    .{ "music_title", "MusicPlayer.Title" },
    .{ "music_artist", "MusicPlayer.Artist" },
    .{ "player_title", "Player.Title" },
    .{ "poster", "Player.Art(poster)" },
    .{ "show_poster", "Player.Art(tvshow.poster)" },
    .{ "thumb", "Player.Art(thumb)" },
};

pub const labels_request = blk: {
    var list: []const u8 = "";
    for (label_names, 0..) |pair, i| {
        list = list ++ (if (i > 0) "," else "") ++ "\"" ++ pair[1] ++ "\"";
    }
    break :blk "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"XBMC.GetInfoLabels\",\"params\":{\"labels\":[" ++ list ++ "]}}";
};

/// How far the player `player_id` is, and whether it moves.
pub fn writePropertiesRequest(w: *std.Io.Writer, player_id: i64) std.Io.Writer.Error!void {
    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"Player.GetProperties\",\"params\":{{\"playerid\":{d},\"properties\":[\"time\",\"totaltime\",\"speed\",\"live\"]}}}}",
        .{player_id},
    );
}

// ----------------------------------------------------------------------------
// Reading the stream
// ----------------------------------------------------------------------------

/// Where the JSON object at the start of `data` ends, past any whitespace
/// before it: the length of `data` it takes up. Null while it has not all
/// arrived; `error.NotJson` for data that is no object.
pub fn objectEnd(data: []const u8) error{NotJson}!?usize {
    var i: usize = 0;
    while (i < data.len and std.ascii.isWhitespace(data[i])) i += 1;
    if (i == data.len) return null;
    if (data[i] != '{') return error.NotJson;

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return error.NotJson;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// The active player that plays something the panel can show.
pub const Player = struct {
    id: i64,
    kind: Kind,

    pub const Kind = enum { video, audio };
};

/// The labels, as Kodi gave them: borrowed from the parsed reply.
pub const Labels = struct {
    video_title: []const u8 = "",
    show: []const u8 = "",
    season: []const u8 = "",
    episode: []const u8 = "",
    year: []const u8 = "",
    channel: []const u8 = "",
    music_title: []const u8 = "",
    music_artist: []const u8 = "",
    player_title: []const u8 = "",
    poster: []const u8 = "",
    show_poster: []const u8 = "",
    thumb: []const u8 = "",
};

pub const Properties = struct {
    time_ms: i64,
    total_ms: i64,
    /// 1 at normal speed, 0 paused, more fast forward, negative rewinding.
    speed: f64,
    live: bool,
};

/// Where a seek has taken playback, as Kodi says in announcing it.
pub const Seek = struct {
    time_ms: i64,
    speed: f64,
};

pub const Message = union(enum) {
    /// Playback has changed: ask again what plays.
    changed,
    /// Playback has been moved to where `Seek` says. Asking how far it is
    /// would not do: Kodi announces a seek before it is done, and until then
    /// still gives the time from before it.
    seeked: Seek,
    /// Nothing plays any more.
    stopped,
    /// The reply to `players_request`: null when nothing the panel can show
    /// plays.
    players: ?Player,
    labels: Labels,
    properties: Properties,
    pong,
    /// A request of ours that Kodi turned down.
    failed: Asked,
    /// Anything else: a notification of no interest, or a reply to nothing
    /// asked.
    other,
};

pub fn parse(root: Value) Message {
    const obj = object(root) orelse return .other;
    if (string(obj.get("method"))) |method| return notification(method, obj.get("params"));

    const id = integer(obj.get("id")) orelse return .other;
    const asked = std.enums.fromInt(Asked, id) orelse return .other;
    if (obj.get("error") != null) return .{ .failed = asked };
    const result = obj.get("result") orelse return .{ .failed = asked };
    return switch (asked) {
        .players => .{ .players = firstPlayer(result) },
        .labels => .{ .labels = parseLabels(result) },
        .properties => if (parseProperties(result)) |p| .{ .properties = p } else .{ .failed = asked },
        .ping => .pong,
    };
}

fn notification(method: []const u8, params: ?Value) Message {
    if (std.mem.eql(u8, method, "Player.OnSeek")) {
        if (seekOf(params)) |seek| return .{ .seeked = seek };
        return .changed;
    }
    const changes = [_][]const u8{
        "Player.OnPlay",  "Player.OnAVStart", "Player.OnResume",
        "Player.OnPause", "Player.OnSeek",    "Player.OnSpeedChanged",
    };
    for (changes) |name| if (std.mem.eql(u8, method, name)) return .changed;
    const ends = [_][]const u8{ "Player.OnStop", "System.OnQuit", "System.OnSleep" };
    for (ends) |name| if (std.mem.eql(u8, method, name)) return .stopped;
    return .other;
}

/// Where an OnSeek notification's `params` say playback went.
fn seekOf(params: ?Value) ?Seek {
    const outer = object(params) orelse return null;
    const data = object(outer.get("data")) orelse return null;
    const player = object(data.get("player")) orelse return null;
    return .{
        .time_ms = durationMs(player.get("time")) orelse return null,
        .speed = number(player.get("speed")) orelse 1,
    };
}

/// The first player playing video or music; a slideshow has nothing to show
/// beside its pictures.
fn firstPlayer(result: Value) ?Player {
    const players = array(result) orelse return null;
    for (players) |p| {
        const obj = object(p) orelse continue;
        const id = integer(obj.get("playerid")) orelse continue;
        const kind = string(obj.get("type")) orelse continue;
        if (std.mem.eql(u8, kind, "video")) return .{ .id = id, .kind = .video };
        if (std.mem.eql(u8, kind, "audio")) return .{ .id = id, .kind = .audio };
    }
    return null;
}

fn parseLabels(result: Value) Labels {
    const obj = object(result) orelse return .{};
    var labels: Labels = .{};
    inline for (label_names) |pair| {
        @field(labels, pair[0]) = string(obj.get(pair[1])) orelse "";
    }
    return labels;
}

fn parseProperties(result: Value) ?Properties {
    const obj = object(result) orelse return null;
    return .{
        .time_ms = durationMs(obj.get("time")) orelse return null,
        .total_ms = durationMs(obj.get("totaltime")) orelse 0,
        .speed = number(obj.get("speed")) orelse 0,
        .live = boolean(obj.get("live")) orelse false,
    };
}

/// A time as Kodi gives one: hours, minutes, seconds and milliseconds.
fn durationMs(v: ?Value) ?i64 {
    const obj = object(v) orelse return null;
    const hours = integer(obj.get("hours")) orelse 0;
    const minutes = integer(obj.get("minutes")) orelse 0;
    const secs = integer(obj.get("seconds")) orelse 0;
    const ms = integer(obj.get("milliseconds")) orelse 0;
    return std.math.clamp(((hours * 60 + minutes) * 60 + secs) * 1000 + ms, 0, std.math.maxInt(i32) * 1000);
}

// ----------------------------------------------------------------------------
// What plays
// ----------------------------------------------------------------------------

/// Shorter than this, and a length is the part of a live stream Kodi holds,
/// not the length of anything: a stream reports one of a few seconds, and
/// says it is not live.
const min_length_ms = 60_000;

/// What the labels say plays, and where its picture is.
pub const Described = struct {
    track: now_playing.Track,
    /// The address the picture is at, as the labels give it.
    picture: []const u8,
    shape: now_playing.Shape,
};

/// `kind` playing what `labels` say: a song by its artist; an episode by
/// its series, season and number; a channel's programme by the channel; a
/// film by its year.
pub fn describe(kind: Player.Kind, labels: Labels) Described {
    var title_buf: [now_playing.max_text]u8 = undefined;
    var artist_buf: [now_playing.max_text]u8 = undefined;
    var out: Described = .{ .track = .{}, .picture = "", .shape = .square };

    if (kind == .audio) {
        out.track.title = .init(clean(&title_buf, firstOf(labels.music_title, labels.player_title)));
        out.track.artist = .init(clean(&artist_buf, labels.music_artist));
        out.picture = labels.thumb;
    } else {
        out.track.title = .init(clean(&title_buf, firstOf(labels.video_title, labels.player_title)));
        if (labels.show.len > 0) {
            const show = clean(&artist_buf, labels.show);
            var line_buf: [now_playing.max_text]u8 = undefined;
            out.track.artist = .init(episodeLine(&line_buf, show, labels.season, labels.episode));
        } else if (labels.channel.len > 0) {
            out.track.artist = .init(clean(&artist_buf, labels.channel));
        } else if (!std.mem.eql(u8, labels.year, "0")) {
            out.track.artist = .init(clean(&artist_buf, labels.year));
        }

        const poster = if (labels.show.len > 0) firstOf(labels.show_poster, labels.poster) else labels.poster;
        if (poster.len > 0 or labels.thumb.len == 0) {
            out.picture = poster;
            out.shape = .poster;
        } else {
            out.picture = labels.thumb;
        }
    }

    out.track.uri = uriOf(out.track.title.slice(), out.track.artist.slice());
    return out;
}

/// What a description is matched by: the same title by the same artist is
/// the same thing playing.
fn uriOf(title: []const u8, artist: []const u8) now_playing.Text {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(title);
    hasher.update("\x00");
    hasher.update(artist);
    var buf: [21]u8 = undefined;
    const uri = std.fmt.bufPrint(&buf, "kodi:{x:0>16}", .{hasher.final()}) catch unreachable;
    return .init(uri);
}

/// `show` with its season and episode, `S01E06`, where Kodi knows them.
fn episodeLine(buf: []u8, show: []const u8, season: []const u8, episode: []const u8) []const u8 {
    const s = std.fmt.parseInt(i32, season, 10) catch return show;
    const e = std.fmt.parseInt(i32, episode, 10) catch return show;
    if (s < 0 or e <= 0) return show;
    return std.fmt.bufPrint(buf, "{s} S{d:0>2}E{d:0>2}", .{ show, @as(u32, @intCast(s)), @as(u32, @intCast(e)) }) catch show;
}

fn firstOf(a: []const u8, b: []const u8) []const u8 {
    return if (a.len > 0) a else b;
}

/// `text` without the markup Kodi's labels carry for its skins: `[B]`,
/// `[COLOR red]` and their ends, and the like; `[CR]` becomes a space. Any
/// other brackets are part of the text.
pub fn clean(buf: []u8, text: []const u8) []const u8 {
    const tags = [_][]const u8{ "B", "I", "LIGHT", "UPPERCASE", "LOWERCASE", "CAPITALIZE", "COLOR" };
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len and len < buf.len) {
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i, ']')) |close| {
                const inside = text[i + 1 .. close];
                const name = if (inside.len > 0 and inside[0] == '/') inside[1..] else inside;
                const word = name[0 .. std.mem.indexOfScalar(u8, name, ' ') orelse name.len];
                const is_tag = for (tags) |tag| {
                    if (std.ascii.eqlIgnoreCase(word, tag)) break true;
                } else false;
                // Only `[COLOR x]` has anything after its name.
                if (is_tag and (word.len == name.len or std.ascii.eqlIgnoreCase(word, "COLOR"))) {
                    i = close + 1;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(inside, "CR")) {
                    buf[len] = ' ';
                    len += 1;
                    i = close + 1;
                    continue;
                }
            }
        }
        buf[len] = text[i];
        len += 1;
        i += 1;
    }
    // Back to the start of a character, if the end fell inside one.
    if (i < text.len and text[i] & 0xC0 == 0x80) {
        while (len > 0 and buf[len - 1] & 0xC0 == 0x80) len -= 1;
        if (len > 0) len -= 1;
    }
    return buf[0..len];
}

/// Where a picture is to be fetched from.
pub const PictureUrl = struct {
    host: []const u8,
    port: u16,
    /// From its first `/`, as it goes in a request line.
    path: []const u8,
};

/// Where the picture the label `label` names is, if it is on the web over
/// HTTPS: as a plain address, or wrapped as Kodi wraps one,
/// `image://<the address, percent-encoded>/`. Anything else, a file on the
/// box or on a share, is Kodi's alone. The address is copied into `buf`,
/// with anything that cannot go in a request line percent-encoded.
pub fn pictureUrl(buf: []u8, label: []const u8) ?PictureUrl {
    var unwrapped_buf: [2048]u8 = undefined;
    var address = label;
    const wrapper = "image://";
    if (std.mem.startsWith(u8, label, wrapper)) {
        var inner = label[wrapper.len..];
        if (std.mem.endsWith(u8, inner, "/")) inner = inner[0 .. inner.len - 1];
        address = percentDecode(&unwrapped_buf, inner) orelse return null;
    }

    const scheme = "https://";
    if (address.len <= scheme.len or !std.ascii.eqlIgnoreCase(address[0..scheme.len], scheme)) return null;
    const rest = address[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return null;

    var host = authority;
    var port: u16 = 443;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
    }
    if (host.len == 0 or host.len > 253) return null;
    for (host) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return null;
    }

    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(host) catch return null;
    const path = if (slash < rest.len) rest[slash..] else "/";
    for (path) |c| {
        if (c <= ' ' or c >= 0x7F or c == '"' or c == '<' or c == '>' or c == '\\' or c == '^' or c == '`' or c == '{' or c == '|' or c == '}') {
            w.print("%{X:0>2}", .{c}) catch return null;
        } else {
            w.writeByte(c) catch return null;
        }
    }
    const written = w.buffered();
    return .{ .host = written[0..host.len], .port = port, .path = written[host.len..] };
}

fn percentDecode(buf: []u8, text: []const u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (len += 1) {
        if (len == buf.len) return null;
        if (text[i] == '%') {
            if (i + 3 > text.len) return null;
            buf[len] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            buf[len] = text[i];
            i += 1;
        }
    }
    return buf[0..len];
}

/// How far into what `uri` names playback was at `received_ms`, by what Kodi
/// says. A live stream has no length or position worth showing: it counts
/// from `watched_since_ms`, when the client first saw it play.
pub fn playbackOf(uri: now_playing.Text, p: Properties, received_ms: i64, watched_since_ms: i64) now_playing.Playback {
    const live = p.live or p.total_ms < min_length_ms;
    return .{
        .uri = uri,
        .playing = p.speed != 0,
        .position_ms = if (live) @max(0, received_ms - watched_since_ms) else std.math.clamp(p.time_ms, 0, p.total_ms),
        .at_ms = received_ms,
        .duration_ms = if (live) 0 else p.total_ms,
        .speed = if (live) 1 else p.speed,
        .live = live,
    };
}

/// `held` moved to where `seek` says, at `received_ms`. A live stream's time
/// is the panel's own, which a seek in it does not change.
pub fn seeked(held: now_playing.Playback, seek: Seek, received_ms: i64) now_playing.Playback {
    if (held.live) return held;
    var moved = held;
    moved.position_ms = std.math.clamp(seek.time_ms, 0, @max(held.duration_ms, 0));
    moved.at_ms = received_ms;
    moved.playing = seek.speed != 0;
    moved.speed = seek.speed;
    return moved;
}

/// Whether `fresh`, how Kodi says playback stands at `now_ms`, tells the
/// panel anything `held` does not: something else playing, a pause or its
/// end, or a position away from where `held` has been counted on to, as a
/// stream that stalled to buffer leaves it.
pub fn differs(held: ?now_playing.Playback, fresh: now_playing.Playback, now_ms: i64) bool {
    const h = held orelse return true;
    if (!h.uri.eql(&fresh.uri) or h.playing != fresh.playing or h.live != fresh.live) return true;
    if (h.duration_ms != fresh.duration_ms) return true;
    return @abs(h.positionAt(now_ms) - fresh.positionAt(now_ms)) > max_drift_ms;
}

// ----------------------------------------------------------------------------
// Retrying
// ----------------------------------------------------------------------------

/// Seconds to wait before trying again after `failures` attempts in a row
/// have failed: doubling from 5 to 30. Kodi is often away, on a TV that is
/// off, and should be seen soon after it is back.
pub fn backoffSeconds(failures: u32) u32 {
    if (failures == 0) return 0;
    const shift: u5 = @intCast(@min(failures - 1, 3));
    return @min(@as(u32, 5) << shift, 30);
}

// ----------------------------------------------------------------------------
// Reading JSON
// ----------------------------------------------------------------------------

/// By value: a copy of the map shares its entries.
fn object(v: ?Value) ?std.json.ObjectMap {
    return switch (v orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn array(v: ?Value) ?[]const Value {
    return switch (v orelse return null) {
        .array => |a| a.items,
        else => null,
    };
}

fn string(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn boolean(v: ?Value) ?bool {
    return switch (v orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn integer(v: ?Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) std.math.lossyCast(i64, f) else null,
        else => null,
    };
}

fn number(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        else => null,
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
//
// The messages are as Kodi 22 sent them on 2026-10-16, cut to what matters.

const testing = std.testing;

fn parseText(arena: std.mem.Allocator, text: []const u8) !Message {
    return parse(try std.json.parseFromSliceLeaky(Value, arena, text, .{}));
}

test "objects that follow one another with nothing between are told apart" {
    const stream = "{\"a\":\"}\\\"{\"} {\"b\":[1,{\"c\":2}]}{\"d\"";
    const first = (try objectEnd(stream)).?;
    try testing.expectEqualStrings("{\"a\":\"}\\\"{\"}", stream[0..first]);
    const second = first + (try objectEnd(stream[first..])).?;
    try testing.expectEqualStrings(" {\"b\":[1,{\"c\":2}]}", stream[first..second]);
    try testing.expectEqual(@as(?usize, null), try objectEnd(stream[second..]));
    try testing.expectEqual(@as(?usize, null), try objectEnd("  "));
    try testing.expectError(error.NotJson, objectEnd("HTTP/1.1 400"));
}

test "the requests are JSON that asks for what is read back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const labels = try std.json.parseFromSliceLeaky(Value, arena, labels_request, .{});
    const asked = array(object(object(labels).?.get("params")).?.get("labels")).?;
    try testing.expectEqual(label_names.len, asked.len);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePropertiesRequest(&w, 1);
    const properties = try std.json.parseFromSliceLeaky(Value, arena, w.buffered(), .{});
    try testing.expectEqual(@as(?i64, 3), integer(object(properties).?.get("id")));
    _ = try std.json.parseFromSliceLeaky(Value, arena, players_request, .{});
    _ = try std.json.parseFromSliceLeaky(Value, arena, ping_request, .{});
}

test "notifications of a change in playback have it asked again, and a stop ends it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const play =
        \\{"jsonrpc":"2.0","method":"Player.OnPlay","params":{"data":{"item":{"episode":6,"season":1,"showtitle":"Young Sherlock","title":"The Case of the Killing Jar","type":"episode"},"player":{"playerid":1,"speed":1}},"sender":"xbmc"}}
    ;
    try testing.expectEqual(Message.changed, try parseText(arena, play));
    try testing.expectEqual(Message.changed, try parseText(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"Player.OnPause\",\"params\":{}}"));
    // A seek that does not say where to is asked about.
    try testing.expectEqual(Message.changed, try parseText(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"Player.OnSeek\",\"params\":{}}"));
    try testing.expectEqual(Message.changed, try parseText(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"Player.OnSeek\",\"params\":[1]}"));
    try testing.expectEqual(Message.stopped, try parseText(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"Player.OnStop\",\"params\":{}}"));
    // Several of these come for one change; OnAVStart is the one asked on.
    try testing.expectEqual(Message.other, try parseText(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"Player.OnAVChange\",\"params\":{}}"));
    try testing.expectEqual(Message.other, try parseText(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"Playlist.OnAdd\",\"params\":{}}"));
}

test "a seek is taken to where Kodi says it went, not to where asking after it says" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Three minutes back, as Kodi 22 announced it on 2026-10-16.
    const seek = try parseText(arena,
        \\{"jsonrpc":"2.0","method":"Player.OnSeek","params":{"data":{"item":{"title":"Jsou mezi námi","type":"movie","year":2026},"player":{"playerid":1,"seekoffset":{"hours":0,"milliseconds":0,"minutes":-3,"seconds":0},"speed":1,"time":{"hours":0,"milliseconds":262,"minutes":27,"seconds":23}}},"sender":"xbmc"}}
    );
    try testing.expectEqual(@as(i64, 1_643_262), seek.seeked.time_ms);

    const held: now_playing.Playback = .{ .uri = .init("kodi:x"), .playing = true, .position_ms = 1_800_000, .at_ms = 0, .duration_ms = 6_362_000 };
    const moved = seeked(held, seek.seeked, 10_000);
    try testing.expectEqual(@as(i64, 1_643_262), moved.positionAt(10_000));
    try testing.expect(moved.playing);

    // Asking right after, Kodi still gives the time from before the seek;
    // the next ask, half a minute on, gives it right.
    const stale = playbackOf(.init("kodi:x"), .{ .time_ms = 1_810_000, .total_ms = 6_362_000, .speed = 1, .live = false }, 10_000, 0);
    try testing.expect(differs(moved, stale, 10_000));

    var live = held;
    live.live = true;
    try testing.expectEqual(live.position_ms, seeked(live, seek.seeked, 10_000).position_ms);
}

test "what Kodi says of playback is taken only where it differs from what the panel counts" {
    const uri: now_playing.Text = .init("kodi:x");
    const held: now_playing.Playback = .{ .uri = uri, .playing = true, .position_ms = 60_000, .at_ms = 0, .duration_ms = 600_000 };
    const at = struct {
        fn of(u: now_playing.Text, time_ms: i64, speed: f64) now_playing.Playback {
            return playbackOf(u, .{ .time_ms = time_ms, .total_ms = 600_000, .speed = speed, .live = false }, 30_000, 0);
        }
    }.of;

    try testing.expect(differs(null, at(uri, 90_000, 1), 30_000));
    try testing.expect(!differs(held, at(uri, 91_000, 1), 30_000));
    // Stalled for ten seconds to buffer.
    try testing.expect(differs(held, at(uri, 80_000, 1), 30_000));
    try testing.expect(differs(held, at(uri, 90_000, 0), 30_000));
    try testing.expect(differs(held, at(.init("kodi:y"), 90_000, 1), 30_000));
}

test "the active player is the first that plays video or music" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reply = try parseText(arena,
        \\{"id":1,"jsonrpc":"2.0","result":[{"playerid":2,"playertype":"internal","type":"picture"},{"playerid":1,"playertype":"internal","type":"video"}]}
    );
    try testing.expectEqual(Player{ .id = 1, .kind = .video }, reply.players.?);
    try testing.expectEqual(@as(?Player, null), (try parseText(arena, "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":[]}")).players);
}

test "a request Kodi turns down is said to have failed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reply = try parseText(arena,
        \\{"error":{"code":-32602,"message":"Invalid params."},"id":3,"jsonrpc":"2.0"}
    );
    try testing.expectEqual(Asked.properties, reply.failed);
}

test "an episode an add-on plays is told by its series, season and number, beside its poster" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reply = try parseText(arena,
        \\{"id":2,"jsonrpc":"2.0","result":{"MusicPlayer.Artist":"","MusicPlayer.Title":"",
        \\"Player.Art(poster)":"https://img.stream-cinema.online/unsafe/fit-in/800x800/smart/filters:no_upscale():quality(40)/thetvdb.com/banners/v4/series/450633/posters/698506419a288.jpg",
        \\"Player.Art(thumb)":"https://img.stream-cinema.online/unsafe/fit-in/800x800/thetvdb.com/screencap.jpg",
        \\"Player.Art(tvshow.poster)":"","Player.Title":"The Case of the Killing Jar","VideoPlayer.ChannelName":"",
        \\"VideoPlayer.Episode":"6","VideoPlayer.Season":"1","VideoPlayer.TVShowTitle":"Young Sherlock",
        \\"VideoPlayer.Title":"The Case of the Killing Jar","VideoPlayer.Year":"2026"}}
    );
    const described = describe(.video, reply.labels);
    try testing.expectEqualStrings("The Case of the Killing Jar", described.track.title.slice());
    try testing.expectEqualStrings("Young Sherlock S01E06", described.track.artist.slice());
    try testing.expectEqual(now_playing.Shape.poster, described.shape);
    try testing.expect(std.mem.endsWith(u8, described.picture, "698506419a288.jpg"));
}

test "a song is told by its artist, beside its cover" {
    const described = describe(.audio, .{
        .music_title = "Jednou",
        .music_artist = "Vladimír Mišík",
        .thumb = "https://example.com/cover.jpg",
        .poster = "https://example.com/poster.jpg",
    });
    try testing.expectEqualStrings("Jednou", described.track.title.slice());
    try testing.expectEqualStrings("Vladimír Mišík", described.track.artist.slice());
    try testing.expectEqual(now_playing.Shape.square, described.shape);
    try testing.expectEqualStrings("https://example.com/cover.jpg", described.picture);
}

test "a film is told by its year, and a stream with no poster has its thumbnail" {
    const film = describe(.video, .{ .video_title = "Pelíšky", .year = "1999", .poster = "https://example.com/p.jpg" });
    try testing.expectEqualStrings("1999", film.track.artist.slice());
    try testing.expectEqual(now_playing.Shape.poster, film.shape);

    const stream = describe(.video, .{
        .player_title = "[B]Narozeninový Stream[/B] [COLOR yellowgreen]LIVE[/COLOR]",
        .year = "0",
        .thumb = "image://https%3a%2f%2fimages.kick.com%2fvideo_thumbnails%2f480.webp/",
    });
    try testing.expectEqualStrings("Narozeninový Stream LIVE", stream.track.title.slice());
    try testing.expectEqualStrings("", stream.track.artist.slice());
    try testing.expectEqual(now_playing.Shape.square, stream.shape);
}

test "the same thing playing is matched by the same uri, and something else is not" {
    const a = describe(.audio, .{ .music_title = "Jednou", .music_artist = "Mišík" });
    const b = describe(.audio, .{ .music_title = "Jednou", .music_artist = "Mišík" });
    const c = describe(.audio, .{ .music_title = "Dvakrát", .music_artist = "Mišík" });
    try testing.expect(a.track.uri.eql(&b.track.uri));
    try testing.expect(!a.track.uri.eql(&c.track.uri));
}

test "Kodi's markup is taken out of a label, and other brackets are left in" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Young Sherlock - EN+tit (2026)", clean(&buf, "Young Sherlock - [B]EN+tit[/B] (2026)"));
    try testing.expectEqualStrings("a b", clean(&buf, "a[CR]b"));
    try testing.expectEqualStrings("[EN] title", clean(&buf, "[EN] [I]title[/I]"));
    try testing.expectEqualStrings("[unclosed", clean(&buf, "[unclosed"));
    // Cut short at a whole character.
    var small: [2]u8 = undefined;
    try testing.expectEqualStrings("a", clean(&small, "ačb"));
}

test "a picture on the web over HTTPS is found, plain or wrapped, and nothing else is" {
    var buf: [512]u8 = undefined;
    const plain = pictureUrl(&buf, "https://img.stream-cinema.online/unsafe/fit-in/800x800/smart/filters:no_upscale():quality(40)/a.jpg").?;
    try testing.expectEqualStrings("img.stream-cinema.online", plain.host);
    try testing.expectEqual(@as(u16, 443), plain.port);
    try testing.expectEqualStrings("/unsafe/fit-in/800x800/smart/filters:no_upscale():quality(40)/a.jpg", plain.path);

    const wrapped = pictureUrl(&buf, "image://https%3a%2f%2fimage.tmdb.org%3a8443%2ft%2fp%2fw500%2fa%20b.jpg/").?;
    try testing.expectEqualStrings("image.tmdb.org", wrapped.host);
    try testing.expectEqual(@as(u16, 8443), wrapped.port);
    try testing.expectEqualStrings("/t/p/w500/a%20b.jpg", wrapped.path);

    try testing.expectEqual(@as(?PictureUrl, null), pictureUrl(&buf, "http://example.com/a.jpg"));
    try testing.expectEqual(@as(?PictureUrl, null), pictureUrl(&buf, "image://smb%3a%2f%2fnas%2fposter.jpg/"));
    try testing.expectEqual(@as(?PictureUrl, null), pictureUrl(&buf, "/storage/poster.jpg"));
    try testing.expectEqual(@as(?PictureUrl, null), pictureUrl(&buf, "https://user@example.com/a.jpg"));
    try testing.expectEqual(@as(?PictureUrl, null), pictureUrl(&buf, "https://exa mple.com/a.jpg"));
    try testing.expectEqual(@as(?PictureUrl, null), pictureUrl(&buf, "image://https%3a%2f%2fx%2/"));
}

test "a stream with a length of seconds is live, counted from when it was first seen" {
    const uri: now_playing.Text = .init("kodi:x");
    const stream = playbackOf(uri, .{ .time_ms = 7_000, .total_ms = 13_000, .speed = 1, .live = false }, 100_000, 40_000);
    try testing.expect(stream.live and stream.playing);
    try testing.expectEqual(@as(i64, 60_000), stream.position_ms);
    try testing.expectEqual(@as(i64, 0), stream.duration_ms);

    const film = playbackOf(uri, .{ .time_ms = 22_000, .total_ms = 2_879_000, .speed = 0, .live = false }, 100_000, 40_000);
    try testing.expect(!film.live and !film.playing);
    try testing.expectEqual(@as(i64, 22_000), film.position_ms);
    try testing.expectEqual(@as(i64, 2_879_000), film.duration_ms);
}

test "a time as Kodi gives it is read in milliseconds" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reply = try parseText(arena,
        \\{"id":3,"jsonrpc":"2.0","result":{"live":false,"percentage":0.77,"speed":1,"time":{"hours":0,"milliseconds":208,"minutes":0,"seconds":22},"totaltime":{"hours":0,"milliseconds":584,"minutes":47,"seconds":59},"type":"video"}}
    );
    try testing.expectEqual(@as(i64, 22_208), reply.properties.time_ms);
    try testing.expectEqual(@as(i64, 2_879_584), reply.properties.total_ms);
    try testing.expectEqual(@as(f64, 1), reply.properties.speed);
}

test "attempts after a failure wait longer each time, up to half a minute" {
    try testing.expectEqual(@as(u32, 5), backoffSeconds(1));
    try testing.expectEqual(@as(u32, 10), backoffSeconds(2));
    try testing.expectEqual(@as(u32, 30), backoffSeconds(4));
    try testing.expectEqual(@as(u32, 30), backoffSeconds(1000));
}
