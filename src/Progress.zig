const builtin = @import("builtin");
const std = @import("std");

const Progress = @This();

writer: *std.Io.Writer,
config: Config,
thread: ?std.Thread = null,
thread_should_exit: bool = false,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
task: ?Task = null,
symbol_index: usize = 0,

pub const Config = struct {
    pub const basic: Config = .{
        .error_symbol = 'E',
        .spinner_symbols = &.{ '|', '/', '-', '\\' },
        .bar_start_symbol = '|',
        .bar_fill_symbols = &.{ '#' },
        .bar_end_symbol = '|',
    };

    pub const elegant: Config = .{
        .success_color = .green,
        .error_color = .red,
        .spinner_color = .blue,

        .success_symbol = '✓',
        .error_symbol = '⨯',
        .spinner_symbols = &.{ '⣾', '⣷', '⣯', '⣟', '⡿', '⢿', '⣻', '⣽' },
        .bar_fill_symbols = &.{ '▏', '▎', '▍', '▌', '▋', '▊', '▊', '█' },
        .bar_end_symbol = '▏',
    };

    success_color: ?ansi_term.Color = null,
    error_color: ?ansi_term.Color = null,
    spinner_color: ?ansi_term.Color = null,
    bar_color: ?ansi_term.Color = null,

    success_symbol: ?u21 = null,
    error_symbol: u21,
    spinner_symbols: []const u21,
    bar_start_symbol: ?u21 = null,
    bar_fill_symbols: []const u21,
    bar_empty_symbol: ?u21 = null,
    bar_end_symbol: u21,
};

const Task = struct {
    text: []const u8,
    total_steps: usize = 0,
    completed_steps: usize = 0,
};

pub fn init(writer: *std.Io.Writer, config: Config) !Progress {
    try ansi_term.hide_cursor(writer);
    return .{
        .writer = writer,
        .config = config,
    };
}

pub fn deinit(progress: *Progress) void {
    progress.stop() catch {};
}

pub fn stop(progress: *Progress) !void {
    if (progress.thread) |thread| {
        {
            progress.mutex.lock();
            defer progress.mutex.unlock();
            progress.thread_should_exit = true;
        }
        progress.cond.signal();
        thread.join();
        progress.thread = null;
    }
    try ansi_term.show_cursor(progress.writer);
    try progress.writer.flush();
}

pub fn begin(progress: *Progress, text: []const u8) !void {
    std.debug.assert(progress.task == null);

    if (progress.thread == null) {
        progress.thread = try .spawn(.{
            .stack_size = 16 * 1024,
        }, update_thread, .{progress});
    }

    {
        progress.mutex.lock();
        defer progress.mutex.unlock();

        const task: Task = .{ .text = text };
        try render(progress, task);
        progress.task = task;
    }

    progress.cond.signal();
}

pub fn update(progress: *Progress, completed_steps: usize, total_steps: usize) !void {
    progress.mutex.lock();
    defer progress.mutex.unlock();

    if (progress.task) |*task| {
        task.completed_steps = completed_steps;
        task.total_steps = total_steps;
        try render(progress, task.*);
    } else {
        return error.NoTaskStarted;
    }
}

pub const FinishStatus = enum {
    success,
    fail,
};

pub fn end(progress: *Progress, status: FinishStatus) !void {
    progress.mutex.lock();
    defer progress.mutex.unlock();

    const task = progress.task orelse return error.NoTaskStarted;
    progress.task = null;

    try ansi_term.clear_line(progress.writer);
    try ansi_term.set_cursor_column(progress.writer, 0);
    try progress.writer.print("{s} ", .{task.text});
    switch (status) {
        .success => if (progress.config.success_symbol) |success_symbol|
            try write_symbol(progress.writer, success_symbol, 1, progress.config.success_color),
        .fail => try write_symbol(progress.writer, progress.config.error_symbol, 1, progress.config.error_color),
    }
    try progress.writer.writeByte('\n');
    try progress.writer.flush();
}

pub fn fail(progress: *Progress) void {
    progress.end(.fail) catch {};
}

fn render(progress: *Progress, task: Task) !void {
    try ansi_term.clear_line(progress.writer);
    try ansi_term.set_cursor_column(progress.writer, 0);
    try write_symbol(progress.writer, progress.config.spinner_symbols[progress.symbol_index], 1, progress.config.spinner_color);
    try progress.writer.print(" {s}", .{task.text});

    if (task.total_steps != 0) {
        const bar_width = 40;
        const fill_symbols_count = progress.config.bar_fill_symbols.len;
        const fill_width: f32 = @as(f32, @floatFromInt(task.completed_steps)) / @as(f32, @floatFromInt(task.total_steps)) * bar_width;

        try progress.writer.writeByte(' ');

        const full_blocks: u32 = @intFromFloat(fill_width);
        const last_block_kind: u32 = @intFromFloat((fill_width - @floor(fill_width)) * @as(f32, @floatFromInt(fill_symbols_count)));

        if (progress.config.bar_start_symbol) |start_symbol|
            try write_symbol(progress.writer, start_symbol, 1, progress.config.bar_color);
        try write_symbol(progress.writer, progress.config.bar_fill_symbols[fill_symbols_count - 1], 1, progress.config.bar_color);
        try write_symbol(progress.writer, progress.config.bar_fill_symbols[fill_symbols_count - 1], full_blocks, progress.config.bar_color);
        if (full_blocks < bar_width) {
            try write_symbol(progress.writer, progress.config.bar_fill_symbols[last_block_kind], 1, progress.config.bar_color);
            try write_symbol(progress.writer, progress.config.bar_empty_symbol orelse ' ', bar_width - full_blocks - 1, progress.config.bar_color);
            try write_symbol(progress.writer, progress.config.bar_end_symbol, 1, progress.config.bar_color);
        }

        try progress.writer.print(" [{}/{}]", .{ task.completed_steps, task.total_steps });
    }

    try progress.writer.flush();
}

fn update_thread(progress: *Progress) void {
    const increment_interval = std.time.ns_per_s / progress.config.spinner_symbols.len;

    wait_for_task: while (true) {
        {
            progress.mutex.lock();
            defer progress.mutex.unlock();

            while (!progress.thread_should_exit and progress.task == null) {
                progress.cond.wait(&progress.mutex);
            }
        }

        if (progress.thread_should_exit) return;

        var timer = std.time.Timer.start() catch unreachable;
        while (true) {
            while (true) {
                if (timer.read() > increment_interval) {
                    break;
                }
                std.Thread.sleep(increment_interval - timer.read());
            }

            timer.reset();

            progress.mutex.lock();
            defer progress.mutex.unlock();

            if (progress.task) |*task| {
                render(progress, task.*) catch {};
                progress.symbol_index += 1;
                progress.symbol_index %= progress.config.spinner_symbols.len;
            } else {
                continue :wait_for_task;
            }

            std.atomic.spinLoopHint();
        }
    }
}

fn write_symbol(writer: *std.Io.Writer, symbol: u21, repeat: usize, maybe_color: ?ansi_term.Color) !void {
    if (repeat == 0) return;
    var buf: [8]u8 = undefined;
    const count = try std.unicode.utf8Encode(symbol, &buf);
    if (maybe_color) |color| try ansi_term.write_color(writer, color);
    if (repeat > 1) {
        try writer.splatBytesAll(buf[0..count], repeat);
    } else {
        try writer.writeAll(buf[0..count]);
    }
    if (maybe_color != null) try ansi_term.reset_color(writer);
}

pub const ansi_term = struct {
    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub const Color = union(enum) {
        default,
        black,
        white,
        red,
        green,
        blue,
        yellow,
        magenta,
        cyan,
        fixed: u8,
        grey: u8,
        rgb: RGB,
    };

    const esc = "\x1B";
    const csi = esc ++ "[";
    const reset = csi ++ "0m";

    pub fn clear_line(writer: *std.Io.Writer) !void {
        try writer.writeAll(csi ++ "2K");
    }

    pub fn hide_cursor(writer: *std.Io.Writer) !void {
        try writer.writeAll(csi ++ "?25l");
    }

    pub fn show_cursor(writer: *std.Io.Writer) !void {
        try writer.writeAll(csi ++ "?25h");
    }

    pub fn set_cursor_column(writer: *std.Io.Writer, column: usize) !void {
        try writer.print(csi ++ "{d}G", .{column});
    }

    pub fn cursor_forward(writer: *std.Io.Writer, columns: usize) !void {
        try writer.print(csi ++ "{d}C", .{columns});
    }

    pub fn write_color(writer: *std.Io.Writer, color: Color) !void {
        try writer.writeAll(csi);
        _ = switch (color) {
            .default => try writer.writeAll("39"),
            .black => try writer.writeAll("30"),
            .red => try writer.writeAll("31"),
            .green => try writer.writeAll("32"),
            .yellow => try writer.writeAll("33"),
            .blue => try writer.writeAll("34"),
            .magenta => try writer.writeAll("35"),
            .cyan => try writer.writeAll("36"),
            .white => try writer.writeAll("37"),
            .fixed => |fixed| try writer.print("48;5;{}", .{fixed}),
            .grey => |grey| try writer.print("48;2;{};{};{}", .{ grey, grey, grey }),
            .rgb => |rgb| try writer.print("38;2;{};{};{}", .{ rgb.r, rgb.g, rgb.b }),
        };
        try writer.writeAll("m");
    }

    pub fn reset_color(writer: *std.Io.Writer) !void {
        try writer.writeAll(reset);
    }
};

/// Terminal size dimensions
pub const TermSize = struct {
    /// Terminal width as measured number of characters that fit into a terminal horizontally
    width: u16,
    /// terminal height as measured number of characters that fit into terminal vertically
    height: u16,
};

pub fn term_size(file: std.fs.File) !?TermSize {
    if (!file.supportsAnsiEscapeCodes()) {
        return null;
    }
    return switch (builtin.os.tag) {
        .windows => blk: {
            var buf: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            break :blk switch (std.os.windows.kernel32.GetConsoleScreenBufferInfo(
                file.handle,
                &buf,
            )) {
                std.os.windows.TRUE => .{
                    .width = @intCast(buf.srWindow.Right - buf.srWindow.Left + 1),
                    .height = @intCast(buf.srWindow.Bottom - buf.srWindow.Top + 1),
                },
                else => error.Unexpected,
            };
        },
        .linux, .macos => blk: {
            var buf: std.posix.winsize = undefined;
            break :blk switch (std.posix.errno(
                std.posix.system.ioctl(
                    file.handle,
                    std.posix.T.IOCGWINSZ,
                    @intFromPtr(&buf),
                ),
            )) {
                .SUCCESS => TermSize{
                    .width = buf.col,
                    .height = buf.row,
                },
                else => error.IoctlError,
            };
        },
        else => error.Unsupported,
    };
}
