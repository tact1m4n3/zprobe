const std = @import("std");

const flash = @import("flash.zig");
pub const Memory = @import("Memory.zig");
pub const Debug = @import("Debug.zig");
pub const CoreId = Debug.CoreId;
pub const CoreMask = Debug.CoreMask;
pub const RegisterId = Debug.RegisterId;

pub const Target = @This();

name: []const u8,
endian: std.builtin.Endian = .little,
arch: Arch,
valid_cores: CoreMask,
attached_cores: CoreMask = .empty,
halted_cores: CoreMask = .empty,
memory_map: []const MemoryRegion,
flash_algorithms: []const flash.Algorithm,
memory: Memory,
debug: Debug,
vtable: *const Vtable,

// TODO: maybe make a tagged union with a custom variant or use a struct with
// decl literals (I would like to explore the latter one)
pub const Arch = enum {
    thumb,
    riscv32,
};

pub const ResetError = error{
    ResetFailed,
};

pub const Vtable = struct {
    /// Brings the target to a known state making it ready to be flashed. All
    /// cores should be halted after this command.
    system_reset: *const fn (target: *Target) ResetError!void,
};

pub fn deinit(target: *Target) void {
    for (0..std.math.maxInt(u6)) |i| {
        const id: CoreId = .num(@intCast(i));
        if (target.attached_cores.is_selected(id)) {
            target.debug.detach(id) catch {};
        }
    }
}

/// Brings the target to a known state making it ready to be flashed. No code
/// must run after this commnad.
pub fn system_reset(target: *Target) ResetError!void {
    try target.vtable.system_reset(target);
}

/// Returns true if the core is halted.
pub fn is_halted(target: *Target, core_id: CoreId) !bool {
    if (target.halted_cores.is_selected(core_id)) return true;
    try target.ensure_core_attached(core_id);
    const state = try target.debug.is_halted(core_id);
    if (state) {
        target.halted_cores = target.halted_cores.combine(.with_id(core_id));
    }
    return state;
}

/// Halts all selected cores.
pub fn halt(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.debug.halt(core_mask.subtract(target.halted_cores));
    target.halted_cores = target.halted_cores.combine(core_mask);
}

/// Resumes execution on all selected cores.
pub fn run(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.debug.run(core_mask);
    target.halted_cores = target.halted_cores.subtract(core_mask);
}

/// Resets all selected cores. After this reset the selected cores will be running.
pub fn reset(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.debug.reset(core_mask);
    target.halted_cores = target.halted_cores.subtract(core_mask);
}

/// Resets all selected cores. After this reset the selected cores will be halted.
pub fn halt_reset(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.debug.halt_reset(core_mask);
    target.halted_cores = target.halted_cores.combine(core_mask);
}

/// Reads from a cpu register. The core must be halted.
// TODO: maybe we can check this somehow
pub fn read_register(target: *Target, core_id: CoreId, reg: RegisterId) !u64 {
    if (!target.halted_cores.is_selected(core_id)) return error.RegisterReadWhileCoreRunning;
    try target.ensure_core_attached(core_id);
    return target.debug.read_register(core_id, reg);
}

/// Writes to a cpu register. The core must be halted.
pub fn write_register(target: *Target, core_id: CoreId, reg: RegisterId, value: u64) !void {
    if (!target.halted_cores.is_selected(core_id)) return error.RegisterWriteWhileCoreRunning;
    try target.ensure_core_attached(core_id);
    return target.debug.write_register(core_id, reg, value);
}

pub fn find_memory_region_kind(
    target: *Target,
    addr: u64,
    len: u64,
) ?Target.MemoryRegion.Kind {
    for (target.memory_map) |region| {
        if (region.offset <= addr and addr + len < region.offset + region.length) {
            return region.kind;
        }
    } else return null;
}

fn ensure_core_attached(target: *Target, core_id: CoreId) !void {
    if (target.attached_cores.is_selected(core_id)) return;
    try target.debug.attach(core_id, target.halted_cores.is_selected(core_id));
    target.attached_cores = target.attached_cores.combine(.with_id(core_id));
}

fn ensure_core_mask_attached(target: *Target, core_mask: CoreMask) !void {
    if (target.attached_cores.contains_all(core_mask)) return;

    for (0..std.math.maxInt(u6)) |i| {
        const id: CoreId = .num(@intCast(i));
        if (core_mask.is_selected(id)) {
            try target.debug.attach(id, target.halted_cores.is_selected(id));
        }
    }
    target.attached_cores = target.attached_cores.combine(core_mask);
}

pub const MemoryRegion = struct {
    offset: u64,
    length: u64,
    kind: Kind,

    pub const Kind = union(enum) {
        flash,
        ram,
    };
};
