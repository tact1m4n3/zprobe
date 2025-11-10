const std = @import("std");

const ARM_DebugInterface = @import("arch/ARM_DebugInterface.zig");
const libusb = @import("libusb.zig");
const c = libusb.c;
pub const CMSIS_DAP = @import("probes/CMSIS_DAP.zig");

const Probe = @This();

ptr: *anyopaque,
vtable: *const Vtable,

pub const AttachError = error{AttachFailed};

pub const Vtable = struct {
    destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    attach: *const fn (ptr: *anyopaque, speed: Speed) AttachError!void,
    detach: *const fn (ptr: *anyopaque) void,
    arm_debug_interface: *const fn (ptr: *anyopaque) ?*ARM_DebugInterface = default_arm_debug_interface,
    // TODO: support riscv
};

pub fn create(allocator: std.mem.Allocator, filter: libusb.DeviceIterator.Filter) !Probe {
    var device_it: libusb.DeviceIterator = try .init(filter);
    defer device_it.deinit();

    while (try device_it.next()) |device| {
        is_cmsis_dap: {
            const cmsis_dap = CMSIS_DAP.create_with_device(allocator, device) catch |err| switch (err) {
                error.InvalidDevice => break :is_cmsis_dap,
                else => return err,
            };

            return cmsis_dap.probe();
        }

        // TODO: add support for other probes
    } else return error.NoProbeFound;
}

pub fn destroy(probe: Probe, allocator: std.mem.Allocator) void {
    probe.vtable.destroy(probe.ptr, allocator);
}

pub fn attach(probe: Probe, speed: Speed) !void {
    try probe.vtable.attach(probe.ptr, speed);
}

pub fn detach(probe: Probe) void {
    probe.vtable.detach(probe.ptr);
}

pub fn arm_debug_interface(probe: Probe) ?*ARM_DebugInterface {
    return probe.vtable.arm_debug_interface(probe.ptr);
}

pub fn default_arm_debug_interface(ptr: *anyopaque) ?*ARM_DebugInterface {
    _ = ptr;
    return null;
}

pub const Speed = enum(u32) {
    _,

    pub fn hz(speed_in_hz: u32) Speed {
        return @enumFromInt(speed_in_hz);
    }

    pub fn khz(speed_in_khz: u32) Speed {
        return @enumFromInt(speed_in_khz * 1_000);
    }

    pub fn mhz(speed_in_mhz: u32) Speed {
        return @enumFromInt(speed_in_mhz * 1_000_000);
    }

    pub fn format(speed: Speed, writer: *std.Io.Writer) !void {
        const speed_in_hz = @intFromEnum(speed);
        if (speed_in_hz >= 1_000_000) {
            try writer.print("{}MHz", .{speed_in_hz / 1_000_000});
        } else if (speed_in_hz >= 1_000) {
            try writer.print("{}kHz", .{speed_in_hz / 1_000});
        } else {
            try writer.print("{}Hz", .{speed_in_hz});
        }
    }
};
