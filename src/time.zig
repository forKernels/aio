const std = @import("std");
const builtin = @import("builtin");

const stdx = @import("./stdx.zig");

const os = std.os;
const posix = std.posix;
const system = posix.system;
const assert = std.debug.assert;
const is_darwin = builtin.target.os.tag.isDarwin();
const is_windows = builtin.target.os.tag == .windows;
const is_linux = builtin.target.os.tag == .linux;
const Instant = stdx.Instant;

/// forTime's clock C-ABI, reached as a PREBUILT archive, never as source.
///
/// WINDOWS ONLY. Both externs are referenced from the Windows arms of `Time`
/// and nowhere else, and an extern nothing references is never emitted -- so a
/// Linux or Darwin build of aio carries no ftim_* symbol and its clocks are
/// exactly what they were. On Windows the symbols stay UNDEFINED in whatever
/// object holds aio (forIO's packs, libfornet.a), and the final executable
/// resolves them against ../forTime/prebuilt/winX86/libfortime.a (GNU ABI) or
/// fortime.lib (MSVC ABI). aio's own Windows test links that archive in
/// build.zig for the same reason forIO's and forNet's tests do.
///
/// Signatures match forIO's fortime_bridge.zig and forNet's declarations, so
/// the one symbol has one type wherever these modules share a compilation.
const fortime = struct {
    extern fn ftim_mono_ns() callconv(.c) u64;
    extern fn ftim_now_unix_ns() callconv(.c) i64;
};

pub const Time = struct {
    /// Hardware and/or software bugs can mean that the monotonic clock may regress.
    /// One example (of many): https://bugzilla.redhat.com/show_bug.cgi?id=448449
    /// We crash the process for safety if this ever happens, to protect against infinite loops.
    /// It's better to crash and come back with a valid monotonic clock than get stuck forever.
    monotonic_guard: u64 = 0,

    /// A timestamp to measure elapsed time, meaningful only on the same system, not across reboots.
    /// Always use a monotonic timestamp if the goal is to measure elapsed time.
    /// This clock is not affected by discontinuous jumps in the system time, for example if the
    /// system administrator manually changes the clock.
    pub fn monotonic(self: *Time) u64 {
        const m = blk: {
            if (is_windows) break :blk monotonic_windows();
            if (is_darwin) break :blk monotonic_darwin();
            if (is_linux) break :blk monotonic_linux();
            @compileError("unsupported OS");
        };

        // "Oops!...I Did It Again"
        if (m < self.monotonic_guard) @panic("a hardware/kernel bug regressed the monotonic clock");
        self.monotonic_guard = m;
        return m;
    }

    pub fn monotonic_instant(self: *Time) Instant {
        return Instant{ .ns = self.monotonic() };
    }

    fn monotonic_windows() u64 {
        assert(is_windows);
        // forTime's monotonic clock: QueryPerformanceCounter, which counts time
        // spent suspended -- the same semantic this arm had when it read QPC
        // itself, and the one the Linux arm reaches for CLOCK_BOOTTIME to get.
        //
        // 0.16 removed std.os.windows.QueryPerformanceCounter, and the fleet
        // does not hand-roll a replacement clock: forTime owns every clock, and
        // a consumer links its PREBUILT archive and declares the extern at the
        // call site (forTime docs/INTEGRATION.md). See `fortime` below.
        //
        // ftim_mono_ns returns 0 only when no monotonic clock is usable, which
        // no Windows since XP lacks. A 0 here would trip nothing silently: the
        // timeout queue would simply never expire, so it is asserted instead.
        const now = fortime.ftim_mono_ns();
        assert(now != 0);
        return now;
    }

    fn monotonic_darwin() u64 {
        assert(is_darwin);
        // Uses mach_continuous_time() instead of mach_absolute_time() as it counts while suspended.
        //
        // https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time
        // https://opensource.apple.com/source/Libc/Libc-1158.1.2/gen/clock_gettime.c.auto.html
        const darwin = struct {
            const mach_timebase_info_t = system.mach_timebase_info_data;
            extern "c" fn mach_timebase_info(info: *mach_timebase_info_t) system.kern_return_t;
            extern "c" fn mach_continuous_time() u64;
        };

        // mach_timebase_info() called through libc already does global caching for us
        //
        // https://opensource.apple.com/source/xnu/xnu-7195.81.3/libsyscall/wrappers/mach_timebase_info.c.auto.html
        var info: darwin.mach_timebase_info_t = undefined;
        if (darwin.mach_timebase_info(&info) != 0) @panic("mach_timebase_info() failed");

        const now = darwin.mach_continuous_time();
        return (now * info.numer) / info.denom;
    }

    fn monotonic_linux() u64 {
        assert(is_linux);
        // The true monotonic clock on Linux is not in fact CLOCK_MONOTONIC:
        //
        // CLOCK_MONOTONIC excludes elapsed time while the system is suspended (e.g. VM migration).
        //
        // CLOCK_BOOTTIME is the same as CLOCK_MONOTONIC but includes elapsed time during a suspend.
        //
        // For more detail and why CLOCK_MONOTONIC_RAW is even worse than CLOCK_MONOTONIC, see
        // https://github.com/ziglang/zig/pull/933#discussion_r656021295.
        return @import("zigcompat.zig").monotonicNanos();
    }

    /// A timestamp to measure real (i.e. wall clock) time, meaningful across systems, and reboots.
    /// This clock is affected by discontinuous jumps in the system time.
    pub fn realtime(_: *Time) i64 {
        if (is_windows) return realtime_windows();
        // macos has supported clock_gettime() since 10.12:
        // https://opensource.apple.com/source/Libc/Libc-1158.1.2/gen/clock_gettime.3.auto.html
        if (is_darwin or is_linux) return realtime_unix();
        @compileError("unsupported OS");
    }

    fn realtime_windows() i64 {
        assert(is_windows);
        // WALL clock, nanoseconds since the Unix epoch -- what this arm returned
        // when it read GetSystemTimePreciseAsFileTime and rebased FILETIME's 1601
        // epoch itself. 0.16 removed os.windows.WINAPI, which that @extern
        // needed; forTime supplies the same reading (see `fortime` below).
        return fortime.ftim_now_unix_ns();
    }

    fn realtime_unix() i64 {
        assert(is_darwin or is_linux);
        const ts = @import("zigcompat.zig").clockRealtime();
        return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
    }

    pub fn tick(_: *Time) void {}
};

test "Time monotonic smoke" {
    var time: Time = .{};
    const instant_1 = time.monotonic_instant();
    const instant_2 = time.monotonic_instant();
    assert(instant_1.duration_since(instant_1).ns == 0);
    assert(instant_2.duration_since(instant_1).ns >= 0);
}
