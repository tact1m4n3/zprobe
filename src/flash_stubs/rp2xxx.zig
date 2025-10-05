const std = @import("std");
const microzig = @import("microzig");

pub const page_size = 4096;

pub fn erase(addr: u32, count: u32) callconv(.c) void {
    const offset = addr - microzig.hal.flash.XIP_BASE;
    microzig.hal.flash.range_erase(offset, count);
}

pub fn program(addr: u32, data: [*]const u8, count: u32) callconv(.c) void {
    const offset = addr - microzig.hal.flash.XIP_BASE;
    microzig.hal.flash.range_program(offset, data[0..count]);
}

pub fn init() void {}
pub fn main() !void {}
