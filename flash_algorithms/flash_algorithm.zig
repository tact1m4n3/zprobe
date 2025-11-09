const builtin = @import("builtin");
const std = @import("std");

pub const Algorithm = struct {
    name: []const u8,
    instructions: []const u8,
    memory_range: MemoryRange,
    init_fn: u64,
    uninit_fn: u64,
    program_page_fn: u64,
    erase_sector_fn: u64,
    erase_all_fn: ?u64 = null,
    verify_fn: ?u64 = null,
    data_section_offset: ?u64 = null,
    page_size: u64,
    stack_size: ?u64 = null,
    erased_byte_value: u8,
    program_page_timeout: u64,
    erase_sector_timeout: u64,
    sectors: []const SectorInfo,

    pub const MemoryRange = struct {
        start: u64,
        size: u64,
    };

    pub const SectorInfo = struct {
        addr: u64,
        size: u64,
    };
};

pub const Function = enum(usize) {
    erase = 1,
    program = 2,
    verify = 3,
};

pub const firmware = struct {
    pub fn init(comptime options: struct {
        init_fn: *const fn (addr: usize, clk: usize, f: Function) callconv(.c) c_int,
        uninit_fn: *const fn (f: Function) callconv(.c) c_int,
        program_page_fn: *const fn (addr: usize, size: usize, buf: [*]const u8) callconv(.c) c_int,
        erase_sector_fn: *const fn (addr: usize) callconv(.c) c_int,
        erase_all_fn: ?*const fn () callconv(.c) c_int = null,
        verify_fn: ?*const fn (addr: usize, size: usize, buf: [*]const u8) callconv(.c) usize = null,
        flash_start: usize,
        flash_size: usize,
        page_size: usize,
        stack_size: ?usize = null,
        erased_byte_value: u8,
        program_page_timeout: usize,
        erase_sector_timeout: usize,
        sectors: []const SectorInfo,
    }) void {
        comptime var sectors: [options.sectors.len]SectorInfo = undefined;
        @memcpy(&sectors, options.sectors);

        @export(options.init_fn, .{ .name = "flash_init" });
        @export(options.uninit_fn, .{ .name = "flash_uninit" });
        @export(options.program_page_fn, .{ .name = "flash_program_page" });
        @export(options.erase_sector_fn, .{ .name = "flash_erase_sector" });
        if (options.erase_all_fn) |erase_all_fn| @export(erase_all_fn, .{ .name = "flash_erase_all" });
        if (options.verify_fn) |verify_fn| @export(verify_fn, .{ .name = "flash_verify" });

        const S = struct {
            const meta: Metadata(options.sectors.len) = .{
                .flash_start = options.flash_start,
                .flash_size = options.flash_size,
                .page_size = options.page_size,
                .stack_size = options.stack_size orelse 0,
                .erased_byte_value = options.erased_byte_value,
                .program_page_timeout = options.program_page_timeout,
                .erase_sector_timeout = options.erase_sector_timeout,
                .sectors = sectors,
            };
        };
        @export(&S.meta, .{
            .name = "metadata",
            .section = ".meta",
        });
    }

    pub fn Metadata(sector_count: usize) type {
        return extern struct {
            flash_start: u64,
            flash_size: u64,
            page_size: u64,
            stack_size: u64,
            erased_byte_value: u8,
            program_page_timeout: u64,
            erase_sector_timeout: u64,
            sectors: [sector_count]SectorInfo,
        };
    }

    pub const SectorInfo = extern struct {
        addr: u64,
        size: u64,
    };
};
