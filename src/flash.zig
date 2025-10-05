const std = @import("std");

const Timeout = @import("Timeout.zig");
const Target = @import("Target.zig");
const Memory = @import("Memory.zig");

// NOTE: We only support 32bit addresses for now

pub const Noop = struct {
    page_size: u32 = 4096,
    chunk_size: u32 = 4096,

    pub fn load(flasher: Noop, _: *Target, addr: u32, data: []const u8) !void {
        std.debug.assert(std.mem.isAligned(addr, flasher.page_size));
        std.debug.assert(data.len == flasher.chunk_size);

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
        page_size: u32,
        stack_pointer_offset: u32,
        return_address_offset: u32,
        verify_fn_offset: u32,
        erase_fn_offset: u32,
        program_fn_offset: u32,
    };

    image_header: ImageHeader,
    image_base: u32,
    page_size: u32,
    chunk_data_addr: u32,
    max_chunk_size: u32,

    pub fn init(target: *Target) !WithStub {
        const flash_stub: []const u8 = (try get_flash_stub(target.name)) orelse return error.NoStubFound;
        const image_header = std.mem.bytesToValue(ImageHeader, flash_stub[0..@sizeOf(ImageHeader)]);
        if (image_header.magic != ImageHeader.MAGIC) return error.MagicNumberMismatch;

        // Find ram to load the stub
        const load_region = ram_search: for (target.memory_map) |region| {
            if (region.kind == .ram) {
                break :ram_search region;
            }
        } else return error.NoRamRegion;

        // Calculate where should chunk data start
        const chunk_data_addr = std.mem.alignForward(
            u32,
            @intCast(load_region.offset + flash_stub.len),
            image_header.page_size,
        );

        // Calculate how much space is there for chunk data
        const max_chunk_size = std.mem.alignBackward(
            u32,
            @intCast(load_region.offset + load_region.length),
            image_header.page_size,
        ) - chunk_data_addr;

        // If we don't have enough space for one page, return error
        if (max_chunk_size < image_header.page_size) {
            return error.MemoryBufferTooSmall;
        }

        // Halt all cores since we are going to modify memory (if any are running)
        try target.halt(.all);

        // Load stub into ram
        try target.write_memory(load_region.offset, flash_stub);

        return .{
            .image_header = image_header,
            .image_base = @intCast(load_region.offset),
            .page_size = image_header.page_size,
            .chunk_data_addr = chunk_data_addr,
            .max_chunk_size = max_chunk_size,
        };
    }

    // TODO: maybe refactor calls to stub function
    /// Verifies flash content.
    pub fn verify(flasher: WithStub, target: *Target, addr: u32, chunk: []const u8) !bool {
        std.debug.assert(std.mem.isAligned(addr, flasher.page_size));
        std.debug.assert(std.mem.isAligned(chunk.len, flasher.page_size));
        std.debug.assert(chunk.len < flasher.max_chunk_size);

        // Load chunk into memory
        try target.write_memory(flasher.chunk_data_addr, chunk);

        // Verify that the flash doesn't already contain the same data
        try target.write_register(.boot, .{ .arg = 0 }, addr);
        try target.write_register(.boot, .{ .arg = 1 }, flasher.chunk_data_addr);
        try target.write_register(.boot, .{ .arg = 2 }, flasher.chunk_size);
        try target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.verify_fn_offset);
        try target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try target.run(.boot);
        try wait(target);

        return (try target.read_register(.boot, .return_value)) & 0xFF == 1;
    }

    // TODO: maybe refactor calls to stub function
    /// Erase and then program flash chunk with data. Address must be aligned
    /// to image_header.page_size and data.len must equal chunk_size.
    pub fn load(flasher: WithStub, target: *Target, addr: u32, chunk: []const u8) !void {
        std.debug.assert(std.mem.isAligned(addr, flasher.page_size));
        std.debug.assert(std.mem.isAligned(chunk.len, flasher.page_size));
        std.debug.assert(chunk.len < flasher.max_chunk_size);

        std.log.debug("program: addr 0x{x:0>8} length 0x{x:0>8}", .{ addr, chunk.len });

        // Load chunk into memory
        try target.write_memory(flasher.chunk_data_addr, chunk);

        // Verify that the flash doesn't already contain the same data
        try target.write_register(.boot, .{ .arg = 0 }, addr);
        try target.write_register(.boot, .{ .arg = 1 }, flasher.chunk_data_addr);
        try target.write_register(.boot, .{ .arg = 2 }, flasher.chunk_size);
        try target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.verify_fn_offset);
        try target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try target.run(.boot);
        try wait(target);
        // If the flash data is identical, return.
        if ((try target.read_register(.boot, .return_value)) & 0xFF == 1) {
            std.log.debug("data identical. return", .{});
            return;
        }

        // Erase chunk
        try target.write_register(.boot, .{ .arg = 0 }, addr);
        try target.write_register(.boot, .{ .arg = 1 }, flasher.chunk_size);
        try target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.erase_fn_offset);
        try target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try target.run(.boot);
        try wait(target);

        // Program chunk
        try target.write_register(.boot, .{ .arg = 0 }, addr);
        try target.write_register(.boot, .{ .arg = 1 }, flasher.chunk_data_addr);
        try target.write_register(.boot, .{ .arg = 2 }, flasher.chunk_size);
        try target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.program_fn_offset);
        try target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try target.run(.boot);
        try wait(target);
    }

    fn wait(target: *Target) !void {
        var timeout: Timeout = try .init(.{
            .after = 5 * std.time.ns_per_s,
            .sleep_per_tick_ns = 100 * std.time.ns_per_ms,
        });
        while (!try target.is_halted(.boot)) {
            try timeout.tick();
        }
    }
};

pub fn elf(
    allocator: std.mem.Allocator,
    target: *Target,
    flasher: WithStub,
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

        const kind = try find_memory_region_kind(target.memory_map, ph.p_paddr, ph.p_filesz);
        if (kind != .flash) continue;

        try segments.append(allocator, .{
            .offset_in_elf = @intCast(ph.p_offset),
            .addr = @intCast(ph.p_paddr),
            .length = @intCast(ph.p_filesz),
        });
    }

    std.mem.sort(Segment, segments.items, {}, Segment.is_less);

    const chunk_data = try allocator.alloc(u8, flasher.chunk_size);
    defer allocator.free(chunk_data);
    var chunk_data_writer: std.Io.Writer = .fixed(chunk_data);
    var maybe_current_chunk_addr: ?u32 = null;

    var segment_index: u32 = 0;
    while (segment_index < segments.items.len) : (segment_index += 1) {
        const segment = segments.items[segment_index];

        if (maybe_current_chunk_addr) |current_chunk_addr| {
            if (segment.addr < current_chunk_addr + flasher.chunk_size) {
                try chunk_data_writer.splatByteAll(0, segment.addr - (current_chunk_addr + chunk_data_writer.end));
            } else {
                try flasher.load(target, maybe_current_chunk_addr.?, chunk_data);
                maybe_current_chunk_addr = null;
                chunk_data_writer.end = 0;
            }
        }

        if (maybe_current_chunk_addr == null) {
            const aligned_addr = std.mem.alignBackward(u32, segment.addr, flasher.page_size);
            try chunk_data_writer.splatByteAll(0, segment.addr - aligned_addr);
            maybe_current_chunk_addr = aligned_addr;
        }

        try elf_reader.seekTo(segment.offset_in_elf);

        var offset: u32 = 0;
        while (offset < segment.length) {
            const count = @min(flasher.chunk_size - chunk_data_writer.end, segment.length - offset);
            try elf_reader.interface.streamExact(&chunk_data_writer, count);
            offset += count;

            if (chunk_data_writer.end == flasher.chunk_size) {
                try flasher.load(target, maybe_current_chunk_addr.?, chunk_data);
                maybe_current_chunk_addr = maybe_current_chunk_addr.? + flasher.chunk_size;
                chunk_data_writer.end = 0;
            }
        }
    }

    if (maybe_current_chunk_addr) |current_chunk_addr| {
        if (chunk_data_writer.end < flasher.chunk_size)
            try chunk_data_writer.splatByteAll(0, flasher.chunk_size - chunk_data_writer.end);
        try flasher.load(target, current_chunk_addr, chunk_data);
    }
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
