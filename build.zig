const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zebzockets = b.addModule("zebzockets", .{ .root_source_file = b.path("src/root.zig") });

    // const lib = b.addStaticLibrary(.{
    //     .name = "zebzockets",
    //     // In this case the main source file is merely a path, however, in more
    //     // complicated build scripts, this could be a generated file.
    //     .root_source_file = b.path("src/root.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    // b.installArtifact(lib);

    const client = b.addExecutable(.{
        .name = "zebzockets_client",
        .root_source_file = b.path("client/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    client.root_module.addImport("zebzockets", zebzockets);
    b.installArtifact(client);
    const client_exe = b.addRunArtifact(client);
    const run_client_step = b.step("run_client", "Run client");
    run_client_step.dependOn(&client_exe.step);
    if (b.args) |args| {
        client_exe.addArgs(args);
    }

    const build_client_step = b.step("client", "Build client");
    build_client_step.dependOn(&client.step);
    const install_client = b.addInstallArtifact(client, .{});
    build_client_step.dependOn(&install_client.step);

    const server = b.addExecutable(.{
        .name = "zebzockets_server",
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    server.root_module.addImport("zebzockets", zebzockets);
    b.installArtifact(server);
    const server_exe = b.addRunArtifact(server);
    const run_server_step = b.step("run_server", "Run server");
    run_server_step.dependOn(&server_exe.step);
    if (b.args) |args| {
        server_exe.addArgs(args);
    }

    const build_server_step = b.step("server", "Build server");
    build_server_step.dependOn(&server.step);
    const install_server = b.addInstallArtifact(server, .{});
    build_server_step.dependOn(&install_server.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_unit_tests.root_module.addImport("zebzockets", zebzockets);
    // lib_unit_tests.root_module.addImport("zebzockets", zebzockets);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const client_unit_tests = b.addTest(.{
        .root_source_file = b.path("client/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // I guess this must be included??
    client_unit_tests.root_module.addImport("zebzockets", zebzockets);

    const run_client_unit_tests = b.addRunArtifact(client_unit_tests);

    const server_unit_tests = b.addTest(.{
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_unit_tests.root_module.addImport("zebzockets", zebzockets);

    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);

    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&zebzockets.step);
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_client_unit_tests.step);
    test_step.dependOn(&run_server_unit_tests.step);
}
