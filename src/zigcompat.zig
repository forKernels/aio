//! zigcompat.zig — the 0.15.2 / 0.16 seam for aio, and where it stops working.
//!
//! Most of 0.16's breakage is decls that MOVED: std.fs.File -> std.Io.File,
//! std.posix.clock_gettime -> std.os.linux.clock_gettime, std.net.Address
//! removed in favour of a carrier aio has to supply itself. Those the `zig16`
//! constant below handles cleanly — it is comptime-known, so the dead arm is
//! never analysed and each compiler sees only its own half.
//!
//! REMOVED BUILTINS DO NOT BELONG HERE. `@Type` became `@EnumLiteral`/`@Union`
//! in 0.16, and a comptime branch CANNOT hide a builtin that no longer exists —
//! it is an AstGen error, a missing token rather than a missing decl. The fix
//! is not a cleverer branch, it is a separate FILE chosen by build.zig, which
//! is what src/reify_016.zig and src/reify_pre016.zig do behind the `reify`
//! module. Everything in THIS file is a decl that moved, which a comptime
//! branch handles correctly.

const std = @import("std");
const builtin = @import("builtin");

pub const zig16 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

/// A sockaddr carrier with the two members aio actually uses: `.any` and
/// `.getOsSockLen()`.
///
/// 0.16 removed `std.net` outright — not renamed, removed — and replaced it
/// with `std.Io.net`, which is a higher-level API where an address LISTENS or
/// CONNECTS rather than being passed to a syscall. aio hands `&addr.any` and
/// `addr.getOsSockLen()` straight to io_uring SQEs, so it needs the carrier,
/// not the connector. On 0.15.2 this is std.net.Address unchanged.
pub const Address = if (zig16) extern struct {
    any: std.posix.sockaddr align(8),

    pub fn getOsSockLen(self: Address) std.posix.socklen_t {
        return switch (self.any.family) {
            std.posix.AF.INET => @sizeOf(std.posix.sockaddr.in),
            std.posix.AF.INET6 => @sizeOf(std.posix.sockaddr.in6),
            std.posix.AF.UNIX => @sizeOf(std.posix.sockaddr.un),
            else => @sizeOf(std.posix.sockaddr),
        };
    }
} else std.net.Address;

/// 0.16 moved File out of std.fs into std.Io. A MOVED decl, so unlike
/// EnumLiteral/UnionFromEnum above this one genuinely works on both — the
/// dead arm is a missing field, not a missing token. forNet's zigcompat.zig
/// carries the identical line.
pub const File = if (zig16) std.Io.File else std.fs.File;

/// Monotonic nanoseconds since an arbitrary epoch.
///
/// 0.16 removed std.time.Timer with no replacement — Io.Timestamp needs an Io,
/// which a benchmark harness has no reason to construct. aio already owns a
/// monotonic clock in time.zig; this exists so callers stop reaching into std
/// for one. CLOCK_BOOTTIME rather than MONOTONIC: BOOTTIME includes time spent
/// suspended, and a benchmark that silently excludes a VM migration reports a
/// duration that never happened.
pub fn monotonicNanos() u64 {
    if (zig16) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.BOOTTIME, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    } else {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME) catch
            @panic("CLOCK_BOOTTIME required");
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
}

// ── the std.posix syscall surface 0.16 moved to std.os.linux ───────────────
// All of these went from an error union over slices to a raw syscall returning
// usize. The 0.16 arms check errno; the 0.15.2 arms keep posix's shape. Only
// the Linux paths are covered — darwin.zig and windows.zig are comptime-pruned
// here and I have no machine to test them on.

fn linuxErr(rc: usize) bool {
    return std.os.linux.errno(rc) != .SUCCESS;
}

pub fn socket(domain: u32, sock_type: u32, protocol: u32) !i32 {
    if (!zig16) return std.posix.socket(domain, sock_type, protocol);
    const rc = std.os.linux.socket(domain, sock_type, protocol);
    if (linuxErr(rc)) return error.SocketCreateFailed;
    return @intCast(rc);
}

pub fn close(fd: i32) void {
    if (!zig16) {
        std.posix.close(fd);
    } else {
        _ = std.os.linux.close(fd);
    }
}

pub fn bind(fd: i32, addr: *const std.posix.sockaddr, len: std.posix.socklen_t) !void {
    if (!zig16) return std.posix.bind(fd, addr, len);
    if (linuxErr(std.os.linux.bind(fd, addr, len))) return error.BindFailed;
}

pub fn listen(fd: i32, backlog: u31) !void {
    if (!zig16) return std.posix.listen(fd, backlog);
    if (linuxErr(std.os.linux.listen(fd, backlog))) return error.ListenFailed;
}

/// Monotonic clock as a timespec, for callers that need the two fields rather
/// than a scalar. CLOCK_MONOTONIC specifically: io_uring's timeout is absolute
/// against this clock, and mixing clock sources there deadlocks rather than
/// merely drifting.
pub fn clockMonotonic() std.os.linux.timespec {
    if (!zig16) {
        return std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
    } else {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return ts;
    }
}

pub fn clockRealtime() std.os.linux.timespec {
    if (!zig16) {
        return std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    } else {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        return ts;
    }
}
