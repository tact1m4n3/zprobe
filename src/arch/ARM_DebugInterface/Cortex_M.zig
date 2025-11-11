const std = @import("std");

const Timeout = @import("../../Timeout.zig");
const Memory = @import("../../Memory.zig");
const Debug = @import("../../Debug.zig");

const Cortex_M = @This();

memory: Memory,

pub fn attach(cortex_m: Cortex_M, should_halt: bool) !void {
    try regs.armv6m.DHCSR_0_15.write(cortex_m.memory, .{
        .C_DEBUGEN = 1,
        .C_MASKINTS = 0,
        .C_HALT = @intFromBool(should_halt),
        .C_STEP = 0,
        .DBGKEY = DHCSR_DEBUGKEY,
    });
}

pub fn detach(cortex_m: Cortex_M) !void {
    try regs.armv6m.DHCSR_0_15.write(cortex_m.memory, .{
        .C_DEBUGEN = 0,
        .C_MASKINTS = 0,
        .C_HALT = 0,
        .C_STEP = 0,
        .DBGKEY = DHCSR_DEBUGKEY,
    });
}

pub fn is_halted(cortex_m: Cortex_M) !bool {
    return (try regs.armv6m.DHCSR_16_31.read(cortex_m.memory)).C_HALT == 1;
}

pub fn halt(cortex_m: Cortex_M) !void {
    try regs.armv6m.DHCSR_0_15.write(cortex_m.memory, .{
        .C_DEBUGEN = 1,
        .C_MASKINTS = 0,
        .C_HALT = 1,
        .C_STEP = 0,
        .DBGKEY = DHCSR_DEBUGKEY,
    });

    const timeout: Timeout = try .init(.{});
    while ((try regs.armv6m.DHCSR_16_31.read(cortex_m.memory)).C_HALT == 0) {
        try timeout.tick();
    }
}

pub fn run(cortex_m: Cortex_M) !void {
    try regs.armv6m.DHCSR_0_15.write(cortex_m.memory, .{
        .C_DEBUGEN = 1,
        .C_MASKINTS = 0,
        .C_HALT = 0,
        .C_STEP = 0,
        .DBGKEY = DHCSR_DEBUGKEY,
    });
}

pub fn reset(cortex_m: Cortex_M) !void {
    try regs.armv6m.DEMCR.modify(cortex_m.memory, .{
        .VC_CORERESET = 0,
    });

    try cortex_m.reset_common();
}

pub fn halt_reset(cortex_m: Cortex_M) !void {
    try regs.armv6m.DEMCR.modify(cortex_m.memory, .{
        .VC_CORERESET = 1,
    });

    try cortex_m.reset_common();
}

fn reset_common(cortex_m: Cortex_M) !void {
    try regs.armv6m.AIRCR.modify(cortex_m.memory, .{
        .SYSRESETREQ = 1,
        .VECTKEY = AIRCR_VECTKEY,
    });

    const timeout: Timeout = try .init(.{
        .sleep_per_tick_ns = 10 * std.time.ns_per_ms,
    });
    while ((try regs.armv6m.DHCSR_16_31.read(cortex_m.memory)).S_RESET_ST == 0) {
        try timeout.tick();
    }
}

pub fn read_register(cortex_m: Cortex_M, reg: RegisterId) !u32 {
    try regs.armv6m.DCRSR.write(cortex_m.memory, .{
        .REGSEL = reg,
        .REGWnR = .read,
    });

    const timeout: Timeout = try .init(.{});
    while ((try regs.armv6m.DHCSR_16_31.read(cortex_m.memory)).S_REGRDY == 0) {
        try timeout.tick();
    }

    return try regs.armv6m.DCRDR.raw_read(cortex_m.memory);
}

pub fn write_register(cortex_m: Cortex_M, reg: RegisterId, value: u32) !void {
    try regs.armv6m.DCRDR.raw_write(cortex_m.memory, value);

    try regs.armv6m.DCRSR.write(cortex_m.memory, .{
        .REGSEL = reg,
        .REGWnR = .write,
    });

    const timeout: Timeout = try .init(.{});
    while ((try regs.armv6m.DHCSR_16_31.read(cortex_m.memory)).S_REGRDY == 0) {
        try timeout.tick();
    }
}

pub const RegisterId = enum(u5) {
    r0 = 0,
    r1,
    r2,
    r3,
    r4,
    r5,
    r6,
    r7,
    r8,
    r9,
    r10,
    r11,
    r12,
    sp,
    lr,
    debug_return_address,
    xpsr,
    msp,
    psp,
    primask_control = 0b10100,
};

pub const AIRCR_VECTKEY = 0x05FA;
pub const DHCSR_DEBUGKEY = 0xA05F;

pub const regs = struct {
    pub const armv6m = struct {
        pub const AIRCR = Register(0xE000ED0C, packed struct(u32) {
            reserved0: u1 = 0,
            VECTCLRACTIVE: u1,
            SYSRESETREQ: u1,
            reserved1: u12 = 0,
            ENDIANESS: u1,
            VECTKEY: u16,
        });

        pub const DHCSR_0_15 = Register(0xE000EDF0, packed struct(u32) {
            C_DEBUGEN: u1,
            C_HALT: u1,
            C_STEP: u1,
            C_MASKINTS: u1,
            reserved0: u12 = 0,
            DBGKEY: u16,
        });

        pub const DHCSR_16_31 = Register(0xE000EDF0, packed struct(u32) {
            C_DEBUGEN: u1,
            C_HALT: u1,
            C_STEP: u1,
            C_MASKINTS: u1,
            reserved0: u12 = 0,
            S_REGRDY: u1,
            S_HALT: u1,
            S_SLEEP: u1,
            S_LOCKUP: u1,
            reserved1: u4 = 0,
            S_RETIRE_ST: u1,
            S_RESET_ST: u1,
            reserved2: u6 = 0,
        });

        pub const DCRSR = Register(0xE000EDF4, packed struct(u32) {
            REGSEL: RegisterId,
            reserved0: u11 = 0,
            REGWnR: enum(u1) {
                read = 0,
                write = 1,
            },
            reserved1: u15 = 0,
        });

        pub const DCRDR = Register(0xE000EDF8, packed struct(u32) {
            DATA: u32,
        });

        pub const DEMCR = Register(0xE000EDFC, packed struct(u32) {
            VC_CORERESET: u1,
            reserved0: u9 = 0,
            VC_HARDERR: u1,
            reserved1: u13 = 0,
            DWTENA: u1,
            reserved2: u7 = 0,
        });
    };
};

pub fn Register(reg_addr: u32, comptime T: type) type {
    return struct {
        pub const Type = T;
        pub const addr = reg_addr;

        pub inline fn raw_read(memory: Memory) !u32 {
            var buf: [1]u32 = undefined;
            try memory.read_u32(reg_addr, &buf);
            return buf[0];
        }

        pub inline fn raw_write(memory: Memory, value: u32) !void {
            try memory.write_u32(reg_addr, &.{value});
        }

        pub inline fn read(memory: Memory) !T {
            return @bitCast(try raw_read(memory));
        }

        pub inline fn write(memory: Memory, value: T) !void {
            try raw_write(memory, @bitCast(value));
        }

        pub inline fn modify(memory: Memory, value: anytype) !void {
            var new = try read(memory);
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                @field(new, field.name) = @field(value, field.name);
            }
            try write(memory, new);
        }
    };
}

pub fn System(comptime core_ids: []const Debug.CoreId) type {
    return struct {
        const Self = @This();

        cpus: [core_ids.len]Cortex_M,

        pub fn init(memories: [core_ids.len]Memory) Self {
            var self: Self = undefined;
            inline for (0..core_ids.len) |i| {
                self.cpus[i] = .{ .memory = memories[i] };
            }
            return self;
        }

        pub fn debug(self: *Self) Debug {
            return .{
                .ptr = self,
                .vtable = &.{
                    .attach = debug_attach,
                    .detach = debug_detach,
                    .is_halted = debug_is_halted,
                    .halt = debug_halt,
                    .run = debug_run,
                    .reset = debug_reset,
                    .halt_reset = debug_halt_reset,
                    .read_register = debug_read_register,
                    .write_register = debug_write_register,
                },
            };
        }

        pub fn debug_attach(ptr: *anyopaque, core_id: Debug.CoreId, should_halt: bool) Debug.TargetedCommandError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (current_id == core_id) {
                    return self.cpus[i].attach(should_halt) catch error.CommandFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn debug_detach(ptr: *anyopaque, core_id: Debug.CoreId) Debug.TargetedCommandError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (current_id == core_id) {
                    return self.cpus[i].detach() catch error.CommandFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn debug_is_halted(ptr: *anyopaque, core_id: Debug.CoreId) Debug.TargetedCommandError!bool {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (current_id == core_id) {
                    return self.cpus[i].is_halted() catch error.CommandFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn debug_halt(ptr: *anyopaque, core_mask: Debug.CoreMask) Debug.CommandError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (core_mask.is_selected(current_id)) {
                    return self.cpus[i].halt() catch error.CommandFailed;
                }
            }
        }

        pub fn debug_run(ptr: *anyopaque, core_mask: Debug.CoreMask) Debug.CommandError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (core_mask.is_selected(current_id)) {
                    return self.cpus[i].run() catch error.CommandFailed;
                }
            }
        }

        pub fn debug_reset(ptr: *anyopaque, core_mask: Debug.CoreMask) Debug.CommandError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (core_mask.is_selected(current_id)) {
                    return self.cpus[i].reset() catch error.CommandFailed;
                }
            }
        }

        pub fn debug_halt_reset(ptr: *anyopaque, core_mask: Debug.CoreMask) Debug.CommandError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (core_mask.is_selected(current_id)) {
                    return self.cpus[i].halt_reset() catch error.CommandFailed;
                }
            }
        }

        pub fn debug_read_register(ptr: *anyopaque, core_id: Debug.CoreId, reg: Debug.RegisterId) Debug.RegisterReadError!u64 {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (current_id == core_id) {
                    return self.cpus[i].read_register(try get_cm_reg(reg)) catch error.ReadFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn debug_write_register(ptr: *anyopaque, core_id: Debug.CoreId, reg: Debug.RegisterId, value: u64) Debug.RegisterWriteError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            inline for (core_ids, 0..) |current_id, i| {
                if (current_id == core_id) {
                    if (value > std.math.maxInt(u32)) return error.RegisterOnly32Bit;
                    return self.cpus[i].write_register(try get_cm_reg(reg), @truncate(value)) catch error.WriteFailed;
                }
            } else return error.InvalidCore;
        }
    };
}

fn get_cm_reg(target_reg: Debug.RegisterId) error{InvalidRegister}!RegisterId {
    return switch (target_reg) {
        .instruction_pointer => .debug_return_address,
        .stack_pointer => .sp,
        .frame_pointer => .r11,
        .return_address => .lr,
        .return_value => .r0,
        .arg => |arg| if (arg < 4)
            @enumFromInt(arg)
        else
            return error.InvalidRegister,
        .number => |number| if (number <= 12)
            @enumFromInt(number)
        else
            return error.InvalidRegister,
    };
}
