const std = @import("std");
const Target = @import("Target.zig");

const RTT_Host = @This();

const SEGGER_RTT_ID: [16]u8 = "SEGGER RTT";

control_block_address: u64,

pub fn init(target: *Target) !RTT_Host {
    const control_block_find_result = try find_control_block(target) orelse return error.MissingControlBlock;
    std.debug.print("{any}\n", .{control_block_find_result.header});
    return .{
        .control_block_address = control_block_find_result.address,
    };
}

const ControlBlockFindResult = struct {
    address: u64,
    header: Header,
};

pub fn find_control_block(target: *Target) !?ControlBlockFindResult {
    // Find ram to load the stub
    for (target.memory_map) |region| {
        if (region.kind == .ram) {
            if (try find_control_block_in_region(target, region)) |result| return result;
        }
    } else return null;
}

pub fn find_control_block_in_region(target: *Target, region: Target.MemoryRegion) !?ControlBlockFindResult {
    const chunk_size = 1024;
    const extra_size = @sizeOf(Header);
    var buf: [chunk_size + extra_size]u8 = @splat(0);
    var offset: u64 = 0;
    while (offset < region.length) : (offset += chunk_size) {
        @memcpy(buf[0..extra_size], buf[chunk_size..]); // can't overlap
        std.debug.print("reading\n", .{});
        try target.read_memory(region.offset + offset, buf[extra_size..]);
        const position = std.mem.indexOf(u8, &buf, "SEGGER RTT") orelse continue;

        const address = offset + position - extra_size;

        var header_reader: std.Io.Reader = .fixed(buf[position..]);
        const header: Header = header_reader.takeStruct(Header, .little) catch unreachable;

        return .{
            .address = address,
            .header = header,
        };
    } else return null;
}

const Header = extern struct {
    id: [16]u8,
    max_up_channels: u32,
    max_down_channels: u32,
};

const Channel = extern struct {
    /// Name is optional and is not required by the spec. Standard names so far are:
    /// "Terminal", "SysView", "J-Scope_t4i4"
    name: [*:0]const u8,

    buffer: [*]u8,

    /// Note from above actual buffer size is size - 1 bytes
    size: u32,

    write_offset: u32,
    read_offset: u32,

    /// Contains configuration flags. Flags[31:24] are used for validity check and must be zero.
    /// Flags[23:2] are reserved for future use. Flags[1:0] = RTT operating mode.
    flags: Flags,

    const Flags = packed struct(u32) {
        mode: Mode,
        reserved: u22,
        must_be_zero: u8,

        const Mode = enum(u2) {
            no_block_skip = 0,
            no_block_trim = 1,
            block_if_full = 2,
            _,
        };
    };
};
