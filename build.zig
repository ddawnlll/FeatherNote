const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
    });
    root_module.addIncludePath(b.path("vendor/sqlite"));
    const assets = b.createModule(.{
        .root_source_file = b.path("assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("assets", assets);
    const sqlite_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite/sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("sqlite3", sqlite_c.createModule());
    root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c11",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_USE_URI=0",
            "-DSQLITE_ENABLE_FTS5",
        },
    });
    // MD4C 0.5.3 (MIT, vendor/md4c): CommonMark + GFM tables/task lists.
    // Zig talks to the bridge header, never to MD4C internals directly.
    const md4c_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/md4c/feathernote_md.h"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("md4c", md4c_c.createModule());
    root_module.addCSourceFile(.{ .file = b.path("vendor/md4c/md4c.c"), .flags = &.{ "-std=c11", "-Ivendor/md4c" } });
    root_module.addCSourceFile(.{ .file = b.path("vendor/md4c/md4c-html.c"), .flags = &.{ "-std=c11", "-Ivendor/md4c" } });
    root_module.addCSourceFile(.{ .file = b.path("vendor/md4c/entity.c"), .flags = &.{ "-std=c11", "-Ivendor/md4c" } });
    root_module.addCSourceFile(.{ .file = b.path("vendor/md4c/feathernote_md.c"), .flags = &.{ "-std=c11", "-Ivendor/md4c" } });

    const exe = b.addExecutable(.{
        .name = "feathernote",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the FeatherNote server");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
