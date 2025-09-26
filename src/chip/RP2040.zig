const std = @import("std");

const Probe = @import("../Probe.zig");
const ADI = @import("../arch/ARM_DebugInterface.zig");
const Memory = @import("../Memory.zig");
const Target = @import("../Target.zig");

const RP2040 = @This();

const CORE0_ID: Target.Core_ID = .boot;
const CORE1_ID: Target.Core_ID = .num(1);

const DP_CORE0: ADI.DP_Address = .{ .multidrop = 0x01002927 };
const AP_CORE0: ADI.AP_Address = .{
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
core0_ap: *ADI.Mem_AP,
core0: ADI.Cortex_M,
core1: ADI.Cortex_M,
target: Target,

pub fn init(probe: Probe) !RP2040 {
    const adi = probe.arm_debug_interface() orelse return error.ADI_NotSupported;

    const core0_ap = try adi.get_memory_ap(AP_CORE0);
    var core0: ADI.Cortex_M = try .init(core0_ap.memory());
    errdefer core0.deinit();

    const core1_ap = try adi.get_memory_ap(AP_CORE1);
    var core1: ADI.Cortex_M = try .init(core1_ap.memory());
    errdefer core1.deinit();

    return .{
        .adi = adi,
        .core0_ap = core0_ap,
        .core0 = core0,
        .core1 = core1,
        .target = .{
            .core_ids = &.{ CORE0_ID, CORE1_ID },
            .memory_map = &.{},
            .vtable = &.{
                .system_reset = system_reset,
                .memory = memory,
                .core_access = ADI.Cortex_M.Multiplex(@This(), "target", &.{
                    .{ .id = CORE0_ID, .name = "core0" },
                    .{ .id = CORE1_ID, .name = "core1" },
                }).core_access_vtable(),
            },
        },
    };
}

pub fn deinit(rp2040: *RP2040) void {
    rp2040.core0.deinit();
    rp2040.core1.deinit();
}

fn do_system_reset(rp2040: *RP2040) !void {
    // reset system
    try rp2040.adi.dp_reg_write(RESCUE_DP, ADI.regs.dp.CTRL_STAT.addr, 0);

    // after full chip reset, we should reinit adi and cores
    try rp2040.adi.reinit();
    try rp2040.core0.reinit();
    try rp2040.core1.reinit();

    try rp2040.core0.halt();
    try rp2040.core0.halt_reset();
}

fn system_reset(target: *Target) Target.CommandError!void {
    const rp2040: *RP2040 = @fieldParentPtr("target", target);
    do_system_reset(rp2040) catch return error.CommandFailed;
}

fn memory(target: *Target) Memory {
    const rp2040: *RP2040 = @fieldParentPtr("target", target);
    return rp2040.core0_ap.memory();
}
