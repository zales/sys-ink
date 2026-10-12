//! The directory procfs and sysfs are read under.
//!
//! `/` on a real machine. Under test it is a directory of fixtures laid out
//! the same way, which is what lets the probing and latching in `system_ops`
//! and `network_ops` run anywhere: which hwmon device is the fan, what happens
//! when a sensor goes away, which interfaces count towards traffic. The
//! production path is the one the tests take, not a second one beside it.

const std = @import("std");

pub const Root = struct {
    dir: std.Io.Dir,
    io: std.Io,

    /// The machine's own tree.
    pub fn system(io: std.Io) !Root {
        return .{ .dir = try std.Io.Dir.openDirAbsolute(io, "/", .{}), .io = io };
    }

    pub fn close(self: Root) void {
        self.dir.close(self.io);
    }

    /// Read a small file into `buf` and return the part of it that was filled.
    /// `path` is as it reads on a real machine, leading slash included.
    pub fn read(self: Root, path: []const u8, buf: []u8) ![]const u8 {
        const file = try self.dir.openFile(self.io, relative(path), .{});
        defer file.close(self.io);

        const len = try file.readPositionalAll(self.io, buf, 0);
        return buf[0..len];
    }

    pub fn exists(self: Root, path: []const u8) bool {
        self.dir.access(self.io, relative(path), .{}) catch return false;
        return true;
    }

    /// An absolute path would be opened as one, whatever `dir` is.
    fn relative(path: []const u8) []const u8 {
        std.debug.assert(path.len > 1 and path[0] == '/');
        return path[1..];
    }
};

/// A tree of made-up files for a test to read as if it were the machine's.
pub const Fixture = struct {
    tmp: std.testing.TmpDir,

    pub fn init() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    pub fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    pub fn root(self: *const Fixture) Root {
        return .{ .dir = self.tmp.dir, .io = std.testing.io };
    }

    /// Create or replace the file at `path`, and the directories above it.
    pub fn put(self: *const Fixture, path: []const u8, content: []const u8) !void {
        const sub_path = Root.relative(path);
        if (std.fs.path.dirname(sub_path)) |parent| try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = content });
    }

    /// Create the directory at `path`, and those above it.
    pub fn makeDir(self: *const Fixture, path: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, Root.relative(path));
    }

    /// The real path of `path` under the fixture, written into `buf`: for
    /// code that is handed a path to write to and knows nothing of roots.
    pub fn realPath(self: *const Fixture, buf: []u8, path: []const u8) ![]const u8 {
        const dir_len = try self.tmp.dir.realPath(std.testing.io, buf);
        if (path.len > buf.len - dir_len) return error.NameTooLong;
        @memcpy(buf[dir_len..][0..path.len], path);
        return buf[0 .. dir_len + path.len];
    }

    pub fn remove(self: *const Fixture, path: []const u8) !void {
        try self.tmp.dir.deleteTree(std.testing.io, Root.relative(path));
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "the machine's own tree is the one at /" {
    const root = try Root.system(testing.io);
    defer root.close();

    try testing.expect(root.exists("/dev/null"));
    try testing.expect(!root.exists("/no/such/place"));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", try root.read("/dev/null", &buf));
}

test "procfs and sysfs answer through it, where there are any" {
    // The daemon's own path to every reading it takes: on Linux, which is
    // where CI runs, this is the real thing rather than a fixture.
    if (@import("builtin").target.os.tag != .linux) return error.SkipZigTest;

    const root = try Root.system(testing.io);
    defer root.close();

    var buf: [64]u8 = undefined;
    _ = try @import("parse.zig").uptime(try root.read("/proc/uptime", &buf));
    try testing.expect(root.exists("/sys/class/net/lo"));
}

test "a file is read from under the root, by the path it has on a machine" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.put("/proc/uptime", "350735.47 234388.90\n");

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("350735.47 234388.90\n", try fixture.root().read("/proc/uptime", &buf));
}

test "a read stops at the end of the buffer" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.put("/proc/stat", "cpu  1 2 3 4 5 6 7\n");

    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("cpu ", try fixture.root().read("/proc/stat", &buf));
}

test "a fixture can say where on the machine one of its files really is" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.put("/proc/uptime", "1.00 1.00\n");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real = try fixture.realPath(&buf, "/proc/uptime");
    try testing.expect(std.fs.path.isAbsolute(real));
    try testing.expect(std.mem.endsWith(u8, real, "/proc/uptime"));

    // And it is that file: read by its real path, with no root in between.
    const file = try std.Io.Dir.openFileAbsolute(testing.io, real, .{});
    defer file.close(testing.io);
    var content: [16]u8 = undefined;
    const len = try file.readPositionalAll(testing.io, &content, 0);
    try testing.expectEqualStrings("1.00 1.00\n", content[0..len]);
}

test "what is not there is an error to read and does not exist" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    try fixture.makeDir("/sys/class/net/eth0/device");

    const root = fixture.root();
    var buf: [16]u8 = undefined;
    try testing.expectError(error.FileNotFound, root.read("/sys/class/hwmon/hwmon0/name", &buf));
    try testing.expect(root.exists("/sys/class/net/eth0/device"));
    try testing.expect(!root.exists("/sys/class/net/docker0/device"));

    try fixture.remove("/sys/class/net/eth0");
    try testing.expect(!root.exists("/sys/class/net/eth0/device"));
}
