const Target = @import("Target.zig");

pub const RP2040 = @import("chips/RP2040.zig");

pub const Tag = enum {
    RP2040,
};

pub const Any = union(Tag) {
    RP2040: RP2040,

    pub fn deinit(any_chip: *Any) void {
        return switch (any_chip.*) {
            inline else => |*chip| chip.deinit(),
        };
    }

    pub fn target(any_chip: *Any) *Target {
        return switch (any_chip.*) {
            inline else => |*chip| &chip.target,
        };
    }
};
