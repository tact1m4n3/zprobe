const std = @import("std");
const zprobe = @import("zprobe");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.log.err("Usage: rp2040_example <elf>", .{});
        return error.Usage;
    }

    const elf_path = args[1];
    const elf_file = try std.fs.cwd().openFile(elf_path, .{});
    defer elf_file.close();

    var elf_file_reader_buf: [4096]u8 = undefined;
    var elf_file_reader = elf_file.reader(&elf_file_reader_buf);
    var elf_info: zprobe.elf.Info = try .init(allocator, &elf_file_reader);
    defer elf_info.deinit(allocator);

    _ = try zprobe.libusb.call(zprobe.libusb.c.libusb_init(null));
    defer zprobe.libusb.c.libusb_exit(null);

    var probe: zprobe.Probe = try .create(allocator, .{});
    defer probe.destroy();

    try probe.attach(.mhz(1));
    defer probe.detach();

    var rp2040: zprobe.targets.RP2040 = try .init(probe);
    defer rp2040.deinit();

    try rp2040.target.system_reset();

    {
        var loader: zprobe.flash.Loader(zprobe.flash.StubFlasher) = .{ .flasher = try .init(&rp2040.target) };
        defer loader.deinit(allocator);
        try loader.add_elf(allocator, &elf_file_reader, elf_info, rp2040.target.memory_map);
        try loader.load(allocator, null);
    }

    try rp2040.target.reset(.all);

    var rtt_host: zprobe.RTT_Host = try .init(allocator, &rp2040.target, .{
        .elf_file_reader = &elf_file_reader,
        .elf_info = elf_info,
    }, null);
    defer rtt_host.deinit(allocator);
    std.log.debug("found rtt at 0x{x}", .{rtt_host.control_block_address});

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try rtt_host.read(&rp2040.target, 0, &buf);
        std.debug.print("{s}", .{buf[0..n]});
    }
}
