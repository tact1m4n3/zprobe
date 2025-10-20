const builtin = @import("builtin");
const std = @import("std");

pub var should_exit: bool = false;

pub fn init() !void {
    try set_ctrl_c_handler(ctrl_c_handler);
}

pub fn were_we_interrupted() error{Interrupt}!void {
    if (should_exit) return error.Interrupt;
}

fn ctrl_c_handler() void {
    // We are ok, right? As in we don't need any syncronization stuff.
    should_exit = true;
}

fn set_ctrl_c_handler(comptime handler: *const fn () void) error{Unexpected}!void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const handler_routine = struct {
            fn handler_routine(dwCtrlType: windows.DWORD) callconv(windows.WINAPI) windows.BOOL {
                if (dwCtrlType == windows.CTRL_C_EVENT) {
                    handler();
                    return windows.TRUE;
                } else {
                    // Ignore this event.
                    return windows.FALSE;
                }
            }
        }.handler_routine;
        try windows.SetConsoleCtrlHandler(handler_routine, true);
    } else {
        const internal_handler = struct {
            fn internal_handler(sig: c_int) callconv(.c) void {
                std.debug.assert(sig == std.posix.SIG.INT);
                handler();
            }
        }.internal_handler;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = internal_handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
}
