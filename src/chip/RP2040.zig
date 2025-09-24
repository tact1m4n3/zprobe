const std = @import("std");

const Probe = @import("../Probe.zig");
const ADI = @import("../arch/ARM_DebugInterface.zig");
const Cortex_M = @import("../cpu/Cortex_M.zig");

const RP2040 = @This();

const DP_CORE0: ADI.DP_Address = .{ .multidrop = 0x01002927 };
const AP_CORE0: ADI.AP_Address = .{
    .dp = DP_CORE0,
    .address = .{ .v1 = 0 },
};

const DP_CORE1: ADI.DP_Address = .{ .multidrop = 0x11002927 };
const AP_CORE1: ADI.AP_Address = .{
    .dp = DP_CORE0,
    .address = .{ .v1 = 1 },
};
const RESCUE_DP: ADI.DP_Address = .{ .multidrop = 0xf1002927 };

adi: *ADI,
core0_ap: ADI.Mem_AP,
core1_ap: ADI.Mem_AP,
core0: Cortex_M = undefined,

pub fn init(allocator: std.mem.Allocator, probe: Probe) !*RP2040 {
    const adi = probe.arm_debug_interface() orelse return error.ADI_NotSupported;

    const rp2040: *RP2040 = try allocator.create(RP2040);
    rp2040.* = .{
        .adi = adi,
        .core0_ap = try .init(adi, AP_CORE0),
        .core1_ap = try .init(adi, AP_CORE1),
    };

    rp2040.core0 = try .init(rp2040.core0_ap.memory());

    return rp2040;
}
