const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const MountError = error{
    AccessDenied,
    DeviceBusy,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    NameTooLong,
    NoDevice,
    FileNotFound,
    SystemResources,
    NotBlockDevice,
    NotDir,
    Unseekable,
    ReadOnlyFileSystem,
    InvalidArgument,
} || posix.UnexpectedError;

pub fn mount(
    source: [*:0]const u8,
    target: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: u32,
    data: usize,
) MountError!void {
    switch (posix.errno(linux.mount(source, target, fstype, flags, data))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .BUSY => return error.DeviceBusy,
        .FAULT => unreachable,
        .INVAL => return error.InvalidArgument,
        .LOOP => return error.SymLinkLoop,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NODEV => return error.NoDevice,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTBLK => return error.NotBlockDevice,
        .NOTDIR => return error.NotDir,
        .NXIO => return error.Unseekable,
        .PERM => return error.AccessDenied,
        .ROFS => return error.ReadOnlyFileSystem,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const UmountError = error{
    WouldBlock,
    DeviceBusy,
    NameTooLong,
    FileNotFound,
    SystemResources,
    AccessDenied,
} || posix.UnexpectedError;

pub fn umount(special: [*:0]const u8, flags: u32) UmountError!void {
    switch (posix.errno(linux.umount2(special, flags))) {
        .SUCCESS => return,
        .AGAIN => return error.WouldBlock,
        .BUSY => return error.DeviceBusy,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .PERM => return error.AccessDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

const PivotRootError = error{
    DeviceBusy,
    FileNotFound,
    AccessDenied,
    InvalidArgument,
} || posix.UnexpectedError;

pub fn pivot_root(new: [*:0]const u8, old: [*:0]const u8) PivotRootError!void {
    switch (posix.errno(linux.syscall2(.pivot_root, @intFromPtr(new), @intFromPtr(old)))) {
        .SUCCESS => return,
        .BUSY => return error.DeviceBusy,
        .INVAL => return error.InvalidArgument,
        .NOTDIR => return error.FileNotFound,
        .PERM => return error.AccessDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const MknodError = error{
    AccessDenied, // EACCES
    InvalidHandle, // EBADF
    DiskQuota, // EDQUOT
    AlreadyExists, // EEXIST
    InvalidPointer, // EFAULT
    InvalidArgument, // EINVAL
    TooManySymlinks, // ELOOP
    NameTooLong, // ENAMETOOLONG
    NoEntry, // ENOENT
    OutOfMemory, // ENOMEM
    NoSpace, // ENOSPC
    NotADirectory, // ENOTDIR
    NotPermitted, // EPERM
    ReadOnlyFS, // EROFS
} || posix.UnexpectedError;

pub fn mknod(path: [*:0]const u8, mode: u32, dev: u32) MknodError!void {
    switch (posix.errno(linux.mknod(path, mode, dev))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .BADF => return error.InvalidHandle,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.AlreadyExists,
        .FAULT => return error.InvalidPointer,
        .INVAL => return error.InvalidArgument,
        .LOOP => return error.TooManySymlinks,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.NoEntry,
        .NOMEM => return error.OutOfMemory,
        .NOSPC => return error.NoSpace,
        .NOTDIR => return error.NotADirectory,
        .PERM => return error.NotPermitted,
        .ROFS => return error.ReadOnlyFS,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const ChrootError = error{
    /// Search permission is denied, or caller lacks CAP_SYS_CHROOT
    AccessDenied,
    /// `path` points outside your process’s address space
    BadAddress,
    /// An I/O error occurred while accessing `path`
    IoError,
    /// Too many symbolic links in `path`
    SymLinkLoop,
    /// A component of `path` (or the entire string) is too long
    NameTooLong,
    /// The directory named by `path` does not exist
    FileNotFound,
    /// The kernel ran out of memory
    SystemResources,
    /// A component of `path` is not a directory
    NotDir,
} || posix.UnexpectedError;

/// Change the root directory of the calling process to `path`,
/// mapping any syscall errno into a `ChrootError`.
pub fn chroot(path: [*:0]const u8) ChrootError!void {
    const e = posix.errno(linux.chroot(path));
    switch (e) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .FAULT => return error.BadAddress,
        .IO => return error.IoError,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        else => |err| return posix.unexpectedErrno(err),
    }
}
