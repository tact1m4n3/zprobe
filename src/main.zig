const builtin = @import("builtin");
const std = @import("std");
const zprobe = @import("zprobe");

const Feedback = @import("main/Feedback.zig");
const signal = @import("main/signal.zig");

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !u8 {
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

    const stderr = std.fs.File.stderr();
    var stderr_writer_buf: [128]u8 = undefined;
    var stderr_writer = stderr.writer(&stderr_writer_buf);

    try signal.init();

    var feedback: Feedback = try .init(&stderr_writer.interface, .elegant);
    defer feedback.deinit();

    // TODO: proper args parsing
    main_impl(allocator, &feedback, .{
        .elf_path = args[1],
    }) catch |err| {
        feedback.fail(err);
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return 1;
    };

    return 0;
}

pub const Args = struct {
    elf_path: []const u8,
};

fn main_impl(
    allocator: std.mem.Allocator,
    feedback: *Feedback,
    args: Args,
) !void {
    try feedback.update("Reading ELF");
    const elf_file = try std.fs.cwd().openFile(args.elf_path, .{});
    defer elf_file.close();

    var elf_file_reader_buf: [4096]u8 = undefined;
    var elf_file_reader = elf_file.reader(&elf_file_reader_buf);
    var elf_info: zprobe.elf.Info = try .init(allocator, &elf_file_reader);
    defer elf_info.deinit(allocator);

    try feedback.update("Connecting to probe");
    var probe: zprobe.Probe = try .create(allocator, .{});
    defer probe.destroy();

    try probe.attach(.mhz(1));
    defer probe.detach();

    try feedback.update("Initializing target");
    var rp2040: zprobe.targets.RP2040 = try .init(probe);
    defer rp2040.deinit();

    try feedback.update("Running system reset");
    try rp2040.target.system_reset();

    try feedback.update("Loading firmware");
    try zprobe.flash.load_elf(allocator, &rp2040.target, elf_info, &elf_file_reader, feedback.progress());

    try feedback.update("Resetting");
    try rp2040.target.reset(.all);

    try feedback.update("Initializing RTT host");
    var rtt_host: zprobe.RTT_Host = try .init(allocator, &rp2040.target, .{
        .progress = feedback.progress(),
    });
    defer rtt_host.deinit(allocator);

    try feedback.end();

    const stdout = std.fs.File.stdout();
    var stdout_writer = stdout.writer(&.{});

    var buf: [1024]u8 = undefined;
    while (!signal.should_exit) {
        const n = try rtt_host.read(&rp2040.target, 0, &buf);
        try stdout_writer.interface.writeAll(buf[0..n]);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}
