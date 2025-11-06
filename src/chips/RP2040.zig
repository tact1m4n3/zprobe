const std = @import("std");

const ADI = @import("../arch/ARM_DebugInterface.zig");
const Target = @import("../Target.zig");
const flash = @import("../flash.zig");
const cortex_m = ADI.cortex_m;
const cortex_m_impl = cortex_m.Impl(ADI.Mem_AP);

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
target: Target,

const target_def: Target = .{
    .name = "RP2040",
    .endian = .little,
    .valid_cores = .with_ids(&.{ CORE0_ID, CORE1_ID }),
    .memory_map = &.{
        .{ .offset = 0x10000000, .length = 2048 * 1024, .kind = .flash },
        .{ .offset = 0x20000000, .length = 256 * 1024, .kind = .ram },
    },
    .flash_algorithms = &.{
        flash.get_algorithm("RP2040"),
        // .{
        //     .name = "RP2040",
        //     .
        // },
    },
    .vtable = &.{
        .system_reset = system_reset,
        .memory = ADI.Mem_AP.target_memory_vtable(@This(), "target", "core0_ap"),
        .core_access = cortex_m.TargetCoreAccess(@This(), "target", &.{
            .{ .id = CORE0_ID, .memory_name = "core0_ap" },
            .{ .id = CORE1_ID, .memory_name = "core1_ap" },
        }).vtable(),
    },
};

pub fn init(adi: *ADI) !RP2040 {
    const core0_ap: ADI.Mem_AP = try .init(adi, AP_CORE0);
    const core1_ap: ADI.Mem_AP = try .init(adi, AP_CORE1);

    return .{
        .adi = adi,
        .core0_ap = core0_ap,
        .core1_ap = core1_ap,
        .target = target_def,
    };
}

pub fn deinit(rp2040: *RP2040) void {
    rp2040.target.deinit();
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

fn system_reset(target: *Target) Target.CommandError!void {
    const rp2040: *RP2040 = @fieldParentPtr("target", target);
    do_system_reset(rp2040) catch return error.CommandFailed;
}
