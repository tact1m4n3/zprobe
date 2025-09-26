const std = @import("std");

const Memory = @import("Memory.zig");

pub const Target = @This();

// Using core masks instead of dedicate interfaces is an interesting design
// choice. It may lead to more efficient code as the riscv debug module
// supports core masks.

// TODO: maybe we should keep a core state here. This would allow to add some
// checks to ensure the correct use of the interface. The core state list would
// have to be heap allocated.

vtable: *const Vtable,
core_ids: []const Core_ID,

memory_map: []const MemoryRegion,

pub const Vtable = struct {
    system_reset: *const fn (target: *Target) CommandError!void,
    memory: *const fn (target: *Target) Memory,
    core_access: CoreAccessVtable,
};

pub const CoreAccessVtable = struct {
    halt: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,
    run: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,

    reset: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,
    halt_reset: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,

    read_core_register: *const fn (target: *Target, core_id: Core_ID, reg: Register_ID) RegisterReadError!u64,
    write_core_register: *const fn (target: *Target, core_id: Core_ID, reg: Register_ID, value: u64) RegisterWriteError!void,
};

pub const CommandError = error{
    CommandFailed,
};

pub const InvalidCoreError = error{
    InvalidCore,
};

pub const RegisterReadError = InvalidCoreError || error{
    InvalidRegister,
    ReadFailed,
};
pub const RegisterWriteError = InvalidCoreError || error{
    InvalidRegister,
    Expected32BitValue,
    WriteFailed,
};

pub fn system_reset(target: *Target) CommandError!void {
    return target.vtable.system_reset(target);
}

pub fn memory(target: *Target) Memory {
    return target.vtable.memory(target);
}

pub fn halt(target: *Target, core_mask: CoreMask) CommandError!void {
    return target.vtable.core_access.halt(target, core_mask);
}

pub fn run(target: *Target, core_mask: CoreMask) CommandError!void {
    return target.vtable.core_access.run(target, core_mask);
}

pub fn reset(target: *Target, core_mask: CoreMask) CommandError!void {
    return target.vtable.core_access.reset(target, core_mask);
}

pub fn halt_reset(target: *Target, core_mask: CoreMask) CommandError!void {
    return target.vtable.core_access.halt_reset(target, core_mask);
}

pub fn read_core_register(target: *Target, core_id: Core_ID, reg: Register_ID) RegisterReadError!u64 {
    return target.vtable.core_access.read_core_register(target, core_id, reg);
}

pub fn write_core_register(target: *Target, core_id: Core_ID, reg: Register_ID, value: u64) RegisterWriteError!void {
    return target.vtable.core_access.write_core_register(target, core_id, reg, value);
}

pub const Core_ID = enum(u6) {
    _,

    pub const boot: Core_ID = @enumFromInt(0);

    pub fn num(n: u6) Core_ID {
        return @enumFromInt(n);
    }
};

pub const CoreMask = enum(u64) {
    _,

    pub const all: CoreMask = @enumFromInt(std.math.maxInt(u64));
    pub const boot: CoreMask = .with_id(.boot);

    pub fn is_selected(mask: CoreMask, id: Core_ID) bool {
        return @intFromEnum(mask) & (@as(u64, 1) << @intFromEnum(id)) != 0;
    }

    pub fn with_id(id: Core_ID) CoreMask {
        return @enumFromInt(@as(u64, 1) << @intFromEnum(id));
    }

    pub fn with_ids(ids: []const Core_ID) CoreMask {
        var mask: u64 = 0;
        for (ids) |n| {
            mask |= @as(u64, 1) << @intFromEnum(n);
        }
        return @enumFromInt(mask);
    }
};

pub const Register_ID = union(enum) {
    special: enum {
        ip,
        sp,
        fp,
    },
    specific: u16,
};

pub const MemoryRegion = struct {
    base: u64,
    size: u64,
    kind: enum {
        flash,
        ram,
    },
};
