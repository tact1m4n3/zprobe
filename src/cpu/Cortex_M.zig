const std = @import("std");

const Memory = @import("../Memory.zig");
const Timeout = @import("../Timeout.zig");

const Cortex_M = @This();

memory: Memory,

pub const AIRCR_VECTKEY = 0x05FA;
pub const DHCSR_DEBUGKEY = 0xA05F;

/// Enables debug
pub fn init(memory: Memory) !Cortex_M {
    try regs.armv6m.DHCSR_0_15.write(memory, .{
        .C_DEBUGEN = 1,
        .C_MASKINTS = 0,
        .C_HALT = 0,
        .C_STEP = 0,
        .DBGKEY = DHCSR_DEBUGKEY,
    });

    return .{
        .memory = memory,
    };
}

pub fn deinit(cortex_m: Cortex_M) void {
    regs.armv6m.DHCSR_0_15.write(cortex_m.memory, .{
        .C_DEBUGEN = 0,
        .C_MASKINTS = 0,
        .C_HALT = 0,
        .C_STEP = 0,
        .DBGKEY = DHCSR_DEBUGKEY,
    }) catch {};
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
    while (!try cortex_m.is_core_halted()) {
        try timeout.tick();
    }
}

pub fn is_core_halted(cortex_m: Cortex_M) !bool {
    const dhcsr = try regs.armv6m.DHCSR_16_31.read(cortex_m.memory);
    return dhcsr.C_HALT == 1 and dhcsr.S_HALT == 1;
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

pub fn set_catch_reset(cortex_m: Cortex_M, enable: bool) !void {
    try regs.armv6m.DEMCR.modify(cortex_m.memory, .{
        .VC_CORERESET = @intFromBool(enable),
    });
}

pub fn set_catch_fault(cortex_m: Cortex_M, enable: bool) !void {
    try regs.armv6m.DEMCR.modify(cortex_m.memory, .{
        .VC_HARDERR = @intFromBool(enable),
    });
}

/// Call only if the core is halted.
pub fn reset(cortex_m: Cortex_M) !void {
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

/// Call only if the core is halted.
pub fn read_cpu_register(cortex_m: Cortex_M, reg: CPU_Register) !u32 {
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

/// Call only if the core is halted.
pub fn write_cpu_register(cortex_m: Cortex_M, reg: CPU_Register, value: u32) !void {
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

pub const CPU_Register = enum(u5) {
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
            REGSEL: CPU_Register,
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
