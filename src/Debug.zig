const std = @import("std");

const Debug = @This();

ptr: *anyopaque,
vtable: *const Vtable,

pub const InvalidCoreError = error{InvalidCore};

pub const CommandError = error{CommandFailed};
pub const TargetedCommandError = InvalidCoreError || CommandError;

pub const RegisterReadError = InvalidCoreError || error{
    InvalidRegister,
    ReadFailed,
};
pub const RegisterWriteError = InvalidCoreError || error{
    InvalidRegister,
    RegisterOnly32Bit,
    WriteFailed,
};

pub const Vtable = struct {
    attach: *const fn (ptr: *anyopaque, core_id: CoreId, should_halt: bool) TargetedCommandError!void,
    detach: *const fn (ptr: *anyopaque, core_id: CoreId) TargetedCommandError!void,

    is_halted: *const fn (ptr: *anyopaque, core_id: CoreId) TargetedCommandError!bool,
    halt: *const fn (ptr: *anyopaque, core_mask: CoreMask) CommandError!void,
    run: *const fn (ptr: *anyopaque, core_mask: CoreMask) CommandError!void,

    reset: *const fn (ptr: *anyopaque, core_mask: CoreMask) CommandError!void,
    halt_reset: *const fn (ptr: *anyopaque, core_mask: CoreMask) CommandError!void,

    read_register: *const fn (ptr: *anyopaque, core_id: CoreId, reg: RegisterId) RegisterReadError!u64,
    write_register: *const fn (ptr: *anyopaque, core_id: CoreId, reg: RegisterId, value: u64) RegisterWriteError!void,
};

pub fn attach(debug: Debug, core_id: CoreId, should_halt: bool) TargetedCommandError!void {
    return debug.vtable.attach(debug.ptr, core_id, should_halt);
}

pub fn detach(debug: Debug, core_id: CoreId) TargetedCommandError!void {
    return debug.vtable.detach(debug.ptr, core_id);
}

pub fn is_halted(debug: Debug, core_id: CoreId) TargetedCommandError!bool {
    return debug.vtable.is_halted(debug.ptr, core_id);
}

pub fn halt(debug: Debug, core_mask: CoreMask) CommandError!void {
    return debug.vtable.halt(debug.ptr, core_mask);
}

pub fn run(debug: Debug, core_mask: CoreMask) CommandError!void {
    return debug.vtable.run(debug.ptr, core_mask);
}

pub fn reset(debug: Debug, core_mask: CoreMask) CommandError!void {
    return debug.vtable.reset(debug.ptr, core_mask);
}

pub fn halt_reset(debug: Debug, core_mask: CoreMask) CommandError!void {
    return debug.vtable.halt_reset(debug.ptr, core_mask);
}

pub fn read_register(debug: Debug, core_id: CoreId, reg: RegisterId) RegisterReadError!u64 {
    return debug.vtable.read_register(debug.ptr, core_id, reg);
}

pub fn write_register(debug: Debug, core_id: CoreId, reg: RegisterId, value: u64) RegisterWriteError!void {
    return debug.vtable.write_register(debug.ptr, core_id, reg, value);
}

pub const CoreId = enum(u6) {
    _,

    pub const boot: CoreId = @enumFromInt(0);

    pub fn num(n: u6) CoreId {
        return @enumFromInt(n);
    }
};

pub const CoreMask = enum(u64) {
    _,

    pub const empty: CoreMask = @enumFromInt(0);
    pub const all: CoreMask = @enumFromInt(std.math.maxInt(u64));
    pub const boot: CoreMask = .with_id(.boot);

    pub fn with_id(id: CoreId) CoreMask {
        return @enumFromInt(@as(u64, 1) << @intFromEnum(id));
    }

    pub fn with_ids(ids: []const CoreId) CoreMask {
        var mask: u64 = 0;
        for (ids) |n| {
            mask |= @as(u64, 1) << @intFromEnum(n);
        }
        return @enumFromInt(mask);
    }

    pub fn is_selected(self: CoreMask, id: CoreId) bool {
        return @intFromEnum(self) & (@as(u64, 1) << @intFromEnum(id)) != 0;
    }

    pub fn contains_any(self: CoreMask, other: CoreMask) bool {
        return @intFromEnum(self) & @intFromEnum(other) != 0;
    }

    pub fn contains_all(self: CoreMask, other: CoreMask) bool {
        return @intFromEnum(self) & @intFromEnum(other) == @intFromEnum(other);
    }

    pub fn combine(self: CoreMask, other: CoreMask) CoreMask {
        return @enumFromInt(@intFromEnum(self) | @intFromEnum(other));
    }

    pub fn subtract(self: CoreMask, other: CoreMask) CoreMask {
        return @enumFromInt(@intFromEnum(self) & ~@intFromEnum(other));
    }

    pub fn apply_mask(self: CoreMask, mask: CoreMask) CoreMask {
        return @enumFromInt(@intFromEnum(self) & @intFromEnum(mask));
    }

    pub fn invert(self: CoreMask) CoreMask {
        return ~@intFromEnum(self);
    }
};

pub const RegisterId = union(enum) {
    instruction_pointer,
    stack_pointer,
    frame_pointer,
    return_address,

    return_value,
    arg: u16,

    number: u16,
};
