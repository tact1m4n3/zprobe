const std = @import("std");

const Probe = @import("../Probe.zig");
const ADI = @import("../arch/ARM_DebugInterface.zig");

const Cortex_M = @import("../cpu/cortex_m.zig").Cortex_M(ADI.Mem_AP);

const RP2040 = @This();

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
core0: Cortex_M,
core1: Cortex_M,

pub fn init(allocator: std.mem.Allocator, probe: Probe) !RP2040 {
    const adi = probe.arm_debug_interface() orelse return error.ADI_NotSupported;

    const core0_ap: ADI.Mem_AP = try .init(allocator, adi, AP_CORE0);
    var core0: Cortex_M = try .init(core0_ap);
    errdefer core0.deinit();

    const core1_ap: ADI.Mem_AP = try .init(allocator, adi, AP_CORE1);
    var core1: Cortex_M = try .init(core1_ap);
    errdefer core1.deinit();

    return .{
        .adi = adi,
        .core0 = core0,
        .core1 = core1,
    };
}

pub fn deinit(rp2040: *RP2040) void {
    rp2040.core0.deinit();
    rp2040.core1.deinit();
}

pub fn system_reset(rp2040: *RP2040) !void {
    // reset system
    try rp2040.adi.dp_reg_write(RESCUE_DP, ADI.regs.dp.CTRL_STAT.addr, 0);
    // after full chip reset, we should also reset the state
    rp2040.adi.state_reset();

    try rp2040.core0.memory.reinit();
    try rp2040.core1.memory.reinit();

    try rp2040.core0.reinit();
    try rp2040.core1.reinit();

    try rp2040.core0.halt();
    try rp2040.core0.set_catch_reset(true);
    try rp2040.core0.set_catch_fault(true);
    try rp2040.core0.reset();
}
