const std = @import("std");

const libusb = @import("libusb.zig");
const Probe = @import("Probe.zig");
const Target = @import("Target.zig");
const arch = @import("arch.zig");
const chip = @import("chip.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.log.err("Usage: zprobe <elf>", .{});
        return error.Usage;
    }

    _ = try libusb.call(libusb.c.libusb_init(null));
    defer libusb.c.libusb_exit(null);

    var probe: Probe = try .create(allocator, .{});
    defer probe.destroy();

    try probe.attach(.mhz(1));
    defer probe.detach();

    var rp2040: chip.RP2040 = try .init(probe);
    defer rp2040.deinit();

    const memory = rp2040.target.memory();

    try rp2040.target.system_reset();

    const elf_path = args[1];
    {
        const elf_file = try std.fs.cwd().openFile(elf_path, .{});
        defer elf_file.close();

        var elf_file_reader_buf: [4096]u8 = undefined;
        var elf_file_reader = elf_file.reader(&elf_file_reader_buf);

        const header = try std.elf.Header.read(&elf_file_reader.interface);

        var ph_iterator = header.iterateProgramHeaders(&elf_file_reader);
        while (try ph_iterator.next()) |ph| {
            if (ph.p_type != std.elf.PT_LOAD) continue;

            try elf_file_reader.seekTo(ph.p_offset);
            const data = try elf_file_reader.interface.readAlloc(allocator, ph.p_filesz);
            defer allocator.free(data);

            try memory.write(ph.p_paddr, data);
        }

        try rp2040.target.write_core_register(.boot, .{ .special = .ip }, @truncate(header.entry));
        try rp2040.target.run(.boot);
    }
}
