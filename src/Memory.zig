const std = @import("std");

const Memory = @This();

ptr: *anyopaque,
vtable: *const Vtable,

pub const UnsupportedError = error{
    Unsupported,
};

pub const WriteError = UnsupportedError || error{
    AddressMisaligned,
    WriteFailed,
};

pub const ReadError = UnsupportedError || error{
    AddressMisaligned,
    ReadFailed,
};

// TODO: support other data sizes
pub const Vtable = struct {
    read_u8: *const fn (ptr: *anyopaque, addr: u64, data: []u8) ReadError!void = default_read_u8,
    read_u16: *const fn (ptr: *anyopaque, addr: u64, data: []u16) ReadError!void = default_read_u16,
    read_u32: *const fn (ptr: *anyopaque, addr: u64, data: []u32) ReadError!void,
    read_u64: *const fn (ptr: *anyopaque, addr: u64, data: []u64) ReadError!void = default_read_u64,
    write_u8: *const fn (ptr: *anyopaque, addr: u64, data: []const u8) WriteError!void = default_write_u8,
    write_u16: *const fn (ptr: *anyopaque, addr: u64, data: []const u16) WriteError!void = default_write_u16,
    write_u32: *const fn (ptr: *anyopaque, addr: u64, data: []const u32) WriteError!void,
    write_u64: *const fn (ptr: *anyopaque, addr: u64, data: []const u64) WriteError!void = default_write_u64,
};

pub fn read(memory: Memory, addr: u64, data: []u8) ReadError!void {
    _ = memory; // autofix
    _ = addr; // autofix
    _ = data; // autofix
    @panic("TODO");
}

pub fn write(memory: Memory, allocator: std.mem.Allocator, addr: u64, data: []const u8) (std.mem.Allocator.Error || WriteError)!void {
    const bytes_before_start = std.mem.alignForward(u64, addr, 4) - addr;
    const bytes_until_end = addr + data.len - std.mem.alignBackward(u64, addr + data.len, 4);

    // if we have at least x aligned words (we should benchmark this)
    if (bytes_before_start + bytes_until_end + @sizeOf(u32) < data.len) {
        if (bytes_before_start > 0) {
            try memory.write_u8(addr, data[0..bytes_before_start]);
        }

        const aligned_data_len = data.len - bytes_before_start - bytes_until_end;
        {
            const u32_data: []u32 = try allocator.alloc(u32, aligned_data_len / @sizeOf(u32));
            defer allocator.free(u32_data);

            for (u32_data, 0..) |*word, i| {
                word.* = std.mem.readInt(u32, data[bytes_before_start + i * @sizeOf(u32) ..][0..4], .little);
            }

            try memory.write_u32(addr + bytes_before_start, u32_data);
        }

        if (bytes_until_end > 0) {
            try memory.write_u8(
                addr + bytes_before_start + aligned_data_len,
                data[data.len - bytes_until_end ..],
            );
        }
    } else {
        try memory.write_u8(addr, data);
    }
}

pub fn read_u8(memory: Memory, addr: u64, data: []u8) ReadError!void {
    return memory.vtable.read_u8(memory.ptr, addr, data);
}

pub fn read_u16(memory: Memory, addr: u64, data: []u16) ReadError!void {
    return memory.vtable.read_u16(memory.ptr, addr, data);
}

pub fn read_u32(memory: Memory, addr: u64, data: []u32) ReadError!void {
    return memory.vtable.read_u32(memory.ptr, addr, data);
}

pub fn read_u64(memory: Memory, addr: u64, data: []u64) ReadError!void {
    return memory.vtable.read_u64(memory.ptr, addr, data);
}

pub fn write_u8(memory: Memory, addr: u64, data: []const u8) WriteError!void {
    return memory.vtable.write_u8(memory.ptr, addr, data);
}

pub fn write_u16(memory: Memory, addr: u64, data: []const u16) WriteError!void {
    return memory.vtable.write_u16(memory.ptr, addr, data);
}

pub fn write_u32(memory: Memory, addr: u64, data: []const u32) WriteError!void {
    return memory.vtable.write_u32(memory.ptr, addr, data);
}

pub fn write_u64(memory: Memory, addr: u64, data: []const u64) WriteError!void {
    return memory.vtable.write_u64(memory.ptr, addr, data);
}

pub fn default_read_u8(_: *anyopaque, _: u64, _: []u8) ReadError!void {
    return error.Unsupported;
}

pub fn default_read_u16(_: *anyopaque, _: u64, _: []u16) ReadError!void {
    return error.Unsupported;
}

pub fn default_read_u64(_: *anyopaque, _: u64, _: []u64) ReadError!void {
    return error.Unsupported;
}

pub fn default_write_u8(_: *anyopaque, _: u64, _: []const u8) WriteError!void {
    return error.Unsupported;
}

pub fn default_write_u16(_: *anyopaque, _: u64, _: []const u16) WriteError!void {
    return error.Unsupported;
}

pub fn default_write_u64(_: *anyopaque, _: u64, _: []const u64) WriteError!void {
    return error.Unsupported;
}
