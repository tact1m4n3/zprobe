const std = @import("std");

const Timeout = @This();

start: std.time.Instant,
after: ?u64,
sleep_per_tick_ns: ?u64,

pub const InitOptions = struct {
    after: ?u64 = 100 * std.time.ns_per_ms,
    sleep_per_tick_ns: ?u64 = null,
};

pub fn init(options: InitOptions) !Timeout {
    return .{
        .start = if (options.after != null) try std.time.Instant.now() else undefined,
        .after = options.after,
        .sleep_per_tick_ns = options.sleep_per_tick_ns,
    };
}

pub fn tick(timeout: Timeout) !void {
    if (timeout.after) |after| {
        const now = try std.time.Instant.now();
        if (now.since(timeout.start) > after) {
            return error.Timeout;
        }
    }

    if (timeout.sleep_per_tick_ns) |sleep_per_tick| {
        std.Thread.sleep(sleep_per_tick);
    }
}
