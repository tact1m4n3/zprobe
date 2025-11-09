const std = @import("std");
const elf = @import("util").elf;
const flash_algorithm = @import("flash_algorithm");

var input_file_reader_buf: [1024]u8 = undefined;
var output_file_writer_buf: [1024]u8 = undefined;

pub fn main() !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    _ = args_iter.next();

    const output_file = try std.fs.cwd().createFile(args_iter.next() orelse return error.NoOutputFile, .{});
    defer output_file.close();
    var output_file_writer = output_file.writer(&output_file_writer_buf);

    var algs: std.ArrayList(flash_algorithm.Algorithm) = .empty;

    while (args_iter.next()) |name| {
        const path = args_iter.next() orelse return error.ExpectedElfPath;

        const input_file = try std.fs.cwd().openFile(path, .{});
        var input_file_reader = input_file.reader(&input_file_reader_buf);

        const elf_info: elf.Info = try .init(allocator, &input_file_reader);
        if (elf_info.load_segments.items.len != 1) {
            return error.ExpectedOneContiguousSegment;
        }
        const segment = elf_info.load_segments.items[0];
        try input_file_reader.seekTo(segment.file_offset);

        const instructions = try allocator.alloc(u8, segment.memory_size);
        try input_file_reader.interface.readSliceAll(instructions[0..segment.file_size]);
        @memset(instructions[segment.file_size..], 0);

        const base64_encoder = std.base64.standard.Encoder;
        const encoded_instructions_len = base64_encoder.calcSize(segment.memory_size);
        const encoded_instructions = try allocator.alloc(u8, encoded_instructions_len);
        _ = base64_encoder.encode(encoded_instructions, instructions);

        const init_fn = if (try elf_info.get_symbol(&input_file_reader, "flash_init")) |sym| sym.st_value else return error.MandatorySymNotFound;
        const uninit_fn = if (try elf_info.get_symbol(&input_file_reader, "flash_uninit")) |sym| sym.st_value else return error.MandatorySymNotFound;
        const program_page_fn = if (try elf_info.get_symbol(&input_file_reader, "flash_program_page")) |sym| sym.st_value else return error.MandatorySymNotFound;
        const erase_sector_fn = if (try elf_info.get_symbol(&input_file_reader, "flash_erase_sector")) |sym| sym.st_value else return error.MandatorySymNotFound;
        const erase_all_fn = if (try elf_info.get_symbol(&input_file_reader, "flash_erase_all")) |sym| sym.st_value else null;
        const verify_fn = if (try elf_info.get_symbol(&input_file_reader, "flash_verify")) |sym| sym.st_value else null;

        const data_section_offset = if (try elf_info.get_symbol(&input_file_reader, "data_section_offset")) |sym| sym.st_value else null;

        const metadata_section = elf_info.sections.get(".meta") orelse return error.MetadataSectionNotFound;
        try input_file_reader.seekTo(metadata_section.file_offset);
        const main_metadata = try input_file_reader.interface.takeStruct(flash_algorithm.firmware.Metadata(0), elf_info.header.endian);
        var metadata_section_offset: usize = @sizeOf(flash_algorithm.firmware.Metadata(0));
        var sectors: std.ArrayList(flash_algorithm.Algorithm.SectorInfo) = .empty;
        while (metadata_section_offset < metadata_section.size) : (metadata_section_offset += @sizeOf(flash_algorithm.firmware.SectorInfo)) {
            const sector = try input_file_reader.interface.takeStruct(flash_algorithm.firmware.SectorInfo, elf_info.header.endian);
            try sectors.append(allocator, .{
                .addr = sector.addr,
                .size = sector.size,
            });
        }

        try algs.append(allocator, .{
            .name = name,
            .instructions = encoded_instructions,
            .memory_range = .{
                .start = main_metadata.flash_start,
                .size = main_metadata.flash_size,
            },
            .init_fn = init_fn,
            .uninit_fn = uninit_fn,
            .program_page_fn = program_page_fn,
            .erase_sector_fn = erase_sector_fn,
            .erase_all_fn = erase_all_fn,
            .verify_fn = verify_fn,
            .data_section_offset = data_section_offset,
            .page_size = main_metadata.page_size,
            .stack_size = if (main_metadata.stack_size != 0) main_metadata.stack_size else null,
            .erased_byte_value = main_metadata.erased_byte_value,
            .program_page_timeout = main_metadata.program_page_timeout,
            .erase_sector_timeout = main_metadata.erase_sector_timeout,
            .sectors = sectors.items,
        });
    }

    try std.zon.stringify.serialize(algs.items, .{}, &output_file_writer.interface);
    try output_file_writer.interface.flush();
}
