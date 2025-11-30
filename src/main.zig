const builtin = @import("builtin");
const std = @import("std");
const zprobe = @import("zprobe");

const cli = @import("main/cli.zig");
const Feedback = @import("main/Feedback.zig");
const signal = @import("main/signal.zig");

pub const std_options: std.Options = .{
    .logFn = Feedback.log_fn,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        else => std.heap.c_allocator,
    };

    if (try cli.parse_args(allocator)) |command| {
        defer command.deinit(allocator);

        const stderr = std.fs.File.stderr();
        var stderr_writer_buf: [128]u8 = undefined;
        var stderr_writer = stderr.writer(&stderr_writer_buf);

        try signal.init();

        var feedback: *Feedback = .init(&stderr_writer.interface, .elegant);
        defer feedback.deinit();

        main_impl(allocator, feedback, command) catch |err| {
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
        .chips => try write_output(&stdout_writer.interface, std.enums.values(cli.ChipTag), args.output_format),
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

pub const AnyChip = union(cli.ChipTag) {
    RP2040: zprobe.chips.RP2040,

    pub fn init(any_chip: *AnyChip, chip_tag: cli.ChipTag, probe: zprobe.Probe) !void {
        switch (chip_tag) {
            inline else => |tag| try @field(any_chip.*, @tagName(tag)).init(probe),
        }
    }

    pub fn deinit(any_chip: *AnyChip) void {
        switch (any_chip.*) {
            inline else => |*chip| chip.deinit(),
        }
    }

    pub fn target(any_chip: *AnyChip) *zprobe.Target {
        return switch (any_chip.*) {
            inline else => |*chip| &chip.target,
        };
    }
};

fn load_impl(allocator: std.mem.Allocator, feedback: *Feedback, args: cli.Command.Load) !void {
    try feedback.update("Connecting to probe");
    var probe: zprobe.Probe = try .create(allocator, .{});
    defer probe.destroy(allocator);

    try probe.attach(args.speed);
    defer probe.detach();

    try feedback.update("Initializing target");
    var chip: AnyChip = undefined;
    try chip.init(args.chip, probe);
    defer chip.deinit();
    const target = chip.target();

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

    zprobe.flash.load_elf(allocator, target, .{
        .elf_info = elf_info,
        .elf_file_reader = &elf_file_reader,
        .run_method = args.run_method,
        .progress = feedback.progress(),
    }) catch |err| switch (err) {
        error.RunMethodRequired => {
            std.log.err("Please specify how you want the image to be ran with the `--run_method` option. Your elf contains segments in both flash and ram.", .{});
            return err;
        },
        else => return err,
    };

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
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
}
