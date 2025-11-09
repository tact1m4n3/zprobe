const std = @import("std");

const elf = @import("util").elf;
const flash_algorithm = @import("flash_algorithm");
pub const Algorithm = flash_algorithm.Algorithm;

const Progress = @import("Progress.zig");
const Target = @import("Target.zig");
const Timeout = @import("Timeout.zig");

const log = std.log.scoped(.flash);

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
        if (!ram_only) flash: {
            for (target.flash_algorithms) |algorithm| {
                const flasher: Flasher = try .init(allocator, target, &algorithm);

                var dirty_pages: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, algorithm.memory_range.size / algorithm.page_size);
                defer dirty_pages.deinit(allocator);

                var total_packed_data: u64 = 0;

                for (loader.segments.items) |*segment| {
                    if (segment.added) continue;
                    if (!segment.is_inside_range(algorithm.memory_range.start, algorithm.memory_range.size)) continue;

                    const algorithm_offset = segment.addr - algorithm.memory_range.start;
                    const start_page_index = algorithm_offset / algorithm.page_size;
                    const end_page_index = (algorithm_offset + segment.data.len) / algorithm.page_size;
                    dirty_pages.setRangeValue(.{
                        .start = start_page_index,
                        .end = end_page_index,
                    }, true);

                    total_packed_data += segment.data.len;

                    segment.added = true;
                    segment.marked = true;
                }

                // TODO: maybe make this check optional
                const should_flash = if (flasher.algorithm.verify_fn != null) blk: {
                    if (maybe_progress) |progress| try progress.begin("Checking", total_packed_data);
                    defer if (maybe_progress) |progress| progress.end();

                    try flasher.begin(.verify);
                    defer flasher.end(.verify) catch {};

                    for (loader.segments.items) |segment| {
                        if (!segment.marked) continue;
                        if (!try verify(&flasher, segment.addr, segment.data, maybe_progress))
                            break :blk true;
                    }
                    break :blk false;
                } else true;
                if (!should_flash) break :flash;

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
                                log.debug("erasing 0x{x}->0x{x}", .{ erase_addr, erase_addr + sector_info.size });
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
                    }
                    try prog.flush();
                }

                if (flasher.algorithm.verify_fn != null) {
                    if (maybe_progress) |progress| try progress.begin("Verify", total_packed_data);
                    defer if (maybe_progress) |progress| progress.end();

                    try flasher.begin(.verify);
                    defer flasher.end(.verify) catch {};

                    for (loader.segments.items) |segment| {
                        if (!segment.marked) continue;
                        log.debug("verifying 0x{x}->0x{x}", .{ segment.addr, segment.addr + segment.data.len });
                        if (!try verify(&flasher, segment.addr, segment.data, maybe_progress))
                            return error.FlashDataMismatch;
                    }
                }

                for (loader.segments.items) |*segment| {
                    if (!segment.marked) continue;
                    segment.marked = false;
                }
            }
        }

        for (loader.segments.items) |*segment| {
            if (segment.added) continue;
            if (target.find_memory_region_kind(segment.addr, segment.data.len)) |kind| {
                if (kind == .ram) {
                    try target.memory.write(segment.addr, segment.data);
                    segment.added = true;
                }
            }
        }

        for (loader.segments.items) |segment| {
            if (!segment.added) log.warn("Segment at 0x{x} with len 0x{x} ignored", .{ segment.addr, segment.data.len });
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
    const default_stack_size = 1024;

    pub const ARM_BKPT: u32 = 0xBE00_BE00;

    target: *Target,
    algorithm: *const Algorithm,
    load_addr: u64,
    code_addr: u64,
    stack_start_addr: u64,
    stack_end_addr: u64,
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

        const header: []const u32 = switch (target.arch) {
            .thumb => switch (target.endian) {
                .little => &.{ARM_BKPT},
                // We convert it to big endian and when written it gets
                // converted back to little.
                .big => &.{std.mem.nativeToBig(u32, ARM_BKPT)},
            },
            else => @panic("TODO"),
        };
        const code_addr = load_addr + header.len * @sizeOf(u32);

        const decoder = std.base64.standard.Decoder;
        const decoded_instructions_max_len = try decoder.calcSizeForSlice(alg.instructions);
        const decoded_instructions: []u8 = try allocator.alloc(u8, decoded_instructions_max_len);
        defer allocator.free(decoded_instructions);
        try decoder.decode(decoded_instructions, alg.instructions);

        // Calculate stack start and end locations
        const stack_align: u64 = switch (target.arch) {
            .thumb => 8,
            .riscv32 => 16,
        };
        const stack_start_addr = code_addr + decoded_instructions.len;
        const stack_size = alg.stack_size orelse default_stack_size;
        const stack_end_addr = std.mem.alignForward(u64, stack_start_addr + stack_size, stack_align);

        // Calculate transfer data start location
        const data_addr = std.mem.alignForward(u64, stack_end_addr, alg.page_size);

        // Calculate max transfer data size
        const max_data_pages = (load_region.offset + load_region.length - data_addr) / alg.page_size;

        // Halt all cores since we are going to modify memory (if any are running)
        try target.halt(.all);

        // Load header
        try target.memory.write_u32(load_addr, header);

        // Load stub into ram
        try target.memory.write(code_addr, decoded_instructions);

        return .{
            .target = target,
            .algorithm = alg,
            .load_addr = load_addr,
            .code_addr = code_addr,
            .stack_start_addr = stack_start_addr,
            .stack_end_addr = stack_end_addr,
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
        }, true);
        try flasher.wait(null);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        if (return_value != 0) return error.BeginFailed;
    }

    pub fn end(flasher: Flasher, function: Function) !void {
        try flasher.call_fn(flasher.algorithm.uninit_fn, &.{
            @intFromEnum(function),
        }, false);
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
        }, false);
        try flasher.wait(.program);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        if (return_value != 0) return error.ProgramPageFailed;
    }

    pub fn erase_sector(flasher: Flasher, addr: u64) !void {
        try flasher.call_fn(flasher.algorithm.erase_sector_fn, &.{addr}, false);
        try flasher.wait(.erase);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        if (return_value != 0) return error.EraseSectorFailed;
    }

    pub fn verify(flasher: Flasher, addr: u64, data_addr: u64, len: u64) !bool {
        const verify_fn = flasher.algorithm.verify_fn orelse return error.OperationNotSupported;

        try flasher.call_fn(verify_fn, &.{ addr, len, data_addr }, false);
        try flasher.wait(.verify);

        const return_value = try flasher.target.read_register(.boot, .return_value);
        return return_value == addr + len;
    }

    fn call_fn(flasher: Flasher, ip: u64, args: []const u64, is_init: bool) !void {
        for (args, 0..) |value, i| {
            try flasher.target.write_register(.boot, .{ .arg = @intCast(i) }, value);
        }

        // Return address is always at the beginning
        try flasher.target.write_register(.boot, .return_address, switch (flasher.target.arch) {
            .thumb => flasher.load_addr + 1,
            else => flasher.load_addr,
        });
        try flasher.target.write_register(.boot, .instruction_pointer, flasher.code_addr + ip);
        if (is_init) {
            try flasher.target.write_register(.boot, .stack_pointer, flasher.stack_end_addr);
            if (flasher.algorithm.data_section_offset) |data_section_offset|
                try flasher.target.write_register(.boot, .static_base, flasher.code_addr + data_section_offset);
        }
        try flasher.target.run(.boot);
    }

    const DEFAULT_TIMEOUT_MS: usize = 1000;

    fn wait(flasher: Flasher, maybe_function: ?Function) !void {
        const timeout_ms = if (maybe_function) |function| switch (function) {
            .program => flasher.algorithm.program_page_timeout,
            .erase => flasher.algorithm.erase_sector_timeout,
            .verify => DEFAULT_TIMEOUT_MS,
        } else DEFAULT_TIMEOUT_MS;

        var timeout: Timeout = try .init(.{
            .after = timeout_ms * std.time.ns_per_ms,
        });
        while (!try flasher.target.is_halted(.boot)) {
            try timeout.tick();
        }
    }
};

pub fn verify(flasher: *const Flasher, addr: u64, data: []const u8, maybe_progress: ?Progress) !bool {
    var offset: u64 = 0;
    while (offset < data.len) : (offset += flasher.algorithm.page_size) {
        const count = @min(data.len - offset, flasher.algorithm.page_size);
        try flasher.target.memory.write(flasher.data_addr, data[offset..][0..count]);
        if (!try flasher.verify(addr + offset, flasher.data_addr, count)) {
            return false;
        }
        if (maybe_progress) |progress| try progress.increment(count);
    }
    return true;
}

/// Writes ordered but maybe sparse data (in terms of address) to flash.
pub const Programmer = struct {
    flasher: *const Flasher,
    maybe_progress: ?Progress,
    writer: Target.Memory.Writer,
    current_flash_addr: u64,

    pub fn init(flasher: *const Flasher, maybe_progress: ?Progress, buffer: []u8) Programmer {
        return .{
            .flasher = flasher,
            .maybe_progress = maybe_progress,
            .writer = .init(flasher.target.memory, buffer, flasher.data_addr),
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
            log.debug("programming 0x{x}->0x{x}", .{ flash_addr + offset, flash_addr + offset + page_size });
            try prog.flasher.program_page(flash_addr + offset, ram_addr + offset);
            if (prog.maybe_progress) |progress| try progress.increment(1);
        }

        prog.writer.offset = 0;
    }
};
