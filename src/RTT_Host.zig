const std = @import("std");

const Timeout = @import("Timeout.zig");
const Progress = @import("Progress.zig");
const elf = @import("elf.zig");
const Target = @import("Target.zig");

const RTT_Host = @This();

name_pool: std.heap.ArenaAllocator,
control_block_address: u64,
header: Header,
up_channels: std.StringHashMapUnmanaged(usize),
down_channels: std.StringHashMapUnmanaged(usize),

pub const BlockLocationHint = union(enum) {
    /// Scan either a given region or the first n bytes in all RAM memory regions
    blind: Blind,
    /// More efficient lookup using info provided by an ELF
    with_elf: With_ELF,

    pub const Blind = union(enum) {
        region: SearchRegion,
        first_n_kilobytes: u64,

        pub const SearchRegion = struct {
            start: u64,
            size: u64,
        };
    };

    pub const With_ELF = struct {
        elf_file_reader: *std.fs.File.Reader,
        elf_info: elf.Info,
        method: Method = .auto,

        pub const Method = union(enum) {
            auto,
            section_name: []const u8,
            symbol_name: []const u8,
        };
    };
};

pub const InitOptions = struct {
    location_hint: BlockLocationHint = .{ .blind = .{ .first_n_kilobytes = 4 } },
    timeout_ns: ?u64 = std.time.ns_per_s,
    progress: ?Progress = null,
};

pub fn init(
    allocator: std.mem.Allocator,
    target: *Target,
    options: InitOptions,
) !RTT_Host {
    const timeout: Timeout = try .init(.{
        .after = options.timeout_ns,
    });

    const result = loop: while (true) {
        if (try find_control_block(allocator, target, options.location_hint, timeout, options.progress)) |result|
            break :loop result;
    } else return error.MissingControlBlock;

    const channels_start = result.address + @sizeOf(Header);

    var up_channels: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer up_channels.deinit(allocator);
    var down_channels: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer down_channels.deinit(allocator);

    var buffer: [@sizeOf(Channel)]u8 = undefined;
    var reader: Target.MemoryReader = .init(target, &buffer, channels_start);

    var name_pool: std.heap.ArenaAllocator = .init(allocator);

    for (0..result.header.max_up_channels + result.header.max_down_channels) |i| {
        const channel = try reader.interface.takeStruct(Channel, target.endian);

        // Check if we are reading something valid
        if (channel.flags.must_be_zero != 0) return error.BadChannel;

        var name_buffer: [32]u8 = undefined; // should be enough
        var name_reader: Target.MemoryReader = .init(target, &name_buffer, channel.name_ptr);
        var name_writer: std.Io.Writer.Allocating = .init(name_pool.allocator());
        _ = try name_reader.interface.streamDelimiterEnding(&name_writer.writer, 0);

        if (i < result.header.max_up_channels) {
            try up_channels.put(allocator, name_writer.written(), i);
        } else {
            try down_channels.put(allocator, name_writer.written(), i);
        }
    }

    return .{
        .name_pool = name_pool,
        .header = result.header,
        .control_block_address = result.address,
        .up_channels = up_channels,
        .down_channels = down_channels,
    };
}

pub fn deinit(rtt_host: *RTT_Host, allocator: std.mem.Allocator) void {
    rtt_host.up_channels.deinit(allocator);
    rtt_host.down_channels.deinit(allocator);
    rtt_host.name_pool.deinit();
}

pub fn read(rtt_host: RTT_Host, target: *Target, index: usize, buffer: []u8) !usize {
    if (index >= rtt_host.header.max_up_channels)
        return error.InvalidChannelIndex;

    const channel_address = rtt_host.control_block_address + @sizeOf(Header) + index * @sizeOf(Channel);
    var channel_buffer: [@sizeOf(Channel)]u8 = undefined;
    var reader: Target.MemoryReader = .init(target, &channel_buffer, channel_address);
    const channel = try reader.interface.takeStruct(Channel, target.endian);

    const first_count_available, const second_count_available = if (channel.read_offset < channel.write_offset)
        .{ channel.write_offset - channel.read_offset - 1, 0 }
    else if (channel.read_offset > channel.write_offset)
        .{ channel.size - channel.read_offset - 1, channel.write_offset }
    else
        return 0;

    const first_count = @min(first_count_available, buffer.len);
    const second_count = @min(second_count_available, buffer.len - first_count);
    if (first_count > 0) try target.read_memory(channel.buffer_ptr + channel.read_offset, buffer[0..first_count]);
    if (second_count > 0) try target.read_memory(channel.buffer_ptr + first_count, buffer[first_count..][0..second_count]);

    var read_offset_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &read_offset_buf, (channel.read_offset + first_count + second_count) % channel.size, target.endian);
    try target.write_memory(channel_address + @offsetOf(Channel, "read_offset"), &read_offset_buf);
    return first_count + second_count;
}

// TODO: write to channel
// pub fn write(rtt_host: RTT_Host, target: *Target, index: usize, buffer: []u8) !usize {
//     if (index >= rtt_host.header.max_down_channels)
//         return error.InvalidChannelIndex;
//
//     const channel_address = rtt_host.control_block_address + @sizeOf(Header) + index * @sizeOf(Channel);
//     var channel_buffer: [@sizeOf(Channel)]u8 = undefined;
//     var reader: Target.MemoryReader = .init(target, &channel_buffer, channel_address);
//     const channel = try reader.interface.takeStruct(Channel, target.endian);
//
//     const first_count_available, const second_count_available = if (channel.read_offset < channel.write_offset)
//         .{ channel.write_offset - channel.read_offset - 1, 0 }
//     else if (channel.read_offset > channel.write_offset)
//         .{ channel.size - channel.read_offset - 1, channel.write_offset }
//     else
//         return 0;
//
//     const first_count = @min(first_count_available, buffer.len);
//     const second_count = @min(second_count_available, buffer.len - first_count);
//     if (first_count > 0) try target.read_memory(channel.buffer_ptr + channel.read_offset, buffer[0..first_count]);
//     if (second_count > 0) try target.read_memory(channel.buffer_ptr + first_count, buffer[first_count..][0..second_count]);
//
//     var read_offset_buf: [4]u8 = undefined;
//     std.mem.writeInt(u32, &read_offset_buf, (channel.read_offset + first_count + second_count) % channel.size, target.endian);
//     try target.write_memory(channel_address + @offsetOf(Channel, "read_offset"), &read_offset_buf);
//     return first_count + second_count;
// }

const ControlBlockFindResult = struct {
    address: u64,
    header: Header,
};

fn find_control_block(
    allocator: std.mem.Allocator,
    target: *Target,
    location_hint: BlockLocationHint,
    timeout: Timeout,
    maybe_progress: ?Progress,
) !?ControlBlockFindResult {
    switch (location_hint) {
        .blind => |blind_hint| switch (blind_hint) {
            .region => |region| return try find_control_block_in_range(allocator, target, region.start, region.size, timeout, maybe_progress),
            .first_n_kilobytes => |n| for (target.memory_map) |region| {
                if ((try find_control_block_in_range(allocator, target, region.offset, @min(n * 1024, region.length), timeout, maybe_progress))) |result| {
                    return result;
                }
            } else return null,
        },
        .with_elf => |with_elf_hint| switch (with_elf_hint.method) {
            .auto => for (with_elf_hint.elf_info.load_segments.items) |seg| {
                if ((try find_control_block_in_range(allocator, target, seg.virtual_address, seg.memory_size, timeout, maybe_progress))) |result| {
                    return result;
                }
            } else return null,
            .section_name => |name| {
                const section = with_elf_hint.elf_info.sections.get(name) orelse return null;
                return find_control_block_in_range(allocator, target, section.address, section.size, timeout, maybe_progress);
            },
            .symbol_name => |name| {
                const symbol = (try elf.get_symbol(with_elf_hint.elf_file_reader, with_elf_hint.elf_info, name)) orelse return null;
                return find_control_block_in_range(allocator, target, symbol.st_value, symbol.st_size, timeout, maybe_progress);
            },
        },
    }
}

// TODO: maybe use memory reader
fn find_control_block_in_range(
    allocator: std.mem.Allocator,
    target: *Target,
    start: u64,
    size: u64,
    timeout: Timeout,
    maybe_progress: ?Progress,
) !?ControlBlockFindResult {
    const chunk_size = 1024;
    const extra_size = @sizeOf(Header);
    var buf: [chunk_size + extra_size]u8 = @splat(0);
    var offset: u64 = 0;

    // NOTE: we could also statically allocate this
    const step_name = try std.fmt.allocPrint(allocator, "Scanning 0x{x:>8} - 0x{x:>8}", .{ start, start + size });
    defer allocator.free(step_name);

    defer if (maybe_progress) |progress| progress.end();

    while (offset < size) : (offset += chunk_size) {
        try timeout.tick();

        if (maybe_progress) |progress| {
            try progress.step(.{
                .name = step_name,
                .completed = offset,
                .total = size,
            });
        }

        @memcpy(buf[0..extra_size], buf[chunk_size..]); // can't overlap

        try target.read_memory(start + offset, buf[extra_size..]);
        const position = std.mem.indexOf(u8, &buf, "SEGGER RTT") orelse continue;

        const address = start + offset + position - extra_size;
        const header: Header = bytes_as_struct(Header, buf[position..][0..@sizeOf(Header)], target.endian);

        return .{
            .address = address,
            .header = header,
        };
    } else return null;
}

fn bytes_as_struct(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) T {
    var value: T = undefined;
    @memcpy(@as([*]u8, @ptrCast(&value))[0..@sizeOf(T)], bytes);
    const native_endian = @import("builtin").target.cpu.arch.endian();
    if (native_endian != endian) std.mem.byteSwapAllFields(T, &value);
    return value;
}

const Header = extern struct {
    id: [16]u8,
    max_up_channels: u32,
    max_down_channels: u32,
};

const Channel = extern struct {
    name_ptr: u32,
    buffer_ptr: u32,
    size: u32,

    write_offset: u32,
    read_offset: u32,

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
