const std = @import("std");
const microzig = @import("microzig");

pub const interrupt = struct {
    pub fn globally_enabled() bool {
        var mrs: u32 = undefined;
        asm volatile ("mrs %[mrs], 16"
            : [mrs] "+r" (mrs),
        );
        return mrs & 0x1 == 0;
    }

    pub fn enable_interrupts() void {
        asm volatile ("cpsie i");
    }

    pub fn disable_interrupts() void {
        asm volatile ("cpsid i");
    }
};

pub const startup_logic = struct {
    pub fn _start() linksection(".bkp") callconv(.c) void {
        @breakpoint();
    }
};

pub fn export_startup_logic() void {
    @export(&startup_logic._start, .{ .name = "_start" });
}
