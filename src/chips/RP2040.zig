const std = @import("std");

const ADI = @import("../arch/ARM_DebugInterface.zig");
const Target = @import("../Target.zig");
const flash = @import("../flash.zig");

const RP2040 = @This();

const CORE0_ID: Target.CoreId = .boot;
const CORE1_ID: Target.CoreId = .num(1);

const DP_CORE0: ADI.DP_Address = .{ .multidrop = 0x01002927 };
pub const AP_CORE0: ADI.AP_Address = .{
    .dp = DP_CORE0,
    .address = .{ .v1 = 0 },
};

const DP_CORE1: ADI.DP_Address = .{ .multidrop = 0x11002927 };
const AP_CORE1: ADI.AP_Address = .{
    .dp = DP_CORE1,
    .address = .{ .v1 = 0 },
};
const RESCUE_DP: ADI.DP_Address = .{ .multidrop = 0xf1002927 };

adi: *ADI,
core0_ap: ADI.Mem_AP,
core1_ap: ADI.Mem_AP,
cores: ADI.Cortex_M.System(&.{
    CORE0_ID,
    CORE1_ID,
}),
target: Target,

pub fn init(rp2040: *RP2040, adi: *ADI) !void {
    rp2040.adi = adi;
    rp2040.core0_ap = try .init(adi, AP_CORE0);
    rp2040.core1_ap = try .init(adi, AP_CORE1);

    rp2040.cores = .init(.{
        rp2040.core0_ap.memory(),
        rp2040.core1_ap.memory(),
    });

    rp2040.target = .{
        .name = "RP2040",
        .endian = .little,
        .arch = .thumb,
        .valid_cores = .with_ids(&.{ CORE0_ID, CORE1_ID }),
        .memory_map = comptime &.{
            .{ .offset = 0x10000000, .length = 2048 * 1024, .kind = .flash },
            .{ .offset = 0x20000000, .length = 256 * 1024, .kind = .ram },
        },
        .flash_algorithms = comptime &.{
            flash.get_algorithm("RP2040"),
            // .{
            //     .name = "RP2040-probe-rs",
            //     .memory_range = .{
            //         .start = 0x10000000,
            //         .size = 0x8000000,
            //     },
            //     .instructions = "8LWFsB5MfEQgeAEoAdEA8Dv4ASAEkCBwFU4wRvcwAPCJ+AOUBEYTT7gcAPCD+AVGMEYA8H/4ApAPSADwe/gBkA5IAPB3+AZGOEYA8HP4B0agR6hHC0h4RDDAApkBYAGZBDDCwASYA5kIcAAgBbDwvVJFAABDWAAAUlAAAEZDAABeAQAA9gAAALC1CEx8RCB4ASgI0QZNfUQoaYBHaGmARwAgIHCwvQEgsL3ARtgAAAC2AAAABUh4RAB4ACgB0QEgcEcBSHBHwEbQcAAArgAAABC1Ckl5RAl4ASkM0Q8hCQdAGAdJeUSMaAEiEQMSBNgjoEcAIBC9ASAQvcBGkAAAAGgAAAAQtQtGCEl5RAl4ASkK0Q8hCQdAGAVJeUTMaBFGGkagRwAgEL0BIBC9WgAAADIAAACAshQhCYiJHkqIACoE0AkdgkL50QiIcEf+3tTUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANTU1A==",
            //     .init_fn = 0x1,
            //     .uninit_fn = 0x89,
            //     .program_page_fn = 0x105,
            //     .erase_sector_fn = 0xd1,
            //     .data_section_offset = 0,
            //     .page_size = 0x1000,
            //     .erased_byte_value = 0xff,
            //     .program_page_timeout = 1000,
            //     .erase_sector_timeout = 3000,
            //     .sectors = &.{.{ .addr = 0x0, .size = 0x1000 }},
            // },
        },
        .memory = rp2040.core0_ap.memory(),
        .debug = rp2040.cores.debug(),
        .vtable = comptime &.{
            .system_reset = system_reset,
        },
    };
}

pub fn deinit(rp2040: *RP2040) void {
    rp2040.target.deinit();
}

fn system_reset(target: *Target) Target.ResetError!void {
    const rp2040: *RP2040 = @fieldParentPtr("target", target);
    do_system_reset(rp2040) catch return error.ResetFailed;
}

fn do_system_reset(rp2040: *RP2040) !void {
    // reset system
    try rp2040.adi.dp_reg_write(RESCUE_DP, ADI.regs.dp.CTRL_STAT.addr, 0);

    // after full chip reset, we should reinit adi and mem aps
    try rp2040.adi.reinit();
    try rp2040.core0_ap.reinit();
    try rp2040.core1_ap.reinit();

    rp2040.target.attached_cores = .empty;
    rp2040.target.halted_cores = .empty;

    // take the boot core out of rescue mode
    try rp2040.target.halt_reset(.boot);
}
