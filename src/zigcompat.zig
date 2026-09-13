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
    if (zig16 and darwin) {
        // Darwin has no BOOTTIME. Its MONOTONIC is mach_continuous_time, which
        // already counts time spent asleep, so it carries the semantic the
        // Linux arm reaches for BOOTTIME to get. Routing through std.c matters
        // here rather than merely being tidy: the Linux arm below issues a
        // LINUX syscall, and on macOS that is SIGSYS. aio's six benchmark
        // tests crashed exactly that way until this branch existed.
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
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
// usize. The 0.16 arms check errno; the 0.15.2 arms keep posix's shape.
//
// DARWIN, 2026-09-11. The note that used to sit here said the non-Linux paths
// were "comptime-pruned here" and untestable for want of a machine. They were
// not pruned — these functions branched on `zig16` and nothing else, so on
// macOS + 0.16 every one of them called a LINUX syscall wrapper. Only `bind`
// failed to compile, because it is the only one whose argument is a pointer to
// a struct that differs between the two platforms. `socket`, `listen` and
// `getSockName` take plain integers, type-checked clean, and would have issued
// Linux syscall numbers on a Darwin kernel at runtime.
//
// That is the failure this file's own header warns about in a different key: a
// dead-on-arrival path passes every build check because nothing analyses it
// until something calls it. aio's test build analyses everything, which is
// where these surfaced.
//
// The Linux arms below are UNCHANGED. Darwin now routes through
// std.posix.system, which resolves to std.c when libc is linked.

const darwin = builtin.os.tag.isDarwin();

fn linuxErr(rc: usize) bool {
    return std.os.linux.errno(rc) != .SUCCESS;
}

/// Darwin's libc wrappers return -1 on failure rather than a negated errno, so
/// the test is a sign check, not an errno decode.
fn darwinErr(rc: anytype) bool {
    return rc == -1;
}

pub fn socket(domain: u32, sock_type: u32, protocol: u32) !i32 {
    if (!zig16) return std.posix.socket(domain, sock_type, protocol);
    if (darwin) {
        const rc = std.posix.system.socket(domain, sock_type, protocol);
        if (darwinErr(rc)) return error.SocketCreateFailed;
        return @intCast(rc);
    }
    const rc = std.os.linux.socket(domain, sock_type, protocol);
    if (linuxErr(rc)) return error.SocketCreateFailed;
    return @intCast(rc);
}

// SOCKET HANDLES ARE NOT i32 ON WINDOWS.
//
// These four took `fd: i32` because every 0.16 arm below calls a raw Linux or
// Darwin syscall, where a socket descriptor really is an i32. The 0.15.2 arm
// does not: it forwards to std.posix, which takes `socket_t` / `fd_t` — and on
// Windows that is a `*ws2_32.SOCKET__opaque`, a pointer. So the shim refused
// its own caller:
//
//   aio/src/io/common.zig:34:42: error: expected type 'i32',
//       found '*os.windows.ws2_32.SOCKET__opaque_1653'
//
// forNet was the only repo that reached it, through forIO's forio_async module.
// Typing the parameters as the std.posix aliases costs nothing on Linux and
// Darwin, where both aliases ARE i32, so the raw-syscall arms still typecheck.
pub fn close(fd: std.posix.fd_t) void {
    if (!zig16) {
        std.posix.close(fd);
    } else if (darwin) {
        _ = std.posix.system.close(fd);
    } else {
        _ = std.os.linux.close(fd);
    }
}

pub fn bind(fd: std.posix.socket_t, addr: *const std.posix.sockaddr, len: std.posix.socklen_t) !void {
    if (!zig16) return std.posix.bind(fd, addr, len);
    if (darwin) {
        if (darwinErr(std.posix.system.bind(fd, addr, len))) return error.BindFailed;
        return;
    }
    if (linuxErr(std.os.linux.bind(fd, addr, len))) return error.BindFailed;
}

pub fn listen(fd: std.posix.socket_t, backlog: u31) !void {
    if (!zig16) return std.posix.listen(fd, backlog);
    if (darwin) {
        if (darwinErr(std.posix.system.listen(fd, backlog))) return error.ListenFailed;
        return;
    }
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

/// Local address of a bound socket. 0.16 moved getsockname to the raw syscall
/// layer with an out-param and a usize return.
pub fn getSockName(fd: std.posix.socket_t, addr: *std.posix.sockaddr, len: *std.posix.socklen_t) !void {
    if (!zig16) return std.posix.getsockname(fd, addr, len);
    var ulen: u32 = @intCast(len.*);
    if (darwin) {
        if (darwinErr(std.posix.system.getsockname(fd, addr, &ulen))) return error.GetSockNameFailed;
        len.* = @intCast(ulen);
        return;
    }
    if (linuxErr(std.os.linux.getsockname(fd, addr, &ulen))) return error.GetSockNameFailed;
    len.* = @intCast(ulen);
}

/// std RENAMED this inside its own error set: 0.15.2 spells it
/// FileLocksNotSupported, 0.16 FileLocksUnsupported. It surfaces as an error
/// SET MISMATCH rather than an unknown name, which reads like a much larger
/// problem than a rename. Shimmable where the @Type builtins were not, because
/// an error literal always exists — `error.Whatever` defines it on the spot.
pub const file_locks_err = if (zig16) error.FileLocksUnsupported else error.FileLocksNotSupported;
