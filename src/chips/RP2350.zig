const std = @import("std");

const Probe = @import("../Probe.zig");
const ADI = @import("../arch/ARM_DebugInterface.zig");
const Target = @import("../Target.zig");
const flash = @import("../flash.zig");

const RP2350 = @This();

const CORE0_ID: Target.CoreId = .boot;
const CORE1_ID: Target.CoreId = .num(1);

const AP_CORE0: ADI.AP_Address = .{ .address = .{ .v2 = 0x02000 } };
const AP_CORE1: ADI.AP_Address = .{ .address = .{ .v2 = 0x04000 } };
const AP_DM_RISCV: ADI.AP_Address = .{ .address = .{ .v2 = 0x0a000 } };
const RP_AP: ADI.AP_Address = .{ .address = .{ .v2 = 0x80000 } };

adi: *ADI,
core0_ap: ADI.Mem_AP,
core1_ap: ADI.Mem_AP,
cores: ADI.Cortex_M.System(&.{
    CORE0_ID,
    CORE1_ID,
}),
target: Target,

pub fn init(rp2350: *RP2350, probe: Probe) !void {
    const adi = probe.arm_debug_interface() orelse return error.ADI_NotSupported;

    rp2350.adi = adi;
    rp2350.core0_ap = try .init(adi, AP_CORE0);
    rp2350.core1_ap = try .init(adi, AP_CORE1);

    rp2350.cores = .init(.{
        rp2350.core0_ap.memory(),
        rp2350.core1_ap.memory(),
    });

    rp2350.target = .{
        .name = "RP2350",
        .endian = .little,
        .arch = .thumb,
        .valid_cores = .with_ids(&.{ CORE0_ID, CORE1_ID }),
        .memory_map = comptime &.{
            .{ .offset = 0x10000000, .length = 2048 * 1024, .kind = .flash },
            .{ .offset = 0x20000000, .length = 256 * 1024, .kind = .ram },
        },
        .flash_algorithms = comptime &.{
            .{
                .name = "RP2350-probe-rs",
                .memory_range = .{
                    .start = 0x10000000,
                    .size = 0x8000000,
                },
                .instructions = "8LUDr4ewFEZaTX1EKHgAKAfQXkh4RABogEddSHhEAGiARwEmLnBgHgMoANON4EhIAPAO+QxGAChf0UZIgBwA8Af5ACgB0AxGV+AGlBAiEHhBTE0oUdERIxh4dShN0RIgApAAeAIoCtABKEbRA5MEkgWRFCAAiBghCog4SQjgA5MEkgWRAPDU+BYgAogzSAQhkEczTAAoIkYA0AJGACgFmQSYA5sp0AB4LkxNKCXRGHh1KCLRApgAeAIoBZEBkgfQASga0RQgAIgYIQqIJkkF4ADwrvgWIAKII0gEIZBHI0wAKCJGANACRgAoBtAEkiBIAPCu+AxGACgC0CBGB7DwvRRIAPCl+AAondEDkQaYACgZ0AaYgEcFmIBHF0h4RAGZAWAWSHhEBpkBYBVIeEQEmQFgFEh4RARgE0h4RAOZAWAucAAk2ecFnNfnAPCr+MBGSUYAAENYAABSRQAQUkUAAFJFACBSUAAQUlAAAFJQACBGQwAAngIAAJQBAACIAQAAiAEAAIQBAACCAQAApAIAAKACAADQtQKvCEx8RCB4ASgK0QdIeEQAaIBHBkh4RABogEcAICBw0L0BINC9DgEAABQBAAAQAQAA0LUCrwlJeUQJeAEpDNEPIQkHQBgGSXlEDGgBIhEDEgTYI6BHACDQvQEg0L3aAAAA0gAAANC1Aq8LRglJeUQJeAEpCtEPIQkHQBgGSXlEDGgRRhpGoEcAINC9ASDQvcBGpAAAAKAAAAAGSF/0QEEBYDDuEPcE1EDsgAdA7IEHQL9wRwAAiO0A4NC1Aq+EshAgAHhNKA/RESAAeHUoC9ESIAB4AigL0AEoBdEUIACIGCEKiCFGCeABIAEHYRjQvf/30/8WIAKIBCEgRpBHAUZAQkhBACny0QEhSQfu54C1AK8A3v7eANTU1AAAAAAAAAAAAAAAAAAAAAAAAAAA",
                .init_fn = 1,
                .uninit_fn = 405,
                .program_page_fn = 509,
                .erase_sector_fn = 457,
                .data_section_offset = 0,
                .page_size = 0x1000,
                .erased_byte_value = 0xff,
                .program_page_timeout = 1000,
                .erase_sector_timeout = 3000,
                .sectors = &.{.{ .addr = 0x0, .size = 0x1000 }},
            },
        },
        .memory = rp2350.core0_ap.memory(),
        .debug = rp2350.cores.debug(),
        .vtable = comptime &.{
            .system_reset = system_reset,
        },
    };
}

pub fn deinit(rp2040: *RP2350) void {
    rp2040.target.deinit();
}

fn system_reset(target: *Target) Target.ResetError!void {
    // NOTE: Currently broken. Leads to weird behaviour
    const rp2350: *RP2350 = @fieldParentPtr("target", target);
    for (0..10) |i| {
        std.log.debug("attempt {} to reset RP2350", .{i});
        do_system_reset(rp2350) catch {
            std.log.info("failed to reset RP2350... attempt {}", .{i});
            continue;
        };
        break;
    } else return error.ResetFailed;
}

fn do_system_reset(rp2350: *RP2350) !void {
    const CTRL: u64 = 0;
    const RESCUE_RESTART: u32 = 0x8000_0000;

    const backup_ctrl_stat = try rp2350.adi.dp_reg_read(.default, ADI.regs.dp.CTRL_STAT.addr);

    // reset system
    var ctrl = try rp2350.adi.ap_reg_read(RP_AP, CTRL);
    try rp2350.adi.ap_reg_write(RP_AP, CTRL, ctrl | RESCUE_RESTART);
    ctrl = try rp2350.adi.ap_reg_read(RP_AP, CTRL);
    try rp2350.adi.ap_reg_write(RP_AP, CTRL, ctrl & ~RESCUE_RESTART);

    // after full chip reset, we should reinit adi and mem aps
    try rp2350.adi.reinit();

    try rp2350.adi.dp_reg_write(.default, ADI.regs.dp.CTRL_STAT.addr, backup_ctrl_stat);

    try rp2350.core0_ap.reinit();
    try rp2350.core1_ap.reinit();

    rp2350.target.attached_cores = .empty;
    rp2350.target.halted_cores = .empty;

    // take the boot core out of rescue mode
    try rp2350.target.halt_reset(.boot);

    var dummy_buf: [1]u32 = undefined;
    try rp2350.target.memory.read_u32(0x2000_0000, &dummy_buf);
}
