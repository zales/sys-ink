//! Spotify's side of the conversation, free of I/O: what is sent, and what
//! is made of what comes back.
//!
//! How the panel learns what is playing is the way librespot does it, with
//! the shortcut its four layers allow: a token from Spotify's own accounts
//! service, issued to the desktop client's ID, opens the WebSocket Spotify
//! pushes playback changes down (the "dealer") directly, without the access
//! point, Login5 and client-token exchanges librespot makes first. The panel
//! then registers as a hidden, non-playing device ("connect state"), which is
//! what has the dealer send it the account's playback, and looks up what a
//! track is called and its cover on its own, since the playing client may
//! leave that out.
//!
//! None of this is a published API. Every step was checked against Spotify
//! itself on 2026-10-15; a change on their side shows up as a warning in the
//! log and the dashboard staying up, never as anything worse.
//!
//! The connection that carries all this is `spotify_client.zig`.

const std = @import("std");
const now_playing = @import("now_playing.zig");

const Value = std.json.Value;

/// The desktop client's ID, the one librespot logs in with. Spotify lets it
/// use the device flow, which is what links a panel with no browser.
pub const client_id = "65b708073fc0480ea92a077233ca87bd";

/// As few as the dealer and the metadata need. Asked for once, at linking.
pub const scopes = "streaming user-read-playback-state user-read-currently-playing user-read-private app-remote-control";

pub const accounts_host = "accounts.spotify.com";
pub const apresolve_host = "apresolve.spotify.com";
pub const image_host = "i.scdn.co";
/// Spotify's embed player, and its oEmbed, both public and without a login:
/// what the player shows, for anything `itemOf` takes.
pub const embed_host = "open.spotify.com";

/// Where the panel is sent to enter its code.
pub const pair_url = "spotify.com/pair";

/// Registers the panel as a device that plays nothing and is hidden from
/// every device list, but is told everything about the account's playback.
pub const register_body =
    \\{"member_type":"CONNECT_STATE","device":{"device_info":{"capabilities":{"can_be_player":false,"hidden":true,"needs_full_player_state":true}}}}
;

/// The dealer drops a connection that has not pinged it for this long.
pub const ping_interval_s = 30;
pub const ping_message = "{\"type\":\"ping\"}";

// ----------------------------------------------------------------------------
// Requests
// ----------------------------------------------------------------------------

/// `pairs` as an `application/x-www-form-urlencoded` body.
pub fn writeForm(w: *std.Io.Writer, pairs: []const [2][]const u8) std.Io.Writer.Error!void {
    for (pairs, 0..) |pair, i| {
        if (i > 0) try w.writeByte('&');
        try writeEscaped(w, pair[0]);
        try w.writeByte('=');
        try writeEscaped(w, pair[1]);
    }
}

/// `text` escaped for a form body or a query string.
pub fn writeEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
            ' ' => try w.writeByte('+'),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
}

/// A track's or an episode's ID in base 62, as its URI has it, in the hex
/// of the 16 bytes it stands for, as the metadata service wants it.
pub fn gidHex(id: []const u8) ?[32]u8 {
    if (id.len == 0 or id.len > 22) return null;
    var n: u128 = 0;
    for (id) |c| {
        const digit: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 36,
            else => return null,
        };
        n = std.math.mul(u128, n, 62) catch return null;
        n = std.math.add(u128, n, digit) catch return null;
    }
    var hex: [32]u8 = undefined;
    _ = std.mem.print(&hex, "{x:0>32}", .{n}) catch unreachable;
    return hex;
}

pub const Item = struct {
    kind: enum { track, episode },
    id: []const u8,

    /// The path to look it up at on the metadata service.
    pub fn metadataPath(self: Item, buf: []u8) ?[]const u8 {
        const gid = gidHex(self.id) orelse return null;
        return std.mem.print(buf, "/metadata/4/{t}/{s}?market=from_token", .{ self.kind, &gid }) catch null;
    }
};

/// What a playing URI is, when it is one whose metadata can be looked up:
/// an advert or a local file has none.
pub fn itemOf(uri: []const u8) ?Item {
    var parts = std.mem.splitScalar(u8, uri, ':');
    if (!std.mem.eql(u8, parts.next() orelse return null, "spotify")) return null;
    const kind = parts.next() orelse return null;
    const id = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (std.mem.eql(u8, kind, "track")) return .{ .kind = .track, .id = id };
    if (std.mem.eql(u8, kind, "episode")) return .{ .kind = .episode, .id = id };
    return null;
}

/// The path of `item`'s page in the embed player.
pub fn embedPagePath(buf: []u8, item: Item) ?[]const u8 {
    return std.mem.print(buf, "/embed/{t}/{s}", .{ item.kind, item.id }) catch null;
}

/// The JSON the embed player's page is built from, which is what it shows:
/// the contents of its one `__NEXT_DATA__` script.
pub fn embedPageData(html: []const u8) ?[]const u8 {
    const open = "<script id=\"__NEXT_DATA__\" type=\"application/json\">";
    const start = (std.mem.indexOf(u8, html, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, html, start, "</script>") orelse return null;
    return html[start..end];
}

/// The path to ask oEmbed about `uri` at.
pub fn embedPath(buf: []u8, uri: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("/oembed?url=") catch return null;
    writeEscaped(&w, uri) catch return null;
    return w.buffered();
}

/// The path of a cover on the image host.
pub fn imagePath(buf: []u8, file_id: []const u8) ?[]const u8 {
    return std.mem.print(buf, "/image/{s}", .{file_id}) catch null;
}

// ----------------------------------------------------------------------------
// Replies from the accounts service
// ----------------------------------------------------------------------------

/// A code for the user to enter, and what to poll for the outcome with.
pub const DeviceCode = struct {
    device_code: []const u8,
    user_code: []const u8,
    expires_in: u32,
    interval: u32,
};

pub fn parseDeviceCode(root: Value) ?DeviceCode {
    const obj = object(root) orelse return null;
    return .{
        .device_code = string(obj.get("device_code")) orelse return null,
        .user_code = string(obj.get("user_code")) orelse return null,
        .expires_in = std.math.cast(u32, integer(obj.get("expires_in")) orelse 600) orelse 600,
        .interval = std.math.cast(u32, @max(1, integer(obj.get("interval")) orelse 5)) orelse 5,
    };
}

pub const Token = struct {
    access_token: []const u8,
    expires_in: u32,
    /// A refresh may hand back a new one, after which the old one is no good.
    refresh_token: ?[]const u8,
};

/// What the token endpoint said.
pub const TokenReply = union(enum) {
    token: Token,
    /// The code has not been entered yet; ask again.
    pending,
    /// Asked too often; ask again, less often.
    slow_down,
    /// Anything else, by the name the endpoint gave it: `invalid_grant` for
    /// a refresh token that has been revoked, `expired_token` for a code that
    /// ran out.
    failed: []const u8,
};

pub fn parseTokenReply(root: Value) TokenReply {
    const obj = object(root) orelse return .{ .failed = "malformed reply" };
    if (string(obj.get("access_token"))) |access| {
        return .{ .token = .{
            .access_token = access,
            .expires_in = std.math.cast(u32, integer(obj.get("expires_in")) orelse 3600) orelse 3600,
            .refresh_token = string(obj.get("refresh_token")),
        } };
    }
    const err = string(obj.get("error")) orelse return .{ .failed = "malformed reply" };
    if (std.mem.eql(u8, err, "authorization_pending")) return .pending;
    if (std.mem.eql(u8, err, "slow_down")) return .slow_down;
    return .{ .failed = err };
}

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

pub const Hosts = struct {
    dealer: HostPort,
    spclient: HostPort,
};

/// The first dealer and spclient the access-point resolver offers.
pub fn parseHosts(root: Value) ?Hosts {
    const obj = object(root) orelse return null;
    return .{
        .dealer = firstHost(obj.get("dealer")) orelse return null,
        .spclient = firstHost(obj.get("spclient")) orelse return null,
    };
}

fn firstHost(list: ?Value) ?HostPort {
    const items = array(list) orelse return null;
    if (items.len == 0) return null;
    const entry = string(items[0]) orelse return null;
    const colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return .{ .host = entry, .port = 443 };
    const port = std.fmt.parseInt(u16, entry[colon + 1 ..], 10) catch return null;
    if (colon == 0) return null;
    return .{ .host = entry[0..colon], .port = port };
}

// ----------------------------------------------------------------------------
// The dealer
// ----------------------------------------------------------------------------

pub const DealerMessage = union(enum) {
    /// The first message on a connection: what to register the device under.
    connection_id: []const u8,
    /// The account's playback, as connect state has it.
    cluster: Value,
    pong,
    /// Anything else, by its URI.
    other: []const u8,
};

pub fn parseDealer(root: Value) ?DealerMessage {
    const obj = object(root) orelse return null;
    const kind = string(obj.get("type")) orelse return null;
    if (std.mem.eql(u8, kind, "pong")) return .pong;
    const uri = string(obj.get("uri")) orelse return .{ .other = kind };

    if (std.mem.startsWith(u8, uri, "hm://pusher/v1/connections/")) {
        const headers = object(obj.get("headers")) orelse return null;
        const id = headerValue(&headers, "Spotify-Connection-Id") orelse return null;
        return .{ .connection_id = id };
    }
    if (std.mem.eql(u8, uri, "hm://connect-state/v1/cluster")) {
        const payloads = array(obj.get("payloads")) orelse return null;
        if (payloads.len == 0) return null;
        // Registered with JSON, the update is JSON. A string here would be the
        // gzipped protobuf a player registers for, which this never asks for.
        const update = object(payloads[0]) orelse return null;
        return .{ .cluster = update.get("cluster") orelse return null };
    }
    return .{ .other = uri };
}

fn headerValue(headers: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return string(entry.value_ptr.*);
    }
    return null;
}

/// The playback a cluster describes, as it stood when it was received at
/// `received_ms`. Null when nothing is playing anywhere on the account.
///
/// The position comes with the server's time of measuring it and the
/// server's time of sending, so how far it has moved on by arrival is told
/// by the server's clock alone, and the panel's own clock never has to agree
/// with Spotify's.
pub fn playbackFromCluster(cluster: Value, received_ms: i64) ?now_playing.Playback {
    const c = object(cluster) orelse return null;
    const state = object(c.get("player_state")) orelse return null;
    const track = object(state.get("track")) orelse return null;
    const uri = string(track.get("uri")) orelse return null;
    if (uri.len == 0) return null;
    const active = string(c.get("active_device_id")) orelse "";
    if (active.len == 0) return null;

    const is_playing = boolean(state.get("is_playing")) orelse false;
    const is_paused = boolean(state.get("is_paused")) orelse false;
    const playing = is_playing and !is_paused;
    const speed = number(state.get("playback_speed")) orelse 1;
    const duration = @max(0, integer(state.get("duration")) orelse 0);

    var position = integer(state.get("position_as_of_timestamp")) orelse 0;
    if (playing) {
        const measured = integer(state.get("timestamp"));
        const sent = integer(c.get("server_timestamp_ms"));
        if (measured != null and sent != null and sent.? > measured.?) {
            const elapsed: f64 = @floatFromInt(sent.? - measured.?);
            position += @intFromFloat(@min(elapsed * std.math.clamp(speed, 0, 4), 1e12));
        }
    }

    return .{
        .uri = .init(uri),
        .playing = playing,
        .position_ms = std.math.clamp(position, 0, duration),
        .at_ms = received_ms,
        .duration_ms = duration,
        .speed = speed,
    };
}

// ----------------------------------------------------------------------------
// Metadata
// ----------------------------------------------------------------------------

/// What the metadata service says of a track or an episode.
pub const Described = struct {
    track: now_playing.Track,
    /// The hex ID of the cover closest to the size drawn, if there is one.
    cover: ?[40]u8,
};

pub fn describe(item: Item, uri: []const u8, root: Value) ?Described {
    const obj = object(root) orelse return null;
    var out: Described = .{ .track = .{ .uri = .init(uri) }, .cover = null };
    out.track.title = .init(string(obj.get("name")) orelse "");

    var images: []const Value = &.{};
    switch (item.kind) {
        .track => {
            var artists: [now_playing.max_text]u8 = undefined;
            var w: std.Io.Writer = .fixed(&artists);
            for (array(obj.get("artist")) orelse &.{}, 0..) |artist, i| {
                const name = string(field(artist, "name")) orelse continue;
                if (i > 0) w.writeAll(", ") catch break;
                w.writeAll(name) catch break;
            }
            out.track.artist = .init(w.buffered());
            const album = obj.get("album");
            out.track.album = .init(string(field(album, "name")) orelse "");
            images = array(field(field(album, "cover_group"), "image")) orelse &.{};
        },
        .episode => {
            const show = obj.get("show");
            out.track.artist = .init(string(field(show, "name")) orelse "");
            images = array(field(obj.get("cover_image"), "image")) orelse
                array(field(field(show, "cover_image"), "image")) orelse &.{};
        },
    }
    out.cover = pickCover(images);
    return out;
}

/// What oEmbed says of `uri`: its title and its cover, and no more. Used for
/// what the metadata service does not know, which is the case for some
/// podcast episodes; it has no artist, and for an episode not its show.
pub fn describeEmbed(uri: []const u8, root: Value) ?Described {
    const obj = object(root) orelse return null;
    const title = string(obj.get("title")) orelse return null;
    var out: Described = .{ .track = .{ .uri = .init(uri), .title = .init(title) }, .cover = null };

    if (string(obj.get("thumbnail_url"))) |url| out.cover = coverIdOf(url);
    return out;
}

/// What the embed player shows of `uri`: its title, the line beneath it, which
/// is the artists of a track and the show of an episode, and its cover. Used
/// for what the metadata service does not know, which is the case for some
/// podcast episodes.
pub fn describeEmbedPage(uri: []const u8, root: Value) ?Described {
    const entity = field(field(field(field(field(root, "props"), "pageProps"), "state"), "data"), "entity");
    const obj = object(entity) orelse return null;
    const title = string(obj.get("title")) orelse string(obj.get("name")) orelse return null;
    var out: Described = .{ .track = .{ .uri = .init(uri), .title = .init(title) }, .cover = null };

    if (string(obj.get("subtitle"))) |subtitle| {
        out.track.artist = .init(subtitle);
    } else {
        var artists: [now_playing.max_text]u8 = undefined;
        var w: std.Io.Writer = .fixed(&artists);
        for (array(obj.get("artists")) orelse &.{}, 0..) |artist, i| {
            const name = string(field(artist, "name")) orelse continue;
            if (i > 0) w.writeAll(", ") catch break;
            w.writeAll(name) catch break;
        }
        out.track.artist = .init(w.buffered());
    }

    // The nearest to the size drawn, as `pickCover` chooses; larger rather
    // than smaller.
    var best_distance: i64 = std.math.maxInt(i64);
    for (array(field(obj.get("visualIdentity"), "image")) orelse &.{}) |image| {
        const id = coverIdOf(string(field(image, "url")) orelse continue) orelse continue;
        const width = integer(field(image, "maxWidth")) orelse 300;
        const distance = if (width >= now_playing.cover_side) width - now_playing.cover_side else 4 * (now_playing.cover_side - width);
        if (distance < best_distance) {
            best_distance = distance;
            out.cover = id;
        }
    }
    return out;
}

/// The cover's ID an image address ends in: the image host serves it as well
/// as the CDN the address names.
fn coverIdOf(url: []const u8) ?[40]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    const id = url[slash + 1 ..];
    return if (isFileId(id)) id[0..40].* else null;
}

/// Forty hex digits, as a cover's ID is: it goes into a URL path.
fn isFileId(id: []const u8) bool {
    if (id.len != 40) return false;
    for (id) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The cover nearest in size to the one drawn: 300 pixels is `DEFAULT`, and
/// the panel's is 128.
fn pickCover(images: []const Value) ?[40]u8 {
    var best: ?[40]u8 = null;
    var best_distance: i64 = std.math.maxInt(i64);
    images: for (images) |image| {
        const id = string(field(image, "file_id")) orelse continue;
        if (!isFileId(id)) continue :images;
        const width = integer(field(image, "width")) orelse 300;
        // Smaller than drawn is upscaled and blurs; prefer larger.
        const distance = if (width >= now_playing.cover_side) width - now_playing.cover_side else 4 * (now_playing.cover_side - width);
        if (distance < best_distance) {
            best_distance = distance;
            best = id[0..40].*;
        }
    }
    return best;
}

// ----------------------------------------------------------------------------
// What is kept between runs
// ----------------------------------------------------------------------------

/// The link to an account, kept in the state file: the refresh token, and
/// the ID the panel registers under, the same every time, so the account
/// does not collect a hidden device per restart.
pub const State = struct {
    refresh_token: []const u8,
    device_id: []const u8,
};

pub fn parseState(root: Value) ?State {
    const obj = object(root) orelse return null;
    const token = string(obj.get("refresh_token")) orelse return null;
    const device = string(obj.get("device_id")) orelse return null;
    if (token.len == 0 or device.len == 0) return null;
    return .{ .refresh_token = token, .device_id = device };
}

pub fn writeState(w: *std.Io.Writer, state: State) std.Io.Writer.Error!void {
    try w.print("{f}\n", .{std.json.fmt(state, .{})});
}

/// A device ID of the kind the web player gives a hidden observer.
pub fn newDeviceId(random: [20]u8) [45]u8 {
    var id: [45]u8 = undefined;
    _ = std.mem.print(&id, "hobs_{x}", .{&random}) catch unreachable;
    return id;
}

// ----------------------------------------------------------------------------
// Retrying
// ----------------------------------------------------------------------------

/// Seconds to wait before trying again after `failures` attempts in a row
/// have failed: doubling from 5 to a ceiling of 5 minutes.
pub fn backoffSeconds(failures: u32) u32 {
    if (failures == 0) return 0;
    const shift: u5 = @intCast(@min(failures - 1, 6));
    return @min(@as(u32, 5) << shift, 300);
}

// ----------------------------------------------------------------------------
// Reading JSON leniently
// ----------------------------------------------------------------------------
//
// Spotify writes 64-bit numbers as strings, as protobuf's JSON mapping does,
// and not always: each of these takes whatever form a value turns up in.

/// By value: a copy of the map shares its entries, and a pointer into `v`
/// would point into this function's own copy of it.
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

fn field(v: ?Value, name: []const u8) ?Value {
    const obj = object(v) orelse return null;
    return obj.get(name);
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
        .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn number(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
//
// The replies here are shaped as Spotify's were on 2026-10-15, cut down to
// what is read, with the names changed.

const testing = std.testing;

fn parse(arena: *std.heap.ArenaAllocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena.allocator(), text, .{});
}

test "a form body escapes what a token can contain" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeForm(&w, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", "AQ+b/c=d e" } });
    try testing.expectEqualStrings("grant_type=refresh_token&refresh_token=AQ%2Bb%2Fc%3Dd+e", w.buffered());
}

test "a base-62 ID turns into the hex the metadata service wants" {
    // From a real track: spotify:track:2xuBAESQMeELjRS53SUTTL.
    try testing.expectEqualStrings("5376b1961ed442249175c443ba083ddd", &gidHex("2xuBAESQMeELjRS53SUTTL").?);
    try testing.expectEqualStrings("00000000000000000000000000000000", &gidHex("0").?);
    try testing.expect(gidHex("not-base62") == null);
    try testing.expect(gidHex("") == null);
    // Too large for 128 bits.
    try testing.expect(gidHex("zzzzzzzzzzzzzzzzzzzzzz") == null);
}

test "only tracks and episodes are looked up" {
    var buf: [128]u8 = undefined;
    const track = itemOf("spotify:track:2xuBAESQMeELjRS53SUTTL").?;
    try testing.expectEqualStrings(
        "/metadata/4/track/5376b1961ed442249175c443ba083ddd?market=from_token",
        track.metadataPath(&buf).?,
    );
    try testing.expect(itemOf("spotify:episode:1tIXasAZVfCgPHoHQTBqkv").?.kind == .episode);
    try testing.expect(itemOf("spotify:ad:123") == null);
    try testing.expect(itemOf("spotify:local:Artist:Album:Title:200") == null);
    try testing.expect(itemOf("") == null);
}

test "a device code and the replies to polling for it are read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const code = parseDeviceCode(try parse(&arena,
        \\{"device_code":"QUJD","user_code":"ABCDEF","verification_uri":"https://spotify.com/pair","expires_in":3599,"interval":5}
    )).?;
    try testing.expectEqualStrings("ABCDEF", code.user_code);
    try testing.expectEqual(@as(u32, 3599), code.expires_in);
    try testing.expectEqual(@as(u32, 5), code.interval);

    try testing.expectEqual(TokenReply.pending, parseTokenReply(try parse(&arena, "{\"error\":\"authorization_pending\"}")));
    try testing.expectEqual(TokenReply.slow_down, parseTokenReply(try parse(&arena, "{\"error\":\"slow_down\"}")));
    try testing.expectEqualStrings("invalid_grant", parseTokenReply(try parse(&arena, "{\"error\":\"invalid_grant\",\"error_description\":\"Refresh token revoked\"}")).failed);

    const token = parseTokenReply(try parse(&arena,
        \\{"access_token":"BQx","token_type":"Bearer","expires_in":3600,"refresh_token":"AQy","scope":"streaming"}
    )).token;
    try testing.expectEqualStrings("BQx", token.access_token);
    try testing.expectEqualStrings("AQy", token.refresh_token.?);

    // A refresh need not hand back a new refresh token.
    const refreshed = parseTokenReply(try parse(&arena, "{\"access_token\":\"BQz\",\"expires_in\":3600}")).token;
    try testing.expect(refreshed.refresh_token == null);
}

test "the dealer and spclient are the first the resolver offers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hosts = parseHosts(try parse(&arena,
        \\{"dealer":["gew4-dealer.spotify.com:443","gew1-dealer.spotify.com:443"],"spclient":["gew4-spclient.spotify.com:443"]}
    )).?;
    try testing.expectEqualStrings("gew4-dealer.spotify.com", hosts.dealer.host);
    try testing.expectEqual(@as(u16, 443), hosts.dealer.port);
    try testing.expectEqualStrings("gew4-spclient.spotify.com", hosts.spclient.host);
    try testing.expect(parseHosts(try parse(&arena, "{\"dealer\":[]}")) == null);
}

test "dealer messages are told apart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const hello = parseDealer(try parse(&arena,
        \\{"headers":{"Spotify-Connection-Id":"Y29ubg=="},"method":"PUT","type":"message","uri":"hm://pusher/v1/connections/Y29ubg%3D%3D"}
    )).?;
    try testing.expectEqualStrings("Y29ubg==", hello.connection_id);

    try testing.expectEqual(DealerMessage.pong, parseDealer(try parse(&arena, "{\"type\":\"pong\"}")).?);

    const resume_point = parseDealer(try parse(&arena,
        \\{"headers":{"Content-Type":"application/json"},"type":"message","uri":"hm://herodotus/uri/spotify:episode:x/resume-point-revision/y"}
    )).?;
    try testing.expect(std.mem.startsWith(u8, resume_point.other, "hm://herodotus/"));

    const update = parseDealer(try parse(&arena,
        \\{"headers":{"content-type":"application/json"},"payloads":[{"cluster":{"active_device_id":"d"},"update_reason":"DEVICE_STATE_CHANGED"}],"type":"message","uri":"hm://connect-state/v1/cluster"}
    )).?;
    try testing.expectEqualStrings("d", update.cluster.object.get("active_device_id").?.string);
}

const cluster_playing =
    \\{"timestamp":"1792098938842","active_device_id":"dev1","server_timestamp_ms":"1792098940842",
    \\ "player_state":{"timestamp":"1792098938842","track":{"uri":"spotify:track:59LpCBnYnt4nopjZNMhhPD","metadata":{}},
    \\  "playback_speed":1,"position_as_of_timestamp":"66","duration":"232484","is_playing":true,"is_paused":false}}
;

test "a playing cluster's position is carried to the moment it arrived by the server's clock" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = playbackFromCluster(try parse(&arena, cluster_playing), 50_000).?;
    try testing.expectEqualStrings("spotify:track:59LpCBnYnt4nopjZNMhhPD", p.uri.slice());
    try testing.expect(p.playing);
    // Measured at 66 ms, sent two seconds later.
    try testing.expectEqual(@as(i64, 2066), p.position_ms);
    try testing.expectEqual(@as(i64, 50_000), p.at_ms);
    try testing.expectEqual(@as(i64, 232_484), p.duration_ms);
}

test "a paused cluster stays where it stopped, and one with nothing active is nothing playing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const paused =
        \\{"active_device_id":"dev1","server_timestamp_ms":"2000",
        \\ "player_state":{"timestamp":"1000","track":{"uri":"spotify:track:a"},
        \\  "position_as_of_timestamp":"24778","duration":"3190700","is_playing":true,"is_paused":true}}
    ;
    const p = playbackFromCluster(try parse(&arena, paused), 0).?;
    try testing.expect(!p.playing);
    try testing.expectEqual(@as(i64, 24_778), p.position_ms);

    const idle =
        \\{"player_state":{"track":{"uri":"spotify:track:a"},"is_playing":false}}
    ;
    try testing.expect(playbackFromCluster(try parse(&arena, idle), 0) == null);
    try testing.expect(playbackFromCluster(try parse(&arena, "{}"), 0) == null);
    try testing.expect(playbackFromCluster(try parse(&arena, "[1,2]"), 0) == null);
}

test "a track is described by its name, its artists, its album and its cover" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const metadata =
        \\{"gid":"5376b1961ed442249175c443ba083ddd","name":"Vzpomínka na samotu","duration":226357,
        \\ "artist":[{"gid":"1","name":"Vladimír Mišík"},{"gid":"2","name":"Etc..."}],
        \\ "album":{"name":"Jednou tě potkám","cover_group":{"image":[
        \\  {"file_id":"ab67616d00001e0277e21f6b2edcdceb7c828c34","size":"DEFAULT","width":300,"height":300},
        \\  {"file_id":"ab67616d0000485177e21f6b2edcdceb7c828c34","size":"SMALL","width":64,"height":64},
        \\  {"file_id":"ab67616d0000b27377e21f6b2edcdceb7c828c34","size":"LARGE","width":640,"height":640}]}}}
    ;
    const uri = "spotify:track:2xuBAESQMeELjRS53SUTTL";
    const d = describe(itemOf(uri).?, uri, try parse(&arena, metadata)).?;
    try testing.expectEqualStrings("Vzpomínka na samotu", d.track.title.slice());
    try testing.expectEqualStrings("Vladimír Mišík, Etc...", d.track.artist.slice());
    try testing.expectEqualStrings("Jednou tě potkám", d.track.album.slice());
    try testing.expectEqualStrings(uri, d.track.uri.slice());
    try testing.expectEqualStrings("ab67616d00001e0277e21f6b2edcdceb7c828c34", &d.cover.?);
}

test "an episode is described by its show, and its own cover or the show's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const metadata =
        \\{"name":"#09: Something","show":{"name":"PALICKA!","cover_image":{"image":[
        \\  {"file_id":"ab6765630000ba8afee814c90bc9c45b8a405ff0","size":"DEFAULT","width":300}]}}}
    ;
    const uri = "spotify:episode:1tIXasAZVfCgPHoHQTBqkv";
    const d = describe(itemOf(uri).?, uri, try parse(&arena, metadata)).?;
    try testing.expectEqualStrings("#09: Something", d.track.title.slice());
    try testing.expectEqualStrings("PALICKA!", d.track.artist.slice());
    try testing.expectEqualStrings("ab6765630000ba8afee814c90bc9c45b8a405ff0", &d.cover.?);
}

test "a cover ID that is not one is not used" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const metadata =
        \\{"name":"x","album":{"cover_group":{"image":[{"file_id":"../../etc/passwd","width":300}]}}}
    ;
    const uri = "spotify:track:2xuBAESQMeELjRS53SUTTL";
    try testing.expect(describe(itemOf(uri).?, uri, try parse(&arena, metadata)).?.cover == null);
}

test "the embed player's page gives an episode its show, and a track its artists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buf: [128]u8 = undefined;
    const episode_uri = "spotify:episode:4XtgZryCRAoEd1wEMbwgXf";
    try testing.expectEqualStrings("/embed/episode/4XtgZryCRAoEd1wEMbwgXf", embedPagePath(&buf, itemOf(episode_uri).?).?);

    // Cut down from the page as it was on 2026-10-16.
    const page =
        \\<!DOCTYPE html><html><head><title>Spotify Embed</title></head><body>
        \\<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{
        \\"type":"episode","name":"Film: Street Fighter - 40 %","title":"Film: Street Fighter - 40 %","subtitle":"Fukocast",
        \\"visualIdentity":{"image":[
        \\{"url":"https://image-cdn-fa.spotifycdn.com/image/ab67656300005f1f6eb6e6843ae20c040fd87832","maxWidth":300},
        \\{"url":"https://image-cdn-fa.spotifycdn.com/image/ab6765630000ba8a6eb6e6843ae20c040fd87832","maxWidth":640},
        \\{"url":"https://image-cdn-fa.spotifycdn.com/image/ab6765630000f68d6eb6e6843ae20c040fd87832","maxWidth":64}]}}}}}}}</script>
        \\</body></html>
    ;
    const json = embedPageData(page).?;
    const episode = describeEmbedPage(episode_uri, try parse(&arena, json)).?;
    try testing.expectEqualStrings("Film: Street Fighter - 40 %", episode.track.title.slice());
    try testing.expectEqualStrings("Fukocast", episode.track.artist.slice());
    try testing.expectEqualStrings("ab67656300005f1f6eb6e6843ae20c040fd87832", &episode.cover.?);

    const track_uri = "spotify:track:2xuBAESQMeELjRS53SUTTL";
    const track = describeEmbedPage(track_uri, try parse(&arena,
        \\{"props":{"pageProps":{"state":{"data":{"entity":{"type":"track","title":"Vzpomínka na samotu",
        \\"artists":[{"name":"Vladimír Mišík"},{"name":"Etc..."}],"visualIdentity":{"image":[]}}}}}}}
    )).?;
    try testing.expectEqualStrings("Vladimír Mišík, Etc...", track.track.artist.slice());
    try testing.expect(track.cover == null);

    try testing.expect(embedPageData("<html>no data</html>") == null);
    try testing.expect(describeEmbedPage(track_uri, try parse(&arena, "{\"props\":{}}")) == null);
}

test "oEmbed gives an episode its title and cover, and nothing that is not an ID becomes a path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const uri = "spotify:episode:4XtgZryCRAoEd1wEMbwgXf";

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/oembed?url=spotify%3Aepisode%3A4XtgZryCRAoEd1wEMbwgXf", embedPath(&buf, uri).?);

    const d = describeEmbed(uri, try parse(&arena,
        \\{"title":"Film: Street Fighter - 40 %","thumbnail_url":"https://image-cdn-ak.spotifycdn.com/image/ab67656300005f1f6eb6e6843ae20c040fd87832","type":"rich"}
    )).?;
    try testing.expectEqualStrings("Film: Street Fighter - 40 %", d.track.title.slice());
    try testing.expectEqualStrings("", d.track.artist.slice());
    try testing.expectEqualStrings(uri, d.track.uri.slice());
    try testing.expectEqualStrings("ab67656300005f1f6eb6e6843ae20c040fd87832", &d.cover.?);

    const odd = describeEmbed(uri, try parse(&arena,
        \\{"title":"x","thumbnail_url":"https://example.com/image/../../etc/passwd"}
    )).?;
    try testing.expect(odd.cover == null);
    try testing.expect(describeEmbed(uri, try parse(&arena, "{\"type\":\"rich\"}")) == null);
}

test "the state file is read back as it was written" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeState(&w, .{ .refresh_token = "AQ\"x", .device_id = "hobs_00" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const state = parseState(try parse(&arena, w.buffered())).?;
    try testing.expectEqualStrings("AQ\"x", state.refresh_token);
    try testing.expectEqualStrings("hobs_00", state.device_id);
    try testing.expect(parseState(try parse(&arena, "{\"refresh_token\":\"\",\"device_id\":\"x\"}")) == null);
}

test "a device ID is hobs_ and forty hex digits" {
    const id = newDeviceId(@splat(0xAB));
    try testing.expect(std.mem.startsWith(u8, &id, "hobs_abab"));
    try testing.expectEqual(@as(usize, 45), id.len);
}

test "retries back off from five seconds to five minutes" {
    try testing.expectEqual(@as(u32, 0), backoffSeconds(0));
    try testing.expectEqual(@as(u32, 5), backoffSeconds(1));
    try testing.expectEqual(@as(u32, 10), backoffSeconds(2));
    try testing.expectEqual(@as(u32, 160), backoffSeconds(6));
    try testing.expectEqual(@as(u32, 300), backoffSeconds(7));
    try testing.expectEqual(@as(u32, 300), backoffSeconds(1000));
}
