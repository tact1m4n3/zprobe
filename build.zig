const std = @import("std");
const microzig = @import("microzig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    if (generate_flash_stubs_bundle(b)) |flash_stubs_bundle|
        exe.root_module.addAnonymousImport("flash_stubs_bundle.tar", .{
            .root_source_file = flash_stubs_bundle,
        });
    b.installArtifact(exe);

    const exe_run = b.addRunArtifact(exe);
    exe_run.addArg("../microzig/examples/raspberrypi/rp2xxx/zig-out/firmware/pico_uart-log.elf");
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&exe_run.step);
}

fn generate_flash_stubs_bundle(b: *std.Build) ?std.Build.LazyPath {
    const mz_dep = b.dependency("microzig", .{});
    const mb = microzig.MicroBuild(.{
        .rp2xxx = true,
    }).init(b, mz_dep) orelse return null;

    const cortex_m_cpu: microzig.Cpu = .{
        .name = "cortex_m0plus",
        .root_source_file = b.path("src/flash_stubs/cpus/cortex_m.zig"),
    };

    const flash_loader_stubs: []const struct {
        name: []const u8,
        file: []const u8,
        target: *const microzig.Target,
    } = &.{
        .{
            .name = "RP2040",
            .file = "rp2xxx.zig",
            .target = mb.ports.rp2xxx.boards.raspberrypi.pico_flashless.derive(.{
                .entry = .{ .symbol_name = "_start" },
                .cpu = cortex_m_cpu,
            }),
        },
    };

    const bundle_flash_stubs_exe = b.addExecutable(.{
        .name = "bundle_flash_stubs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bundle_flash_stubs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const bundle_flash_stubs_run = b.addRunArtifact(bundle_flash_stubs_exe);
    const output = bundle_flash_stubs_run.addOutputFileArg("bundled_flash_stubs.tar");
    for (flash_loader_stubs) |stub| {
        const test_program_fw = mb.add_firmware(.{
            .name = stub.name,
            .root_source_file = b.path(b.fmt("src/flash_stubs/{s}", .{stub.file})),
            .target = stub.target,
            .optimize = .ReleaseSmall,
            .linker_script = .{
                .file = b.path("src/flash_stubs/linker.ld"),
                .generate = .none,
            },
            .stack = .{ .symbol_name = "_stack_end" },
            .unwind_tables = .none,
        });
        test_program_fw.artifact.pie = true;

        // for debugging
        mb.install_firmware(test_program_fw, .{ .format = .bin });
        mb.install_firmware(test_program_fw, .{ .format = .elf });

        bundle_flash_stubs_run.addFileArg(test_program_fw.get_emitted_bin(.bin));
    }

    return output;
}
