const std = @import("std");

const Timeout = @import("../../Timeout.zig");
const Target = @import("../../Target.zig");
const Mem_AP = @import("../../arch/ARM_DebugInterface/Mem_AP.zig");

pub fn Impl(Memory: type) type {
    return struct {
        pub fn attach(memory: *Memory, should_halt: bool) !void {
            try regs.armv6m.DHCSR_0_15.write(memory, .{
                .C_DEBUGEN = 1,
                .C_MASKINTS = 0,
                .C_HALT = @intFromBool(should_halt),
                .C_STEP = 0,
                .DBGKEY = DHCSR_DEBUGKEY,
            });
        }

        pub fn detach(memory: *Memory) !void {
            try regs.armv6m.DHCSR_0_15.write(memory, .{
                .C_DEBUGEN = 0,
                .C_MASKINTS = 0,
                .C_HALT = 0,
                .C_STEP = 0,
                .DBGKEY = DHCSR_DEBUGKEY,
            });
        }

        pub fn is_halted(memory: *Memory) !bool {
            return (try regs.armv6m.DHCSR_16_31.read(memory)).C_HALT == 1;
        }

        pub fn halt(memory: *Memory) !void {
            try regs.armv6m.DHCSR_0_15.write(memory, .{
                .C_DEBUGEN = 1,
                .C_MASKINTS = 0,
                .C_HALT = 1,
                .C_STEP = 0,
                .DBGKEY = DHCSR_DEBUGKEY,
            });

            const timeout: Timeout = try .init(.{});
            while ((try regs.armv6m.DHCSR_16_31.read(memory)).C_HALT == 0) {
                try timeout.tick();
            }
        }

        pub fn run(memory: *Memory) !void {
            try regs.armv6m.DHCSR_0_15.write(memory, .{
                .C_DEBUGEN = 1,
                .C_MASKINTS = 0,
                .C_HALT = 0,
                .C_STEP = 0,
                .DBGKEY = DHCSR_DEBUGKEY,
            });
        }

        pub fn reset(memory: *Memory) !void {
            try regs.armv6m.DEMCR.modify(memory, .{
                .VC_CORERESET = 0,
            });

            try reset_common(memory);
        }

        pub fn halt_reset(memory: *Memory) !void {
            try regs.armv6m.DEMCR.modify(memory, .{
                .VC_CORERESET = 1,
            });

            try reset_common(memory);
        }

        fn reset_common(memory: *Memory) !void {
            try regs.armv6m.AIRCR.modify(memory, .{
                .SYSRESETREQ = 1,
                .VECTKEY = AIRCR_VECTKEY,
            });

            const timeout: Timeout = try .init(.{
                .sleep_per_tick_ns = 10 * std.time.ns_per_ms,
            });
            while ((try regs.armv6m.DHCSR_16_31.read(memory)).S_RESET_ST == 0) {
                try timeout.tick();
            }
        }

        pub fn read_register(memory: *Memory, reg: RegisterId) !u32 {
            try regs.armv6m.DCRSR.write(memory, .{
                .REGSEL = reg,
                .REGWnR = .read,
            });

            const timeout: Timeout = try .init(.{});
            while ((try regs.armv6m.DHCSR_16_31.read(memory)).S_REGRDY == 0) {
                try timeout.tick();
            }

            return try regs.armv6m.DCRDR.raw_read(memory);
        }

        pub fn write_register(memory: *Memory, reg: RegisterId, value: u32) !void {
            try regs.armv6m.DCRDR.raw_write(memory, value);

            try regs.armv6m.DCRSR.write(memory, .{
                .REGSEL = reg,
                .REGWnR = .write,
            });

            const timeout: Timeout = try .init(.{});
            while ((try regs.armv6m.DHCSR_16_31.read(memory)).S_REGRDY == 0) {
                try timeout.tick();
            }
        }
    };
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

        pub inline fn raw_read(memory: anytype) !u32 {
            return memory.read_u32(reg_addr);
        }

        pub inline fn raw_write(memory: anytype, value: u32) !void {
            try memory.write_u32(reg_addr, value);
        }

        pub inline fn read(memory: anytype) !T {
            return @bitCast(try raw_read(memory));
        }

        pub inline fn write(memory: anytype, value: T) !void {
            try raw_write(memory, @bitCast(value));
        }

        pub inline fn modify(memory: anytype, value: anytype) !void {
            var new = try read(memory);
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                @field(new, field.name) = @field(value, field.name);
            }
            try write(memory, new);
        }
    };
}

pub fn Multiplex(Parent: type, comptime target_name: []const u8, comptime cpus: []const struct {
    id: Target.CoreId,
    memory_name: []const u8,
}) type {
    return struct {
        const Self = @This();

        pub fn core_access_vtable() Target.CoreAccessVtable {
            return .{
                .attach = target_attach,
                .detach = target_detach,
                .is_halted = target_is_halted,
                .halt = target_halt,
                .run = target_run,
                .reset = target_reset,
                .halt_reset = target_halt_reset,
                .read_register = target_read_register,
                .write_register = target_write_register,
            };
        }

        pub fn target_attach(target: *Target, core_id: Target.CoreId) Target.CommandError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (cpu.id == core_id) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.attach(&@field(parent, cpu.memory_name), target.halted_cores.is_selected(core_id)) catch error.CommandFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn target_detach(target: *Target, core_id: Target.CoreId) Target.CommandError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (cpu.id == core_id) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.detach(&@field(parent, cpu.memory_name)) catch error.CommandFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn target_is_halted(target: *Target, core_id: Target.CoreId) Target.CommandError!bool {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (cpu.id == core_id) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.is_halted(&@field(parent, cpu.memory_name)) catch error.CommandFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn target_halt(target: *Target, core_mask: Target.CoreMask) Target.CommandError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (core_mask.is_selected(cpu.id)) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.halt(&@field(parent, cpu.memory_name)) catch error.CommandFailed;
                }
            }
        }

        pub fn target_run(target: *Target, core_mask: Target.CoreMask) Target.CommandError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (core_mask.is_selected(cpu.id)) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.run(&@field(parent, cpu.memory_name)) catch error.CommandFailed;
                }
            }
        }

        pub fn target_reset(target: *Target, core_mask: Target.CoreMask) Target.CommandError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (core_mask.is_selected(cpu.id)) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.reset(&@field(parent, cpu.memory_name)) catch error.CommandFailed;
                }
            }
        }

        pub fn target_halt_reset(target: *Target, core_mask: Target.CoreMask) Target.CommandError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (core_mask.is_selected(cpu.id)) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.halt_reset(&@field(parent, cpu.memory_name)) catch error.CommandFailed;
                }
            }
        }

        pub fn target_read_register(target: *Target, core_id: Target.CoreId, reg: Target.RegisterId) Target.RegisterReadError!u64 {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (cpu.id == core_id) {
                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.read_register(&@field(parent, cpu.memory_name), try get_cm_reg(reg)) catch error.ReadFailed;
                }
            } else return error.InvalidCore;
        }

        pub fn target_write_register(target: *Target, core_id: Target.CoreId, reg: Target.RegisterId, value: u64) Target.RegisterWriteError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);

            inline for (cpus) |cpu| {
                if (cpu.id == core_id) {
                    if (value > std.math.maxInt(u32)) return error.RegisterOnly32Bit;

                    const CPU_Impl = Impl(@FieldType(Parent, cpu.memory_name));
                    return CPU_Impl.write_register(&@field(parent, cpu.memory_name), try get_cm_reg(reg), @truncate(value)) catch error.WriteFailed;
                }
            } else return error.InvalidCore;
        }
    };
}

fn get_cm_reg(target_reg: Target.RegisterId) error{InvalidRegister}!RegisterId {
    return switch (target_reg) {
        .special => |special| switch (special) {
            .ip => .debug_return_address,
            .sp => .sp,
            .fp => .r11,
        },
        .arg => |arg| if (arg < 4)
            @enumFromInt(arg)
        else
            return error.InvalidRegister,
        .number => |number| if (number < 5)
            @enumFromInt(number)
        else
            return error.InvalidRegister,
    };
}
