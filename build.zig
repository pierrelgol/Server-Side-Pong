const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz = httpz_dep.module("httpz");

    const pg_dep = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });
    const pg = pg_dep.module("pg");

    const server_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
    });
    server_module.addImport("httpz", httpz);
    server_module.addImport("pg", pg);

    const server = b.addExecutable(.{
        .name = "server",
        .root_module = server_module,
        .link_libc = true,
    });
    server.linkLibC();
    b.installArtifact(server);

    const check_server = b.addExecutable(.{
        .name = "server",
        .root_module = server_module,
    });

    const check_step = b.step("check", "run compilation without emitting binaries");
    check_step.dependOn(&check_server.step);

    const run_step = b.step("run", "Run the server and the client");
    const run_server = b.addRunArtifact(server);

    if (b.args) |args| {
        run_server.addArgs(args);
    }
    run_step.dependOn(&run_server.step);

    const test_server = b.addTest(.{
        .root_module = server_module,
        .link_libc = true,
    });
    test_server.linkLibC();

    const run_test_server = b.addRunArtifact(test_server);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test_server.step);
}
