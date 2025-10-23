const std = @import("std");

pub const Info = struct {
    format: Format,
    header: std.elf.Header,
    string_table: []const u8,
    sections: std.StringHashMapUnmanaged(Section),
    load_segments: std.ArrayList(Segment),

    pub const Format = enum {
        @"32",
        @"64",
    };

    // TODO: what other info do we care about
    pub const Section = struct {
        address: u64,
        file_offset: u64,
        size: u64,
    };

    pub const Segment = struct {
        physical_address: u64,
        virtual_address: u64,
        file_offset: u64,
        file_size: u64,
        memory_size: u64,
        flags: Flags,

        pub const Flags = packed struct {
            read: bool,
            write: bool,
            exec: bool,
        };
    };

    pub fn init(allocator: std.mem.Allocator, file_reader: *std.fs.File.Reader) !Info {
        var header = try std.elf.Header.read(&file_reader.interface);

        const format: Format = if (header.is_64) .@"64" else .@"32";

        const string_table = blk: {
            var shdr: std.elf.Elf64_Shdr = undefined;
            if (format == .@"32") {
                // var shdr32: std.elf.Elf32_Shdr = undefined;
                const offset = header.shoff + @sizeOf(std.elf.Elf32_Shdr) * header.shstrndx;
                try file_reader.seekTo(offset);
                const shdr32 = try file_reader.interface.takeStruct(std.elf.Elf32_Shdr, header.endian);

                shdr = .{
                    .sh_name = shdr32.sh_name,
                    .sh_type = shdr32.sh_type,
                    .sh_flags = shdr32.sh_flags,
                    .sh_addr = shdr32.sh_addr,
                    .sh_offset = shdr32.sh_offset,
                    .sh_size = shdr32.sh_size,
                    .sh_link = shdr32.sh_link,
                    .sh_info = shdr32.sh_info,
                    .sh_addralign = shdr32.sh_addralign,
                    .sh_entsize = shdr32.sh_entsize,
                };
            } else {
                const offset = header.shoff + @sizeOf(std.elf.Elf64_Shdr) * header.shstrndx;
                try file_reader.seekTo(offset);
                shdr = try file_reader.interface.takeStruct(std.elf.Elf64_Shdr, header.endian);
            }

            try file_reader.seekTo(shdr.sh_offset);
            break :blk try file_reader.interface.readAlloc(allocator, shdr.sh_size);
        };
        errdefer allocator.free(string_table);

        var sections: std.StringHashMapUnmanaged(Section) = .empty;
        errdefer sections.deinit(allocator);

        var section_header_it = header.iterateSectionHeaders(file_reader);
        while (try section_header_it.next()) |shdr| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(string_table[shdr.sh_name..])));
            try sections.put(allocator, name, .{
                .address = shdr.sh_addr,
                .size = shdr.sh_size,
                .file_offset = shdr.sh_offset,
            });
        }

        var loaded_regions: std.ArrayList(Segment) = .empty;
        errdefer loaded_regions.deinit(allocator);

        var program_header_iterator = header.iterateProgramHeaders(file_reader);
        while (try program_header_iterator.next()) |phdr| {
            if (phdr.p_type != std.elf.PT_LOAD) continue;
            if (phdr.p_memsz == 0) continue;
            if (phdr.p_filesz > phdr.p_memsz) return error.MalformedElf;

            try loaded_regions.append(allocator, .{
                .physical_address = phdr.p_paddr,
                .virtual_address = phdr.p_vaddr,
                .file_offset = phdr.p_offset,
                .file_size = phdr.p_filesz,
                .memory_size = phdr.p_memsz,
                .flags = .{
                    .read = phdr.p_flags & std.elf.PF_R != 0,
                    .write = phdr.p_flags & std.elf.PF_W != 0,
                    .exec = phdr.p_flags & std.elf.PF_X != 0,
                },
            });
        }

        return .{
            .header = header,
            .format = format,
            .string_table = string_table,
            .sections = sections,
            .load_segments = loaded_regions,
        };
    }

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        self.sections.deinit(allocator);
        self.load_segments.deinit(allocator);
        allocator.free(self.string_table);
    }
};

pub fn get_symbol(reader: *std.fs.File.Reader, info: Info, name: []const u8) !?std.elf.Elf64_Sym {
    const symbol_section = info.sections.get(".symtab") orelse return error.NoSymbolTable;
    try reader.seekTo(symbol_section.file_offset);
    while (reader.pos < symbol_section.file_offset + symbol_section.size) {
        const sym: std.elf.Elf64_Sym = switch (info.format) {
            .@"32" => blk: {
                const sym_32 = try reader.interface.takeStruct(std.elf.Elf32_Sym, info.header.endian);
                break :blk .{
                    .st_name = sym_32.st_name,
                    .st_info = sym_32.st_info,
                    .st_other = sym_32.st_other,
                    .st_shndx = sym_32.st_shndx,
                    .st_value = sym_32.st_value,
                    .st_size = sym_32.st_size,
                };
            },
            .@"64" => try reader.interface.takeStruct(std.elf.Elf64_Sym, info.header.endian),
        };

        const current_name = std.mem.span(@as([*:0]const u8, @ptrCast(info.string_table[sym.st_name..])));
        if (std.mem.eql(u8, name, current_name)) {
            return sym;
        }
    } else return null;
}
