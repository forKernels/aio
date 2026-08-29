const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast (org optimize policy): no Fortran under this layer, so the compute
    // IS the Zig and safety checks sit on the hot path rather than off it.
    //
    // NOT a bare standardOptimizeOption(.{}): that defaults to Debug, which
    // materializes `undefined` as real bytes and once shipped a 68MB archive.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (delivery default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // Reflective type construction, selected BY COMPILER VERSION.
    //
    // 0.16 removed @Type in favour of @Union/@Enum/@Struct. That cannot be
    // handled with a comptime branch the way a moved namespace member can:
    // "invalid builtin function" comes from AstGen, which walks the whole file
    // before any branch is evaluated, so a dead branch still fails. The wrong
    // file therefore must never be reached -- hence picking it here.
    const zig16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;
    const reify_module = b.addModule("reify", .{
        .root_source_file = b.path(if (zig16) "src/reify_016.zig" else "src/reify_pre016.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("aio", .{
        .root_source_file = b.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("reify", reify_module);

    const unit_tests = b.addTest(.{
        .root_module = module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // HTTP 服务器示例
    const http_server_module = b.addModule("http_server", .{
        .root_source_file = b.path("examples/http_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_server_module.addImport("aio", module);

    const http_server = b.addExecutable(.{
        .name = "http_server",
        .root_module = http_server_module,
    });

    const run_http_server = b.addRunArtifact(http_server);
    run_http_server.step.dependOn(b.getInstallStep());

    const http_server_step = b.step("http_server", "Run HTTP server example");
    http_server_step.dependOn(&run_http_server.step);
}
