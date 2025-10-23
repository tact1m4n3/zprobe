const std = @import("std");

pub const Progress = @This();

ptr: *anyopaque,
vtable: *const Vtable,

pub const Vtable = struct {
    begin: *const fn (ptr: *anyopaque, name: []const u8, length: usize) Error!void,
    increment: *const fn (ptr: *anyopaque, by: usize) Error!void,
    end: *const fn (ptr: *anyopaque) void,
};

pub const Error = error {
    Other,
    Interrupt,
};

pub fn begin(progress: Progress, name: []const u8, length: usize) Error!void {
    try progress.vtable.begin(progress.ptr, name, length);
}

pub fn increment(progress: Progress, by: usize) Error!void {
    try progress.vtable.increment(progress.ptr, by);
}

pub fn end(progress: Progress) void {
    progress.vtable.end(progress.ptr);
}
