const std = @import("std");
const microzig = @import("microzig");

pub const erase_sector_size = 4096;
pub const program_sector_size = 256;

pub fn erase(addr: u32, count: u32) callconv(.c) void {
    const offset = addr - microzig.hal.flash.XIP_BASE;
    microzig.hal.flash.range_erase(offset, count);
    @breakpoint();
    microzig.hang();
}

pub fn program(addr: u32, data: [*]const u8, count: u32) callconv(.c) void {
    const offset = addr - microzig.hal.flash.XIP_BASE;
    microzig.hal.flash.range_program(offset, data[0..count]);
    @breakpoint();
    microzig.hang();
}

pub fn init() void {}
pub fn main() !void {}
