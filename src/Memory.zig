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

pub const Vtable = struct {
    read_u8: *const fn (ptr: *anyopaque, addr: u64, data: []u8) ReadError!void = default_read_u8,
    read_u16: *const fn (ptr: *anyopaque, addr: u64, data: []u16) ReadError!void = default_read_u16,
    read_u32: *const fn (ptr: *anyopaque, addr: u64, data: []u32) ReadError!void,
    read_u64: *const fn (ptr: *anyopaque, addr: u64, data: []u64) ReadError!void = default_read_u64,
    write_u8: *const fn (ptr: *anyopaque, addr: u64, data: []const u8) WriteError!void = default_write_u8,
    write_u16: *const fn (ptr: *anyopaque, addr: u64, data: []const u16) WriteError!void = default_write_u16,
    write_u32: *const fn (ptr: *anyopaque, addr: u64, data: []const u32) WriteError!void,
    write_u64: *const fn (ptr: *anyopaque, addr: u64, data: []const u64) WriteError!void = default_write_u64,

    read: *const fn (ptr: *anyopaque, addr: u64, data: []u8) ReadError!void = default_read_u8,
    write: *const fn (ptr: *anyopaque, addr: u64, data: []const u8) WriteError!void = default_write_u8,
};

pub fn read_u8(memory: Memory, addr: u64, data: []u8) ReadError!void {
    try memory.vtable.read_u8(memory.ptr, addr, data);
}

pub fn read_u16(memory: Memory, addr: u64, data: []u16) ReadError!void {
    try memory.vtable.read_u16(memory.ptr, addr, data);
}

pub fn read_u32(memory: Memory, addr: u64, data: []u32) ReadError!void {
    try memory.vtable.read_u32(memory.ptr, addr, data);
}

pub fn read_u64(memory: Memory, addr: u64, data: []u64) ReadError!void {
    try memory.vtable.read_u64(memory.ptr, addr, data);
}

pub fn write_u8(memory: Memory, addr: u64, data: []const u8) WriteError!void {
    try memory.vtable.write_u8(memory.ptr, addr, data);
}

pub fn write_u16(memory: Memory, addr: u64, data: []const u16) WriteError!void {
    try memory.vtable.write_u16(memory.ptr, addr, data);
}

pub fn write_u32(memory: Memory, addr: u64, data: []const u32) WriteError!void {
    try memory.vtable.write_u32(memory.ptr, addr, data);
}

pub fn write_u64(memory: Memory, addr: u64, data: []const u64) WriteError!void {
    try memory.vtable.write_u64(memory.ptr, addr, data);
}

pub fn read(memory: Memory, addr: u64, data: []u8) ReadError!void {
    try memory.vtable.read(memory.ptr, addr, data);
}

pub fn write(memory: Memory, addr: u64, data: []const u8) WriteError!void {
    try memory.vtable.write(memory.ptr, addr, data);
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
