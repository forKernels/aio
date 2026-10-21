//! c_abi.zig -- root of the delivered libaio.a: zaio_*, aio's completion loop
//! behind a C ABI. The C declarations are include/zaio.h.
//!
//! WHY A C ABI
//! -----------
//! aio's own surface is generic Zig: every submission takes a comptime Context
//! type and a comptime callback, and the caller embeds IO.Completion in its own
//! types. No C declaration can name either. Consumers therefore compiled aio's
//! source (forIO through a zon path dependency; Wintermute through a vendored
//! copy). The fleet rule is that no library compiles another's source, so aio
//! ships this archive instead and a consumer declares `extern fn zaio_*`.
//!
//! The design is forIO's fio_net_* (forIO src/zig/net/exports.zig, the one
//! consumer that already put aio behind a C ABI), moved down to the library it
//! wraps. Status values, struct layouts, the 512-byte completion and the
//! callback signature are identical to fio_net_*, so forIO's exports can forward
//! to these one for one. forIO's synchronous socket calls that aio itself does
//! not make (bind, a datagram connect, listen with errno-precise statuses) stay
//! in forIO.
//!
//! PREFIX: zaio_, not aio_. POSIX already owns aio_* (<aio.h>: aio_read,
//! aio_cancel, ...) and the header name aio.h.
//!
//! THREADING -- the part a C caller cannot see from a signature
//! -----------------------------------------------------------
//! One thread runs a loop at a time; `owner` records which. Callbacks run on it.
//! Only wake and cancel_all may be called from other threads. cancel_all
//! marshals rather than touching the backend under a running loop, because the
//! Linux backend's cancel is not safe from a second thread and the Darwin
//! backend's cancel is a no-op:
//!
//!   cancel_all (any thread)            run / run_for (owner)
//!   -----------------------            ---------------------
//!   cancel_requested = true            owner = me          (publish)
//!   io.wake()                          if cancel_requested: owner = 0, CANCELED
//!   if owner == me: return (deferred)  io.run... (callbacks see cancel_requested
//!   wait until owner == 0                        and are suppressed)
//!   backendCancel()  (once)            if cancel_requested: backendCancel()
//!                                      owner = 0
//!
//! Both flags are sequentially consistent, so whichever side acts second sees
//! the other: a run never enters the backend after a cancel was requested, and a
//! cancel never enters it while a run is inside.

const std = @import("std");
const builtin = @import("builtin");

const IO = @import("io.zig").IO;
const Address = @import("zigcompat.zig").Address;
const posix = std.posix;

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

// =============================================================================
// Types (mirrored field for field in include/zaio.h)
// =============================================================================

/// Values equal forIO's FIO_NET_* one for one; see the file header.
pub const ZaioStatus = enum(c_int) {
    ok = 0,
    pending = 1,
    would_block = -1,
    closed = -2,
    canceled = -3,
    timed_out = -4,
    refused = -5,
    unreachable_ = -6,
    reset = -7,
    addr_in_use = -8,
    addr_not_available = -9,
    access_denied = -10,
    not_connected = -11,
    message_too_big = -12,
    invalid = -13,
    busy = -14,
    no_memory = -15,
    resources = -16,
    unsupported = -17,
    system = -18,
};

pub const ZaioLoop = opaque {};

/// Caller-owned storage for one operation. Fixed at 512 bytes on every target
/// so a C struct can embed it; the backend's Completion lives inside.
pub const ZaioCompletion = extern struct {
    _opaque: [64]u64,
};

pub const ZaioSockAddr = extern struct {
    struct_size: u32,
    family: u16,
    port: u16,
    flowinfo: u32,
    scope_id: u32,
    addr: [16]u8,
};

pub const ZaioTcpOptions = extern struct {
    struct_size: u32,
    nodelay: u8,
    keepalive: u8,
    _reserved: u16,
    rcvbuf: i32,
    sndbuf: i32,
    keepalive_idle_s: u32,
    keepalive_interval_s: u32,
    keepalive_count: u32,
    user_timeout_ms: u32,
};

pub const ZaioLoopOptions = extern struct {
    struct_size: u32,
    entries: u32,
    flags: u32,
    _reserved: u32,
};

pub const ZaioCallback = *const fn (
    user: ?*anyopaque,
    completion: *ZaioCompletion,
    status: ZaioStatus,
    value: u64,
) callconv(.c) void;

pub const invalid_socket: u64 = std.math.maxInt(u64);

/// Largest single transfer handed to the backend. Linux caps read/write at
/// 0x7ffff000; one limit everywhere keeps `value` meaning the same thing.
const max_transfer: usize = 0x7fff_f000;

comptime {
    const assert = std.debug.assert;
    assert(@sizeOf(ZaioCompletion) == 512 and @alignOf(ZaioCompletion) == 8);
    assert(@sizeOf(ZaioSockAddr) == 32 and @alignOf(ZaioSockAddr) == 4);
    assert(@offsetOf(ZaioSockAddr, "addr") == 16);
    assert(@sizeOf(ZaioTcpOptions) == 32 and @alignOf(ZaioTcpOptions) == 4);
    assert(@sizeOf(ZaioLoopOptions) == 16);
    assert(@bitSizeOf(c_int) == 32);
}

// =============================================================================
// Internal state
// =============================================================================

const Loop = struct {
    io: IO,
    /// Token of the thread inside run / run_for; 0 when none.
    owner: std.atomic.Value(u64) = .init(0),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// The backend's cancel_all has run (exactly once).
    backend_canceled: std.atomic.Value(bool) = .init(false),
};

/// What a ZaioCompletion holds.
const Slot = struct {
    io_completion: IO.Completion,
    loop: *Loop,
    callback: ZaioCallback,
    user: ?*anyopaque,
};

comptime {
    if (@sizeOf(Slot) > @sizeOf(ZaioCompletion) or @alignOf(Slot) > @alignOf(ZaioCompletion))
        @compileError(std.fmt.comptimePrint(
            "aio's Completion outgrew zaio_completion: slot {d} B align {d}, storage 512 B align 8. " ++
                "Growing the storage is an ABI change (include/zaio.h, and forIO's fio_net_completion).",
            .{ @sizeOf(Slot), @alignOf(Slot) },
        ));
}

fn loopOf(handle: ?*ZaioLoop) ?*Loop {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn currentToken() u64 {
    const id = std.Thread.getCurrentId();
    return @as(u64, @intCast(id)) +% 1;
}

fn backendCancel(loop: *Loop) void {
    if (loop.backend_canceled.swap(true, .seq_cst)) return;
    loop.io.cancel_all();
}

fn enter(loop: *Loop) ZaioStatus {
    if (loop.cancel_requested.load(.seq_cst)) return .canceled;
    if (loop.owner.cmpxchgStrong(0, currentToken(), .seq_cst, .seq_cst) != null) return .busy;
    // Re-check after publishing: see the THREADING note at the top.
    if (loop.cancel_requested.load(.seq_cst)) {
        loop.owner.store(0, .seq_cst);
        return .canceled;
    }
    return .ok;
}

fn leave(loop: *Loop) ZaioStatus {
    const canceled = loop.cancel_requested.load(.seq_cst);
    // Requested from a callback on this thread, or by a thread now waiting for
    // `owner` to clear: finish it before letting go, so the waiter returns only
    // once the backend holds nothing.
    if (canceled) backendCancel(loop);
    loop.owner.store(0, .seq_cst);
    return if (canceled) .canceled else .ok;
}

// ---- sockets and addresses --------------------------------------------------

/// SOCKET is a pointer on Windows and an fd elsewhere; both widen to u64.
const socket_is_handle = @typeInfo(IO.socket_t) == .pointer;

fn toSocket(v: u64) ?IO.socket_t {
    if (v == invalid_socket) return null;
    if (socket_is_handle) {
        if (v == 0) return null;
        return @ptrFromInt(std.math.cast(usize, v) orelse return null);
    }
    return std.math.cast(IO.socket_t, v);
}

fn fromSocket(s: IO.socket_t) u64 {
    if (socket_is_handle) return @intFromPtr(s);
    return if (s < 0) invalid_socket else @intCast(s);
}

/// The C ABI's family numbers. Never AF_*, whose values differ per OS.
const Family = enum(u16) { ipv4 = 4, ipv6 = 6 };

fn familyOf(v: u16) ?Family {
    if (v == @intFromEnum(Family.ipv4)) return .ipv4;
    if (v == @intFromEnum(Family.ipv6)) return .ipv6;
    return null;
}

fn afOf(family: Family) u32 {
    return switch (family) {
        .ipv4 => posix.AF.INET,
        .ipv6 => posix.AF.INET6,
    };
}

fn toAddress(a: *const ZaioSockAddr) ?Address {
    if (a.struct_size < @sizeOf(ZaioSockAddr)) return null;
    var out: Address = .{ .storage = std.mem.zeroes(posix.sockaddr.storage) };
    switch (familyOf(a.family) orelse return null) {
        .ipv4 => {
            if (@hasField(posix.sockaddr.in, "len")) out.in.len = @sizeOf(posix.sockaddr.in);
            out.in.family = posix.AF.INET;
            out.in.port = std.mem.nativeToBig(u16, a.port);
            // addr[0..4] is network order; so is sin_addr's memory.
            out.in.addr = @bitCast(a.addr[0..4].*);
        },
        .ipv6 => {
            if (@hasField(posix.sockaddr.in6, "len")) out.in6.len = @sizeOf(posix.sockaddr.in6);
            out.in6.family = posix.AF.INET6;
            out.in6.port = std.mem.nativeToBig(u16, a.port);
            out.in6.flowinfo = std.mem.nativeToBig(u32, a.flowinfo);
            out.in6.addr = a.addr;
            out.in6.scope_id = a.scope_id;
        },
    }
    return out;
}

/// POSIX: shut a socket down before closing it. io_uring holds its own
/// reference to the file, so close() alone never wakes a pending recv; kqueue
/// drops the registration silently. Shutdown makes the pending operation
/// complete. ENOTCONN on an unconnected socket is expected and ignored.
/// Winsock's closesocket aborts pending overlapped I/O by itself.
fn shutdownBoth(s: IO.socket_t) void {
    if (is_linux) {
        _ = std.os.linux.shutdown(s, std.os.linux.SHUT.RDWR);
    } else if (is_darwin) {
        _ = std.c.shutdown(s, std.c.SHUT.RDWR);
    }
}

// ---- status mapping ---------------------------------------------------------

/// Every error name any backend reports, and the status a C caller sees.
///
/// statusOf() is exhaustive over the error set it is handed: a name missing
/// here is a COMPILE error naming the backend's error set, not a silent
/// ZAIO_SYSTEM. A backend that grows an error therefore stops the build on
/// the target that grew it.
const error_status = [_]struct { []const u8, ZaioStatus }{
    .{ "WouldBlock", .would_block },
    .{ "FileDescriptorInvalid", .closed },
    .{ "FileDescriptorNotASocket", .closed },
    .{ "SocketNotListening", .closed },
    .{ "NotOpenForReading", .closed },
    .{ "NotOpenForWriting", .closed },
    .{ "Canceled", .canceled },
    .{ "Cancelled", .canceled }, // IOCP's spelling (wincompat.zig)
    .{ "ConnectionTimedOut", .timed_out },
    .{ "ConnectionRefused", .refused },
    .{ "NetworkUnreachable", .unreachable_ },
    .{ "HostUnreachable", .unreachable_ },
    .{ "ConnectionResetByPeer", .reset },
    .{ "ConnectionAborted", .reset },
    .{ "BrokenPipe", .reset },
    .{ "AddressInUse", .addr_in_use },
    .{ "AddressNotAvailable", .addr_not_available },
    .{ "AccessDenied", .access_denied },
    .{ "PermissionDenied", .access_denied },
    .{ "BlockedByFirewall", .access_denied },
    .{ "SocketNotConnected", .not_connected },
    .{ "MessageTooBig", .message_too_big },
    .{ "OutOfMemory", .no_memory },
    .{ "SystemResources", .resources },
    .{ "ProcessFdQuotaExceeded", .resources },
    .{ "SystemFdQuotaExceeded", .resources },
    .{ "OperationNotSupported", .unsupported },
    .{ "OperationUnsupported", .unsupported },
    .{ "AddressFamilyNotSupported", .unsupported },
    .{ "ProtocolNotSupported", .unsupported },
    .{ "ProtocolFamilyNotAvailable", .unsupported },
    .{ "SocketTypeNotSupported", .unsupported },
    .{ "AlreadyConnected", .invalid },
    .{ "OpenAlreadyInProgress", .invalid },
    .{ "InvalidProtocolOption", .invalid },
    .{ "EntriesNotPowerOfTwo", .invalid },
    .{ "EntriesZero", .invalid },
    .{ "EntriesTooLarge", .invalid },
    // SYSTEM: what forIO's fio_net_* already reported for each of these (its
    // table ended in `else => .system`). Listed by name so that a name nobody
    // has looked at is a compile error rather than a silent SYSTEM.
    .{ "Unexpected", .system },
    // darwin_posix.zig (kqueue, connect, fcntl)
    .{ "ConnectionPending", .system },
    .{ "EventNotFound", .system },
    .{ "ProcessNotFound", .system },
    .{ "FileBusy", .system },
    .{ "Locked", .system },
    .{ "DeadLock", .system },
    .{ "LockedRegionLimitExceeded", .system },
    // io_uring setup and submission (linux.zig, std.os.linux.IoUring)
    .{ "ArgumentsInvalid", .system },
    .{ "SystemOutdated", .system },
    .{ "BufferInvalid", .system },
    .{ "CompletionQueueOvercommitted", .system },
    .{ "FileDescriptorInBadState", .system },
    .{ "InvalidThread", .system },
    .{ "InvalidVersion", .system },
    .{ "LockedMemoryLimitExceeded", .system },
    .{ "MappingAlreadyExists", .system },
    .{ "MemoryMappingNotSupported", .system },
    .{ "OpcodeNotSupported", .system },
    .{ "ParamsOutsideAccessibleAddressSpace", .system },
    .{ "RingShuttingDown", .system },
    .{ "SignalInterrupt", .system },
    .{ "SubmissionQueueEntryInvalid", .system },
    // IOCP and Winsock (wincompat.zig)
    .{ "Aborted", .system },
    .{ "EOF", .system },
    .{ "WinsockStartupFailed", .system },
    // socket() and std's socket error sets, every backend
    .{ "SocketCreateFailed", .system },
    .{ "FastOpenAlreadyInProgress", .system },
    .{ "FileNotFound", .system },
    // File operations (zaio_read/write/fsync/close/open_dir). The status set is
    // forIO's FIO_NET_* one for one, so file errors map onto it rather than
    // adding codes, as FileNotFound above already does.
    .{ "InputOutput", .system },
    .{ "DeviceBusy", .system },
    .{ "PipeBusy", .system },
    .{ "AntivirusInterference", .system },
    .{ "NoSpaceLeft", .resources },
    .{ "DiskQuota", .resources },
    .{ "FileTooBig", .resources },
    .{ "ReadOnlyFileSystem", .access_denied },
    .{ "FileLocksUnsupported", .unsupported },
    .{ "IsDir", .invalid },
    .{ "NotDir", .invalid },
    .{ "NameTooLong", .invalid },
    .{ "BadPathName", .invalid },
    .{ "SymLinkLoop", .invalid },
    .{ "PathAlreadyExists", .invalid },
    .{ "NetworkNotFound", .invalid },
    .{ "Alignment", .invalid },
    .{ "Unseekable", .invalid },
    .{ "InvalidWtf8", .invalid }, // Windows open_dir: a path that is not WTF-8
    .{ "NotConnected", .not_connected }, // write on a socket fd (Linux, Windows)
    .{ "NetworkDown", .system },
    .{ "NetworkSubsystemFailed", .system },
    .{ "NoDevice", .system },
    .{ "Overflow", .system },
    .{ "ProtocolFailure", .system },
    .{ "SocketNotBound", .system },
    .{ "TimeoutTooBig", .system },
};

fn statusNamed(comptime name: []const u8) ?ZaioStatus {
    // A byte compare per table entry, at comptime: past the default quota.
    @setEvalBranchQuota(20_000);
    for (error_status) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

fn statusOf(err: anytype) ZaioStatus {
    const E = @TypeOf(err);
    const members = @typeInfo(E).error_set orelse
        @compileError("aio c_abi: statusOf needs a concrete error set, not anyerror");
    comptime {
        var missing: []const u8 = "";
        for (members) |m| {
            if (statusNamed(m.name) == null) missing = missing ++ " error." ++ m.name;
        }
        if (missing.len != 0) @compileError("aio c_abi: " ++ @typeName(E) ++ " can report" ++
            missing ++ ", with no zaio status. Add each to error_status in src/c_abi.zig.");
    }
    inline for (members) |m| {
        if (err == @field(anyerror, m.name)) return comptime statusNamed(m.name).?;
    }
    // `err` is a member of E and the loop returned for every member of E.
    unreachable;
}

// ---- trampolines ------------------------------------------------------------

fn deliver(slot: *Slot, status: ZaioStatus, value: u64) void {
    // cancel_all() from a callback earlier in this run: nothing more is called
    // back, even though the backend finishes the run it is in.
    if (slot.loop.cancel_requested.load(.seq_cst)) return;
    slot.callback(slot.user, @ptrCast(slot), status, value);
}

fn onAccept(slot: *Slot, _: *IO.Completion, result: IO.AcceptError!IO.socket_t) void {
    const s = result catch |err| return deliver(slot, statusOf(err), 0);
    if (slot.loop.cancel_requested.load(.seq_cst)) {
        // Nobody will be told about this socket; do not leak it.
        slot.loop.io.close_socket(s);
        return;
    }
    slot.callback(slot.user, @ptrCast(slot), .ok, fromSocket(s));
}

fn onConnect(slot: *Slot, _: *IO.Completion, result: IO.ConnectError!void) void {
    result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, 0);
}

fn onRecv(slot: *Slot, _: *IO.Completion, result: IO.RecvError!usize) void {
    const n = result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, n);
}

fn onSend(slot: *Slot, _: *IO.Completion, result: IO.SendError!usize) void {
    const n = result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, n);
}

fn onTimeout(slot: *Slot, _: *IO.Completion, result: IO.TimeoutError!void) void {
    result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, 0);
}

const Prepared = struct { loop: *Loop, slot: *Slot };

fn prepare(
    handle: ?*ZaioLoop,
    completion: ?*ZaioCompletion,
    callback: ?ZaioCallback,
    user: ?*anyopaque,
) union(enum) { ready: Prepared, failed: ZaioStatus } {
    const loop = loopOf(handle) orelse return .{ .failed = .invalid };
    const storage = completion orelse return .{ .failed = .invalid };
    const cb = callback orelse return .{ .failed = .invalid };
    if (loop.cancel_requested.load(.seq_cst)) return .{ .failed = .canceled };
    const slot: *Slot = @ptrCast(@alignCast(storage));
    // The backend overwrites io_completion itself when the operation is queued.
    slot.loop = loop;
    slot.callback = cb;
    slot.user = user;
    return .{ .ready = .{ .loop = loop, .slot = slot } };
}

// =============================================================================
// Loop
// =============================================================================

fn createLoop(entries: u12) !*Loop {
    const loop = try std.heap.page_allocator.create(Loop);
    errdefer std.heap.page_allocator.destroy(loop);
    loop.* = .{ .io = try IO.init(entries, 0) };
    return loop;
}

pub export fn zaio_loop_create(opts: ?*const ZaioLoopOptions, out_loop: ?*?*ZaioLoop) callconv(.c) ZaioStatus {
    const out = out_loop orelse return .invalid;
    out.* = null;
    var entries: u12 = 256;
    if (opts) |o| {
        if (o.struct_size < @sizeOf(ZaioLoopOptions) or o.flags != 0) return .invalid;
        if (o.entries != 0) {
            if (o.entries > 2048 or !std.math.isPowerOfTwo(o.entries)) return .invalid;
            entries = @intCast(o.entries);
        }
    }
    const loop = createLoop(entries) catch |err| return statusOf(err);
    out.* = @ptrCast(loop);
    return .ok;
}

pub export fn zaio_loop_destroy(handle: ?*ZaioLoop) callconv(.c) ZaioStatus {
    const loop = loopOf(handle) orelse return .invalid;
    if (loop.owner.load(.seq_cst) != 0) return .busy;
    loop.cancel_requested.store(true, .seq_cst);
    backendCancel(loop);
    loop.io.deinit();
    std.heap.page_allocator.destroy(loop);
    return .ok;
}

pub export fn zaio_loop_run(handle: ?*ZaioLoop) callconv(.c) ZaioStatus {
    const loop = loopOf(handle) orelse return .invalid;
    const entered = enter(loop);
    if (entered != .ok) return entered;
    const result = loop.io.run();
    const left = leave(loop);
    result catch |err| return if (left == .canceled) .canceled else statusOf(err);
    return left;
}

pub export fn zaio_loop_run_for(handle: ?*ZaioLoop, timeout_ns: u64) callconv(.c) ZaioStatus {
    const loop = loopOf(handle) orelse return .invalid;
    const ns = std.math.cast(u63, timeout_ns) orelse return .invalid;
    const entered = enter(loop);
    if (entered != .ok) return entered;
    const result = loop.io.run_for_ns(ns);
    const left = leave(loop);
    result catch |err| return if (left == .canceled) .canceled else statusOf(err);
    return left;
}

pub export fn zaio_loop_wake(handle: ?*ZaioLoop) callconv(.c) ZaioStatus {
    const loop = loopOf(handle) orelse return .invalid;
    loop.io.wake();
    return .ok;
}

pub export fn zaio_loop_cancel_all(handle: ?*ZaioLoop) callconv(.c) ZaioStatus {
    const loop = loopOf(handle) orelse return .invalid;
    loop.cancel_requested.store(true, .seq_cst);
    loop.io.wake();
    // From a callback on the running thread: that run finishes the cancel
    // before it returns (leave()).
    if (loop.owner.load(.seq_cst) == currentToken()) return .ok;
    // Another thread is inside the backend: let it leave. It sees the request
    // at its next check, which the wake above makes prompt.
    while (loop.owner.load(.seq_cst) != 0) std.Thread.yield() catch {};
    backendCancel(loop);
    return .ok;
}

pub export fn zaio_completion_size() callconv(.c) usize {
    return @sizeOf(ZaioCompletion);
}

pub export fn zaio_completion_alignment() callconv(.c) usize {
    return @alignOf(ZaioCompletion);
}

// =============================================================================
// Sockets (synchronous)
// =============================================================================

pub export fn zaio_tcp_open(handle: ?*ZaioLoop, family: u16, opts: ?*const ZaioTcpOptions, out_sock: ?*u64) callconv(.c) ZaioStatus {
    const out = out_sock orelse return .invalid;
    out.* = invalid_socket;
    const loop = loopOf(handle) orelse return .invalid;
    const fam = familyOf(family) orelse return .invalid;
    if (loop.cancel_requested.load(.seq_cst)) return .canceled;

    var options: IO.TCPOptions = .{ .rcvbuf = 0, .sndbuf = 0, .keepalive = null, .user_timeout_ms = 0, .nodelay = false };
    if (opts) |o| {
        if (o.struct_size < @sizeOf(ZaioTcpOptions)) return .invalid;
        if (o.rcvbuf < 0 or o.sndbuf < 0) return .invalid;
        options.nodelay = o.nodelay != 0;
        options.rcvbuf = o.rcvbuf;
        options.sndbuf = o.sndbuf;
        options.user_timeout_ms = std.math.cast(c_int, o.user_timeout_ms) orelse return .invalid;
        if (o.keepalive != 0) options.keepalive = .{
            // Linux rejects 0 for each; 0 here means "the kernel's default".
            .keepidle = std.math.cast(c_int, if (o.keepalive_idle_s == 0) 7200 else o.keepalive_idle_s) orelse return .invalid,
            .keepintvl = std.math.cast(c_int, if (o.keepalive_interval_s == 0) 75 else o.keepalive_interval_s) orelse return .invalid,
            .keepcnt = std.math.cast(c_int, if (o.keepalive_count == 0) 9 else o.keepalive_count) orelse return .invalid,
        };
    }
    const s = loop.io.open_socket_tcp(afOf(fam), options) catch |err| return statusOf(err);
    out.* = fromSocket(s);
    return .ok;
}

pub export fn zaio_udp_open(handle: ?*ZaioLoop, family: u16, out_sock: ?*u64) callconv(.c) ZaioStatus {
    const out = out_sock orelse return .invalid;
    out.* = invalid_socket;
    const loop = loopOf(handle) orelse return .invalid;
    const fam = familyOf(family) orelse return .invalid;
    if (loop.cancel_requested.load(.seq_cst)) return .canceled;
    const s = loop.io.open_socket_udp(afOf(fam)) catch |err| return statusOf(err);
    out.* = fromSocket(s);
    return .ok;
}

pub export fn zaio_socket_close(handle: ?*ZaioLoop, sock: u64) callconv(.c) ZaioStatus {
    const loop = loopOf(handle) orelse return .invalid;
    const s = toSocket(sock) orelse return .invalid;
    shutdownBoth(s);
    loop.io.close_socket(s);
    return .ok;
}

// =============================================================================
// Submissions: PENDING and one callback, or an error and none
// =============================================================================

pub export fn zaio_accept(handle: ?*ZaioLoop, sock: u64, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const s = toSocket(sock) orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.accept(*Slot, p.slot, onAccept, &p.slot.io_completion, s);
    return .pending;
}

pub export fn zaio_connect(handle: ?*ZaioLoop, sock: u64, addr: ?*const ZaioSockAddr, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const s = toSocket(sock) orelse return .invalid;
    const a = toAddress(addr orelse return .invalid) orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.connect(*Slot, p.slot, onConnect, &p.slot.io_completion, s, a);
    return .pending;
}

pub export fn zaio_recv(handle: ?*ZaioLoop, sock: u64, buf: ?[*]u8, len: usize, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const s = toSocket(sock) orelse return .invalid;
    const b = buf orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.recv(*Slot, p.slot, onRecv, &p.slot.io_completion, s, b[0..@min(len, max_transfer)]);
    return .pending;
}

pub export fn zaio_send(handle: ?*ZaioLoop, sock: u64, buf: ?[*]const u8, len: usize, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const s = toSocket(sock) orelse return .invalid;
    const b = buf orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.send(*Slot, p.slot, onSend, &p.slot.io_completion, s, b[0..@min(len, max_transfer)]);
    return .pending;
}

pub export fn zaio_send_now(handle: ?*ZaioLoop, sock: u64, buf: ?[*]const u8, len: usize, out_sent: ?*usize) callconv(.c) ZaioStatus {
    const out = out_sent orelse return .invalid;
    out.* = 0;
    const loop = loopOf(handle) orelse return .invalid;
    const s = toSocket(sock) orelse return .invalid;
    const b = buf orelse return .invalid;
    if (loop.cancel_requested.load(.seq_cst)) return .canceled;
    const n = loop.io.send_now(s, b[0..@min(len, max_transfer)]) orelse return .would_block;
    out.* = n;
    return .ok;
}

pub export fn zaio_timeout(handle: ?*ZaioLoop, timeout_ns: u64, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const ns = std.math.cast(u63, timeout_ns) orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.timeout(*Slot, p.slot, onTimeout, &p.slot.io_completion, ns);
    return .pending;
}

// =============================================================================
// Files
// =============================================================================
// fd is the OS file descriptor (a HANDLE on Windows), carried in u64 exactly as
// sockets are. Same contract as recv/send: ZAIO_PENDING, then the callback runs
// once with ZAIO_OK and the bytes moved (read/write) or 0 (fsync/close).

const fd_is_handle = @typeInfo(IO.fd_t) == .pointer;

fn toFd(v: u64) ?IO.fd_t {
    if (v == invalid_socket) return null;
    if (fd_is_handle) {
        if (v == 0) return null;
        return @ptrFromInt(std.math.cast(usize, v) orelse return null);
    }
    return std.math.cast(IO.fd_t, v);
}

fn fromFd(f: IO.fd_t) u64 {
    if (fd_is_handle) return @intFromPtr(f);
    return if (f < 0) invalid_socket else @intCast(f);
}

fn onRead(slot: *Slot, _: *IO.Completion, result: IO.ReadError!usize) void {
    const n = result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, n);
}

fn onWrite(slot: *Slot, _: *IO.Completion, result: IO.WriteError!usize) void {
    const n = result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, n);
}

fn onFsync(slot: *Slot, _: *IO.Completion, result: IO.FsyncError!void) void {
    result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, 0);
}

fn onClose(slot: *Slot, _: *IO.Completion, result: IO.CloseError!void) void {
    result catch |err| return deliver(slot, statusOf(err), 0);
    deliver(slot, .ok, 0);
}

pub export fn zaio_read(handle: ?*ZaioLoop, fd: u64, buf: ?[*]u8, len: usize, offset: u64, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const f = toFd(fd) orelse return .invalid;
    const b = buf orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.read(*Slot, p.slot, onRead, &p.slot.io_completion, f, b[0..@min(len, max_transfer)], offset);
    return .pending;
}

pub export fn zaio_write(handle: ?*ZaioLoop, fd: u64, buf: ?[*]const u8, len: usize, offset: u64, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const f = toFd(fd) orelse return .invalid;
    const b = buf orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.write(*Slot, p.slot, onWrite, &p.slot.io_completion, f, b[0..@min(len, max_transfer)], offset);
    return .pending;
}

pub export fn zaio_fsync(handle: ?*ZaioLoop, fd: u64, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const f = toFd(fd) orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.fsync(*Slot, p.slot, onFsync, &p.slot.io_completion, f);
    return .pending;
}

pub export fn zaio_close(handle: ?*ZaioLoop, fd: u64, completion: ?*ZaioCompletion, callback: ?ZaioCallback, user: ?*anyopaque) callconv(.c) ZaioStatus {
    const f = toFd(fd) orelse return .invalid;
    const p = switch (prepare(handle, completion, callback, user)) {
        .ready => |r| r,
        .failed => |status| return status,
    };
    p.loop.io.close(*Slot, p.slot, onClose, &p.slot.io_completion, f);
    return .pending;
}

/// Synchronous, like IO.open_dir: opens a directory for fsync-ing its entries.
/// path is not NUL-terminated; path_len bytes are used.
pub export fn zaio_open_dir(path: ?[*]const u8, path_len: usize, out_fd: ?*u64) callconv(.c) ZaioStatus {
    const out = out_fd orelse return .invalid;
    out.* = invalid_socket;
    const p = path orelse return .invalid;
    const f = IO.open_dir(p[0..path_len]) catch |err| return statusOf(err);
    out.* = fromFd(f);
    return .ok;
}

// =============================================================================
// Tests (Zig-level). The C-ABI suite links the SEALED archive: tests/cabi/.
// =============================================================================

const testing = std.testing;

test "layout: the sizes zaio.h promises" {
    try testing.expectEqual(@as(usize, 512), zaio_completion_size());
    try testing.expectEqual(@as(usize, 8), zaio_completion_alignment());
    try testing.expect(@sizeOf(Slot) <= 512);
}

test "addresses: family 4/6 map to AF_*; AF_* values and short structs are refused" {
    var v4 = std.mem.zeroes(ZaioSockAddr);
    v4.struct_size = @sizeOf(ZaioSockAddr);
    v4.family = 4;
    v4.port = 8080;
    v4.addr[0..4].* = .{ 127, 0, 0, 1 };
    const a4 = toAddress(&v4).?;
    try testing.expectEqual(@as(@TypeOf(a4.any.family), posix.AF.INET), a4.any.family);
    try testing.expectEqual(@as(u16, 8080), std.mem.bigToNative(u16, a4.in.port));
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, @as([4]u8, @bitCast(a4.in.addr)));

    var v6 = std.mem.zeroes(ZaioSockAddr);
    v6.struct_size = @sizeOf(ZaioSockAddr);
    v6.family = 6;
    v6.port = 443;
    v6.flowinfo = 7;
    v6.scope_id = 3;
    v6.addr[15] = 1;
    const a6 = toAddress(&v6).?;
    try testing.expectEqual(@as(@TypeOf(a6.any.family), posix.AF.INET6), a6.any.family);
    try testing.expectEqual(@as(u16, 443), std.mem.bigToNative(u16, a6.in6.port));
    try testing.expectEqual(@as(u32, 7), std.mem.bigToNative(u32, a6.in6.flowinfo));
    try testing.expectEqual(@as(u32, 3), a6.in6.scope_id);
    try testing.expectEqual(v6.addr, a6.in6.addr);

    var bad = v4;
    bad.family = 2; // AF_INET's value, not 4
    try testing.expect(toAddress(&bad) == null);
    bad = v4;
    bad.struct_size = 16;
    try testing.expect(toAddress(&bad) == null);
}

test "every status the error table names is a distinct ZaioStatus value" {
    inline for (error_status) |entry| {
        try testing.expect(entry[1] != .ok and entry[1] != .pending);
    }
    try testing.expectEqual(ZaioStatus.would_block, statusOf(@as(error{WouldBlock}, error.WouldBlock)));
    try testing.expectEqual(ZaioStatus.system, statusOf(@as(error{ Unexpected, Canceled }, error.Unexpected)));
    try testing.expectEqual(ZaioStatus.canceled, statusOf(@as(error{ Unexpected, Canceled }, error.Canceled)));
}

test "loop: create, run, run_for, wake, destroy; NULL and bad options are INVALID" {
    var loop: ?*ZaioLoop = null;
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(null, &loop));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_run(loop));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_wake(loop));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_run_for(loop, 1_000_000));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_destroy(loop));

    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_run(null));
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_run_for(null, 1));
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_wake(null));
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_cancel_all(null));
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_destroy(null));
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_create(null, null));
    var bad_opts = ZaioLoopOptions{ .struct_size = @sizeOf(ZaioLoopOptions), .entries = 100, .flags = 0, ._reserved = 0 };
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_create(&bad_opts, &loop));
    try testing.expect(loop == null);
    bad_opts.entries = 64;
    bad_opts.flags = 1;
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_create(&bad_opts, &loop));
    bad_opts.flags = 0;
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(&bad_opts, &loop));
    try testing.expectEqual(ZaioStatus.invalid, zaio_loop_run_for(loop, std.math.maxInt(u64)));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_destroy(loop));
}

/// Records one callback.
const Seen = struct {
    calls: u32 = 0,
    status: ZaioStatus = .pending,
    value: u64 = 0,

    fn cb(user: ?*anyopaque, _: *ZaioCompletion, status: ZaioStatus, value: u64) callconv(.c) void {
        const self: *Seen = @ptrCast(@alignCast(user.?));
        self.calls += 1;
        self.status = status;
        self.value = value;
    }
};

fn runUntil(loop: ?*ZaioLoop, seen: *const Seen) !void {
    var spins: u32 = 0;
    while (seen.calls == 0) : (spins += 1) {
        if (spins == 200) return error.TestTimedOut;
        try testing.expectEqual(ZaioStatus.ok, zaio_loop_run_for(loop, 10_000_000));
    }
}

test "timeout: PENDING, then exactly one OK callback; submissions validate their arguments" {
    var loop: ?*ZaioLoop = null;
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(null, &loop));
    defer _ = zaio_loop_destroy(loop);

    var seen: Seen = .{};
    var c: ZaioCompletion = undefined;
    try testing.expectEqual(ZaioStatus.pending, zaio_timeout(loop, 1_000_000, &c, Seen.cb, &seen));
    try runUntil(loop, &seen);
    try testing.expectEqual(@as(u32, 1), seen.calls);
    try testing.expectEqual(ZaioStatus.ok, seen.status);

    try testing.expectEqual(ZaioStatus.invalid, zaio_timeout(null, 1, &c, Seen.cb, &seen));
    try testing.expectEqual(ZaioStatus.invalid, zaio_timeout(loop, 1, null, Seen.cb, &seen));
    try testing.expectEqual(ZaioStatus.invalid, zaio_timeout(loop, 1, &c, null, &seen));
    try testing.expectEqual(ZaioStatus.invalid, zaio_timeout(loop, std.math.maxInt(u64), &c, Seen.cb, &seen));
    try testing.expectEqual(ZaioStatus.invalid, zaio_accept(loop, invalid_socket, &c, Seen.cb, &seen));
    try testing.expectEqual(ZaioStatus.invalid, zaio_connect(loop, 3, null, &c, Seen.cb, &seen));
    try testing.expectEqual(ZaioStatus.invalid, zaio_recv(loop, 3, null, 1, &c, Seen.cb, &seen));
    try testing.expectEqual(ZaioStatus.invalid, zaio_send(loop, 3, null, 1, &c, Seen.cb, &seen));
    var sent: usize = 99;
    try testing.expectEqual(ZaioStatus.invalid, zaio_send_now(loop, 3, null, 1, &sent));
    try testing.expectEqual(@as(usize, 0), sent);
    try testing.expectEqual(ZaioStatus.invalid, zaio_send_now(loop, 3, "x", 1, null));
}

test "cancel_all: idempotent; afterwards runs and submissions are CANCELED, no callback runs" {
    var loop: ?*ZaioLoop = null;
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(null, &loop));
    defer _ = zaio_loop_destroy(loop);

    const Never = struct {
        fn cb(_: ?*anyopaque, _: *ZaioCompletion, _: ZaioStatus, _: u64) callconv(.c) void {
            @panic("a callback ran after cancel_all");
        }
    };
    var c: ZaioCompletion = undefined;
    try testing.expectEqual(ZaioStatus.pending, zaio_timeout(loop, 5_000_000, &c, Never.cb, null));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_cancel_all(loop));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_cancel_all(loop));
    try testing.expectEqual(ZaioStatus.canceled, zaio_loop_run_for(loop, 20_000_000));
    try testing.expectEqual(ZaioStatus.canceled, zaio_loop_run(loop));
    try testing.expectEqual(ZaioStatus.canceled, zaio_timeout(loop, 1, &c, Never.cb, null));
    var sock: u64 = 0;
    try testing.expectEqual(ZaioStatus.canceled, zaio_tcp_open(loop, 4, null, &sock));
    try testing.expectEqual(invalid_socket, sock);
    try testing.expectEqual(ZaioStatus.canceled, zaio_udp_open(loop, 4, &sock));
}

test "cancel_all from another thread ends a blocked run_for; from a callback, its run returns CANCELED" {
    var loop: ?*ZaioLoop = null;
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(null, &loop));
    const Never = struct {
        fn cb(_: ?*anyopaque, _: *ZaioCompletion, _: ZaioStatus, _: u64) callconv(.c) void {
            @panic("a callback ran after cancel_all");
        }
    };
    var c: ZaioCompletion = undefined;
    try testing.expectEqual(ZaioStatus.pending, zaio_timeout(loop, 10 * std.time.ns_per_s, &c, Never.cb, null));
    const Canceler = struct {
        fn run(l: ?*ZaioLoop, status: *ZaioStatus) void {
            // Let the main thread get inside run_for first; cancel_all is
            // correct either way, this only makes the cross-thread path likely.
            var spins: u32 = 0;
            while (loopOf(l).?.owner.load(.seq_cst) == 0 and spins < 1_000_000) : (spins += 1) std.atomic.spinLoopHint();
            status.* = zaio_loop_cancel_all(l);
        }
    };
    var cancel_status: ZaioStatus = .pending;
    const thread = try std.Thread.spawn(.{}, Canceler.run, .{ loop, &cancel_status });
    // Bounded by the cancel, not by the 10 s timer or the 5 s run.
    try testing.expectEqual(ZaioStatus.canceled, zaio_loop_run_for(loop, 5 * std.time.ns_per_s));
    thread.join();
    try testing.expectEqual(ZaioStatus.ok, cancel_status);
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_destroy(loop));

    // From a callback: the run that called it back returns CANCELED.
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(null, &loop));
    defer _ = zaio_loop_destroy(loop);
    const FromCallback = struct {
        fn cb(user: ?*anyopaque, _: *ZaioCompletion, _: ZaioStatus, _: u64) callconv(.c) void {
            const l: ?*ZaioLoop = @ptrCast(user);
            std.debug.assert(zaio_loop_cancel_all(l) == .ok);
        }
    };
    var first: ZaioCompletion = undefined;
    var second: ZaioCompletion = undefined;
    try testing.expectEqual(ZaioStatus.pending, zaio_timeout(loop, 0, &first, FromCallback.cb, @ptrCast(loop)));
    try testing.expectEqual(ZaioStatus.pending, zaio_timeout(loop, 5 * std.time.ns_per_s, &second, Never.cb, null));
    var spins: u32 = 0;
    while (true) : (spins += 1) {
        const status = zaio_loop_run_for(loop, 10_000_000);
        if (status == .canceled) break;
        try testing.expectEqual(ZaioStatus.ok, status);
        if (spins == 200) return error.TestTimedOut;
    }
}

test "sockets: open validates family and options; udp opens and closes" {
    var loop: ?*ZaioLoop = null;
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(null, &loop));
    defer _ = zaio_loop_destroy(loop);

    var sock: u64 = 0;
    try testing.expectEqual(ZaioStatus.invalid, zaio_tcp_open(loop, 2, null, &sock));
    try testing.expectEqual(invalid_socket, sock);
    try testing.expectEqual(ZaioStatus.invalid, zaio_tcp_open(null, 4, null, &sock));
    try testing.expectEqual(ZaioStatus.invalid, zaio_tcp_open(loop, 4, null, null));
    var opts = std.mem.zeroes(ZaioTcpOptions);
    opts.struct_size = 8;
    try testing.expectEqual(ZaioStatus.invalid, zaio_tcp_open(loop, 4, &opts, &sock));
    opts.struct_size = @sizeOf(ZaioTcpOptions);
    opts.rcvbuf = -1;
    try testing.expectEqual(ZaioStatus.invalid, zaio_tcp_open(loop, 4, &opts, &sock));

    try testing.expectEqual(ZaioStatus.invalid, zaio_udp_open(loop, 0, &sock));
    try testing.expectEqual(ZaioStatus.ok, zaio_udp_open(loop, 4, &sock));
    try testing.expect(sock != invalid_socket);
    try testing.expectEqual(ZaioStatus.ok, zaio_socket_close(loop, sock));
    try testing.expectEqual(ZaioStatus.invalid, zaio_socket_close(loop, invalid_socket));
    try testing.expectEqual(ZaioStatus.invalid, zaio_socket_close(null, 3));
}

test "tcp loopback: accept + connect + send + recv + send_now; close completes a pending recv" {
    var loop: ?*ZaioLoop = null;
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_create(null, &loop));
    defer _ = zaio_loop_destroy(loop);

    var opts = std.mem.zeroes(ZaioTcpOptions);
    opts.struct_size = @sizeOf(ZaioTcpOptions);
    opts.nodelay = 1;
    var listener: u64 = invalid_socket;
    try testing.expectEqual(ZaioStatus.ok, zaio_tcp_open(loop, 4, &opts, &listener));
    defer _ = zaio_socket_close(loop, listener);

    // Listening is the caller's own syscall (zaio exports none); the test uses
    // aio's Zig listen on the same socket.
    var at = std.mem.zeroes(ZaioSockAddr);
    at.struct_size = @sizeOf(ZaioSockAddr);
    at.family = 4;
    at.addr[0..4].* = .{ 127, 0, 0, 1 };
    const bound = try @import("io/common.zig").listen(toSocket(listener).?, toAddress(&at).?, .{ .backlog = 4 });
    at.port = std.mem.bigToNative(u16, bound.in.port);
    try testing.expect(at.port != 0);

    var client: u64 = invalid_socket;
    try testing.expectEqual(ZaioStatus.ok, zaio_tcp_open(loop, 4, &opts, &client));
    defer _ = zaio_socket_close(loop, client);

    var accepted: Seen = .{};
    var connected: Seen = .{};
    var c_accept: ZaioCompletion = undefined;
    var c_connect: ZaioCompletion = undefined;
    try testing.expectEqual(ZaioStatus.pending, zaio_accept(loop, listener, &c_accept, Seen.cb, &accepted));
    try testing.expectEqual(ZaioStatus.pending, zaio_connect(loop, client, &at, &c_connect, Seen.cb, &connected));
    try runUntil(loop, &accepted);
    try runUntil(loop, &connected);
    try testing.expectEqual(ZaioStatus.ok, accepted.status);
    try testing.expectEqual(ZaioStatus.ok, connected.status);
    const server = accepted.value;
    try testing.expect(server != invalid_socket);

    const msg = "zaio loopback";
    var in: [64]u8 = undefined;
    var sent: Seen = .{};
    var got: Seen = .{};
    var c_send: ZaioCompletion = undefined;
    var c_recv: ZaioCompletion = undefined;
    try testing.expectEqual(ZaioStatus.pending, zaio_recv(loop, server, &in, in.len, &c_recv, Seen.cb, &got));
    try testing.expectEqual(ZaioStatus.pending, zaio_send(loop, client, msg, msg.len, &c_send, Seen.cb, &sent));
    try runUntil(loop, &sent);
    try runUntil(loop, &got);
    try testing.expectEqual(ZaioStatus.ok, sent.status);
    try testing.expectEqual(@as(u64, msg.len), sent.value);
    try testing.expectEqual(ZaioStatus.ok, got.status);
    try testing.expectEqualStrings(msg, in[0..@intCast(got.value)]);

    // send_now: Linux takes it without waiting; the other backends always say
    // WOULD_BLOCK (the documented fallback is zaio_send).
    var now: usize = 0;
    const now_status = zaio_send_now(loop, client, msg, msg.len, &now);
    if (is_linux) {
        try testing.expectEqual(ZaioStatus.ok, now_status);
        try testing.expectEqual(msg.len, now);
        var drained: Seen = .{};
        try testing.expectEqual(ZaioStatus.pending, zaio_recv(loop, server, &in, in.len, &c_recv, Seen.cb, &drained));
        try runUntil(loop, &drained);
        try testing.expectEqual(ZaioStatus.ok, drained.status);
    } else {
        try testing.expectEqual(ZaioStatus.would_block, now_status);
        try testing.expectEqual(@as(usize, 0), now);
    }

    // Ending a recv pending on the server socket: CLOSED, or OK with 0 bytes --
    // both mean end of stream. io_uring and IOCP complete it when the socket is
    // closed under it. kqueue does NOT: close() drops the registration and the
    // operation is stranded, so on macOS the caller shuts the socket down
    // first, runs the loop until the operation completes, then closes
    // (include/zaio.h, zaio_socket_close).
    var orphan: Seen = .{};
    try testing.expectEqual(ZaioStatus.pending, zaio_recv(loop, server, &in, in.len, &c_recv, Seen.cb, &orphan));
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_run_for(loop, 30_000_000)); // in the kernel now
    try testing.expectEqual(@as(u32, 0), orphan.calls);
    if (is_darwin) {
        shutdownBoth(toSocket(server).?);
    } else {
        try testing.expectEqual(ZaioStatus.ok, zaio_socket_close(loop, server));
    }
    try runUntil(loop, &orphan);
    try testing.expectEqual(ZaioStatus.ok, zaio_loop_run_for(loop, 20_000_000));
    try testing.expectEqual(@as(u32, 1), orphan.calls); // exactly once
    try testing.expect(orphan.status == .closed or (orphan.status == .ok and orphan.value == 0));
    if (is_darwin) try testing.expectEqual(ZaioStatus.ok, zaio_socket_close(loop, server));
}
