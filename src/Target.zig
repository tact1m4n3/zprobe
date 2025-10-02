const std = @import("std");

pub const Target = @This();

// Using core masks instead of dedicate interfaces is an interesting design
// choice. It may lead to more efficient code as the riscv debug module
// supports core masks.

// TODO:
// - implement some sort of per core state
// - implement locking mechanism for different parts (individual cores and memory)

name: []const u8,
core_ids: []const Core_ID,
memory_map: []const MemoryRegion,
vtable: *const Vtable,

pub const UnsupportedError = error{
    Unsupported,
};

pub const MemoryWriteError = UnsupportedError || error{
    AddressMisaligned,
    WriteFailed,
};

pub const MemoryReadError = UnsupportedError || error{
    AddressMisaligned,
    ReadFailed,
};

pub const InvalidCoreError = error{
    InvalidCore,
};

pub const CommandError = InvalidCoreError || error{
    CommandFailed,
};

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
    /// Brings the target to a known state making it ready to be flashed. No
    /// code must run after this commnad.
    system_reset: *const fn (target: *Target) CommandError!void,
    memory: MemoryVtable,
    core_access: CoreAccessVtable,
};

pub const MemoryVtable = struct {
    read: *const fn (target: *Target, addr: u64, data: []u8) MemoryReadError!void,
    write: *const fn (target: *Target, addr: u64, data: []const u8) MemoryWriteError!void,
};

pub const CoreAccessVtable = struct {
    is_halted: *const fn (target: *Target, core_id: Core_ID) CommandError!bool,
    halt: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,
    run: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,

    reset: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,
    halt_reset: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,

    read_register: *const fn (target: *Target, core_id: Core_ID, reg: Register_ID) RegisterReadError!u64,
    write_register: *const fn (target: *Target, core_id: Core_ID, reg: Register_ID, value: u64) RegisterWriteError!void,
};

/// Brings the target to a known state making it ready to be flashed. No code
/// must run after this commnad.
pub fn system_reset(target: *Target) CommandError!void {
    return target.vtable.system_reset(target);
}

/// Reads target memory.
pub fn read_memory(target: *Target, addr: u64, data: []u8) MemoryReadError!void {
    try target.vtable.memory.read(target, addr, data);
}

/// Writes target memory.
pub fn write_memory(target: *Target, addr: u64, data: []const u8) MemoryWriteError!void {
    try target.vtable.memory.write(target, addr, data);
}

/// Returns true if the core is halted.
pub fn is_halted(target: *Target, core_id: Core_ID) CommandError!bool {
    return try target.vtable.core_access.is_halted(target, core_id);
}

/// Halts all selected cores.
pub fn halt(target: *Target, core_mask: CoreMask) CommandError!void {
    try target.vtable.core_access.halt(target, core_mask);
}

/// Resumes execution on all selected cores.
pub fn run(target: *Target, core_mask: CoreMask) CommandError!void {
    try target.vtable.core_access.run(target, core_mask);
}

/// Resets all selected cores. After this reset the selected cores will be running.
pub fn reset(target: *Target, core_mask: CoreMask) CommandError!void {
    try target.vtable.core_access.reset(target, core_mask);
}

/// Resets all selected cores. After this reset the selected cores will be halted.
pub fn halt_reset(target: *Target, core_mask: CoreMask) CommandError!void {
    return target.vtable.core_access.halt_reset(target, core_mask);
}

/// Reads from a cpu register. The core must be halted.
// TODO: maybe we can check this somehow
pub fn read_register(target: *Target, core_id: Core_ID, reg: Register_ID) RegisterReadError!u64 {
    return target.vtable.core_access.read_register(target, core_id, reg);
}

/// Writes to a cpu register. The core must be halted.
pub fn write_register(target: *Target, core_id: Core_ID, reg: Register_ID, value: u64) RegisterWriteError!void {
    return target.vtable.core_access.write_register(target, core_id, reg, value);
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

pub const CoreState = struct {
    halted: bool,
    catch_reset: bool,
};

pub const Register_ID = union(enum) {
    special: enum {
        ip,
        sp,
        fp,
    },
    arg: u16,
    number: u16,
};

pub const MemoryRegion = struct {
    offset: u64,
    length: u64,
    kind: Kind,

    pub const Kind = enum {
        flash,
        ram,
    };
};
