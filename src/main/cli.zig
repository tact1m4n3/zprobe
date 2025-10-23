const std = @import("std");
const clap = @import("clap");
const zprobe = @import("zprobe");

// TODO: if we have other root level args we should make an `Args` struct for
// that also contains `Command`
pub const Command = union(CommandList) {
    list: List,
    load: Load,

    pub const List = struct {
        request: Request,
        output_format: OutputFormat,

        pub const Request = enum {
            probes,
            chips,
        };

        pub const OutputFormat = enum {
            json,
            zon,
            text,
        };
    };

    pub const Load = struct {
        elf_file: []const u8,
        speed: zprobe.probe.Speed,
        chip: zprobe.chip.Tag,
        run_method: ?zprobe.flash.RunMethod,
        rtt: bool,
    };
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
    var main_res = clap.parseEx(clap.Help, &params.root, .{
        .COMMAND = clap.parsers.enumeration(CommandList),
    }, &args_iter, .{
        .diagnostic = &main_diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| switch (err) {
        error.NameNotPartOfEnum => {
            try writer.interface.writeAll("Invalid command.\n");
            try print_root_help(&writer.interface);
            return error.InvalidCommand;
        },
        else => {
            try main_diag.report(&writer.interface, err);
            try print_root_help(&writer.interface);
            return err;
        },
    };
    defer main_res.deinit();

    if (main_res.args.help != 0) {
        try print_root_help(&writer.interface);
        return null;
    }

    const command = main_res.positionals[0] orelse {
        try writer.interface.writeAll("Command missing.\n");
        try print_root_help(&writer.interface);
        return error.MissingCommand;
    };

    switch (command) {
        .list => {
            var list_diag: clap.Diagnostic = .{};
            var list_res = clap.parseEx(clap.Help, &params.list, .{
                .REQUEST = enumeration_parser(Command.List.Request, error{InvalidRequest}, error.InvalidRequest),
                .FORMAT = enumeration_parser(Command.List.OutputFormat, error{InvalidFormat}, error.InvalidFormat),
            }, &args_iter, .{
                .diagnostic = &list_diag,
                .allocator = allocator,
            }) catch |err| {
                switch (err) {
                    error.InvalidRequest => try writer.interface.writeAll("You haven't asked for anything to list.\n"),
                    error.InvalidFormat => try writer.interface.writeAll("Invalid output format.\n"),
                    else => try list_diag.report(&writer.interface, err),
                }
                try print_command_help(&writer.interface, "list");
                return err;
            };
            defer list_res.deinit();

            const request = list_res.positionals[0] orelse {
                try writer.interface.writeAll("Missing what to list.\n");
                try print_command_help(&writer.interface, "load");
                return error.MissingChip;
            };

            const output_format = list_res.args.format orelse .text;

            return .{ .list = .{
                .request = request,
                .output_format = output_format,
            } };
        },
        .load => {
            var load_diag: clap.Diagnostic = .{};
            var load_res = clap.parseEx(clap.Help, &params.load, .{
                .SPEED = speed_parser,
                .CHIP = enumeration_parser(zprobe.chip.Tag, error{InvalidChip}, error.InvalidChip),
                .RUN = enumeration_parser(zprobe.flash.RunMethod, error{InvalidRunMethod}, error.InvalidRunMethod),
                .ELF_FILE = clap.parsers.string,
            }, &args_iter, .{
                .diagnostic = &load_diag,
                .allocator = allocator,
            }) catch |err| {
                switch (err) {
                    error.InvalidSpeed => try writer.interface.writeAll("Invalid protocol speed. Valid examples: 10MHz, 100kHz.\n"),
                    error.InvalidChip => try writer.interface.writeAll("Invalid chip. Run `zprobe list chips` for a list of all supported chips.\n"),
                    error.InvalidRunMethod => try writer.interface.writeAll("Invalid run method.\n"),
                    else => try load_diag.report(&writer.interface, err),
                }
                try print_command_help(&writer.interface, "load");
                return err;
            };
            defer load_res.deinit();

            if (load_res.args.help != 0) {
                try print_command_help(&writer.interface, "load");
                return null;
            }

            const elf_file = load_res.positionals[0] orelse {
                try writer.interface.writeAll("No ELF specified.\n");
                try print_command_help(&writer.interface, "load");
                return error.Missing_ELF;
            };

            const speed: zprobe.probe.Speed = load_res.args.speed orelse .mhz(10);

            const chip = load_res.args.chip orelse {
                try writer.interface.writeAll("No chip specified. Use the `--chip <CHIP>` option to choose one. " ++
                    "Run `zprobe list chips` for a list of all supported chips.\n");
                try print_command_help(&writer.interface, "load");
                return error.MissingChip;
            };

            const run_method = load_res.args.@"run-method" orelse null;

            return .{ .load = .{
                .speed = speed,
                .chip = chip,
                .run_method = run_method,
                .rtt = load_res.args.rtt != 0,
                .elf_file = elf_file,
            } };
        },
    }
}

pub const CommandList = enum {
    list,
    load,
};

const command_descriptions = struct {
    pub const list = "List stuff like connected probes or supported chips.";
    pub const load = "Load an ELF onto the target, maybe execute it and maybe print RTT logs.";
};

const params = struct {
    const root = clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<COMMAND>
        \\
    );

    const list = clap.parseParamsComptime(
        \\-h, --help         Display this help and exit.
        \\--format <FORMAT>  What format to use for the output.
        \\<REQUEST>          What do you want to list? Valid options: `probes`, `chips`.
        \\
    );

    const load = clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\--speed <SPEED>     Set the protocol speed for the probe. Must be suffixed by kHz or MHz. Defaults to 10MHz.
        \\--chip <CHIP>       Set the chip of your target.
        \\--run-method <RUN>  How should this image be ran? Valid options: `call_entry`, `reboot`.
        \\--rtt               Print RTT logs after loading the image.
        \\<ELF_FILE>
        \\
    );
};

const help_options: clap.HelpOptions = .{
    .indent = 4,
    .description_on_new_line = false,
    .description_indent = 0,
    .spacing_between_parameters = 0,
};

fn print_root_help(writer: *std.Io.Writer) !void {
    try writer.writeAll("Usage: zprobe ");
    try clap.usage(writer, clap.Help, &params.root);
    try writer.writeByte('\n');
    try clap.help(writer, clap.Help, &params.root, help_options);
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

fn enumeration_parser(comptime T: type, comptime E: type, err: E) fn ([]const u8) E!T {
    return struct {
        fn parse(in: []const u8) E!T {
            return std.meta.stringToEnum(T, in) orelse err;
        }
    }.parse;
}

fn speed_parser(value: []const u8) error{InvalidSpeed}!zprobe.probe.Speed {
    if (std.mem.endsWith(u8, value, "kHz")) {
        return .khz(std.fmt.parseInt(u32, value[0 .. value.len - 3], 10) catch return error.InvalidSpeed);
    } else if (std.mem.endsWith(u8, value, "MHz")) {
        return .mhz(std.fmt.parseInt(u32, value[0 .. value.len - 3], 10) catch return error.InvalidSpeed);
    } else {
        return error.InvalidSpeed;
    }
}
