const builtin = @import("builtin");
const std = @import("std");
const zprobe = @import("zprobe");

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        else => std.heap.c_allocator,
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.log.err("Usage: zprobe <elf>", .{});
        return error.Usage;
    }

    const stdout = std.fs.File.stdout();
    var stdout_writer_buf: [128]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_writer_buf);

    const elf_path = args[1];
    const elf_file = try std.fs.cwd().openFile(elf_path, .{});
    defer elf_file.close();

    var elf_file_reader_buf: [4096]u8 = undefined;
    var elf_file_reader = elf_file.reader(&elf_file_reader_buf);
    var elf_info: zprobe.elf.Info = try .init(allocator, &elf_file_reader);
    defer elf_info.deinit(allocator);

    var progress: zprobe.Progress = try .init(&stdout_writer.interface, .elegant);
    defer progress.deinit();

    try progress.begin("Connecting to probe");
    var probe = zprobe.Probe.create(allocator, .{}) catch |err| {
        switch (err) {
            error.NoProbeFound => progress.fail(),
            else => progress.fail(),
        }
        return err;
    };
    defer probe.destroy();
    probe.attach(.mhz(1)) catch |err| {
        progress.fail();
        return err;
    };
    defer probe.detach();
    try progress.end(.success);

    try progress.begin("Initializing and resetting target");
    var rp2040 = zprobe.targets.RP2040.init(probe) catch |err| {
        progress.fail();
        return err;
    };
    defer rp2040.deinit();
    rp2040.target.system_reset() catch |err| {
        progress.fail();
        return err;
    };
    try progress.end(.success);

    try progress.begin("Flashing");
    zprobe.flash.load_elf(allocator, &rp2040.target, elf_info, &elf_file_reader, &progress) catch |err| {
        progress.fail();
        return err;
    };
    try progress.end(.success);

    try rp2040.target.reset(.all);

    try progress.begin("Starting RTT host");
    var rtt_host = zprobe.RTT_Host.init(allocator, &rp2040.target, .{
        .elf_file_reader = &elf_file_reader,
        .elf_info = elf_info,
    }, null) catch |err| {
        progress.fail();
        return err;
    };
    defer rtt_host.deinit(allocator);
    try progress.end(.success);

    try progress.stop();

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try rtt_host.read(&rp2040.target, 0, &buf);
        try stdout.writeAll(buf[0..n]);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}
