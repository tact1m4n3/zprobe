const std = @import("std");

const libusb = @import("libusb.zig");
const Probe = @import("Probe.zig");
const arch = @import("arch.zig");
const cpu = @import("cpu.zig");
const ARM_DebugInterface = @import("arch/ARM_DebugInterface.zig");
const chip = @import("chip.zig");

const DP_CORE0: ARM_DebugInterface.DP_Address = .{ .multidrop = 0x01002927 };
const AP_CORE0: ARM_DebugInterface.AP_Address = .{
    .dp = DP_CORE0,
    .address = .{ .v1 = 0 },
};

const DP_CORE1: ARM_DebugInterface.DP_Address = .{ .multidrop = 0x11002927 };
const AP_CORE1: ARM_DebugInterface.AP_Address = .{
    .dp = DP_CORE1,
    .address = .{ .v1 = 0 },
};
const RESCUE_DP: ARM_DebugInterface.DP_Address = .{ .multidrop = 0xf1002927 };

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

    var rp2040: chip.RP2040 = try .init(allocator, probe);
    defer rp2040.deinit();

    try rp2040.system_reset();

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

            try rp2040.core0.memory.write(ph.p_paddr, data);
        }

        try rp2040.core0.write_cpu_register(.debug_return_address, @truncate(header.entry));
        try rp2040.core0.run();
    }
}
