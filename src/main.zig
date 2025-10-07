const std = @import("std");

const libusb = @import("libusb.zig");
const Probe = @import("Probe.zig");
const Target = @import("Target.zig");
const arch = @import("arch.zig");
const targets = @import("targets.zig");
const flash = @import("flash.zig");
const RTT_Host = @import("RTT_Host.zig");

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

    var rp2040: targets.RP2040 = try .init(probe);
    defer rp2040.deinit();

    try rp2040.target.system_reset();

    // const elf_path = args[1];
    // {
    //     const elf_file = try std.fs.cwd().openFile(elf_path, .{});
    //     defer elf_file.close();
    //
    //     var elf_file_reader_buf: [4096]u8 = undefined;
    //     var elf_file_reader = elf_file.reader(&elf_file_reader_buf);
    //
    //     var loader: flash.Loader(flash.StubFlasher) = .{ .flasher = try .init(&rp2040.target) };
    //     defer loader.deinit(allocator);
    //     try loader.add_elf(allocator, &elf_file_reader, rp2040.target.memory_map);
    //     try loader.load(allocator, null);
    // }

    try rp2040.target.reset(.all);

    const rtt_host: RTT_Host = try .init(&rp2040.target);
    std.log.debug("found rtt at 0x{x}", .{rtt_host.control_block_address});

    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        try rp2040.target.halt(.boot);
        std.log.debug("ip: {x}", .{try rp2040.target.read_register(.boot, .instruction_pointer)});
        try rp2040.target.run(.boot);
    }
}
