const std = @import("std");

const Timeout = @import("Timeout.zig");
const Target = @import("Target.zig");
const Memory = @import("Memory.zig");

// NOTE: We only support 32bit addresses for now

pub const Noop = struct {
    erase_page_size: u32 = 4 * 1024,
    program_page_size: u32 = 256,

    pub fn erase(flasher: Noop, addr: u32, length: u32) !void {
        std.debug.assert(std.mem.isAligned(addr, flasher.erase_page_size));
        std.debug.assert(std.mem.isAligned(length, flasher.erase_page_size));

        std.log.debug("erase: addr 0x{x:0>8} length 0x{x:0>8}", .{ addr, length });
    }

    pub fn program(flasher: Noop, addr: u32, data: []const u8) !void {
        std.debug.assert(std.mem.isAligned(addr, flasher.program_page_size));
        std.debug.assert(std.mem.isAligned(data.len, flasher.program_page_size));

        std.log.debug("program: addr 0x{x:0>8} length 0x{x:0>8}", .{ addr, data.len });
        var it = std.mem.window(u8, data, 4 * 8, 4 * 8);
        var offset: u32 = 0;
        while (it.next()) |bytes| {
            std.debug.print("0x{x:0>8}: 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8}\n", .{
                addr + offset,
                std.mem.readInt(u32, bytes[0..][0..4], .little),
                std.mem.readInt(u32, bytes[4..][0..4], .little),
                std.mem.readInt(u32, bytes[8..][0..4], .little),
                std.mem.readInt(u32, bytes[12..][0..4], .little),
                std.mem.readInt(u32, bytes[16..][0..4], .little),
                std.mem.readInt(u32, bytes[20..][0..4], .little),
                std.mem.readInt(u32, bytes[24..][0..4], .little),
                std.mem.readInt(u32, bytes[28..][0..4], .little),
            });
            offset += 4 * 8;
        }
    }
};

const flash_stubs_bundle_tar: []const u8 = @embedFile("flash_stubs_bundle.tar");

pub fn get_flash_stub(name: []const u8) !?[]const u8 {
    var tar_reader: std.Io.Reader = .fixed(flash_stubs_bundle_tar);

    var file_name_buffer: [32]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &.{},
    });

    while (try it.next()) |file| {
        std.debug.print("{s}\n", .{file.name});
        if (file.kind == .file and std.mem.eql(u8, name, file.name)) {
            return try tar_reader.take(file.size);
        }
    }

    return null;
}

pub const WithStub = struct {
    pub const ImageHeader = extern struct {
        pub const MAGIC = 0xBAD_C0FFE;

        magic: u32,
        erase_sector_size: u32,
        program_sector_size: u32,
        stack_pointer_offset: u32,
        erase_fn_offset: u32,
        program_fn_offset: u32,
    };

    target: *Target,
    image_header: ImageHeader,
    erase_sector_size: u32,
    program_sector_size: u32,
    image_base: u32,
    mem_buf_addr: u32,
    mem_buf_length: u32,

    pub fn init(target: *Target) !WithStub {
        const flash_stub: []const u8 = (try get_flash_stub(target.name)) orelse return error.NoStubFound;
        const image_header = std.mem.bytesToValue(ImageHeader, flash_stub[0..@sizeOf(ImageHeader)]);
        if (image_header.magic != 0xBAD_C0FFE) return error.MagicNumberMismatch;

        const load_region = ram_search: for (target.memory_map) |region| {
            if (region.kind == .ram) {
                break :ram_search region;
            }
        } else return error.NoRamRegion;

        const mem_buf_addr = std.mem.alignForward(
            u32,
            @intCast(load_region.offset + flash_stub.len),
            image_header.program_sector_size,
        );
        const mem_buf_length = std.mem.alignBackward(
            u32,
            @intCast(load_region.offset + load_region.length),
            image_header.program_sector_size,
        ) - mem_buf_addr;

        try target.write_memory(load_region.offset, flash_stub);

        return .{
            .target = target,
            .image_header = image_header,
            .erase_sector_size = image_header.erase_sector_size,
            .program_sector_size = image_header.program_sector_size,
            .image_base = @intCast(load_region.offset),
            .mem_buf_addr = mem_buf_addr,
            .mem_buf_length = mem_buf_length,
        };
    }

    /// Address must be aligned to erase_sector_size and length must be a
    /// multiple of erase_sector_size
    pub fn erase(flasher: WithStub, addr: u32, length: u32) !void {
        std.debug.assert(std.mem.isAligned(addr, flasher.erase_sector_size));
        std.debug.assert(std.mem.isAligned(length, flasher.erase_sector_size));

        try flasher.target.write_register(.boot, .{ .arg = 0 }, addr);
        try flasher.target.write_register(.boot, .{ .arg = 1 }, length);
        try flasher.target.write_register(.boot, .{ .special = .ip }, flasher.image_base + flasher.image_header.erase_fn_offset);
        try flasher.target.write_register(.boot, .{ .special = .sp }, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try flasher.target.run(.boot);

        try flasher.wait_for_function();
    }

    /// Address must be aligned to program_sector_size and length must be a
    /// multiple of progam_sector_size
    pub fn program(flasher: WithStub, addr: u32, data: []const u8) !void {
        std.debug.assert(std.mem.isAligned(addr, flasher.program_sector_size));
        std.debug.assert(std.mem.isAligned(data.len, flasher.program_sector_size));

        var offset: u32 = 0;

        while (offset < data.len) {
            const count = @min(
                data.len - offset,
                flasher.mem_buf_length,
            );

            try flasher.target.write_memory(flasher.mem_buf_addr, data[offset..][0..count]);

            try flasher.target.write_register(.boot, .{ .arg = 0 }, addr);
            try flasher.target.write_register(.boot, .{ .arg = 1 }, flasher.mem_buf_addr);
            try flasher.target.write_register(.boot, .{ .arg = 2 }, count);
            try flasher.target.write_register(.boot, .{ .special = .ip }, flasher.image_base + flasher.image_header.program_fn_offset);
            try flasher.target.write_register(.boot, .{ .special = .sp }, flasher.image_base + flasher.image_header.stack_pointer_offset);
            try flasher.target.run(.boot);

            try flasher.wait_for_function();

            offset += count;
        }
    }

    fn wait_for_function(flasher: WithStub) !void {
        var timeout: Timeout = try .init(.{
            .after = 5 * std.time.ns_per_s,
            .sleep_per_tick_ns = 100 * std.time.ns_per_ms,
        });
        while (!try flasher.target.is_halted(.boot)) {
            try timeout.tick();
        }
    }
};

pub fn elf(
    allocator: std.mem.Allocator,
    flasher: anytype,
    memory_map: []const Target.MemoryRegion,
    elf_reader: *std.fs.File.Reader,
) !void {
    const header = try std.elf.Header.read(&elf_reader.interface);

    const Segment = struct {
        offset_in_elf: u32,
        addr: u32,
        length: u32,

        fn is_less(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.addr < rhs.addr;
        }
    };

    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);

    var ph_iterator = header.iterateProgramHeaders(elf_reader);
    while (try ph_iterator.next()) |ph| {
        if (ph.p_type != std.elf.PT_LOAD) continue;
        if (ph.p_filesz == 0) continue;

        const kind = try find_memory_region_kind(memory_map, ph.p_paddr, ph.p_filesz);
        if (kind != .flash) continue;

        try segments.append(allocator, .{
            .offset_in_elf = @intCast(ph.p_offset),
            .addr = @intCast(ph.p_paddr),
            .length = @intCast(ph.p_filesz),
        });
    }

    std.mem.sort(Segment, segments.items, {}, Segment.is_less);

    var data: std.Io.Writer.Allocating = .init(allocator);
    defer data.deinit();

    const first_segment = segments.items[0];

    var current_erase_start = std.mem.alignBackward(u32, first_segment.addr, flasher.erase_sector_size);
    var current_program_start = std.mem.alignBackward(u32, first_segment.addr, flasher.program_sector_size);

    // align write
    try data.ensureUnusedCapacity(first_segment.addr - current_program_start);
    data.writer.end += first_segment.addr - current_program_start;

    // read data
    try elf_reader.seekTo(first_segment.offset_in_elf);
    try data.ensureUnusedCapacity(first_segment.length);
    try elf_reader.interface.streamExact(&data.writer, first_segment.length);

    var last_segment_end = first_segment.addr + first_segment.length;
    for (segments.items[1..]) |seg| {
        if (seg.addr < last_segment_end) return error.OverlappingSegments;
        if (seg.addr - last_segment_end > flasher.program_sector_size) {
            if (current_erase_start < last_segment_end) {
                const padded_erase_len = std.mem.alignForward(u32, @intCast(data.written().len), flasher.erase_sector_size);
                try flasher.erase(current_erase_start, padded_erase_len);
            }

            const padded_data_len = std.mem.alignForward(u32, @intCast(data.written().len), flasher.program_sector_size);
            try data.ensureTotalCapacity(padded_data_len);
            data.writer.end = padded_data_len;
            try flasher.program(current_program_start, data.written());

            current_erase_start = std.mem.alignBackward(u32, seg.addr, flasher.erase_sector_size);
            current_program_start = std.mem.alignBackward(u32, seg.addr, flasher.program_sector_size);

            data.clearRetainingCapacity();

            // align write
            try data.ensureUnusedCapacity(seg.addr - current_program_start);
            data.writer.end += seg.addr - current_program_start;
        }

        // read data
        try elf_reader.seekTo(seg.offset_in_elf);
        try data.ensureUnusedCapacity(seg.length);
        try elf_reader.interface.streamExact(&data.writer, seg.length);

        last_segment_end = seg.addr + seg.length;
    }

    if (current_erase_start < last_segment_end) {
        const padded_erase_len = std.mem.alignForward(u32, @intCast(data.written().len), flasher.erase_sector_size);
        try flasher.erase(current_erase_start, padded_erase_len);
    }

    const padded_data_len = std.mem.alignForward(u32, @intCast(data.written().len), flasher.program_sector_size);
    try data.ensureTotalCapacity(padded_data_len);
    data.writer.end = padded_data_len;
    try flasher.program(current_program_start, data.written());
}

// TODO: relocate this
pub fn run_ram_image(allocator: std.mem.Allocator, target: *Target, elf_reader: *std.fs.File.Reader) !void {
    const header = try std.elf.Header.read(&elf_reader.interface);

    var ph_iterator = header.iterateProgramHeaders(elf_reader);
    while (try ph_iterator.next()) |ph| {
        if (ph.p_type != std.elf.PT_LOAD) continue;

        try elf_reader.seekTo(ph.p_offset);
        const data = try elf_reader.interface.readAlloc(allocator, ph.p_filesz);
        defer allocator.free(data);

        const kind = try find_memory_region_kind(target.memory_map, ph.p_paddr, ph.p_memsz);
        if (kind != .ram) return error.SectionNotInRam;

        try target.write_memory(ph.p_paddr, data);
    }

    try target.write_register(.boot, .{ .special = .ip }, @truncate(header.entry));
    try target.run(.boot);
}

fn find_memory_region_kind(
    memory_map: []const Target.MemoryRegion,
    addr: u64,
    len: u64,
) error{InvalidSection}!Target.MemoryRegion.Kind {
    for (memory_map) |region| {
        if (region.offset <= addr and addr + len < region.offset + region.length) {
            return region.kind;
        }
    }
    return error.InvalidSection;
}
