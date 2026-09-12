//! darwin_posix.zig — the 0.15.2 / 0.16 seam for aio's kqueue backend.
//!
//! zigcompat.zig covers the LINUX half of 0.16's std.posix removals and says so
//! in its own header: "Only the Linux paths are covered — darwin.zig and
//! windows.zig are comptime-pruned here and I have no machine to test them on."
//! This file is that missing half, written and built on the machine that was
//! missing.
//!
//! WHY A NAMESPACE RATHER THAN 89 EDITS. darwin.zig opens with
//! `const posix = std.posix;` and then calls `posix.<thing>` 89 times. Only the
//! alias changes; every call site keeps the shape it already had. Rewriting the
//! call sites instead would touch 89 lines to express one decision, and each
//! rewritten line is a place to get an errno mapping subtly wrong.
//!
//! WHY std.c AND NOT THE ADVERTISED REPLACEMENTS. Every 0.16 replacement for
//! these calls wants an `Io` threaded down from `main` — std.Io.File, Io.Dir,
//! Io.Clock. aio is a library reached from forIO, which is reached from Fortran
//! and from C, and never sees a Zig `main` at all, so an `Io` is unavailable by
//! construction rather than by inconvenience. `std.posix.system` still resolves
//! to `std.c` when libc is linked, which it is here, so the bodies below are the
//! 0.15.2 std.posix bodies with their original errno switches intact.
//!
//! THE MAPPINGS ARE PORTED, NOT INVENTED. Each switch below is copied from
//! 0.15.2's std.posix, which is still installed, because the event loop treats
//! specific errors as control flow rather than failure: darwin.zig requeues onto
//! io_pending when it sees error.WouldBlock. Collapsing these to one error per
//! call — the shape zigcompat.zig's Linux arm uses, where nothing switches on
//! them — would turn a would-block into a hard failure and stall the loop.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const zig16 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

// ── decls that survived 0.16 — passed straight through ─────────────────────
// darwin.zig reaches for these through the same `posix.` alias, so they have to
// exist here even though nothing about them changed.

pub const E = posix.E;
pub const F = posix.F;
pub const FD_CLOEXEC = posix.FD_CLOEXEC;
pub const IPPROTO = posix.IPPROTO;
pub const Kevent = posix.Kevent;
pub const LOCK = posix.LOCK;
pub const O = posix.O;
pub const OpenError = posix.OpenError;
pub const SHUT = posix.SHUT;
pub const SO = posix.SO;
pub const SOCK = posix.SOCK;
pub const SOL = posix.SOL;
pub const SetSockOptError = posix.SetSockOptError;
pub const Stat = posix.Stat;
pub const SyncError = posix.SyncError;
pub const UnexpectedError = posix.UnexpectedError;
pub const errno = posix.errno;
pub const fd_t = posix.fd_t;
pub const mode_t = posix.mode_t;
pub const off_t = posix.off_t;
pub const openat = posix.openat;
pub const setsockopt = posix.setsockopt;
pub const socket_t = posix.socket_t;
pub const system = posix.system;
pub const timespec = posix.timespec;
pub const unexpectedErrno = posix.unexpectedErrno;

// ── error sets 0.16 deleted along with their functions ─────────────────────
// Reproduced rather than aliased: on 0.16 there is nothing left to alias to.
// The member lists are 0.15.2's, so a `catch |err| switch (err)` in darwin.zig
// still sees every arm it was written against.

pub const KQueueError = if (zig16) error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || UnexpectedError else posix.KQueueError;

pub const KEventError = if (zig16) error{
    AccessDenied,
    EventNotFound,
    ProcessNotFound,
    SystemResources,
    Overflow,
} else posix.KEventError;

pub const SocketError = if (zig16) error{
    PermissionDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
} || UnexpectedError else posix.SocketError;

pub const ConnectError = if (zig16) error{
    AccessDenied,
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    WouldBlock,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    NetworkUnreachable,
    ConnectionTimedOut,
    FileNotFound,
} || UnexpectedError else posix.ConnectError;

pub const AcceptError = if (zig16) error{
    WouldBlock,
    ConnectionAborted,
    SocketNotListening,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    OperationNotSupported,
    ProtocolFailure,
    BlockedByFirewall,
    ConnectionResetByPeer,
    NetworkSubsystemFailed,
} || UnexpectedError else posix.AcceptError;

pub const ShutdownError = if (zig16) error{
    ConnectionAborted,
    ConnectionResetByPeer,
    BlockingOperationInProgress,
    NetworkSubsystemFailed,
    SocketNotConnected,
    SystemResources,
} || UnexpectedError else posix.ShutdownError;

pub const ShutdownHow = if (zig16) enum { recv, send, both } else posix.ShutdownHow;

pub const FlockError = if (zig16) error{
    WouldBlock,
    FileLocksNotSupported,
    SystemResources,
} || UnexpectedError else posix.FlockError;

pub const FcntlError = if (zig16) error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
} || UnexpectedError else posix.FcntlError;

pub const FStatError = if (zig16) error{
    SystemResources,
    AccessDenied,
} || UnexpectedError else posix.FStatError;

pub const TruncateError = if (zig16) error{
    FileTooBig,
    InputOutput,
    FileBusy,
    AccessDenied,
    PermissionDenied,
} || UnexpectedError else posix.TruncateError;

pub const PWriteError = if (zig16) error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    PermissionDenied,
    BrokenPipe,
    Unseekable,
    AccessDenied,
    NotOpenForWriting,
} || UnexpectedError else posix.PWriteError;

pub const RecvFromError = if (zig16) error{
    WouldBlock,
    SystemResources,
    ConnectionRefused,
    ConnectionResetByPeer,
    SocketNotConnected,
    SocketNotBound,
    MessageTooBig,
    NetworkSubsystemFailed,
    ConnectionTimedOut,
} || UnexpectedError else posix.RecvFromError;

pub const SendError = if (zig16) error{
    AccessDenied,
    WouldBlock,
    FastOpenAlreadyInProgress,
    ConnectionResetByPeer,
    MessageTooBig,
    SystemResources,
    BrokenPipe,
    NetworkSubsystemFailed,
    NetworkUnreachable,
    ConnectionTimedOut,
} || UnexpectedError else posix.SendError;

// ── the calls themselves ───────────────────────────────────────────────────
// Each 0.16 arm is 0.15.2's body with `system.` left as it was. `.INTR =>
// continue` is preserved everywhere it appeared: a signal arriving mid-syscall
// is not a failure, and returning one to an event loop turns a stray SIGCHLD
// into a dropped connection.

pub fn close(fd: fd_t) void {
    if (!zig16) return posix.close(fd);
    switch (errno(system.close(fd))) {
        .BADF => unreachable, // Always a race condition.
        .INTR => return, // Still a success; see ziglang/zig#2425.
        else => return,
    }
}

pub fn kqueue() KQueueError!i32 {
    if (!zig16) return posix.kqueue();
    const rc = system.kqueue();
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn kevent(
    kq: i32,
    changelist: []const Kevent,
    eventlist: []Kevent,
    timeout: ?*const timespec,
) KEventError!usize {
    if (!zig16) return posix.kevent(kq, changelist, eventlist, timeout);
    while (true) {
        const rc = system.kevent(
            kq,
            changelist.ptr,
            std.math.cast(c_int, changelist.len) orelse return error.Overflow,
            eventlist.ptr,
            std.math.cast(c_int, eventlist.len) orelse return error.Overflow,
            timeout,
        );
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.AccessDenied,
            .FAULT => unreachable,
            .BADF => unreachable, // Always a race condition.
            .INTR => continue,
            .INVAL => unreachable,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            .SRCH => return error.ProcessNotFound,
            else => unreachable,
        }
    }
}

/// Darwin's socket(2) rejects SOCK.NONBLOCK and SOCK.CLOEXEC, so 0.15.2 masks
/// them off and then applies them with fcntl on the returned descriptor. BOTH
/// halves are load-bearing. Masking without applying hands back a BLOCKING
/// socket, and the first accept(2) on it blocks the whole event loop forever
/// rather than returning EAGAIN for the loop to requeue on. That is not a
/// theoretical failure: it is what this shim did until aio's own test
/// "accept function updated for Darwin" hung in __accept and a stack sample
/// showed where.
fn setSockFlags(sock: socket_t, flags: u32) FcntlError!void {
    if ((flags & SOCK.CLOEXEC) != 0) {
        var fd_flags = try fcntl(sock, F.GETFD, 0);
        fd_flags |= FD_CLOEXEC;
        _ = try fcntl(sock, F.SETFD, fd_flags);
    }
    if ((flags & SOCK.NONBLOCK) != 0) {
        var fl_flags = try fcntl(sock, F.GETFL, 0);
        fl_flags |= 1 << @bitOffsetOf(O, "NONBLOCK");
        _ = try fcntl(sock, F.SETFL, fl_flags);
    }
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) (SocketError || FcntlError)!socket_t {
    if (!zig16) return posix.socket(domain, socket_type, protocol);
    const filtered = socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC);
    const rc = system.socket(domain, filtered, protocol);
    switch (errno(rc)) {
        .SUCCESS => {
            const fd: socket_t = @intCast(rc);
            // The fd exists before the fallible fcntl pair; without this a
            // failed SETFL leaks it for the life of the process.
            errdefer close(fd);
            try setSockFlags(fd, socket_type);
            return fd;
        },
        .ACCES => return error.PermissionDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn connect(sock: socket_t, sock_addr: *const posix.sockaddr, len: posix.socklen_t) ConnectError!void {
    if (!zig16) return posix.connect(sock, sock_addr, len);
    while (true) {
        switch (errno(system.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable, // Socket address outside the process address space.
            .INTR => continue,
            .ISCONN => unreachable, // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // fd does not refer to a socket.
            .PROTOTYPE => unreachable, // Socket type does not support this protocol.
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound, // AF.UNIX path does not exist.
            .CONNABORTED => unreachable, // Reused a socket that saw ConnectionRefused.
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// The pending error on a socket that finished connecting asynchronously. The
/// outer switch is the getsockopt call; the inner one is the error it fetched,
/// which is the value the connect actually failed with.
pub fn getsockoptError(sockfd: fd_t) ConnectError!void {
    if (!zig16) return posix.getsockoptError(sockfd);
    var err_code: i32 = undefined;
    var size: u32 = @sizeOf(u32);
    const rc = system.getsockopt(sockfd, SOL.SOCKET, SO.ERROR, @ptrCast(&err_code), &size);
    std.debug.assert(size == 4);
    switch (errno(rc)) {
        .SUCCESS => switch (@as(E, @enumFromInt(err_code))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .FAULT => unreachable,
            .ISCONN => unreachable, // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable,
            .PROTOTYPE => unreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |err| return unexpectedErrno(err),
        },
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOPROTOOPT => unreachable,
        .NOTSOCK => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn shutdown(sock: socket_t, how: ShutdownHow) ShutdownError!void {
    if (!zig16) return posix.shutdown(sock, how);
    const rc = system.shutdown(sock, switch (how) {
        .recv => SHUT.RD,
        .send => SHUT.WR,
        .both => SHUT.RDWR,
    });
    switch (errno(rc)) {
        .SUCCESS => return,
        .BADF => unreachable,
        .INVAL => unreachable,
        .NOTCONN => return error.SocketNotConnected,
        .NOTSOCK => unreachable,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    if (!zig16) return posix.fcntl(fd, cmd, arg);
    while (true) {
        const rc = system.fcntl(fd, cmd, arg);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable, // invalid parameters
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable, // invalid parameter
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn flock(fd: fd_t, operation: i32) FlockError!void {
    if (!zig16) return posix.flock(fd, operation);
    while (true) {
        const rc = system.flock(fd, operation);
        switch (errno(rc)) {
            .SUCCESS => return,
            .BADF => unreachable,
            .INTR => continue,
            .INVAL => unreachable, // invalid parameters
            .NOLCK => return error.SystemResources,
            .AGAIN => return error.WouldBlock,
            .OPNOTSUPP => return error.FileLocksNotSupported,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn fstat(fd: fd_t) FStatError!Stat {
    if (!zig16) return posix.fstat(fd);
    var stat = std.mem.zeroes(Stat);
    switch (errno(system.fstat(fd, &stat))) {
        .SUCCESS => return stat,
        .INVAL => unreachable,
        .BADF => unreachable, // Always a race condition.
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn fsync(fd: fd_t) SyncError!void {
    if (!zig16) return posix.fsync(fd);
    switch (errno(system.fsync(fd))) {
        .SUCCESS => return,
        .BADF, .INVAL, .ROFS => unreachable,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .DQUOT => return error.DiskQuota,
        else => |err| return unexpectedErrno(err),
    }
}

/// Takes u64 to match 0.15.2's signature; the negative check is 0.15.2's and
/// exists so an oversized length surfaces as FileTooBig instead of an EINVAL
/// that could have come from three other causes.
pub fn ftruncate(fd: fd_t, length: u64) TruncateError!void {
    if (!zig16) return posix.ftruncate(fd, length);
    const signed_len: i64 = @bitCast(length);
    if (signed_len < 0) return error.FileTooBig;
    while (true) {
        switch (errno(system.ftruncate(fd, signed_len))) {
            .SUCCESS => return,
            .INTR => continue,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .PERM => return error.PermissionDenied,
            .TXTBSY => return error.FileBusy,
            .BADF, .INVAL => unreachable,
            .ACCES => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// 0.16 removed `openZ` as well as `open`, so the NUL-terminated half is
/// inlined here rather than delegated. `toPosixPath` survived and does the
/// length check, so a path too long for the stack buffer still surfaces as
/// NameTooLong instead of truncating into the wrong file.
pub fn open(file_path: []const u8, flags: O, perm: mode_t) OpenError!fd_t {
    if (!zig16) return posix.open(file_path, flags, perm);
    const path_c = try posix.toPosixPath(file_path);
    while (true) {
        const rc = system.open(&path_c, flags, perm);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .FAULT => unreachable,
            .INVAL => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .FBIG, .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.ProcessNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn pwrite(fd: fd_t, bytes: []const u8, offset: u64) PWriteError!usize {
    if (!zig16) return posix.pwrite(fd, bytes, offset);
    if (bytes.len == 0) return 0;
    const signed_offset: i64 = @bitCast(offset);
    while (true) {
        const rc = system.pwrite(fd, bytes.ptr, bytes.len, signed_offset);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => unreachable,
            .BADF => return error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .NXIO => return error.Unseekable,
            .SPIPE => return error.Unseekable,
            .OVERFLOW => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn recv(sock: socket_t, buf: []u8, flags: u32) RecvFromError!usize {
    if (!zig16) return posix.recv(sock, buf, flags);
    while (true) {
        const rc = system.recv(sock, buf.ptr, buf.len, @intCast(flags));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => unreachable, // always a race condition
            .FAULT => unreachable,
            .INVAL => unreachable,
            .NOTCONN => return error.SocketNotConnected,
            .NOTSOCK => unreachable,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .NOMEM => return error.SystemResources,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn send(sock: socket_t, buf: []const u8, flags: u32) SendError!usize {
    if (!zig16) return posix.send(sock, buf, flags);
    while (true) {
        const rc = system.send(sock, buf.ptr, buf.len, flags);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .BADF => unreachable, // always a race condition
            .CONNRESET => return error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable, // not connection-mode, no peer set
            .FAULT => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .ISCONN => unreachable,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTSOCK => unreachable,
            .PIPE => return error.BrokenPipe,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .NETDOWN => return error.NetworkSubsystemFailed,
            else => |err| return unexpectedErrno(err),
        }
    }
}
