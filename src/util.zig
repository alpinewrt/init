const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub fn patchFd(device: []const u8, fd: posix.fd_t, flags: posix.O) !void {
    var flags_var: posix.O = flags;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    flags_var.NOCTTY = true;
    const path = blk: {
        if (std.fs.path.isAbsolute(device)) {
            break :blk device;
        } else {
            break :blk try std.fs.path.join(fba.allocator(), &.{ "/dev", device });
        }
    };
    const nfd = try posix.open(path, flags_var, 0);
    errdefer posix.close(nfd);

    try posix.dup2(nfd, fd);
}

pub fn patchStdio(device: []const u8) !void {
    try patchFd(device, std.io.getStdIn().handle, .{ .ACCMODE = .RDONLY });
    try patchFd(device, std.io.getStdOut().handle, .{ .ACCMODE = .WRONLY });
    try patchFd(device, std.io.getStdErr().handle, .{ .ACCMODE = .WRONLY });
}
