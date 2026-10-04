//! The HTTP API, served beside the panel preview when `WEB_PREVIEW` is on.
//!
//!     GET    /api/status   the latest readings, as JSON
//!     POST   /api/notice   put a notice on the panel
//!     DELETE /api/notice   take the notice on show down
//!
//! This module is the I/O-free half — which route a request is, whether it
//! may use it, and what the status looks like — so all of it runs under the
//! unit tests. `web_preview.zig` does the serving.
//!
//! ## Who may do what
//!
//! Reading is as open as the preview itself: `/api/status` carries nothing the
//! frame does not already show. Writing needs `WEB_API_TOKEN`, sent as
//! `Authorization: Bearer <token>`, and without a token configured the notice
//! routes stay shut — the preview listening on a port is not a decision to let
//! whoever reaches it write on the panel. `NOTIFY_ENABLED=false` shuts them
//! too, as it does the pipe and MQTT.
//!
//! A notice body is whatever the pipe and MQTT take: plain text, or JSON as
//! `notice.parse` describes.

const std = @import("std");
const http_request = @import("http_request.zig");
const notice = @import("notice.zig");

/// Longest notice body accepted. The same room the pipe gives a notice.
pub const max_notice_body = 4096;

pub const Route = enum {
    page,
    frame,
    status,
    post_notice,
    delete_notice,
    /// A known path, but not with that method.
    method_not_allowed,
    not_found,
};

pub fn route(method: http_request.Method, path: []const u8) Route {
    const eql = std.mem.eql;
    if (eql(u8, path, "/")) return if (method == .get) .page else .method_not_allowed;
    if (eql(u8, path, "/frame.bmp")) return if (method == .get) .frame else .method_not_allowed;
    if (eql(u8, path, "/api/status")) return if (method == .get) .status else .method_not_allowed;
    if (eql(u8, path, "/api/notice")) return switch (method) {
        .post => .post_notice,
        .delete => .delete_notice,
        else => .method_not_allowed,
    };
    return .not_found;
}

/// The `Allow` header for a `method_not_allowed` answer on `path`.
pub fn allowedMethods(path: []const u8) []const u8 {
    return if (std.mem.eql(u8, path, "/api/notice")) "POST, DELETE" else "GET";
}

pub const Options = struct {
    /// Bearer token the notice routes demand. Null or empty: they are shut.
    token: ?[]const u8 = null,
    notices_enabled: bool = true,

    pub fn acceptsNotices(self: Options) bool {
        const token = self.token orelse return false;
        return self.notices_enabled and token.len > 0;
    }
};

pub const NoticeOutcome = union(enum) {
    /// Hand this to the main loop, which reads it as any other notice.
    accepted: []const u8,
    /// No token configured, or notices turned off.
    disabled,
    unauthorized,
    /// Plain text with nothing visible in it, which would do nothing.
    empty,
};

/// What becomes of a request to one of the notice routes.
///
/// The body is parsed here only to turn away one that would do nothing, so
/// the sender hears about it; the main loop parses it again when it applies it,
/// as it does for the pipe and MQTT.
pub fn noticeRequest(options: Options, route_: Route, request: http_request.Request) NoticeOutcome {
    if (!options.acceptsNotices()) return .disabled;
    if (!authorized(request.authorization, options.token.?)) return .unauthorized;

    return switch (route_) {
        // The dismissal every other source already understands.
        .delete_notice => .{ .accepted = "{\"text\": \"\"}" },
        .post_notice => blk: {
            var scratch: [8192]u8 = undefined;
            break :blk if (notice.parse(&scratch, request.body) == null) .empty else .{ .accepted = request.body };
        },
        else => unreachable,
    };
}

/// Whether `authorization` is `Bearer <token>`.
///
/// Compared through a hash of each side, so the time taken says nothing about
/// how much of a guess was right — and nothing about the token's length either,
/// which a byte-by-byte compare of unequal lengths would give away.
pub fn authorized(authorization: ?[]const u8, token: []const u8) bool {
    const value = authorization orelse return false;
    const scheme = "Bearer ";
    if (value.len < scheme.len or !std.ascii.eqlIgnoreCase(value[0..scheme.len], scheme)) return false;
    const offered = std.mem.trim(u8, value[scheme.len..], " ");

    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a: [Sha256.digest_length]u8 = undefined;
    var b: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(offered, &a, .{});
    Sha256.hash(token, &b, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, a, b);
}

/// What `/api/status` reports: the readings the panel was last drawn from.
///
/// Null means not known — no such sensor on this hardware, or no reading yet —
/// never zero standing in for it. Names follow the MQTT topics where there is
/// one, so a reading is called the same wherever it is read.
pub const Status = struct {
    /// Percent.
    cpu_load: u8,
    /// °C.
    cpu_temp: u32,
    /// Percent.
    memory: u8,
    /// Percent.
    disk_usage: u8,
    /// °C.
    disk_temp: ?u32,
    /// RPM.
    fan_speed: ?u32,
    uptime_minutes: ?u64,
    ip_address: ?[]const u8,
    /// Whether that address is on a cable rather than Wi-Fi.
    wired: bool,
    /// dBm.
    signal_strength: ?i32,
    internet: ?bool,
    download_bytes_per_second: u64,
    upload_bytes_per_second: u64,
    apt_updates: ?u32,
    undervoltage: ?bool,
    nvme_fault: ?bool,
    /// Percent of rated life used; may exceed 100.
    ssd_wear: ?u8,
};

/// Buffer size `writeStatus` needs, with room to spare.
pub const status_json_max = 1024;

/// `status` as a JSON object, written into `buf`.
pub fn writeStatus(buf: []u8, status: Status) error{WriteFailed}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try std.json.Stringify.value(status, .{}, &w);
    return w.buffered();
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "routes by method and path" {
    try testing.expectEqual(Route.page, route(.get, "/"));
    try testing.expectEqual(Route.frame, route(.get, "/frame.bmp"));
    try testing.expectEqual(Route.status, route(.get, "/api/status"));
    try testing.expectEqual(Route.post_notice, route(.post, "/api/notice"));
    try testing.expectEqual(Route.delete_notice, route(.delete, "/api/notice"));

    try testing.expectEqual(Route.method_not_allowed, route(.post, "/api/status"));
    try testing.expectEqual(Route.method_not_allowed, route(.get, "/api/notice"));
    try testing.expectEqual(Route.method_not_allowed, route(.other, "/"));
    try testing.expectEqual(Route.not_found, route(.get, "/api"));
    try testing.expectEqual(Route.not_found, route(.get, "/api/status/"));
}

test "a bearer token must match exactly" {
    try testing.expect(authorized("Bearer s3cret", "s3cret"));
    try testing.expect(authorized("bearer s3cret", "s3cret"));
    try testing.expect(authorized("Bearer   s3cret ", "s3cret"));

    try testing.expect(!authorized(null, "s3cret"));
    try testing.expect(!authorized("Bearer s3cre", "s3cret"));
    try testing.expect(!authorized("Bearer s3crett", "s3cret"));
    try testing.expect(!authorized("Basic czNjcmV0", "s3cret"));
    try testing.expect(!authorized("s3cret", "s3cret"));
    try testing.expect(!authorized("Bearer", "s3cret"));
    try testing.expect(!authorized("Bearer ", "s3cret"));
}

const open: Options = .{ .token = "s3cret" };

fn post(body: []const u8, auth: ?[]const u8) http_request.Request {
    return .{ .method = .post, .path = "/api/notice", .authorization = auth, .body = body };
}

test "an authorized notice is passed on as it was sent" {
    const outcome = noticeRequest(open, .post_notice, post("{\"text\": \"Hi\", \"duration\": 5}", "Bearer s3cret"));
    try testing.expectEqualStrings("{\"text\": \"Hi\", \"duration\": 5}", outcome.accepted);
}

test "notices need a configured token, and then that token" {
    try testing.expectEqual(NoticeOutcome.disabled, noticeRequest(.{}, .post_notice, post("Hi", null)));
    try testing.expectEqual(NoticeOutcome.disabled, noticeRequest(.{ .token = "" }, .post_notice, post("Hi", "Bearer ")));
    try testing.expectEqual(
        NoticeOutcome.disabled,
        noticeRequest(.{ .token = "s3cret", .notices_enabled = false }, .post_notice, post("Hi", "Bearer s3cret")),
    );
    try testing.expectEqual(NoticeOutcome.unauthorized, noticeRequest(open, .post_notice, post("Hi", null)));
    try testing.expectEqual(NoticeOutcome.unauthorized, noticeRequest(open, .post_notice, post("Hi", "Bearer nope")));
}

test "a notice with nothing to show is turned away" {
    try testing.expectEqual(NoticeOutcome.empty, noticeRequest(open, .post_notice, post("  \n", "Bearer s3cret")));
    // An explicit dismissal is not empty: it asks for something.
    try testing.expectEqualStrings("{\"text\": \"\"}", noticeRequest(open, .post_notice, post("{\"text\": \"\"}", "Bearer s3cret")).accepted);
}

test "DELETE dismisses, and is authorized like POST" {
    const del: http_request.Request = .{ .method = .delete, .path = "/api/notice", .authorization = "Bearer s3cret" };
    const dismissal = noticeRequest(open, .delete_notice, del).accepted;

    var scratch: [8192]u8 = undefined;
    try testing.expectEqualStrings("", notice.parse(&scratch, dismissal).?.text);

    var anonymous = del;
    anonymous.authorization = null;
    try testing.expectEqual(NoticeOutcome.unauthorized, noticeRequest(open, .delete_notice, anonymous));
}

test "the status is JSON with unknown readings as null" {
    var buf: [status_json_max]u8 = undefined;
    const json = try writeStatus(&buf, .{
        .cpu_load = 12,
        .cpu_temp = 48,
        .memory = 31,
        .disk_usage = 67,
        .disk_temp = null,
        .fan_speed = 2100,
        .uptime_minutes = 3 * 1440 + 125,
        .ip_address = "192.168.1.20",
        .wired = true,
        .signal_strength = null,
        .internet = true,
        .download_bytes_per_second = 1_250_000,
        .upload_bytes_per_second = 0,
        .apt_updates = null,
        .undervoltage = false,
        .nvme_fault = null,
        .ssd_wear = 3,
    });

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqual(@as(i64, 12), obj.get("cpu_load").?.integer);
    try testing.expectEqual(@as(i64, 4445), obj.get("uptime_minutes").?.integer);
    try testing.expectEqualStrings("192.168.1.20", obj.get("ip_address").?.string);
    try testing.expectEqual(@as(i64, 1_250_000), obj.get("download_bytes_per_second").?.integer);
    try testing.expect(obj.get("disk_temp").? == .null);
    try testing.expect(obj.get("apt_updates").? == .null);
    try testing.expectEqual(false, obj.get("undervoltage").?.bool);
    try testing.expectEqual(@as(usize, @typeInfo(Status).@"struct".field_names.len), obj.count());
}

test "the largest status fits the buffer" {
    var buf: [status_json_max]u8 = undefined;
    _ = try writeStatus(&buf, .{
        .cpu_load = 255,
        .cpu_temp = std.math.maxInt(u32),
        .memory = 255,
        .disk_usage = 255,
        .disk_temp = std.math.maxInt(u32),
        .fan_speed = std.math.maxInt(u32),
        .uptime_minutes = std.math.maxInt(u64),
        .ip_address = "255.255.255.255",
        .wired = false,
        .signal_strength = std.math.minInt(i32),
        .internet = false,
        .download_bytes_per_second = std.math.maxInt(u64),
        .upload_bytes_per_second = std.math.maxInt(u64),
        .apt_updates = std.math.maxInt(u32),
        .undervoltage = true,
        .nvme_fault = true,
        .ssd_wear = 255,
    });
}
