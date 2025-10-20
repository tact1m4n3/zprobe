const std = @import("std");
const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const flash = rp2xxx.flash;

// TODO: this doesn't work yet on rp2350 as microzig doesn't support it

pub const page_size = 4096;
pub const ideal_transfer_size = 4 * page_size; // this should be benchmarked

pub fn begin() callconv(.c) void {
    rp2xxx.init_sequence(rp2xxx.clock_config);

    // Setup flash
    rp2xxx.rom.connect_internal_flash();
    rp2xxx.rom.flash_exit_xip();
    flash.boot2.flash_enable_xip();
}

pub fn verify(addr: usize, data: [*]const u8, count: usize) callconv(.c) bool {
    const words = count / @sizeOf(u32);
    const ram_data_u32: [*]const u32 = @alignCast(@ptrCast(data)); // it is aligned to page_size so it's safe
    const flash_data_u32: [*]const u32 = @ptrFromInt(addr);
    return std.mem.eql(u32, flash_data_u32[0..words], ram_data_u32[0..words]);
}

pub fn erase(addr: usize, count: usize) callconv(.c) void {
    const offset = addr - microzig.hal.flash.XIP_BASE;
    flash.range_erase(offset, count);
}

pub fn program(addr: usize, data: [*]const u8, count: usize) callconv(.c) void {
    const offset = addr - microzig.hal.flash.XIP_BASE;
    flash.range_program(offset, data[0..count]);
}

// We don't use the default startup procedure
pub fn init() void {}
pub fn main() void {}
