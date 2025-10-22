const std = @import("std");
const clap = @import("clap");
const zprobe = @import("zprobe");

pub const Command = union(CommandList) {
    list,
    chips,
    rtt: struct {
        speed: zprobe.probe.ProtocolSpeed,
        chip: zprobe.chip.Tag,
        elf_file: ?[]const u8,
    },
    flash: struct {
        speed: zprobe.probe.ProtocolSpeed,
        chip: zprobe.chip.Tag,
        elf_file: []const u8,
    },
    run: struct {
        speed: zprobe.probe.ProtocolSpeed,
        chip: zprobe.chip.Tag,
        elf_file: []const u8,
    },
};

pub fn parse_args(allocator: std.mem.Allocator) !?Command {
    var args_iter: std.process.ArgIterator = try .initWithAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next();

    const stderr: std.fs.File = .stderr();
    var buf: [1024]u8 = undefined;
    var writer = stderr.writer(&buf);
    defer writer.interface.flush() catch {};

    var main_diag: clap.Diagnostic = .{};
    var main_res = clap.parseEx(clap.Help, &main_params, .{
        .command = clap.parsers.enumeration(CommandList),
    }, &args_iter, .{
        .diagnostic = &main_diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| switch (err) {
        error.NameNotPartOfEnum => {
            try writer.interface.writeAll("Invalid command.\n");
            try print_main_help(&writer.interface);
            return error.InvalidCommand;
        },
        else => {
            try main_diag.report(&writer.interface, err);
            try print_main_help(&writer.interface);
            return err;
        },
    };
    defer main_res.deinit();

    if (main_res.args.help != 0) {
        try print_main_help(&writer.interface);
        return null;
    }

    const command = main_res.positionals[0] orelse {
        try writer.interface.writeAll("Command missing.\n");
        try print_main_help(&writer.interface);
        return error.MissingCommand;
    };

    switch (command) {
        .list => return .list,
        .chips => return .chips,
        .rtt => {
            var flash_diag: clap.Diagnostic = .{};
            var flash_res = clap.parseEx(clap.Help, &params.flash, .{
                .speed = speed_parser,
                .chip = chip_parser,
                .elf_file = clap.parsers.string,
            }, &args_iter, .{
                .diagnostic = &flash_diag,
                .allocator = allocator,
            }) catch |err| switch (err) {
                error.InvalidSpeed => {
                    try writer.interface.writeAll("Invalid protocol speed. Valid examples: 10MHz, 100kHz.\n");
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
                error.InvalidChip => {
                    try writer.interface.writeAll("Invalid chip. We only support these ones:\n");
                    try std.zon.stringify.serialize(std.enums.values(zprobe.chip.Tag), .{}, &writer.interface);
                    try writer.interface.writeByte('\n');
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
                else => {
                    try flash_diag.report(&writer.interface, err);
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
            };
            defer flash_res.deinit();

            if (flash_res.args.help != 0) {
                try print_command_help(&writer.interface, "flash");
                return null;
            }

            const speed: zprobe.probe.ProtocolSpeed = flash_res.args.speed orelse .mhz(10);

            const chip = flash_res.args.chip orelse {
                try writer.interface.writeAll("Missing chip. We only support these ones:\n");
                try std.zon.stringify.serialize(std.enums.values(zprobe.chip.Tag), .{}, &writer.interface);
                try writer.interface.writeByte('\n');
                try print_command_help(&writer.interface, "flash");
                return error.MissingChip;
            };

            const elf_file = flash_res.positionals[0] orelse null;

            return .{ .rtt = .{
                .speed = speed,
                .chip = chip,
                .elf_file = elf_file,
            } };
        },
        .flash => {
            var flash_diag: clap.Diagnostic = .{};
            var flash_res = clap.parseEx(clap.Help, &params.flash, .{
                .speed = speed_parser,
                .chip = chip_parser,
                .elf_file = clap.parsers.string,
            }, &args_iter, .{
                .diagnostic = &flash_diag,
                .allocator = allocator,
            }) catch |err| switch (err) {
                error.InvalidSpeed => {
                    try writer.interface.writeAll("Invalid protocol speed. Valid examples: 10MHz, 100kHz.\n");
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
                error.InvalidChip => {
                    try writer.interface.writeAll("Invalid chip. We only support these ones:\n");
                    try std.zon.stringify.serialize(std.enums.values(zprobe.chip.Tag), .{}, &writer.interface);
                    try writer.interface.writeByte('\n');
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
                else => {
                    try flash_diag.report(&writer.interface, err);
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
            };
            defer flash_res.deinit();

            if (flash_res.args.help != 0) {
                try print_command_help(&writer.interface, "flash");
                return null;
            }

            const speed: zprobe.probe.ProtocolSpeed = flash_res.args.speed orelse .mhz(10);

            const chip = flash_res.args.chip orelse {
                try writer.interface.writeAll("Missing chip. We only support these ones:\n");
                try std.zon.stringify.serialize(std.enums.values(zprobe.chip.Tag), .{}, &writer.interface);
                try writer.interface.writeByte('\n');
                try print_command_help(&writer.interface, "flash");
                return error.MissingChip;
            };

            const elf_file = flash_res.positionals[0] orelse {
                try writer.interface.writeAll("Missing ELF.\n");
                try print_command_help(&writer.interface, "flash");
                return error.Missing_ELF;
            };

            return .{ .flash = .{
                .speed = speed,
                .chip = chip,
                .elf_file = elf_file,
            } };
        },
        .run => {
            var flash_diag: clap.Diagnostic = .{};
            var flash_res = clap.parseEx(clap.Help, &params.flash, .{
                .speed = speed_parser,
                .chip = chip_parser,
                .elf_file = clap.parsers.string,
            }, &args_iter, .{
                .diagnostic = &flash_diag,
                .allocator = allocator,
            }) catch |err| switch (err) {
                error.InvalidSpeed => {
                    try writer.interface.writeAll("Invalid protocol speed. Valid examples: 10MHz, 100kHz.\n");
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
                error.InvalidChip => {
                    try writer.interface.writeAll("Invalid chip. We only support these ones:\n");
                    try std.zon.stringify.serialize(std.enums.values(zprobe.chip.Tag), .{}, &writer.interface);
                    try writer.interface.writeByte('\n');
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
                else => {
                    try flash_diag.report(&writer.interface, err);
                    try print_command_help(&writer.interface, "flash");
                    return err;
                },
            };
            defer flash_res.deinit();

            if (flash_res.args.help != 0) {
                try print_command_help(&writer.interface, "flash");
                return null;
            }

            const speed: zprobe.probe.ProtocolSpeed = flash_res.args.speed orelse .mhz(10);

            const chip = flash_res.args.chip orelse {
                try writer.interface.writeAll("Missing chip. We only support these ones:\n");
                try std.zon.stringify.serialize(std.enums.values(zprobe.chip.Tag), .{}, &writer.interface);
                try writer.interface.writeByte('\n');
                try print_command_help(&writer.interface, "flash");
                return error.MissingChip;
            };

            const elf_file = flash_res.positionals[0] orelse {
                try writer.interface.writeAll("Missing ELF.\n");
                try print_command_help(&writer.interface, "flash");
                return error.Missing_ELF;
            };

            return .{ .run = .{
                .speed = speed,
                .chip = chip,
                .elf_file = elf_file,
            } };
        },
    }
}

pub const CommandList = enum {
    list,
    chips,
    rtt,
    flash,
    run,
};

const command_descriptions = struct {
    pub const list = "List connected probes.";
    pub const chips = "List all supported chips.";
    pub const flash = "Load an ELF onto the target.";
    pub const rtt = "Print RTT logs.";
    pub const run = "Load an ELF onto the target, execute it and print RTT logs.";
};

const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);

const params = struct {
    const flash = clap.parseParamsComptime(
        \\-h, --help         Display this help and exit.
        \\--speed <speed>    Set the protocol speed for the probe. Must be suffixed by kHz or MHz. Defaults to 10MHz.
        \\--chip <chip>      Set the chip.
        \\<elf_file>
        \\
    );
};

const help_options: clap.HelpOptions = .{
    .indent = 4,
    .description_on_new_line = false,
    .description_indent = 0,
    .spacing_between_parameters = 0,
};

fn print_main_help(writer: *std.Io.Writer) !void {
    try writer.writeAll("Usage: zprobe ");
    try clap.usage(writer, clap.Help, &main_params);
    try writer.writeByte('\n');
    try clap.help(writer, clap.Help, &main_params, help_options);
    try writer.writeByte('\n');
    try print_commands(writer);
    try writer.writeByte('\n');
}

fn print_command_help(writer: *std.Io.Writer, comptime command_name: []const u8) !void {
    try writer.writeAll("Usage: zprobe " ++ command_name ++ " ");
    try clap.usage(writer, clap.Help, &@field(params, command_name));
    try writer.writeByte('\n');
    try clap.help(writer, clap.Help, &@field(params, command_name), help_options);
    try writer.writeByte('\n');
}

fn print_commands(writer: *std.Io.Writer) !void {
    const command_list = comptime blk: {
        var tmp: []const u8 = &.{};
        var max_len: usize = 0;
        for (@typeInfo(CommandList).@"enum".fields) |field| {
            max_len = @max(max_len, field.name.len);
        }
        for (@typeInfo(CommandList).@"enum".fields) |field| {
            tmp = tmp ++ [1]u8{' '} ** 4 ++ field.name;
            if (@hasDecl(command_descriptions, field.name)) {
                tmp = tmp ++ [1]u8{' '} ** (max_len - field.name.len + 4) ++ @field(command_descriptions, field.name);
            }
            tmp = tmp ++ "\n";
        }
        break :blk tmp;
    };
    try writer.writeAll("Command list:\n" ++ command_list);
}

fn speed_parser(value: []const u8) error{InvalidSpeed}!zprobe.probe.ProtocolSpeed {
    if (std.mem.endsWith(u8, value, "kHz")) {
        return .khz(std.fmt.parseInt(u32, value[0 .. value.len - 3], 10) catch return error.InvalidSpeed);
    } else if (std.mem.endsWith(u8, value, "MHz")) {
        return .mhz(std.fmt.parseInt(u32, value[0 .. value.len - 3], 10) catch return error.InvalidSpeed);
    } else {
        return error.InvalidSpeed;
    }
}

fn chip_parser(value: []const u8) error{InvalidChip}!zprobe.chip.Tag {
    return std.meta.stringToEnum(zprobe.chip.Tag, value) orelse return error.InvalidChip;
}
