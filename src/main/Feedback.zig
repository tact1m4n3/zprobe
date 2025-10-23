const builtin = @import("builtin");
const std = @import("std");
const zprobe = @import("zprobe");

const Progress = zprobe.Progress;
const signal = @import("signal.zig");

const Feedback = @This();

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
        .bar_fill_symbols = &.{'#'},
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
    step_name: ?[]const u8 = null,
    total: usize = 0,
    completed: usize = 0,
};

pub fn init(writer: *std.Io.Writer, config: Config) !Feedback {
    return .{
        .writer = writer,
        .config = config,
    };
}

pub fn deinit(feedback: *Feedback) void {
    feedback.end() catch {};
}

pub fn progress(feedback: *Feedback) Progress {
    return .{
        .ptr = feedback,
        .vtable = &.{
            .step = type_erased_progress_step,
            .end = type_erased_progress_end,
        },
    };
}

pub fn end(feedback: *Feedback) !void {
    if (feedback.thread) |thread| {
        {
            feedback.mutex.lock();
            defer feedback.mutex.unlock();
            feedback.thread_should_exit = true;
        }
        feedback.cond.signal();
        thread.join();
        feedback.thread = null;
        feedback.thread_should_exit = false;
    }

    feedback.task = null;
    try ansi_term.clear_line(feedback.writer);
    try ansi_term.set_cursor_column(feedback.writer, 0);
    try ansi_term.show_cursor(feedback.writer);
    try feedback.writer.flush();
}

pub fn update(feedback: *Feedback, text: []const u8) !void {
    try signal.were_we_interrupted();

    if (feedback.thread == null) {
        try ansi_term.hide_cursor(feedback.writer);
        feedback.thread = try .spawn(.{
            .stack_size = 16 * 1024,
        }, update_thread, .{feedback});
    }

    {
        feedback.mutex.lock();
        defer feedback.mutex.unlock();

        const task: Task = .{ .text = text };
        try render(feedback, task);
        feedback.task = task;
    }

    feedback.cond.signal();
}

pub fn reset(feedback: *Feedback) !void {
    try signal.were_we_interrupted();

    feedback.mutex.lock();
    defer feedback.mutex.unlock();
    feedback.task = null;
    try ansi_term.clear_line(feedback.writer);
    try ansi_term.set_cursor_column(feedback.writer, 0);
    try feedback.writer.flush();
}

pub fn fail(feedback: *Feedback) void {
    feedback.do_fail() catch {};
}

fn do_fail(feedback: *Feedback) !void {
    feedback.mutex.lock();
    defer feedback.mutex.unlock();

    if (feedback.task) |task| {
        try ansi_term.clear_line(feedback.writer);
        try ansi_term.set_cursor_column(feedback.writer, 0);
        try feedback.writer.print("{s} ", .{task.text});
        try ansi_term.write_color(feedback.writer, .red);
        try feedback.writer.writeAll("FAILED\n");
        try ansi_term.reset_color(feedback.writer);
        try feedback.writer.flush();
    }

    feedback.task = null;
}

fn progress_step(feedback: *Feedback, s: Progress.Step) !void {
    try signal.were_we_interrupted();

    feedback.mutex.lock();
    defer feedback.mutex.unlock();

    if (feedback.task) |*task| {
        task.step_name = s.name;
        task.completed = s.completed;
        task.total = s.total;
        try render(feedback, task.*);
    }
}

fn type_erased_progress_step(ptr: *anyopaque, s: Progress.Step) Progress.StepError!void {
    const feedback: *Feedback = @ptrCast(@alignCast(ptr));
    feedback.progress_step(s) catch |err| switch (err) {
        error.Interrupt => return error.Interrupt,
        else => return error.Other,
    };
}

fn type_erased_progress_end(ptr: *anyopaque) void {
    const feedback: *Feedback = @ptrCast(@alignCast(ptr));
    feedback.mutex.lock();
    defer feedback.mutex.unlock();

    if (feedback.task) |*task| {
        task.step_name = null;
        task.completed = 0;
        task.total = 0;
        render(feedback, task.*) catch {};
    }
}

fn render(feedback: *Feedback, task: Task) !void {
    try ansi_term.clear_line(feedback.writer);
    try ansi_term.set_cursor_column(feedback.writer, 0);
    try write_symbol(feedback.writer, feedback.config.spinner_symbols[feedback.symbol_index], 1, feedback.config.spinner_color);
    try feedback.writer.print(" {s}", .{task.text});

    if (task.step_name) |step_name| {
        try feedback.writer.print(" > {s}", .{step_name});
    }

    if (task.total != 0) {
        const bar_width = 40;
        const fill_symbols_count = feedback.config.bar_fill_symbols.len;
        const fill_width: f32 = @as(f32, @floatFromInt(task.completed)) / @as(f32, @floatFromInt(task.total)) * bar_width;

        try feedback.writer.writeByte(' ');

        const full_blocks: u32 = @intFromFloat(fill_width);
        const last_block_kind: u32 = @intFromFloat((fill_width - @floor(fill_width)) * @as(f32, @floatFromInt(fill_symbols_count)));

        if (feedback.config.bar_start_symbol) |start_symbol|
            try write_symbol(feedback.writer, start_symbol, 1, feedback.config.bar_color);
        try write_symbol(feedback.writer, feedback.config.bar_fill_symbols[fill_symbols_count - 1], 1, feedback.config.bar_color);
        try write_symbol(feedback.writer, feedback.config.bar_fill_symbols[fill_symbols_count - 1], full_blocks, feedback.config.bar_color);
        if (full_blocks < bar_width) {
            try write_symbol(feedback.writer, feedback.config.bar_fill_symbols[last_block_kind], 1, feedback.config.bar_color);
            try write_symbol(feedback.writer, feedback.config.bar_empty_symbol orelse ' ', bar_width - full_blocks - 1, feedback.config.bar_color);
            try write_symbol(feedback.writer, feedback.config.bar_end_symbol, 1, feedback.config.bar_color);
        }

        try feedback.writer.print(" [{}/{}]", .{ task.completed, task.total });
    }

    try feedback.writer.flush();
}

fn update_thread(feedback: *Feedback) void {
    const increment_interval = std.time.ns_per_s / feedback.config.spinner_symbols.len;

    wait_for_task: while (true) {
        {
            feedback.mutex.lock();
            defer feedback.mutex.unlock();

            while (!feedback.thread_should_exit and feedback.task == null) {
                feedback.cond.wait(&feedback.mutex);
            }
        }

        var timer = std.time.Timer.start() catch unreachable;
        while (true) {
            if (feedback.thread_should_exit) return;

            while (true) {
                if (timer.read() > increment_interval) {
                    break;
                }
                std.Thread.sleep(increment_interval - timer.read());
            }

            timer.reset();

            feedback.mutex.lock();
            defer feedback.mutex.unlock();

            if (feedback.task) |*task| {
                render(feedback, task.*) catch {};
                feedback.symbol_index += 1;
                feedback.symbol_index %= feedback.config.spinner_symbols.len;
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

    const esc_seq = "\x1B";
    const csi_seq = esc_seq ++ "[";
    const reset_seq = csi_seq ++ "0m";

    pub fn clear_line(writer: *std.Io.Writer) !void {
        try writer.writeAll(csi_seq ++ "2K");
    }

    pub fn hide_cursor(writer: *std.Io.Writer) !void {
        try writer.writeAll(csi_seq ++ "?25l");
    }

    pub fn show_cursor(writer: *std.Io.Writer) !void {
        try writer.writeAll(csi_seq ++ "?25h");
    }

    pub fn set_cursor_column(writer: *std.Io.Writer, column: usize) !void {
        try writer.print(csi_seq ++ "{d}G", .{column});
    }

    pub fn cursor_forward(writer: *std.Io.Writer, columns: usize) !void {
        try writer.print(csi_seq ++ "{d}C", .{columns});
    }

    pub fn write_color(writer: *std.Io.Writer, color: Color) !void {
        try writer.writeAll(csi_seq);
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
        try writer.writeAll(reset_seq);
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
