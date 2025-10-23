const std = @import("std");

const ARM_DebugInterface = @import("arch/ARM_DebugInterface.zig");
const libusb = @import("libusb.zig");
const c = libusb.c;

pub const CMSIS_DAP = @import("probes/CMSIS_DAP.zig");

pub const Tag = enum {
    cmsis_dap,
};

pub const Any = union(Tag) {
    cmsis_dap: CMSIS_DAP,

    pub fn detect_usb(allocator: std.mem.Allocator, filter: libusb.DeviceIterator.Filter) !Any {
        var device_it: libusb.DeviceIterator = try .init(filter);
        defer device_it.deinit();

        while (try device_it.next()) |device| {
            is_cmsis_dap: {
                const cmsis_dap = CMSIS_DAP.init_with_device(allocator, device) catch |err| switch (err) {
                    error.InvalidDevice => break :is_cmsis_dap,
                    else => return err,
                };
                return .{ .cmsis_dap = cmsis_dap };
            }

            // TODO: add support for other probes
        } else return error.NoProbeFound;
    }

    pub fn deinit(any_probe: *Any) void {
        return switch (any_probe.*) {
            inline else => |*probe| probe.deinit(),
        };
    }

    pub fn attach(any_probe: *Any, speed: Speed) !void {
        return switch (any_probe.*) {
            inline else => |*probe| try probe.attach(speed),
        };
    }

    pub fn detach(any_probe: *Any) void {
        return switch (any_probe.*) {
            inline else => |*probe| probe.detach(),
        };
    }

    pub fn arm_debug_interface(any_probe: *Any) ?*ARM_DebugInterface {
        return switch (any_probe.*) {
            inline .cmsis_dap => |*probe| &probe.adi,
        };
    }
};

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
            try writer.print("{} MHz", .{speed_in_hz / 1_000_000});
        } else if (speed_in_hz >= 1_000) {
            try writer.print("{} kHz", .{speed_in_hz / 1_000});
        } else {
            try writer.print("{} Hz", .{speed_in_hz});
        }
    }
};
