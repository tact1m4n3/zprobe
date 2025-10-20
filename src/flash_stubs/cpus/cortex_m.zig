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
    const MAGIC_32 = 0xBAD_C0FFE;
    const MAGIC_64 = 0xBAD_BAD_BAD_C00FFE;

    magic: u64,
    page_size: usize,
    ideal_transfer_size: usize,
    stack_pointer: *const anyopaque,
    return_address: *const fn () callconv(.naked) noreturn = return_address,
    begin: *const fn () callconv(.c) void,
    verify: *const fn (addr: usize, data: [*]const u8, count: usize) callconv(.c) bool,
    erase: *const fn (addr: usize, count: usize) callconv(.c) void,
    program: *const fn (addr: usize, data: [*]const u8, count: usize) callconv(.c) void,
};

// chip independent
pub fn return_address() callconv(.naked) noreturn {
    @breakpoint();
}

// chip independent
pub fn default_begin() callconv(.c) void {}

// chip independent
pub fn default_verify(addr: usize, data: [*]const u8, count: usize) callconv(.c) bool {
    const flash_data: []const u8 = @as([*]const u8, @ptrFromInt(addr))[0..count];
    return std.mem.eql(u8, flash_data, data[0..count]);
}

pub const startup_logic = struct {
    pub fn _start() callconv(.c) void {
        unreachable;
    }

    pub var image_header: ImageHeader = .{
        .magic = ImageHeader.MAGIC_32,
        .page_size = microzig.app.page_size,
        .ideal_transfer_size = if (@hasDecl(microzig.app, "ideal_transfer_size"))
            microzig.app.ideal_transfer_size
        else
            microzig.app.page_size,
        .stack_pointer = microzig.utilities.get_end_of_stack(),
        .begin = if (@hasDecl(microzig.app, "begin")) microzig.app.begin else default_begin,
        .verify = if (@hasDecl(microzig.app, "verify")) microzig.app.verify else default_verify,
        .erase = microzig.app.erase,
        .program = microzig.app.program,
    };
};

pub fn export_startup_logic() void {
    @export(&startup_logic._start, .{ .name = "_start" });
    @export(&startup_logic.image_header, .{ .name = "image_header", .section = ".image_header" });
}
