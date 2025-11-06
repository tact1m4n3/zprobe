const std = @import("std");
const microzig = @import("microzig");

const zprobe = @import("src/root.zig");

pub const LoadOptions = struct {
    elf_file: std.Build.LazyPath,
    speed: zprobe.probe.Speed = .mhz(10),
    run_method: ?zprobe.flash.RunMethod = null,
    chip: zprobe.chip.Tag,
    rtt: bool = false,
};

pub fn load(dep: *std.Build.Dependency, options: LoadOptions) *std.Build.Step {
    std.debug.assert(@intFromEnum(options.speed) >= 1000); // speed must be greater than 1KHz

    const b = dep.builder;
    const exe = dep.artifact("zprobe");
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{
        "load",
        "--chip",
        @tagName(options.chip),
        "--speed",
        b.fmt("{f}", .{options.speed}),
    });
    if (options.run_method) |run_method| run.addArgs(&.{ "--run-method", @tagName(run_method) });
    if (options.rtt) run.addArg("--rtt");
    run.addFileArg(options.elf_file);

    return &run.step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libusb_dep = b.dependency("libusb", .{
        .target = target,
        .optimize = .ReleaseFast,
        .@"system-libudev" = false,
        .linkage = .static,
    });

    const flash_algorithm_mod = b.createModule(.{
        .root_source_file = b.path("flash_algorithms/flash_algorithm.zig"),
    });

    const util_mod = b.createModule(.{
        .root_source_file = b.path("util/root.zig"),
    });

    const zprobe_mod = b.addModule("zprobe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "flash_algorithm", .module = flash_algorithm_mod },
            .{ .name = "util", .module = util_mod },
        },
    });
    zprobe_mod.linkLibrary(libusb_dep.artifact("usb"));

    const zprobe_test = b.addTest(.{
        .name = "zprobe_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flash_algorithm", .module = flash_algorithm_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });

    if (bundle_flash_algorithms(b, flash_algorithm_mod, util_mod)) |flash_algs_bundle|
        zprobe_mod.addAnonymousImport("flash_algorithms_bundle", .{
            .root_source_file = flash_algs_bundle,
        });

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const zprobe_exe = b.addExecutable(.{
        .name = "zprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap_dep.module("clap") },
                .{ .name = "zprobe", .module = zprobe_mod },
            },
        }),
    });
    b.installArtifact(zprobe_exe);

    const test_run = b.addRunArtifact(zprobe_test);
    const test_step = b.step("test", "Test zprobe");
    test_step.dependOn(&test_run.step);
}

fn bundle_flash_algorithms(b: *std.Build, alg_mod: *std.Build.Module, util_mod: *std.Build.Module) ?std.Build.LazyPath {
    const mz_dep = b.dependency("microzig", .{});
    const mb = microzig.MicroBuild(.{
        .rp2xxx = true,
    }).init(b, mz_dep) orelse return null;

    const cortex_m_cpu_path = b.path("flash_algorithms/cpus/cortex_m.zig");

    const flash_algs: []const struct {
        name: []const u8,
        file: []const u8,
        target: *const microzig.Target,
    } = &.{
        .{
            .name = "RP2040",
            .file = "rp2xxx.zig",
            .target = mb.ports.rp2xxx.boards.raspberrypi.pico_flashless.derive(.{
                .entry = .{ .symbol_name = "_start" },
                .cpu = .{
                    .name = "cortex_m0plus",
                    .root_source_file = cortex_m_cpu_path,
                },
            }),
        },
        // .{
        //     .name = "RP2350_ARM",
        //     .file = "rp2xxx.zig",
        //     .target = mb.ports.rp2xxx.boards.raspberrypi.pico2_arm_flashless.derive(.{
        //         .entry = .{ .symbol_name = "_start" },
        //         .cpu = .{
        //             .name = "cortex_m33",
        //             .root_source_file = cortex_m_cpu_path,
        //         },
        //     }),
        // },
    };

    const bundle_flash_algs_exe = b.addExecutable(.{
        .name = "generate_bundle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("flash_algorithms/generate_bundle.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "flash_algorithm", .module = alg_mod },
                .{ .name = "util", .module = util_mod },
            },
        }),
    });

    const bundle_flash_algs_run = b.addRunArtifact(bundle_flash_algs_exe);
    const output = bundle_flash_algs_run.addOutputFileArg("flash_algorithms_bundle.zon");
    for (flash_algs) |alg| {
        const test_program_fw = mb.add_firmware(.{
            .name = alg.name,
            .root_source_file = b.path(b.fmt("flash_algorithms/{s}", .{alg.file})),
            .target = alg.target,
            .optimize = .ReleaseSmall,
            .linker_script = .{
                .file = b.path("flash_algorithms/linker.ld"),
                .generate = .none,
            },
            .stack = .{ .symbol_name = "_stack_end" },
            .unwind_tables = .none,
            .imports = &.{
                .{ .name = "flash_algorithm", .module = alg_mod },
            },
        });
        test_program_fw.artifact.pie = true;

        // for debugging
        mb.install_firmware(test_program_fw, .{ .format = .bin });
        mb.install_firmware(test_program_fw, .{ .format = .elf });

        bundle_flash_algs_run.addArg(alg.name);
        bundle_flash_algs_run.addFileArg(test_program_fw.get_emitted_elf());
    }

    return output;
}
