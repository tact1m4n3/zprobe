const std = @import("std");

const flash = @import("flash.zig");

pub const Target = @This();

name: []const u8,
endian: std.builtin.Endian,
valid_cores: CoreMask,
attached_cores: CoreMask = .empty,
halted_cores: CoreMask = .empty,
memory_map: []const MemoryRegion,
flash_algorithms: []const flash.Algorithm,
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
    attach: *const fn (target: *Target, core_id: CoreId) CommandError!void,
    detach: *const fn (target: *Target, core_id: CoreId) CommandError!void,

    is_halted: *const fn (target: *Target, core_id: CoreId) CommandError!bool,
    halt: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,
    run: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,

    reset: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,
    halt_reset: *const fn (target: *Target, core_mask: CoreMask) CommandError!void,

    read_register: *const fn (target: *Target, core_id: CoreId, reg: RegisterId) RegisterReadError!u64,
    write_register: *const fn (target: *Target, core_id: CoreId, reg: RegisterId, value: u64) RegisterWriteError!void,
};

pub fn deinit(target: *Target) void {
    for (0..std.math.maxInt(u6)) |i| {
        const id: CoreId = .num(@intCast(i));
        if (target.attached_cores.is_selected(id)) {
            target.vtable.core_access.detach(target, id) catch {};
        }
    }
}

/// Brings the target to a known state making it ready to be flashed. No code
/// must run after this commnad.
pub fn system_reset(target: *Target) !void {
    try target.vtable.system_reset(target);
}

/// Reads target memory.
pub fn read_memory(target: *Target, addr: u64, data: []u8) !void {
    try target.vtable.memory.read(target, addr, data);
}

/// Writes target memory.
pub fn write_memory(target: *Target, addr: u64, data: []const u8) !void {
    try target.vtable.memory.write(target, addr, data);
}

/// Returns true if the core is halted.
pub fn is_halted(target: *Target, core_id: CoreId) !bool {
    if (target.halted_cores.is_selected(core_id)) return true;
    try target.ensure_core_attached(core_id);
    const state = try target.vtable.core_access.is_halted(target, core_id);
    if (state) {
        target.halted_cores = target.halted_cores.combine(.with_id(core_id));
    }
    return state;
}

/// Halts all selected cores.
pub fn halt(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.vtable.core_access.halt(target, core_mask);
    target.halted_cores = target.halted_cores.combine(core_mask);
}

/// Resumes execution on all selected cores.
pub fn run(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.vtable.core_access.run(target, core_mask);
    target.halted_cores = target.halted_cores.subtract(core_mask);
}

/// Resets all selected cores. After this reset the selected cores will be running.
pub fn reset(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.vtable.core_access.reset(target, core_mask);
    target.halted_cores = target.halted_cores.subtract(core_mask);
}

/// Resets all selected cores. After this reset the selected cores will be halted.
pub fn halt_reset(target: *Target, raw_core_mask: CoreMask) !void {
    const core_mask = raw_core_mask.apply_mask(target.valid_cores);
    try target.ensure_core_mask_attached(core_mask);
    try target.vtable.core_access.halt_reset(target, core_mask);
    target.halted_cores = target.halted_cores.combine(core_mask);
}

/// Reads from a cpu register. The core must be halted.
// TODO: maybe we can check this somehow
pub fn read_register(target: *Target, core_id: CoreId, reg: RegisterId) !u64 {
    if (!target.halted_cores.is_selected(core_id)) return error.RegisterReadWhileCoreRunning;
    try target.ensure_core_attached(core_id);
    return target.vtable.core_access.read_register(target, core_id, reg);
}

/// Writes to a cpu register. The core must be halted.
pub fn write_register(target: *Target, core_id: CoreId, reg: RegisterId, value: u64) !void {
    if (!target.halted_cores.is_selected(core_id)) return error.RegisterWriteWhileCoreRunning;
    try target.ensure_core_attached(core_id);
    return target.vtable.core_access.write_register(target, core_id, reg, value);
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

fn ensure_core_attached(target: *Target, core_id: CoreId) CommandError!void {
    if (target.attached_cores.is_selected(core_id)) return;
    try target.vtable.core_access.attach(target, core_id);
    target.attached_cores = target.attached_cores.combine(.with_id(core_id));
}

fn ensure_core_mask_attached(target: *Target, core_mask: CoreMask) CommandError!void {
    if (target.attached_cores.contains_all(core_mask)) return;

    for (0..std.math.maxInt(u6)) |i| {
        const id: CoreId = .num(@intCast(i));
        if (core_mask.is_selected(id)) {
            try target.vtable.core_access.attach(target, id);
        }
    }
    target.attached_cores = target.attached_cores.combine(core_mask);
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

pub const MemoryRegion = struct {
    offset: u64,
    length: u64,
    kind: Kind,

    pub const Kind = union(enum) {
        flash,
        ram,
    };
};

pub const MemoryReader = struct {
    interface: std.Io.Reader,
    target: *Target,
    address: u64,
    offset: u64 = 0,

    pub fn init(target: *Target, buffer: []u8, address: u64) MemoryReader {
        return .{
            .interface = init_interface(buffer),
            .target = target,
            .address = address,
        };
    }

    pub fn init_interface(buffer: []u8) std.Io.Reader {
        return .{
            .buffer = buffer,
            .seek = 0,
            .end = 0,
            .vtable = &.{
                .stream = stream,
            },
        };
    }

    pub fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const memory_reader: *MemoryReader = @alignCast(@fieldParentPtr("interface", r));

        const buf = limit.slice(w.writableSliceGreedy(1) catch return error.ReadFailed);
        memory_reader.target.read_memory(memory_reader.address + memory_reader.offset, buf) catch return error.ReadFailed;
        memory_reader.offset += buf.len;
        return buf.len;
    }
};

pub const MemoryWriter = struct {
    interface: std.Io.Writer,
    target: *Target,
    address: u64,
    offset: u64 = 0,

    pub fn init(target: *Target, buffer: []u8, address: u64) MemoryWriter {
        return .{
            .interface = init_interface(buffer),
            .target = target,
            .address = address,
        };
    }

    pub fn init_interface(buffer: []u8) std.Io.Writer {
        return .{
            .buffer = buffer,
            .end = 0,
            .vtable = &.{
                .drain = drain,
            },
        };
    }

    pub fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const memory_writer: *MemoryWriter = @alignCast(@fieldParentPtr("interface", w));

        {
            const buffered = w.buffered();
            if (buffered.len > 0) {
                memory_writer.target.write_memory(memory_writer.address + memory_writer.offset, buffered) catch return error.WriteFailed;
                memory_writer.offset += buffered.len;
                _ = w.consumeAll();
            }
        }

        var n: usize = 0;

        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            memory_writer.target.write_memory(memory_writer.address + memory_writer.offset, buf) catch return error.WriteFailed;
            memory_writer.offset += buf.len;
            n += buf.len;
        }

        const splat_buf = data[data.len - 1];
        if (splat_buf.len > 0 and splat > 0) {
            for (0..splat) |_| {
                memory_writer.target.write_memory(memory_writer.address + memory_writer.offset, splat_buf) catch return error.WriteFailed;
                memory_writer.offset += splat_buf.len;
                n += splat_buf.len;
            }
        }

        return n;
    }
};
