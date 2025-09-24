const std = @import("std");
const MicroBuild = @import("microzig").MicroBuild;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild(.{ .rp2xxx = true }).init(b, mz_dep) orelse return;
    const test_program_fw = mb.add_firmware(.{
        .name = "test_program",
        .root_source_file = b.path("test.zig"),
        .target = mb.ports.rp2xxx.boards.raspberrypi.pico_flashless,
        .optimize = optimize,
    });
    mb.install_firmware(test_program_fw, .{ .format = .bin });
    mb.install_firmware(test_program_fw, .{ .format = .elf });

    const libusb_dep = b.dependency("libusb", .{
        .target = target,
        .optimize = optimize,
        .system_libudev = true,
    });

    const exe = b.addExecutable(.{
        .name = "zprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.linkLibrary(libusb_dep.artifact("usb"));
    b.installArtifact(exe);

    const exe_run = b.addRunArtifact(exe);
    exe_run.addFileArg(test_program_fw.get_emitted_elf());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&exe_run.step);
}
