const std = @import("std");
const os = std.os;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;
const util = @import("util.zig");
const mkdev = @import("mkdev.zig");
const log = std.log.scoped(.early);
const posix_ext = @import("posix_ext.zig");

const MountOptions = struct {
    source: [*:0]const u8,
    target: [*:0]const u8,
    fstype: [*:0]const u8,
    flags: u32,
    data: ?*const anyopaque,
};

const devpts_type = "devpts";

const mount_map = [_]MountOptions{
    .{
        .source = "proc",
        .target = "/proc",
        .fstype = "proc",
        .flags = linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.NOSUID | linux.MS.RELATIME,
        .data = null,
    },
    .{
        .source = "sysfs",
        .target = "/sys",
        .fstype = "sysfs",
        .flags = linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.NOSUID | linux.MS.RELATIME,
        .data = null,
    },
    .{
        .source = "efivars",
        .target = "/sys/firmware/efi/efivars",
        .fstype = "efivarfs",
        .flags = linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.NOSUID | linux.MS.RELATIME,
        .data = null,
    },
    .{
        .source = "cgroup2",
        .target = "/sys/fs/cgroup",
        .fstype = "cgroup2",
        .flags = linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.NOSUID | linux.MS.RELATIME,
        .data = @ptrCast("nsdelegate"),
    },
    .{
        .source = "tmpfs",
        .target = "/dev",
        .fstype = "devtmpfs",
        .flags = linux.MS.NOEXEC | linux.MS.NOSUID | linux.MS.RELATIME,
        .data = @ptrCast("mode=0755,size=512K"),
    },
    .{
        .source = "devpts",
        .target = "/dev/pts",
        .fstype = "devpts",
        .flags = linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.NOSUID | linux.MS.RELATIME,
        .data = null,
    },
};

fn mounts() !void {
    inline for (mount_map) |opt| {
        if (mem.eql(u8, opt.fstype[0..devpts_type.len], devpts_type)) {
            posix.symlink("/tmp/shm", "/dev/shm") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            posix.mkdir("/dev/pts", 0o755) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
        }
        posix_ext.mount(
            opt.source,
            opt.target,
            opt.fstype,
            opt.flags,
            @intFromPtr(opt.data),
        ) catch |err| switch (err) {
            error.DeviceBusy, error.FileNotFound => {},
            else => |e| {
                log.err("mount from {s} to {s}", .{ opt.source, opt.target });
                return e;
            },
        };
    }

    try setupDev();
    try console("/dev/console");

    //posix_ext.mount(
    //    "tmpfs",
    //    "/tmp",
    //    "tmpfs",
    //    linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOATIME,
    //    @intFromPtr("mode=01777"),
    //) catch |err| switch (err) {
    //    error.DeviceBusy, error.FileNotFound => {},
    //    else => |e| {
    //        return e;
    //    },
    //};
    //try posix.mkdir("/tmp/shm", 0o1777);
    //try posix.mkdir("/tmp/run", 0o755);
    //try posix.mkdir("/tmp/lock", 0o755);
    //try posix.mkdir("/tmp/state", 0o755);

    mountRoot() catch |err| @panic(@errorName(err));
}

fn mountRoot() !void {
    var file = try std.fs.cwd().openFile("/proc/cmdline", .{});
    defer file.close();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        var buf_fba: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf_fba);
        if (try file.reader().readUntilDelimiterOrEof(&buf, ' ')) |pair| {
            var it = mem.splitScalar(u8, pair, '=');
            const first = it.first();
            const rest = it.rest();
            if (mem.eql(u8, first, "root")) {
                const root_path = try fba.allocator().dupeZ(u8, rest);
                std.fs.accessAbsolute(root_path, .{ .mode = .read_only }) catch |err| {
                    log.err("access to {s} {s}", .{ root_path, @errorName(err) });
                    return err;
                };
                log.info("mounting root={s} to {s}", .{ rest, "/sysroot" });
                try posix_ext.mount(root_path, "/sysroot", "ext4", linux.MS.RDONLY | linux.MS.RELATIME, 0);
                break;
            }
        } else {
            break;
        }
    }
    log.info("switching root start", .{});
    try switchRoot("/sysroot");
    log.info("switching root complete", .{});
    try mountOverlay();
}

fn mountOverlay() !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var buf1: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf1);
    const gpa = fba.allocator();
    const overlay_fs = try std.fs.readLinkAbsolute("/dev/block/bootdevice/by-name/systemrw", &buf);
    log.info("overlay_fs={s}", .{overlay_fs});
    try posix_ext.mount(try gpa.dupeZ(u8, overlay_fs), "/overlay", "ext4", linux.MS.NOATIME, 0);
    log.info("overlay={s} mounted at /overlay", .{overlay_fs});
    try fopivot(.{ .rw_root = "/overlay", .ro_root = "/mnt/rom" });
    try execOrignalInit("/sbin/init");
}

fn execOrignalInit(init: [*:0]const u8) !void {
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    const argv_buf = try allocator.allocSentinel(
        ?[*:0]const u8,
        os.argv.len,
        null,
    );
    argv_buf[0] = init;
    for (os.argv[1..], 0..) |arg, i| argv_buf[i + 1] = arg;

    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(os.environ.ptr);
    const res: posix.ExecveError!void = posix.execveZ(init, argv_buf, envp);
    try res;
}

fn switchRoot(new_root: [*:0]const u8) !void {
    var dir = try std.fs.openDirAbsolute("/", .{ .iterate = true });
    defer dir.close();

    const umounts = [_][]const u8{ "/dev", "/proc", "/sys", "/run" };

    for (umounts) |umount| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const gpa = fba.allocator();
        const newmount = try std.fs.path.joinZ(gpa, &.{
            mem.span(new_root),
            umount,
        });
        const umount_cstr = try gpa.dupeZ(u8, umount);
        {
            const sb = std.fs.cwd().statFile(umount) catch {
                continue;
            };
            if (sb.kind != .directory) continue;
        }
        const sb = std.fs.cwd().statFile(newmount[0..newmount.len]) catch {
            log.warn("new mount not found={s}", .{newmount});
            try posix_ext.umount(umount_cstr, linux.MNT.DETACH);
            continue;
        };
        if (sb.kind != .directory) {
            log.warn("new mount is not a directory {s}", .{newmount});
            try posix_ext.umount(umount_cstr, linux.MNT.DETACH);
            continue;
        }
        log.info("umount={s}, newmount={s}", .{ umount_cstr, newmount });
        posix_ext.mount(umount_cstr, newmount, null, linux.MS.MOVE, 0) catch |err| switch (err) {
            error.InvalidArgument => {},
            else => {
                log.warn("failed to mount moving {s} {s}, {s}", .{ umount, newmount, @errorName(err) });
                try posix_ext.umount(umount_cstr, linux.MNT.FORCE);
            },
        };
    }

    std.fs.deleteTreeAbsolute("/") catch {};

    try posix.chdir(mem.span(new_root));

    try posix_ext.mount(new_root, "/", null, linux.MS.MOVE, 0);

    try posix_ext.chroot(".");

    try posix.chdir("/");
}

const PivotOptions = struct {
    rw_root: []const u8,
    ro_root: [*:0]const u8,
};

/// Parameters:
/// 1. rw_root -- path where the read/write root is mounted
/// 2. work_dir -- path to the overlay workdir (must be on same filesystem as rw_root)
/// Overlay will be set up on /mnt, original root on /mnt/rom
fn fopivot(options: PivotOptions) !void {
    var buf0: [64]u8 = undefined;
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    var buf3: [64]u8 = undefined;

    const overlay = try std.fmt.bufPrintZ(&buf0, "overlayfs:{s}", .{options.rw_root});
    const upperdir = try std.fmt.bufPrint(&buf1, "{s}/upper", .{options.rw_root});
    const workdir = try std.fmt.bufPrint(&buf2, "{s}/work", .{options.rw_root});

    std.fs.cwd().makePath(upperdir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| {
            log.err("make path {s}, {s}", .{ upperdir, @errorName(e) });
            return err;
        },
    };

    std.fs.cwd().makePath(workdir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| {
            log.err("make path {s}, {s}", .{ upperdir, @errorName(e) });
            return err;
        },
    };

    log.info("overlay={s} upper={s}, work={s}", .{ overlay, upperdir, workdir });

    const mount_options = try std.fmt.bufPrintZ(
        &buf3,
        "lowerdir=/,upperdir={s},workdir={s}",
        .{ upperdir, workdir },
    );
    try posix_ext.mount(
        overlay,
        "/mnt",
        "overlay",
        linux.MS.NOATIME,
        @intFromPtr(mount_options.ptr),
    );
    log.info("overlay mounted at /mnt", .{});
    try mountMove("/", "/mnt", "/proc");
    try posix_ext.pivot_root("/mnt", options.ro_root);
    try mountMove("/rom", "/", "/dev");
    try mountMove("/rom", "/", "/sys");
    try mountMove("/rom", "/", "/overlay");
    //mountMove("/rom", "/", "/tmp") catch {};
}

fn mountMove(old_root: []const u8, new_root: []const u8, dir: []const u8) !void {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const gpa = fba.allocator();
    const olddir = try std.fs.path.joinZ(gpa, &.{ old_root, dir });
    const newdir = try std.fs.path.joinZ(gpa, &.{ new_root, dir });

    try posix_ext.mount(olddir, newdir, null, linux.MS.NOATIME | linux.MS.MOVE, 0);
}

fn console(dev: []const u8) !void {
    _ = std.fs.cwd().statFile(dev) catch |err| {
        log.err("Failed to stat {s}: {s}", .{ dev, @errorName(err) });
        return;
    };
    try util.patchStdio(dev);
}

fn setupDev() !void {
    try mkdev.mkdev();
}

pub fn run() !void {
    if (linux.getpid() != 1) return;
    try mounts();
}
