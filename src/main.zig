const sa_shutdown: posix.Sigaction = .{
    .handler = .{ .sigaction = signalShutdown },
    .flags = posix.SA.SIGINFO,
    .mask = std.posix.empty_sigset,
    .restorer = null,
};

fn signalShutdown(
    signal: i32,
    siginfo: *const posix.siginfo_t,
    data: ?*anyopaque,
) callconv(.c) void {
    _ = signal;
    _ = siginfo;
    _ = data;
    log.info("signaling a reboot", .{});
    posix.sync();
    std.time.sleep(2 * std.time.ns_per_s);
    posix.reboot(.{ .RESTART = {} }) catch {};
    while (true) {}
}

pub fn main() !void {
    posix.sigaction(posix.SIG.TERM, &sa_shutdown, null);
    posix.sigaction(posix.SIG.USR1, &sa_shutdown, null);
    posix.sigaction(posix.SIG.USR2, &sa_shutdown, null);
    posix.sigaction(posix.SIG.PWR, &sa_shutdown, null);

    try early.run();

    while (true) {}
}

var panicking = std.atomic.Value(u8).init(0);
threadlocal var panic_stage: usize = 0;

pub const panic = std.debug.FullPanic(panicFn);
fn panicFn(
    msg: []const u8,
    first_trace_addr: ?usize,
) noreturn {
    @branchHint(.cold);

    // Note there is similar logic in handleSegfaultPosix and handleSegfaultWindowsExtra.
    nosuspend switch (panic_stage) {
        0 => {
            panic_stage = 1;

            _ = panicking.fetchAdd(1, .seq_cst);

            {
                std.debug.lockStdErr();
                defer std.debug.unlockStdErr();

                const stderr = std.io.getStdErr().writer();
                const current_thread_id = std.Thread.getCurrentId();
                stderr.print("thread {} panic: ", .{current_thread_id}) catch {};
                stderr.print("{s}\n", .{msg}) catch {};

                if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
                std.debug.dumpCurrentStackTrace(first_trace_addr orelse @returnAddress());
            }

            waitForOtherThreadToFinishPanicking();
        },
        1 => {
            panic_stage = 2;

            // A panic happened while trying to print a previous panic message.
            // We're still holding the mutex but that's fine as we're going to
            // call abort().
            std.io.getStdErr().writeAll("aborting due to recursive panic\n") catch {};
        },
        else => {}, // Panicked while printing the recursive panic message.
    };
    while (true) {}
}

/// Must be called only after adding 1 to `panicking`. There are three callsites.
fn waitForOtherThreadToFinishPanicking() void {
    if (panicking.fetchSub(1, .seq_cst) != 1) {
        // Sleep forever without hammering the CPU
        var futex = std.atomic.Value(u32).init(0);
        while (true) std.Thread.Futex.wait(&futex, 0);
        unreachable;
    }
}

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const log = std.log.scoped(.init_main);
const early = @import("early.zig");
