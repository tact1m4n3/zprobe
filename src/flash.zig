const std = @import("std");

const Progress = @import("Progress.zig");
const Timeout = @import("Timeout.zig");
const Target = @import("Target.zig");
const elf = @import("elf.zig");

pub fn load_elf(
    allocator: std.mem.Allocator,
    target: *Target,
    elf_info: elf.Info,
    elf_file_reader: *std.fs.File.Reader,
    maybe_progress: ?Progress,
) !void {
    const stub_flasher: StubFlasher = try .init(target);

    var loader: Loader = .{};
    defer loader.deinit(allocator);
    try loader.add_elf(allocator, elf_file_reader, elf_info, target.memory_map);

    const output = try loader.bake(allocator, stub_flasher.page_size, stub_flasher.ideal_transfer_size);
    defer output.deinit(allocator);

    try output.load(stub_flasher, maybe_progress);
}

pub const Loader = struct {
    segments: std.ArrayList(Segment) = .empty,

    pub fn deinit(loader: *Loader, allocator: std.mem.Allocator) void {
        for (loader.segments.items) |segment| {
            allocator.free(segment.data);
        }
        loader.segments.deinit(allocator);
    }

    pub fn add_elf(
        loader: *Loader,
        allocator: std.mem.Allocator,
        elf_file_reader: *std.fs.File.Reader,
        elf_info: elf.Info,
        memory_map: []const Target.MemoryRegion,
    ) !void {
        var new_segments: std.ArrayList(Segment) = .empty;
        defer new_segments.deinit(allocator);
        errdefer for (new_segments.items) |segment| allocator.free(segment.data);

        for (elf_info.load_segments.items) |elf_seg| {
            const kind = try find_memory_region_kind(memory_map, elf_seg.physical_address, elf_seg.file_size);
            if (kind != .flash) {
                std.log.warn("found non flash segment", .{});
                continue;
            }

            const data = try allocator.alloc(u8, elf_seg.memory_size);
            errdefer allocator.free(data);

            try elf_file_reader.seekTo(elf_seg.file_offset);
            try elf_file_reader.interface.readSliceAll(data[0..elf_seg.file_size]);
            @memset(data[elf_seg.file_size..], 0);

            const segment: Segment = .{
                .addr = elf_seg.physical_address,
                .data = data,
            };
            try segment.check_overlapping(new_segments.items);
            try segment.check_overlapping(loader.segments.items);
            try new_segments.append(allocator, segment);
        }

        try loader.segments.ensureUnusedCapacity(allocator, new_segments.items.len);
        loader.segments.appendSliceAssumeCapacity(new_segments.items);
        std.mem.sort(Segment, loader.segments.items, {}, Segment.is_less);
    }

    pub fn add_segments(loader: *Loader, allocator: std.mem.Allocator, new_segments: []const Segment) !void {
        for (new_segments) |segment| {
            try segment.check_overlapping(loader.segments.items);
        }
        try loader.segments.ensureUnusedCapacity(allocator, new_segments.len);
        loader.segments.appendSliceAssumeCapacity(new_segments);
        std.mem.sort(Segment, loader.segments.items, {}, Segment.is_less);
    }

    pub fn bake(loader: Loader, allocator: std.mem.Allocator, page_size: u64, chunk_size: u64) !Output {
        var data: std.Io.Writer.Allocating = .init(allocator);
        defer data.deinit();

        var addrs: std.ArrayList(u64) = .empty;
        defer addrs.deinit(allocator);

        const ChunkInfo = struct {
            addr: u64,
            end: u64,
        };
        var maybe_current_chunk: ?ChunkInfo = null;

        for (loader.segments.items) |segment| {
            if (maybe_current_chunk) |*current_chunk| {
                if (segment.addr < current_chunk.addr + chunk_size) {
                    const splat_length = segment.addr - (current_chunk.addr + current_chunk.end);
                    try data.writer.splatByteAll(0, splat_length);
                    current_chunk.end += splat_length;
                } else {
                    if (current_chunk.end < chunk_size)
                        try data.writer.splatByteAll(0, chunk_size - current_chunk.end);

                    try addrs.append(allocator, current_chunk.addr);
                    maybe_current_chunk = null;
                }
            }

            if (maybe_current_chunk == null) {
                const aligned_addr = std.mem.alignBackward(u64, segment.addr, page_size);
                const splat_length = segment.addr - aligned_addr;
                try data.writer.splatByteAll(0, splat_length);
                maybe_current_chunk = .{
                    .addr = aligned_addr,
                    .end = splat_length,
                };
            }

            var offset: u64 = 0;
            while (offset < segment.data.len) {
                const current_chunk = unwrap_mut_opt(ChunkInfo, &maybe_current_chunk);

                const count = @min(chunk_size - current_chunk.end, segment.data.len - offset);

                try data.writer.writeAll(segment.data[offset..][0..count]);
                offset += count;
                current_chunk.end += count;

                if (current_chunk.end == chunk_size) {
                    try addrs.append(allocator, current_chunk.addr);
                    maybe_current_chunk = .{
                        .addr = current_chunk.addr + chunk_size,
                        .end = 0,
                    };
                }
            }
        }

        if (maybe_current_chunk) |chunk| {
            if (chunk.end != 0) {
                if (chunk.end < chunk_size)
                    try data.writer.splatByteAll(0, chunk_size - chunk.end);
                try addrs.append(allocator, chunk.addr);
            }
        }

        const data_owned = try data.toOwnedSlice();
        errdefer allocator.free(data_owned);
        const addrs_owned = try addrs.toOwnedSlice(allocator);
        errdefer allocator.free(addrs_owned);
        return .{
            .data = data_owned,
            .addrs = addrs_owned,
            .chunk_size = chunk_size,
        };
    }
};

pub const Segment = struct {
    addr: u64,
    data: []const u8,

    fn is_less(_: void, lhs: @This(), rhs: @This()) bool {
        return lhs.addr < rhs.addr;
    }

    fn check_overlapping(segment: Segment, others: []const Segment) !void {
        for (others) |other_segment| {
            if (segment.addr < other_segment.addr + other_segment.data.len and
                segment.addr + segment.data.len > other_segment.addr)
                return error.OverlappingSegment;
        }
    }
};

pub const Output = struct {
    data: []const u8,
    addrs: []const u64,
    chunk_size: u64,

    pub fn deinit(output: Output, allocator: std.mem.Allocator) void {
        allocator.free(output.data);
        allocator.free(output.addrs);
    }

    pub fn load(output: Output, flasher: anytype, maybe_progress: ?Progress) !void {
        if (maybe_progress) |progress| {
            try progress.step(.{
                .name = "Flashing",
                .completed = 0,
                .total = output.addrs.len,
            });
        }
        defer if (maybe_progress) |progress| progress.end();

        try flasher.begin();

        for (output.addrs, 0..) |addr, i| {
            try flasher.load(addr, output.data[i * output.chunk_size ..][0..output.chunk_size]);

            if (maybe_progress) |progress| {
                try progress.step(.{
                    .name = "Flashing",
                    .completed = i + 1,
                    .total = output.addrs.len,
                });
            }
        }

        try flasher.end();
    }
};

pub const StubFlasher = struct {
    target: *Target,
    stub: []const u8,
    format: Format,
    image_header: ImageHeader64,
    image_base: u64,
    page_size: u64,
    ideal_transfer_size: u64,
    max_transfer_size: u64,
    data_addr: u64,

    pub const ImageHeader32 = extern struct {
        pub const MAGIC = 0xBAD_C0FFE;

        magic: u64,
        page_size: u32,
        ideal_transfer_size: u32,
        stack_pointer_offset: u32,
        return_address_offset: u32,
        begin_fn_offset: u32,
        verify_fn_offset: u32,
        erase_fn_offset: u32,
        program_fn_offset: u32,
    };

    pub const ImageHeader64 = extern struct {
        pub const MAGIC = 0xBAD_BAD_BAD_C00FFE;

        magic: u64,
        page_size: u64,
        ideal_transfer_size: u64,
        stack_pointer_offset: u64,
        return_address_offset: u64,
        begin_fn_offset: u64,
        verify_fn_offset: u64,
        erase_fn_offset: u64,
        program_fn_offset: u64,
    };

    pub const Format = enum {
        @"32bit",
        @"64bit",
    };

    pub fn init(target: *Target) !StubFlasher {
        const stub: []const u8 = (try get_flash_stub(target.name)) orelse return error.NoStubFound;
        var header_reader: std.Io.Reader = .fixed(stub);

        // Peek magic to check if the stub is 32bit or 64bit
        const magic = try header_reader.peekInt(u64, .little);

        // Read header
        const format: Format, const image_header: ImageHeader64 = switch (magic) {
            ImageHeader32.MAGIC => blk: {
                const image_header_32 = try header_reader.takeStruct(ImageHeader32, .little);
                break :blk .{ .@"32bit", .{
                    .magic = image_header_32.magic,
                    .page_size = image_header_32.page_size,
                    .ideal_transfer_size = image_header_32.ideal_transfer_size,
                    .stack_pointer_offset = image_header_32.stack_pointer_offset,
                    .return_address_offset = image_header_32.return_address_offset,
                    .begin_fn_offset = image_header_32.begin_fn_offset,
                    .verify_fn_offset = image_header_32.verify_fn_offset,
                    .erase_fn_offset = image_header_32.erase_fn_offset,
                    .program_fn_offset = image_header_32.program_fn_offset,
                } };
            },
            ImageHeader64.MAGIC => .{ .@"64bit", try header_reader.takeStruct(ImageHeader64, .little) },
            else => return error.InvalidMagic,
        };

        // Find ram to load the stub
        const load_region = ram_search: for (target.memory_map) |region| {
            if (region.kind == .ram) {
                break :ram_search region;
            }
        } else return error.NoRamRegion;

        const image_base = load_region.offset;

        // Calculate where should transfer data start
        const transfer_data_addr = std.mem.alignForward(
            u64,
            load_region.offset + stub.len,
            image_header.page_size,
        );

        if (format == .@"32bit" and transfer_data_addr > std.math.maxInt(u32))
            return error.NotSupported;

        // Calculate how much space is there for chunk data
        const max_transfer_size = std.mem.alignBackward(
            u64,
            load_region.offset + load_region.length,
            image_header.page_size,
        ) - transfer_data_addr;

        // If we don't have enough space for the ideal transfer size, return
        // error
        if (max_transfer_size < image_header.ideal_transfer_size) {
            return error.MemoryBufferTooSmall;
        }

        return .{
            .target = target,
            .stub = stub,
            .format = format,
            .image_header = image_header,
            .image_base = image_base,
            .page_size = image_header.page_size,
            .ideal_transfer_size = image_header.ideal_transfer_size,
            .max_transfer_size = max_transfer_size,
            .data_addr = transfer_data_addr,
        };
    }

    pub fn begin(flasher: StubFlasher) !void {
        // Halt all cores since we are going to modify memory (if any are running)
        try flasher.target.halt(.all);

        // Load stub into ram
        try flasher.target.write_memory(flasher.image_base, flasher.stub);

        // Call begin
        try flasher.target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try flasher.target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.begin_fn_offset);
        try flasher.target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try flasher.target.run(.boot);

        // awaited later
    }

    pub fn end(flasher: StubFlasher) !void {
        try flasher.wait();
    }

    // TODO: maybe refactor calls to stub function
    /// Verifies flash content.
    pub fn verify(flasher: StubFlasher, addr: u64, data: []const u8) !bool {
        std.debug.assert(std.mem.isAligned(addr, flasher.page_size));
        std.debug.assert(std.mem.isAligned(data.len, flasher.page_size));
        std.debug.assert(data.len <= flasher.max_transfer_size);

        try flasher.wait();

        // If the stub is 32 bit, we don't support 64 bit addresses
        if (flasher.format == .@"32bit") {
            if (addr > std.math.maxInt(u32)) return error.NotSupported;
            if (data.len > std.math.maxInt(u32)) return error.NotSupported;
        }

        // Load chunk into memory
        try flasher.target.write_memory(flasher.data_addr, data);

        // Verify that the flash doesn't already contain the same data
        try flasher.target.write_register(.boot, .{ .arg = 0 }, addr);
        try flasher.target.write_register(.boot, .{ .arg = 1 }, flasher.data_addr);
        try flasher.target.write_register(.boot, .{ .arg = 2 }, data.len);
        try flasher.target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try flasher.target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.verify_fn_offset);
        try flasher.target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try flasher.target.run(.boot);
        try flasher.wait();

        return (try flasher.target.read_register(.boot, .return_value)) & 0xFF == 1;
    }

    // TODO: maybe refactor calls to stub function
    /// Erase and then program flash. Address must be aligned to page_size and
    /// data.len must be a multiple of page_size and less then or equal to the
    /// max_transfer_size.
    pub fn load(flasher: StubFlasher, addr: u64, data: []const u8) !void {
        std.debug.assert(std.mem.isAligned(addr, flasher.page_size));
        std.debug.assert(std.mem.isAligned(data.len, flasher.page_size));
        std.debug.assert(data.len <= flasher.max_transfer_size);

        // If the stub is 32 bit, we don't support 64 bit addresses
        if (flasher.format == .@"32bit") {
            if (addr > std.math.maxInt(u32)) return error.NotSupported;
            if (data.len > std.math.maxInt(u32)) return error.NotSupported;
        }

        try flasher.wait();

        std.log.debug("program: addr 0x{x:0>8} length 0x{x:0>8}", .{ addr, data.len });

        // Load chunk into memory
        try flasher.target.write_memory(flasher.data_addr, data);

        // Verify that the flash doesn't already contain the same data
        try flasher.target.write_register(.boot, .{ .arg = 0 }, addr);
        try flasher.target.write_register(.boot, .{ .arg = 1 }, flasher.data_addr);
        try flasher.target.write_register(.boot, .{ .arg = 2 }, data.len);
        try flasher.target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try flasher.target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.verify_fn_offset);
        try flasher.target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try flasher.target.run(.boot);
        try flasher.wait();

        // If the flash data is identical, return.
        if ((try flasher.target.read_register(.boot, .return_value)) & 0xFF == 1) {
            std.log.debug("data identical. return", .{});
            return;
        }

        // Erase chunk
        try flasher.target.write_register(.boot, .{ .arg = 0 }, addr);
        try flasher.target.write_register(.boot, .{ .arg = 1 }, data.len);
        try flasher.target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try flasher.target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.erase_fn_offset);
        try flasher.target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try flasher.target.run(.boot);
        try flasher.wait();

        // Program chunk
        try flasher.target.write_register(.boot, .{ .arg = 0 }, addr);
        try flasher.target.write_register(.boot, .{ .arg = 1 }, flasher.data_addr);
        try flasher.target.write_register(.boot, .{ .arg = 2 }, data.len);
        try flasher.target.write_register(.boot, .return_address, flasher.image_base + flasher.image_header.return_address_offset);
        try flasher.target.write_register(.boot, .instruction_pointer, flasher.image_base + flasher.image_header.program_fn_offset);
        try flasher.target.write_register(.boot, .stack_pointer, flasher.image_base + flasher.image_header.stack_pointer_offset);
        try flasher.target.run(.boot);
        // try flasher.wait();
        // awaited later
    }

    fn wait(flasher: StubFlasher) !void {
        var timeout: Timeout = try .init(.{
            .after = 5 * std.time.ns_per_s,
        });
        while (!try flasher.target.is_halted(.boot)) {
            try timeout.tick();
        }
    }

    const flash_stubs_bundle_tar: []const u8 = @embedFile("flash_stubs_bundle.tar");

    fn get_flash_stub(name: []const u8) !?[]const u8 {
        var tar_reader: std.Io.Reader = .fixed(flash_stubs_bundle_tar);

        var file_name_buffer: [32]u8 = undefined;
        var it: std.tar.Iterator = .init(&tar_reader, .{
            .file_name_buffer = &file_name_buffer,
            .link_name_buffer = &.{},
        });

        while (try it.next()) |file| {
            if (file.kind == .file and std.mem.eql(u8, name, file.name)) {
                return try tar_reader.take(file.size);
            }
        }

        return null;
    }
};

pub const DebugFlasher = struct {
    page_size: u32 = 4096,
    ideal_transfer_size: u32 = 4096,

    pub fn begin(_: DebugFlasher) !void {}
    pub fn end(_: DebugFlasher) !void {}

    pub fn load(flasher: DebugFlasher, addr: u64, data: []const u8) !void {
        try std.debug.assert(std.mem.isAligned(addr, flasher.page_size));
        try std.debug.assert(std.mem.isAligned(data.len, flasher.page_size));
        try std.debug.assert(data.len <= flasher.max_chunk_size);

        if (addr != 0x10000000) return;

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

test "load_segments" {
    // zig fmt: off
    const expected_data: []const u8 = &.{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x00, 0x00,
        0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x00,
        0x01, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x0A,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    // zig fmt: on
    const expected_addrs: []const u64 = &.{ 0x00, 0x10 };
    const chunk_size = 16;
    const page_size = 8;

    const allocator = std.testing.allocator;

    var loader: Loader = .{};
    defer loader.deinit(allocator);
    try loader.add_segments(allocator, &.{
        .{ .addr = 0x00, .data = try allocator.dupe(u8, &.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 }) },
        .{ .addr = 0x08, .data = try allocator.dupe(u8, &.{ 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C }) },
        .{ .addr = 0x0E, .data = try allocator.dupe(u8, &.{0x0D}) },
        .{ .addr = 0x10, .data = try allocator.dupe(u8, &.{0x01}) },
        .{ .addr = 0x13, .data = try allocator.dupe(u8, &.{0x0C}) },
        .{ .addr = 0x17, .data = try allocator.dupe(u8, &.{0x0A}) },
    });

    const output = try loader.bake(allocator, chunk_size, page_size);
    defer output.deinit(allocator);

    try std.testing.expectEqualSlices(u8, expected_data, output.data);
    try std.testing.expectEqualSlices(u64, expected_addrs, output.addrs);
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

fn unwrap_mut_opt(T: type, opt: *?T) *T {
    if (opt.*) |*value| return value;
    unreachable;
}
