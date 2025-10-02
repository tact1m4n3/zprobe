const std = @import("std");

var output_file_writer_buf: [1024]u8 = undefined;

pub fn main() !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return error.UsageError;

    const output_file = try std.fs.cwd().createFile(args[1], .{});
    defer output_file.close();
    var output_file_writer = output_file.writer(&output_file_writer_buf);

    var archiver: std.tar.Writer = .{
        .underlying_writer = &output_file_writer.interface,
    };

    for (args[2..]) |path| {
        const input_file = try std.fs.cwd().openFile(path, .{});
        var input_file_reader = input_file.reader(&.{});
        const name = std.fs.path.stem(path);
        try archiver.writeFile(name, &input_file_reader, 0);
    }
    try output_file_writer.interface.flush();
}
