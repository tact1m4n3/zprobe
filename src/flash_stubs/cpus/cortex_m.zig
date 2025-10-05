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

// chip independent
// TODO: have different version for 64 bit, if we should support this
pub const ImageHeader = extern struct {
    const MAGIC = 0xBAD_C0FFE;

    magic: u32 = MAGIC,
    page_size: u32,
    stack_pointer: *const anyopaque,
    return_address: *const fn () callconv(.naked) noreturn = return_address,
    verify: *const fn (addr: u32, data: [*]const u8, count: u32) callconv(.c) bool,
    erase: *const fn (addr: u32, count: u32) callconv(.c) void,
    program: *const fn (addr: u32, data: [*]const u8, count: u32) callconv(.c) void,
};

// chip independent
pub fn return_address() callconv(.naked) noreturn {
    @breakpoint();
}

// chip independent
pub fn default_verify(addr: u32, data: [*]const u8, count: u32) callconv(.c) bool {
    const flash_data: []const u8 = @as([*]const u8, @ptrFromInt(addr))[0..count];
    return std.mem.eql(u8, flash_data, data[0..count]);
}

pub const startup_logic = struct {
    /// We don't care to actually run the firmware
    pub fn _start() callconv(.c) void {
        unreachable;
    }

    pub var image_header: ImageHeader = .{
        .page_size = microzig.app.page_size,
        .stack_pointer = microzig.utilities.get_end_of_stack(),
        .verify = if (@hasDecl(microzig.app, "verify")) microzig.app.verify else default_verify,
        .erase = microzig.app.erase,
        .program = microzig.app.program,
    };
};

pub fn export_startup_logic() void {
    @export(&startup_logic._start, .{ .name = "_start" });
    @export(&startup_logic.image_header, .{ .name = "image_header", .section = ".image_header" });
}
