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

// TODO: relocate
pub const ImageHeader = extern struct {
    magic: u32,
    erase_sector_size: u32,
    program_sector_size: u32,
    stack_pointer: *const anyopaque,
    erase: *const fn (addr: u32, length: u32) callconv(.c) void,
    program: *const fn (addr: u32, data: [*]const u8, length: u32) callconv(.c) void,
};

pub const startup_logic = struct {
    /// We don't care to actually run the firmware
    pub fn _start() callconv(.c) void {
        unreachable;
    }

    pub var image_header: ImageHeader = .{
        .magic = 0xBAD_C0FFE,
        .erase_sector_size = microzig.app.erase_sector_size,
        .program_sector_size = microzig.app.program_sector_size,
        .stack_pointer = microzig.utilities.get_end_of_stack(),
        .erase = microzig.app.erase,
        .program = microzig.app.program,
    };
};

pub fn export_startup_logic() void {
    @export(&startup_logic._start, .{ .name = "_start" });
    @export(&startup_logic.image_header, .{ .name = "image_header", .section = ".image_header" });
}
