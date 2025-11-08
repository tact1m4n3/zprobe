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

pub const Reader = struct {
    interface: std.Io.Reader,
    memory: Memory,
    address: u64,
    offset: u64 = 0,

    pub fn init(memory: Memory, buffer: []u8, address: u64) Reader {
        return .{
            .interface = init_interface(buffer),
            .memory = memory,
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
        const reader: *Reader = @alignCast(@fieldParentPtr("interface", r));

        const buf = limit.slice(w.writableSliceGreedy(1) catch return error.ReadFailed);
        reader.memory.read(reader.address, buf) catch return error.ReadFailed;
        reader.offset += buf.len;
        return buf.len;
    }
};

pub const Writer = struct {
    interface: std.Io.Writer,
    memory: Memory,
    address: u64,
    offset: u64 = 0,

    pub fn init(memory: Memory, buffer: []u8, address: u64) Writer {
        return .{
            .interface = init_interface(buffer),
            .memory = memory,
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
        const writer: *Writer = @alignCast(@fieldParentPtr("interface", w));

        {
            const buffered = w.buffered();
            if (buffered.len > 0) {
                writer.write(buffered) catch return error.WriteFailed;
                _ = w.consumeAll();
            }
        }

        var n: usize = 0;

        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            writer.write(buf) catch return error.WriteFailed;
            n += buf.len;
        }

        const splat_buf = data[data.len - 1];
        if (splat_buf.len > 0 and splat > 0) {
            for (0..splat) |_| {
                writer.write(splat_buf) catch return error.WriteFailed;
                n += splat_buf.len;
            }
        }

        return n;
    }

    fn write(memory_writer: *Writer, buf: []const u8) !void {
        try memory_writer.memory.write(memory_writer.address + memory_writer.offset, buf);
        memory_writer.offset += buf.len;
    }
};
