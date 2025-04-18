const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.mkdev);
const posix_ext = @import("posix_ext.zig");

const Rule = struct {
    basename: []const u8,
    mode: posix.mode_t,
};

const rule: []const Rule = @import("mkdev.zig");

pub fn mkdev() !void {
    try posix.chdir("/dev");
    try findDevs(true);
    try findDevs(false);
    try posix.chdir("/");
}

fn parseUeventFile(gpa: mem.Allocator, stream: anytype, real_path: []const u8, mode: *posix.mode_t) ![*:0]u8 {
    const symlink_dir = "/dev/block/bootdevice/by-name";
    var devname_maybe: ?[*:0]u8 = null;
    var partname_maybe: ?[]u8 = null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.fs.cwd().makePath("block/bootdevice/by-name");
    while (true) {
        if (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            var it = mem.splitScalar(u8, line, '=');
            const first = it.first();
            const rest = it.rest();
            if (mem.eql(u8, first, "DEVNAME")) {
                devname_maybe = try gpa.dupeZ(u8, rest);
            } else if (mem.eql(u8, first, "DEVMODE")) {
                mode.* = try std.fmt.parseInt(posix.mode_t, rest, 8);
            } else if (mem.eql(u8, first, "PARTNAME")) {
                partname_maybe = try gpa.dupeZ(u8, rest);
            }
        } else {
            break;
        }
    }
    if (devname_maybe) |devname_cstr| {
        @branchHint(.likely);
        const devname = mem.span(devname_cstr);
        if (partname_maybe) |partname| {
            try std.fs.symLinkAbsolute(
                try std.fs.path.join(gpa, &.{ "/dev", devname }),
                try std.fs.path.join(gpa, &.{ symlink_dir, partname }),
                .{},
            );
        }
        if (std.fs.path.dirname(devname)) |dirname| {
            std.fs.cwd().makePath(dirname) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
        }
        return devname;
    }
    return try gpa.dupeZ(u8, std.fs.path.basename(real_path));
}

fn findDevs(block: bool) !void {
    var mode: posix.mode_t = 0o600;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    //errdefer arena_state.deinit();

    const arena = arena_state.allocator();

    const path = if (block) "/sys/dev/block" else "/sys/dev/char";

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();
    //errdefer dir.close();

    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (entry.kind != .sym_link) continue;
        var it = mem.splitScalar(u8, entry.basename, ':');
        const first = it.first();
        const rest = it.rest();
        if (first.len == 0 or rest.len == 0) continue;
        const major = try std.fmt.parseInt(u64, first, 10);
        const minor = try std.fmt.parseInt(u64, rest, 10);
        const real_path = try dir.readLink(entry.path, &buf);
        const full_path = try std.fs.path.resolve(arena, &.{ path, real_path, "uevent" });
        var uevent_file = try std.fs.cwd().openFile(full_path, .{});
        defer uevent_file.close();
        //errdefer uevent_file.close();
        const devname_cstr = try parseUeventFile(arena, uevent_file.reader(), full_path, &mode);
        makeDev(devname_cstr, block, major, minor, mode) catch |err| switch (err) {
            error.AlreadyExists => {},
            else => |e| return e,
        };
    }
}

fn makeDev(path: [*:0]const u8, block: bool, major: u64, minor: u64, mode: posix.mode_t) !void {
    var mode_ = mode;
    mode_ |= if (block) posix.S.IFBLK else posix.S.IFCHR;
    try posix_ext.mknod(path, @intCast(mode_), @intCast(makedev(major, minor)));
}

pub fn makedev(x: u64, y: u64) u64 {
    return ((((x & @as(u64, 0xfffff000)) << @as(c_int, 32)) |
        ((x & @as(u64, 0x00000fff)) << @as(c_int, 8))) |
        ((y & @as(u64, 0xffffff00)) << @as(c_int, 12))) |
        (y & @as(u64, 0x000000ff));
}
