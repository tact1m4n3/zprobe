const builtin = @import("builtin");
const std = @import("std");
const zprobe = @import("zprobe");

const cli = @import("main/cli.zig");
const Feedback = @import("main/Feedback.zig");
const signal = @import("main/signal.zig");

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

    if (try cli.parse_args(allocator)) |command| {
        std.debug.print("{any}", .{command});

        const stderr = std.fs.File.stderr();
        var stderr_writer_buf: [128]u8 = undefined;
        var stderr_writer = stderr.writer(&stderr_writer_buf);

        try signal.init();

        var feedback: Feedback = try .init(&stderr_writer.interface, .elegant);
        defer feedback.deinit();

        main_impl(allocator, &feedback, command) catch |err| {
            feedback.fail();
            return err;
        };
    }
}

fn main_impl(allocator: std.mem.Allocator, feedback: *Feedback, command: cli.Command) !void {
    const stdout = std.fs.File.stdout();
    var stdout_writer_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_writer_buf);

    switch (command) {
        .list => return,
        .chips => {
            try std.zon.stringify.serialize(std.enums.values(zprobe.chip.Tag), .{}, &stdout_writer.interface);
            try stdout_writer.interface.writeByte('\n');
            try stdout_writer.interface.flush();
            return;
        },
        else => {},
    }

    try feedback.update("Connecting to probe");
    var any_probe: zprobe.probe.Any = try .detect_usb(allocator, .{});
    defer any_probe.deinit();

    try any_probe.attach(.mhz(10));
    defer any_probe.detach();

    try feedback.update("Initializing target");
    var rp2040: zprobe.chip.Any = .{ .RP2040 = try .init(any_probe.arm_debug_interface() orelse return error.No_ARM_DebugInterface) };
    defer rp2040.deinit();
    const target = rp2040.target();

    const elf_file_path = switch (command) {
        .list, .chips => unreachable,
        inline else => |cmd| cmd.elf_file,
    };

    try feedback.update("Reading ELF");
    const elf_file = try std.fs.cwd().openFile(elf_file_path, .{});
    defer elf_file.close();

    var elf_file_reader_buf: [4096]u8 = undefined;
    var elf_file_reader = elf_file.reader(&elf_file_reader_buf);
    var elf_info: zprobe.elf.Info = try .init(allocator, &elf_file_reader);
    defer elf_info.deinit(allocator);

    try feedback.update("Running system reset");
    try target.system_reset();

    try feedback.update("Loading firmware");
    try zprobe.flash.load_elf(allocator, target, elf_info, &elf_file_reader, feedback.progress());

    try feedback.update("Resetting");
    try target.reset(.all);

    try feedback.update("Initializing RTT host");
    var rtt_host: zprobe.RTT_Host = try .init(allocator, target, .{
        .progress = feedback.progress(),
    });
    defer rtt_host.deinit(allocator);

    try feedback.end();

    var buf: [1024]u8 = undefined;
    while (!signal.should_exit) {
        const n = try rtt_host.read(target, 0, &buf);
        try stdout_writer.interface.writeAll(buf[0..n]);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}
