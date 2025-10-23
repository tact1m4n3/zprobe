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
    switch (command) {
        .list => |args| try list_impl(args),
        .load => |args| try load_impl(allocator, feedback, args),
    }
}

fn list_impl(args: cli.Command.List) !void {
    const stdout = std.fs.File.stdout();
    var stdout_writer_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_writer_buf);

    switch (args.request) {
        .probes => @panic("TODO"),
        .chips => try write_output(&stdout_writer.interface, std.enums.values(zprobe.chip.Tag), args.output_format),
    }

    try stdout_writer.interface.flush();
}

fn write_output(writer: *std.Io.Writer, data: anytype, output_format: cli.Command.List.OutputFormat) !void {
    switch (output_format) {
        .text => try serialize_text(writer, data),
        .json => try writer.print("{f}\n", .{std.json.fmt(data, .{ .whitespace = .indent_4 })}),
        .zon => {
            try std.zon.stringify.serialize(data, .{}, writer);
            try writer.writeByte('\n');
        },
    }
}

// TODO: implement more data types
fn serialize_text(writer: *std.Io.Writer, data: anytype) !void {
    const type_info = @typeInfo(@TypeOf(data));
    switch (type_info) {
        .void => try writer.writeAll("void\n"),
        .enum_literal => |_| try writer.print("{t}\n", .{data}),
        .@"enum" => |_| try writer.print("{t}\n", .{data}),
        .pointer => |ptr| {
            switch (ptr.size) {
                .one => try serialize_text(writer, data.*),
                .slice => for (data) |item|
                    try serialize_text(writer, item),
                else => return error.Unsupported,
            }
        },
        else => return error.Unsupported,
    }
}

fn load_impl(allocator: std.mem.Allocator, feedback: *Feedback, args: cli.Command.Load) !void {
    try feedback.update("Connecting to probe");
    var any_probe: zprobe.probe.Any = try .detect_usb(allocator, .{});
    defer any_probe.deinit();

    try any_probe.attach(args.speed);
    defer any_probe.detach();

    try feedback.update("Initializing target");
    var rp2040: zprobe.chip.Any = switch (args.chip) {
        // Chips that take in arm debug interface
        inline .RP2040 => |tag| @unionInit(
            zprobe.chip.Any,
            @tagName(tag),
            try .init(any_probe.arm_debug_interface() orelse return error.No_ARM_DebugInterface),
        ),
    };
    defer rp2040.deinit();
    const target = rp2040.target();

    try feedback.update("Reading ELF");
    const elf_file = try std.fs.cwd().openFile(args.elf_file, .{});
    defer elf_file.close();

    var elf_file_reader_buf: [4096]u8 = undefined;
    var elf_file_reader = elf_file.reader(&elf_file_reader_buf);
    var elf_info: zprobe.elf.Info = try .init(allocator, &elf_file_reader);
    defer elf_info.deinit(allocator);

    try feedback.update("Running system reset");
    try target.system_reset();

    try feedback.update("Loading image");

    if (is_ram_image(target, elf_info)) {
        try zprobe.flash.run_ram_image(allocator, target, elf_info, &elf_file_reader, feedback.progress());
    } else {
        try zprobe.flash.load_elf(allocator, target, elf_info, &elf_file_reader, feedback.progress());
        try target.reset(.all);
    }

    if (args.rtt) {
        try feedback.update("Initializing RTT host");
        var rtt_host: zprobe.RTT_Host = try .init(allocator, target, .{
            .progress = feedback.progress(),
            .location_hint = .{ .with_elf = .{
                .elf_info = elf_info,
                .elf_file_reader = &elf_file_reader,
                .method = .auto,
            } },
        });
        defer rtt_host.deinit(allocator);

        try feedback.end();

        const stdout: std.fs.File = .stdout();
        var writer = stdout.writer(&.{});
        var buf: [1024]u8 = undefined;
        while (!signal.should_exit) {
            const n = try rtt_host.read(target, 0, &buf);
            try writer.interface.writeAll(buf[0..n]);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
}

fn is_ram_image(target: *zprobe.Target, elf_info: zprobe.elf.Info) bool {
    for (elf_info.load_segments.items) |segment| {
        if (target.find_memory_region_kind(segment.physical_address, segment.memory_size) != .ram)
            return false;
    } else return true;
}
