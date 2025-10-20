const std = @import("std");

pub const Progress = @This();

ptr: *anyopaque,
vtable: *const Vtable,

pub const Vtable = struct {
    step: *const fn (ptr: *anyopaque, s: Step) StepError!void,
    end: *const fn (ptr: *anyopaque) void,
};

pub const StepError = error {
    Other,
    Interrupt,
};

pub const Step = struct {
    name: []const u8,
    completed: usize,
    total: usize,
};

pub fn step(progress: Progress, s: Step) StepError!void {
    try progress.vtable.step(progress.ptr, s);
}

pub fn end(progress: Progress) void {
    progress.vtable.end(progress.ptr);
}
