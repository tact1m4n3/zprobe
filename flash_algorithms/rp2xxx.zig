const std = @import("std");
const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const flash = rp2xxx.flash;
const flash_algorithm = @import("flash_algorithm");

comptime {
    flash_algorithm.firmware.init(.{
        .init_fn = &init_fn,
        .uninit_fn = &uninit_fn,
        .program_page_fn = &program_page_fn,
        .erase_sector_fn = &erase_sector_fn,
        .verify_fn = &verify_fn,
        .flash_start = flash.XIP_BASE,
        .flash_size = 0x8000000,
        .page_size = program_page_size * 16,
        .erased_byte_value = 0xFF,
        .program_page_timeout = 1000,
        .erase_sector_timeout = 3000,
        .sectors = &.{
            .{ .addr = 0, .size = erase_sector_size },
        },
    });
}

const program_page_size = 256;
const erase_sector_size = 4096;

// TODO: this doesn't work yet on rp2350 as microzig doesn't support it

fn init_fn(_: usize, _: usize, f: flash_algorithm.Function) callconv(.c) c_int {
    rp2xxx.init_sequence(rp2xxx.clock_config);

    switch (f) {
        .verify => {
            // Enable flash
            rp2xxx.rom.connect_internal_flash();
            rp2xxx.rom.flash_exit_xip();
            flash.boot2.flash_enable_xip();
        },
        else => {},
    }

    return 0;
}

fn uninit_fn(_: flash_algorithm.Function) callconv(.c) c_int {
    return 0;
}

fn program_page_fn(addr: usize, size: usize, data: [*]const u8) callconv(.c) c_int {
    const offset = addr - flash.XIP_BASE;
    const aligned_size = (size + program_page_size - 1) & ~@as(usize, program_page_size - 1);
    flash.range_program(offset, data[0..aligned_size]);
    return 0;
}

fn erase_sector_fn(addr: usize) callconv(.c) c_int {
    const offset = addr - flash.XIP_BASE;
    flash.range_erase(offset, erase_sector_size);
    return 0;
}

fn verify_fn(addr: usize, size: usize, data: [*]const u8) callconv(.c) usize {
    const flash_data: [*]const u8 = @ptrFromInt(addr);
    if (std.mem.eql(u8, flash_data[0..size], data[0..size])) {
        return addr + size;
    } else {
        return 0;
    }
}

// We don't use the default startup procedure
pub fn init() void {}
pub fn main() void {}
