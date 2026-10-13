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
    // ReleaseSafe: aio now ships as the zaio_* C-ABI archive (libaio.a), and
    // that boundary is a wrapper -- the fleet rule is that wrappers keep their
    // checks. It is also what consumers already shipped: forIO compiled aio
    // into libforio_net.a at forIO's ReleaseSafe. (Was ReleaseFast, on the
    // pure-Zig policy forTime still follows.)
    //
    // NOT a bare standardOptimizeOption(.{}): that defaults to Debug, which
    // materializes `undefined` as real bytes and once shipped a 68MB archive.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (delivery default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

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

    // The test gets its OWN module, never the exported `aio` one. Under 0.16
    // addObjectFile attaches to the MODULE, not the compile step, so the forTime
    // archive the Windows test links below would otherwise ride along into every
    // consumer of `aio`: forIO's forio_async, and through it forNet's archive
    // object. On COFF that was not merely redundant -- forNet's windows-gnu
    // fornet.obj came out as forTime's archive with forNet's own code unit gone,
    // and libfornet.a shipped 0 of its 53 fnet_ exports. forIO's build.zig
    // records the same 0.16 trap for its pack tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("reify", reify_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
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

    // The seal tool's keep-glob matching (tools/wrap.zig). A host tool, so a
    // host test: it decides what the delivery exposes on every target.
    const seal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wrap.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(seal_tests).step);

    // =========================================================================
    // DELIVERY: prebuilt/<short>/libaio.a + zaio.h -- aio's zaio_* C ABI.
    //
    // Consumers link this archive instead of compiling aio's source (fleet
    // rule: no library compiles another's). src/c_abi.zig is compiled as an
    // OBJECT from a module of its own, never the exported `aio` module, which
    // must not carry exports. tools/wrap.zig then seals it: ld -r, objcopy
    // keeps only tools/keep_public.txt global, native `ar rcs`, and the build
    // FAILS if nm then finds any other public symbol.
    //
    // The seal runs the HOST's nm/ld/objcopy/ar, so it runs only when the
    // target is the host: each target branch builds natively. A cross build
    // fails with that reason instead of installing nothing; `zig build check
    // -Dtarget=<triple>` compile-checks the object for any target.
    //
    // windows-msvc: link.exe rejects a GNU-processed COFF, so that ABI ships
    // aio.lib built by Zig and UNSEALED, as forIO's MSVC packs do.
    // =========================================================================
    const cabi_module = b.createModule(.{
        .root_source_file = b.path("src/c_abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    cabi_module.addImport("reify", reify_module);
    const cabi_obj = b.addObject(.{ .name = "aio_cabi", .root_module = cabi_module });
    b.step("check", "Compile the zaio_* C-ABI object for -Dtarget (no archive, no run)").dependOn(&cabi_obj.step);

    const short = deliveryName(b, target.result);
    const host = b.graph.host.result;
    const native = target.result.os.tag == host.os.tag and target.result.cpu.arch == host.cpu.arch;
    // The header ships BESIDE the archive: a consumer copies its externs from
    // prebuilt/<short>/zaio.h, the file it links next to.
    const delivery = b.addUpdateSourceFiles();
    delivery.addCopyFileToSource(b.path("include/zaio.h"), b.fmt("prebuilt/{s}/zaio.h", .{short}));
    b.getInstallStep().dependOn(&delivery.step);

    if (target.result.abi == .msvc) {
        // src/msvc_root.zig: the same exports, with std.debug kept off
        // compiler-rt, which link.exe does not have (see that file).
        const msvc_module = b.createModule(.{
            .root_source_file = b.path("src/msvc_root.zig"),
            .target = target,
            .optimize = optimize,
        });
        msvc_module.addImport("reify", reify_module);
        const lib = b.addLibrary(.{ .linkage = .static, .name = "aio", .root_module = msvc_module });
        delivery.addCopyFileToSource(lib.getEmittedBin(), b.fmt("prebuilt/{s}/aio.lib", .{short}));
    } else if (native) {
        const wrap_exe = b.addExecutable(.{
            .name = "aio-wrap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/wrap.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        const archive = b.pathFromRoot(b.fmt("prebuilt/{s}/libaio.a", .{short}));
        const seal = b.addRunArtifact(wrap_exe);
        seal.addArg(archive); // <out_lib>
        seal.addArg(b.pathFromRoot(b.fmt(".zig-cache/wrap/{s}", .{short}))); // <workdir>
        seal.addPrefixedFileArg("@", b.path("tools/keep_public.txt")); // <keep>
        seal.addFileArg(cabi_obj.getEmittedBin()); // <obj>
        seal.has_side_effects = true; // runs nm/ld/objcopy/ar on the host -- never cache-skip
        b.getInstallStep().dependOn(&seal.step);

        // test-cabi: C, against the DELIVERED header, linking the SEALED archive.
        const cabi_test = b.addExecutable(.{
            .name = "zaio_test",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        cabi_test.root_module.addCSourceFile(.{
            .file = b.path("tests/cabi/zaio_test.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
        cabi_test.root_module.addIncludePath(b.path(b.fmt("prebuilt/{s}", .{short})));
        cabi_test.root_module.addObjectFile(.{ .cwd_relative = archive });
        if (target.result.os.tag == .windows) {
            // aio's Windows clocks are forTime's (src/time.zig).
            cabi_test.root_module.addObjectFile(.{ .cwd_relative = b.pathFromRoot("../forTime/prebuilt/winX86/libfortime.a") });
            for ([_][]const u8{ "ws2_32", "mswsock", "ntdll", "kernel32" }) |name| cabi_test.root_module.linkSystemLibrary(name, .{});
        }
        cabi_test.step.dependOn(&seal.step);
        cabi_test.step.dependOn(&delivery.step);
        const run_cabi = b.addRunArtifact(cabi_test);
        run_cabi.has_side_effects = true;
        b.step("test-cabi", "C-ABI tests: tests/cabi/zaio_test.c against prebuilt/<short>/{zaio.h,libaio.a}").dependOn(&run_cabi.step);
    } else {
        b.getInstallStep().dependOn(&b.addFail(b.fmt(
            "libaio.a is sealed with the host's nm/ld/objcopy/ar, so it is built natively on its " ++
                "target branch ({s}). Use `zig build check -Dtarget=...` to compile-check from here.",
            .{short},
        )).step);
    }

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

/// prebuilt/<short>/ -- the fleet's delivery names (forIO, forTime) for the
/// four delivered targets. Any other target gets "<os>-<arch>": visible and
/// distinct, never a shared "unknown" that lands where no consumer looks.
fn deliveryName(b: *std.Build, t: std.Target) []const u8 {
    if (t.os.tag == .macos) return "macos";
    if (t.os.tag == .linux and t.cpu.arch == .aarch64) return "thor";
    if (t.os.tag == .linux and t.cpu.arch == .x86_64) return "linX86";
    if (t.os.tag == .windows and t.cpu.arch == .x86_64) return "winX86";
    return b.fmt("{s}-{s}", .{ @tagName(t.os.tag), @tagName(t.cpu.arch) });
}
