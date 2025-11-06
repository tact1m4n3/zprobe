const std = @import("std");

const elf = @import("util").elf;
const flash_algorithm = @import("flash_algorithm");
pub const Algorithm = flash_algorithm.Algorithm;

const Progress = @import("Progress.zig");
const Timeout = @import("Timeout.zig");
const Target = @import("Target.zig");

pub const RunMethod = enum {
    reboot,
    call_entry,
};

pub fn load_elf(
    allocator: std.mem.Allocator,
    target: *Target,
    elf_info: elf.Info,
    elf_file_reader: *std.fs.File.Reader,
    maybe_run_method: ?RunMethod,
    maybe_progress: ?Progress,
) !void {
    var flash_only = true;
    var ram_only = true;

    for (elf_info.load_segments.items) |elf_seg| {
        if (elf_seg.file_size == 0) continue;
        if (target.find_memory_region_kind(elf_seg.physical_address, elf_seg.memory_size)) |region_kind| {
            switch (region_kind) {
                .flash => ram_only = false,
                .ram => flash_only = false,
            }
        }
    }

    if (!flash_only and !ram_only and maybe_run_method == null) {
        return error.RunMethodRequired;
    }

    var loader: Loader = .{};
    defer loader.deinit(allocator);
    try loader.add_elf(allocator, elf_info, elf_file_reader);
    try loader.load(allocator, target, maybe_progress, ram_only);

    // TODO: should we call system reset afterwards?
    if (maybe_run_method) |run_method| switch (run_method) {
        .reboot => try target.reset(.all),
        .call_entry => {
            try target.write_register(.boot, .instruction_pointer, elf_info.header.entry);
            try target.run(.boot);
        },
    } else if (flash_only) {
        try target.reset(.all);
    } else if (ram_only) {
        try target.write_register(.boot, .instruction_pointer, elf_info.header.entry);
        try target.run(.boot);
    } else unreachable; // branch checked earlier
}

pub const Loader = struct {
    segments: std.ArrayList(Segment) = .empty,

    pub const Segment = struct {
        addr: u64,
        data: []const u8,
        marked: bool = false,
        added: bool = false,

        fn is_less(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.addr < rhs.addr;
        }

        fn is_inside_range(segment: Segment, addr: u64, size: u64) bool {
            return segment.addr < addr + size and segment.addr + segment.data.len > addr;
        }

        fn is_overlapping_others(segment: Segment, others: []const Segment) !void {
            for (others) |other_segment| {
                if (segment.is_inside_range(other_segment.addr, other_segment.data.len))
                    return error.OverlappingSegment;
            }
        }
    };

    pub fn deinit(loader: *Loader, allocator: std.mem.Allocator) void {
        for (loader.segments.items) |segment| {
            allocator.free(segment.data);
        }
        loader.segments.deinit(allocator);
    }

    pub fn add_elf(
        loader: *Loader,
        allocator: std.mem.Allocator,
        elf_info: elf.Info,
        elf_file_reader: *std.fs.File.Reader,
    ) !void {
        var new_segments: std.ArrayList(Segment) = .empty;
        defer new_segments.deinit(allocator);
        errdefer for (new_segments.items) |segment| allocator.free(segment.data);

        for (elf_info.load_segments.items) |elf_seg| {
            if (elf_seg.file_size == 0) continue;

            const data = try allocator.alloc(u8, elf_seg.file_size);
            errdefer allocator.free(data);
            try elf_file_reader.seekTo(elf_seg.file_offset);
            try elf_file_reader.interface.readSliceAll(data);

            const segment: Segment = .{
                .addr = elf_seg.physical_address,
                .data = data,
            };
            try segment.is_overlapping_others(new_segments.items);
            try segment.is_overlapping_others(loader.segments.items);
            try new_segments.append(allocator, segment);
        }

        try loader.segments.ensureUnusedCapacity(allocator, new_segments.items.len);
        loader.segments.appendSliceAssumeCapacity(new_segments.items);
        std.mem.sort(Segment, loader.segments.items, {}, Segment.is_less);
    }

    pub fn add_segments(loader: *Loader, allocator: std.mem.Allocator, new_segments: []const Segment) !void {
        for (new_segments) |segment| {
            try segment.is_overlapping_others(loader.segments.items);
        }
        try loader.segments.ensureUnusedCapacity(allocator, new_segments.len);
        loader.segments.appendSliceAssumeCapacity(new_segments);
        std.mem.sort(Segment, loader.segments.items, {}, Segment.is_less);
    }

    pub fn load(loader: *Loader, allocator: std.mem.Allocator, target: *Target, maybe_progress: ?Progress, ram_only: bool) !void {
        if (!ram_only) {
            for (target.flash_algorithms) |algorithm| {
                const flasher: Flasher = try .init(allocator, target, &algorithm);

                var dirty_pages: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, algorithm.memory_range.size / algorithm.page_size);
                defer dirty_pages.deinit(allocator);

                for (loader.segments.items) |*segment| {
                    if (segment.added) continue;
                    if (!segment.is_inside_range(algorithm.memory_range.start, algorithm.memory_range.size)) continue;

                    // TODO: maybe also verify if flash already contains the expected
                    // segment data. If it does we don't set the dirty bits.

                    const algorithm_offset = segment.addr - algorithm.memory_range.start;
                    const start_page_index = algorithm_offset / algorithm.page_size;
                    const end_page_index = (algorithm_offset + segment.data.len) / algorithm.page_size;
                    dirty_pages.setRangeValue(.{
                        .start = start_page_index,
                        .end = end_page_index,
                    }, true);

                    segment.added = true;
                    segment.marked = true;
                }

                const total_dirty_pages = dirty_pages.count();

                // Start erasing
                {
                    if (maybe_progress) |progress| try progress.begin("Erasing", total_dirty_pages);
                    defer if (maybe_progress) |progress| progress.end();

                    try flasher.begin(.erase);
                    defer flasher.end(.erase) catch {};

                    const page_end_index = (algorithm.memory_range.start + algorithm.memory_range.size) / algorithm.page_size;
                    var sector_index: usize = 0;
                    while (sector_index < algorithm.sectors.len) : (sector_index += 1) {
                        const sector_info = algorithm.sectors[sector_index];

                        const pages_per_sector = sector_info.size / algorithm.page_size;
                        var index = sector_info.addr / algorithm.page_size;

                        const end_index = if (sector_index < algorithm.sectors.len - 1)
                            algorithm.sectors[sector_index + 1].addr / algorithm.page_size
                        else
                            page_end_index;

                        while (index < end_index) : (index += pages_per_sector) {
                            // This operation can be done much more efficiently with some custom logic
                            var should_erase = false;
                            for (0..pages_per_sector) |i| {
                                if (index + i < dirty_pages.bit_length and dirty_pages.isSet(index + i)) {
                                    should_erase = true;
                                    break;
                                }
                            }
                            if (should_erase) {
                                const erase_addr = algorithm.memory_range.start + index * algorithm.page_size;
                                try flasher.erase_sector(erase_addr);
                                if (maybe_progress) |progress| try progress.increment(pages_per_sector);
                            }
                        }
                    }
                }

                // Start flashing
                {
                    if (maybe_progress) |progress| try progress.begin("Flashing", total_dirty_pages);
                    defer if (maybe_progress) |progress| progress.end();

                    try flasher.begin(.program);
                    defer flasher.end(.program) catch {};

                    // TODO: What makes a good buffer size here?
                    var buffer: [4096]u8 = undefined;
                    var prog: Programmer = .init(&flasher, maybe_progress, &buffer);

                    for (loader.segments.items) |*segment| {
                        if (!segment.marked) continue;
                        try prog.write(segment.addr, segment.data);
                        segment.marked = false;
                    }
                    try prog.flush();
                }
            }
        }

        for (loader.segments.items) |*segment| {
            if (segment.added) continue;
            if (target.find_memory_region_kind(segment.addr, segment.data.len)) |kind| {
                if (kind == .ram) {
                    try target.write_memory(segment.addr, segment.data);
                    segment.added = true;
                }
            }
        }

        for (loader.segments.items) |segment| {
            if (!segment.added) std.log.warn("Segment at 0x{x} with len 0x{x} ignored", .{ segment.addr, segment.data.len });
        }
    }
};

pub fn get_algorithm(comptime name: []const u8) Algorithm {
    const algorithms_bundle: []const Algorithm = @import("flash_algorithms_bundle");
    for (algorithms_bundle) |alg| {
        if (std.mem.eql(u8, name, alg.name))
            return alg;
    } else @compileError(std.fmt.comptimePrint("Flash algorithm with name {s} not found", .{name}));
}

/// Calls flash algorithm function for you.
pub const Flasher = struct {
    const stack_size = 8096;
    const stack_align = 128;

    target: *Target,
    algorithm: *const Algorithm,
    load_addr: u64,
    stack_end: u64,
    data_addr: u64,
    max_data_pages: u64,

    pub fn init(allocator: std.mem.Allocator, target: *Target, alg: *const Algorithm) !Flasher {
        // Find ram to load the stub
        const load_region = ram_search: for (target.memory_map) |region| {
            if (region.kind == .ram) {
                break :ram_search region;
            }
        } else return error.NoRamRegion;

        const load_addr = load_region.offset;

        const decoder = std.base64.standard.Decoder;
        const decoded_instructions_max_len = try decoder.calcSizeForSlice(alg.instructions);
        const decoded_instructions: []u8 = try allocator.alloc(u8, decoded_instructions_max_len);
        defer allocator.free(decoded_instructions);
        try decoder.decode(decoded_instructions, alg.instructions);

        // Calculate stack end location
        const stack_end = std.mem.alignForward(u64, load_addr + decoded_instructions.len + stack_size, stack_align);

        // Calculate transfer data start location
        const data_addr = std.mem.alignForward(u64, stack_end, alg.page_size);

        // Calculate max transfer data size
        const max_data_pages = (load_region.offset + load_region.length - data_addr) / alg.page_size;

        // Halt all cores since we are going to modify memory (if any are running)
        try target.halt(.all);

        // Load stub into ram
        try target.write_memory(load_addr, decoded_instructions);

        return .{
            .target = target,
            .algorithm = alg,
            .load_addr = load_addr,
            .stack_end = stack_end,
            .data_addr = data_addr,
            .max_data_pages = max_data_pages,
        };
    }

    pub const Function = flash_algorithm.Function;

    pub fn begin(flasher: Flasher, function: Function) !void {
        try flasher.call_fn(flasher.algorithm.init_fn, &.{
            flasher.algorithm.memory_range.start,
            0,
            @intFromEnum(function),
        });
        try flasher.wait(null);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        if (return_value != 0) return error.BeginFailed;
    }

    pub fn end(flasher: Flasher, function: Function) !void {
        try flasher.call_fn(flasher.algorithm.uninit_fn, &.{
            @intFromEnum(function),
        });
        try flasher.wait(null);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        if (return_value != 0) return error.EndFailed;
    }

    /// Program flash. Address must be aligned to page_size and
    /// data.len must less than page_size.
    pub fn program_page(flasher: Flasher, addr: u64, data_addr: u64) !void {
        try flasher.call_fn(flasher.algorithm.program_page_fn, &.{
            addr,
            flasher.algorithm.page_size,
            data_addr,
        });
        try flasher.wait(.program);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        if (return_value != 0) return error.ProgramPageFailed;
    }

    pub fn erase_sector(flasher: Flasher, addr: u64) !void {
        try flasher.call_fn(flasher.algorithm.erase_sector_fn, &.{addr});
        try flasher.wait(.program);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        if (return_value != 0) return error.EraseSectorFailed;
    }

    pub fn verify_sector(flasher: Flasher, addr: u64, data: []const u8) !bool {
        const verify_fn = flasher.algorithm.verify_fn orelse return error.OperationNotSupported;

        try flasher.target.write_memory(flasher.data_addr, data);

        try flasher.call_fn(verify_fn, &.{
            addr,
            data.len,
            flasher.data_addr,
        });
        try flasher.wait(.verify);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        return return_value == addr + data.len;
    }

    fn call_fn(flasher: Flasher, ip: u64, args: []const u64) !void {
        for (args, 0..) |value, i| {
            try flasher.target.write_register(.boot, .{ .arg = @intCast(i) }, value);
        }

        // Return address is always at the beginning
        try flasher.target.write_register(.boot, .return_address, flasher.load_addr + 1);
        try flasher.target.write_register(.boot, .instruction_pointer, flasher.load_addr + ip);
        try flasher.target.write_register(.boot, .stack_pointer, flasher.stack_end);
        try flasher.target.run(.boot);
    }

    fn wait(flasher: Flasher, maybe_function: ?Function) !void {
        const timeout_ms = if (maybe_function) |function| switch (function) {
            .program => flasher.algorithm.program_page_timeout,
            .erase => flasher.algorithm.erase_sector_timeout,
            .verify => 5000, // should we also take this?
        } else 1000;

        var timeout: Timeout = try .init(.{
            .after = timeout_ms * std.time.ns_per_ms,
        });
        while (!try flasher.target.is_halted(.boot)) {
            try timeout.tick();
        }
    }
};

/// Writes ordered but maybe sparse data (in terms of address) to flash.
pub const Programmer = struct {
    flasher: *const Flasher,
    maybe_progress: ?Progress,
    writer: Target.MemoryWriter,
    current_flash_addr: u64,

    pub fn init(flasher: *const Flasher, maybe_progress: ?Progress, buffer: []u8) Programmer {
        return .{
            .flasher = flasher,
            .maybe_progress = maybe_progress,
            .writer = .init(flasher.target, buffer, flasher.data_addr),
            .current_flash_addr = flasher.algorithm.memory_range.start,
        };
    }

    pub fn write(prog: *Programmer, addr: u64, data: []const u8) !void {
        const page_size = prog.flasher.algorithm.page_size;
        std.debug.assert(prog.current_flash_addr <= addr);
        if (addr >= std.mem.alignForward(u64, prog.current_flash_addr, page_size) + page_size or
            (prog.writer.offset + data.len) / page_size + 2 >= prog.flasher.max_data_pages)
        {
            try prog.flush();
            prog.current_flash_addr = std.mem.alignBackward(u64, addr, page_size);
        }
        try prog.writer.interface.splatByteAll(prog.flasher.algorithm.erased_byte_value, addr - prog.current_flash_addr);
        try prog.writer.interface.writeAll(data);
        prog.current_flash_addr += data.len;
    }

    pub fn flush(prog: *Programmer) !void {
        if (prog.writer.offset == 0) return;

        const page_size = prog.flasher.algorithm.page_size;
        const aligned_end = std.mem.alignForward(u64, prog.current_flash_addr, page_size);
        try prog.writer.interface.splatByteAll(prog.flasher.algorithm.erased_byte_value, aligned_end - prog.current_flash_addr);
        try prog.writer.interface.flush();

        prog.current_flash_addr = aligned_end;

        const ram_addr: u64 = prog.writer.address;
        const flash_addr: u64 = prog.current_flash_addr - prog.writer.offset;
        var offset: u64 = 0;
        while (offset < prog.writer.offset) : (offset += page_size) {
            try prog.flasher.program_page(flash_addr + offset, ram_addr + offset);
            if (prog.maybe_progress) |progress| try progress.increment(1);
        }

        prog.writer.offset = 0;
    }
};

// test "load_segments" {
//     // // zig fmt: off
//     // const expected_data: []const u8 = &.{
//     //     0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x00, 0x00,
//     //     0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x00,
//     //     0x01, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x0A,
//     //     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
//     // };
//     // // zig fmt: on
//     // const expected_addrs: []const u64 = &.{ 0x00, 0x8, 0x10, 0x18 };
//
//     const allocator = std.testing.allocator;
//
//     var loader: Loader = .{};
//     defer loader.deinit(allocator);
//     try loader.add_segments(allocator, &.{
//         .{ .addr = 0x00, .data = try allocator.dupe(u8, &.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 }) },
//         .{ .addr = 0x08, .data = try allocator.dupe(u8, &.{ 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C }) },
//         .{ .addr = 0x0E, .data = try allocator.dupe(u8, &.{0x0D}) },
//         .{ .addr = 0x10, .data = try allocator.dupe(u8, &.{0x01}) },
//         .{ .addr = 0x13, .data = try allocator.dupe(u8, &.{0x0C}) },
//         .{ .addr = 0x17, .data = try allocator.dupe(u8, &.{0x0A}) },
//         .{ .addr = 0x100, .data = try allocator.dupe(u8, &.{ 0x0A, 0x0B, 0x0C }) },
//         .{ .addr = 0x104, .data = try allocator.dupe(u8, &.{0x0A}) },
//     });
//
//     const algorithm: Algorithm = .{
//         .name = "dummy",
//         .instructions = "",
//         .memory_range = .{ .start = 0, .size = 100 },
//         .init_fn = undefined,
//         .uninit_fn = undefined,
//         .program_page_fn = undefined,
//         .erase_sector_fn = undefined,
//         .program_page_timeout = 1000,
//         .erase_sector_timeout = 1000,
//         .erased_byte_value = 0xFF,
//         .page_size = 8,
//         .sectors = &.{.{ .addr = 0, .size = 16 }},
//     };
//
//     var dummy_target: Target = .{
//         .name = "dummy",
//         .endian = .little,
//         .flash_algorithms = &.{
//             algorithm,
//         },
//         .memory_map = &.{
//             .{ .offset = 0, .length = 0x100, .kind = .flash },
//             .{ .offset = 0x100, .length = 0x100, .kind = .ram },
//         },
//         .valid_cores = .empty,
//         .vtable = undefined,
//     };
//
//     const plan: Plan = try .init(allocator, &dummy_target, loader.segments.items);
//     defer plan.deinit(allocator);
//
//     for (plan.flash_tasks) |task| {
//         for (task.addrs) |addr| std.debug.print("{} ", .{addr});
//         std.debug.print("\n", .{});
//     }
//
//     for (plan.erase_tasks) |task| {
//         for (task.sectors) |sector| std.debug.print("{}-{} ", .{ sector.addr, sector.size });
//         std.debug.print("\n", .{});
//     }
//     // std.debug.print("{any}\n{any}\n{any}\n", .{plan.flash_tasks, plan.erase_tasks, plan.ram_tasks});
// }
