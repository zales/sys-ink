//! Reading an HTTP/1.1 request out of the bytes received so far.
//!
//! The I/O-free half of the daemon's HTTP API: `frame_server.receiveRequest`
//! feeds it what the socket has delivered and keeps reading until it says the
//! request is whole. Only what the API needs is understood — the method, the
//! path, `Authorization`, `Content-Length` and `Expect` — and everything else
//! in the headers is skipped over.
//!
//! No chunked bodies: every client that matters sends `Content-Length` for a
//! body this small, and one that does not is told so with a 411.

const std = @import("std");

pub const Method = enum { get, post, delete, other };

pub const Request = struct {
    method: Method,
    /// The request target without its query string.
    path: []const u8,
    /// The `Authorization` value, trimmed, if the client sent one.
    authorization: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const Result = union(enum) {
    complete: Request,
    /// The headers have not all arrived yet.
    need_headers,
    /// The headers are in but not all of the body. `expect_continue` means the
    /// client holds the body back until it is told to send it.
    need_body: struct { expect_continue: bool },
    bad_request,
    /// A body without `Content-Length`, which here means chunked.
    length_required,
    /// A body longer than the caller will take.
    too_large,
};

/// Longest header block accepted. A request line, a bearer token and the
/// usual handful of client headers fit many times over.
pub const max_header_len = 4096;

/// Look at `data`, everything received so far, and say what it amounts to.
///
/// `max_body` bounds `Content-Length`, which is checked as soon as the headers
/// are in, so an oversized body is refused before any of it is waited for.
pub fn parse(data: []const u8, max_body: usize) Result {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
        return if (data.len > max_header_len) .too_large else .need_headers;
    };
    if (header_end > max_header_len) return .too_large;

    var lines = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
    var request = parseRequestLine(lines.first()) orelse return .bad_request;

    var content_length: ?usize = null;
    var expect_continue = false;

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .bad_request;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const length = std.fmt.parseInt(usize, value, 10) catch return .bad_request;
            // Two different lengths are the classic request-smuggling shape.
            if (content_length != null and content_length != length) return .bad_request;
            content_length = length;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return .length_required;
        } else if (std.ascii.eqlIgnoreCase(name, "authorization")) {
            request.authorization = value;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            expect_continue = std.ascii.eqlIgnoreCase(value, "100-continue");
        }
    }

    // Without either header a request has no body at all.
    const length = content_length orelse 0;
    if (length > max_body) return .too_large;

    const body_start = header_end + 4;
    const received = data.len - body_start;
    if (received < length) return .{ .need_body = .{ .expect_continue = expect_continue } };

    request.body = data[body_start..][0..length];
    return .{ .complete = request };
}

fn parseRequestLine(line: []const u8) ?Request {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return null;
    if (target.len == 0 or target[0] != '/') return null;

    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return .{
        .method = methodOf(method),
        .path = target[0..path_end],
    };
}

fn methodOf(name: []const u8) Method {
    // Methods are case-sensitive; `get` is not GET.
    if (std.mem.eql(u8, name, "GET")) return .get;
    if (std.mem.eql(u8, name, "POST")) return .post;
    if (std.mem.eql(u8, name, "DELETE")) return .delete;
    return .other;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn expectComplete(data: []const u8) !Request {
    return switch (parse(data, 1024)) {
        .complete => |r| r,
        else => |other| {
            std.debug.print("expected a complete request, got {t}\n", .{other});
            return error.TestUnexpectedResult;
        },
    };
}

test "a GET without a body is complete once its headers are" {
    const r = try expectComplete("GET /api/status?pretty=1 HTTP/1.1\r\nHost: pi\r\nAccept: */*\r\n\r\n");
    try testing.expectEqual(Method.get, r.method);
    try testing.expectEqualStrings("/api/status", r.path);
    try testing.expectEqual(@as(?[]const u8, null), r.authorization);
    try testing.expectEqualStrings("", r.body);
}

test "a POST carries its body and authorization" {
    const r = try expectComplete("POST /api/notice HTTP/1.1\r\n" ++
        "authorization:   Bearer s3cret \r\n" ++
        "Content-Length: 15\r\n\r\n" ++
        "Backup finished");
    try testing.expectEqual(Method.post, r.method);
    try testing.expectEqualStrings("Bearer s3cret", r.authorization.?);
    try testing.expectEqualStrings("Backup finished", r.body);
}

test "a request is incomplete until the blank line arrives" {
    try testing.expectEqual(Result.need_headers, parse("GET / HTTP/1.1\r\nHost: pi\r\n", 1024));
    try testing.expectEqual(Result.need_headers, parse("", 1024));
}

test "a body still on its way is waited for" {
    const head = "POST /api/notice HTTP/1.1\r\nContent-Length: 5\r\n\r\n";
    try testing.expectEqual(false, parse(head ++ "abc", 1024).need_body.expect_continue);

    const waiting = "POST /api/notice HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n";
    try testing.expectEqual(true, parse(waiting, 1024).need_body.expect_continue);
}

test "bytes past the declared length are not part of the body" {
    const r = try expectComplete("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nhiGET / HTTP/1.1");
    try testing.expectEqualStrings("hi", r.body);
}

test "an oversized body is refused before it is waited for" {
    try testing.expectEqual(Result.too_large, parse("POST /x HTTP/1.1\r\nContent-Length: 1025\r\n\r\n", 1024));
}

test "an endless header block is refused" {
    const junk = "GET / HTTP/1.1\r\nX: " ++ "a" ** max_header_len;
    try testing.expectEqual(Result.too_large, parse(junk, 1024));
    try testing.expectEqual(Result.too_large, parse(junk ++ "\r\n\r\n", 1024));
}

test "chunked bodies are not supported" {
    try testing.expectEqual(
        Result.length_required,
        parse("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 1024),
    );
}

test "malformed requests are rejected" {
    for ([_][]const u8{
        "GET\r\n\r\n",
        "GET / HTTP/1.1 extra\r\n\r\n",
        "GET / SPDY/3\r\n\r\n",
        "GET api HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nno colon here\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: ten\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
    }) |data| {
        try testing.expectEqual(Result.bad_request, parse(data, 1024));
    }
}

test "a repeated but agreeing Content-Length is fine" {
    const r = try expectComplete("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok");
    try testing.expectEqualStrings("ok", r.body);
}

test "unknown and lower-case methods are not mistaken for known ones" {
    try testing.expectEqual(Method.other, (try expectComplete("PUT / HTTP/1.1\r\n\r\n")).method);
    try testing.expectEqual(Method.other, (try expectComplete("get / HTTP/1.1\r\n\r\n")).method);
    try testing.expectEqual(Method.delete, (try expectComplete("DELETE /api/notice HTTP/1.0\r\n\r\n")).method);
}
