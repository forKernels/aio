const std = @import("std");

const zig16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

/// 0.16 moved cwd access behind std.Io. `path` is absolute (pathFromRoot), so
/// the cwd handle is only the API's entry point, not a base for the lookup.
fn pathExists(b: *std.Build, path: []const u8) bool {
    if (zig16) {
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    } else {
        std.fs.cwd().access(path, .{}) catch return false;
    }
    return true;
}

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
    // file therefore must never be reached -- hence picking it here. (`zig16` is
    // the file-scope constant above.)
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

    // WINDOWS: aio's clocks are forTime's (src/time.zig), wired the fleet way --
    // the PREBUILT archive, with the externs declared at the call site. A
    // library leaves ftim_* undefined for its consumer to resolve; a test
    // EXECUTABLE has no consumer, so it links the archive itself, exactly as
    // forIO's and forNet's test binaries already do.
    //
    // Resolved from THIS build root, not the process cwd, so the probe means the
    // same thing when aio is a dependency of forIO or forNet. A missing archive
    // fails only aio's own `zig build test`, with the reason, instead of a bare
    // "undefined symbol: ftim_mono_ns" -- and never touches a dependent's build.
    //
    // Linux and Darwin reference no ftim_* symbol, so nothing changes there.
    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) {
        const archive = b.pathFromRoot(if (target.result.abi == .msvc)
            "../forTime/prebuilt/winX86/fortime.lib"
        else
            "../forTime/prebuilt/winX86/libfortime.a");
        if (pathExists(b, archive)) {
            unit_tests.root_module.addObjectFile(.{ .cwd_relative = archive });
        } else {
            const missing = b.addFail(b.fmt(
                "aio's Windows test resolves its clocks from forTime's prebuilt {s}, " ++
                    "which is not there. Check out forTime (winX86 delivery) beside aio.",
                .{archive},
            ));
            run_unit_tests.step.dependOn(&missing.step);
        }
    }

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
