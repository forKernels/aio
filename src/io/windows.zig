//! aio's Windows backend: I/O completion ports.
//!
//! Copied from TigerBeetle with the rest of aio and never built on Zig 0.16 until
//! 2026-09-14. This file is that port.
//!
//! BACKEND CHOICE -- IOCP, not a WSAPoll readiness loop
//! -------------------------------------------------------
//! aio's contract is COMPLETION-based: the caller hands over a buffer and a
//! Completion and is called back with a RESULT (bytes moved, an accepted socket),
//! never with "ready, now do it yourself". io_uring is that model natively;
//! darwin.zig adapts kqueue's readiness to it by retrying the syscall once the fd
//! is ready. Windows' native completion model is IOCP: AcceptEx, ConnectEx, WSARecv
//! and WSASend take an OVERLAPPED and post exactly one packet when the kernel has
//! done the work. That maps one-to-one onto a Completion: no retry loop, no fd_set
//! ceiling, and none of WSAPoll's history (it did not report a refused
//! non-blocking connect until Windows 10 2004).
//!
//! COMPLETION MODEL
//! ----------------
//!   submit()   puts the Completion on `completed`.
//!   flush()    runs it; do_operation starts the overlapped call.
//!                * Synchronous success: sockets are opened with
//!                  FILE_SKIP_COMPLETION_PORT_ON_SUCCESS, so NO packet is queued
//!                  and the callback gets the result now.
//!                * WSA_IO_PENDING: do_operation returns the internal
//!                  error.IoPending. The Completion joins `inflight`,
//!                  `io_pending` counts the one packet the port now owes, and
//!                  nothing is called back.
//!   GetQueuedCompletionStatusEx reaps the packet, the Completion goes back on
//!   `completed`, do_operation runs again, reads the outcome with
//!   WSAGetOverlappedResult, and the callback gets it.
//!
//! TIMEOUTS
//! --------
//! Userland: a queue of absolute deadlines on forTime's monotonic clock (Time).
//! flush() blocks in GetQueuedCompletionStatusEx for at most the nearest deadline,
//! rounded UP to a whole millisecond, so a timer never fires early. The wait's
//! granularity is the system timer tick (~15.6 ms unless some process raises it),
//! so a timeout can fire up to one tick LATE -- never early. Blocking also happens
//! when only timers are pending: waiting on a port with nothing queued is a
//! plain sleep, where returning would make run_for_ns() spin a core.
//!
//! CANCELLATION -- what cancel_all() guarantees, as linux.zig's does
//! -----------------------------------------------------------------
//!   * afterwards no callback runs and no new operation starts;
//!   * it returns only when every overlapped operation the kernel holds has
//!     completed, so no packet can later write into a Completion or a buffer the
//!     caller frees once it returns.
//! Work that never reached the kernel is discarded. Each in-flight operation is
//! aborted with CancelIoEx and its packet -- success or ERROR_OPERATION_ABORTED,
//! the port does not care which -- is reaped and dropped. One pass suffices:
//! requesting cancellation is synchronous, so there is no queued/wait handshake
//! per target as io_uring needs.
//!
//! linux.zig's cancel fix (85d9ffb) is about reading a tagged union's payload
//! inside an assignment to that same union: result-location semantics construct
//! the new value in place, so the read sees the NEW active field. Nothing here
//! assigns a payload-carrying union from its own old value. Cancel state is a
//! plain enum in an atomic. The one read that must precede an overwrite -- an
//! in-flight Completion's handle and OVERLAPPED, taken out of `operation` by
//! `pending_target` -- happens before CancelIoEx and before its packet is reaped,
//! and nothing rewrites `operation` in between. `submit` builds the new operation
//! from the caller's arguments, never from the Completion it overwrites.
//!
//! cancel_all() may run from a callback, from the loop's thread between runs, or
//! from ANOTHER thread while the loop runs -- forNet's Server.stop() is the last.
//! A two-flag handshake makes that safe with no lock on the hot path: flush()
//! publishes its thread id and then re-checks the cancel flag; cancel_all() raises
//! the flag and then waits for any OTHER thread's flush to leave. With both flags
//! sequentially consistent, whichever runs second sees the first.
//!
//! FILE I/O -- positional and synchronous
//! --------------------------------------
//! read/write/fsync use ReadFile / WriteFile with an OVERLAPPED carrying the
//! offset, and FlushFileBuffers. aio does not own these handles: forIO passes
//! std.Io.File handles opened without FILE_FLAG_OVERLAPPED. Associating a foreign
//! handle with the port cannot be undone and would turn every later overlapped
//! call on it, by anyone, into a packet this loop does not expect. The kqueue
//! backend is synchronous for regular files too (a regular file is always ready).
//! A handle its owner DID open overlapped still works: the call returns
//! ERROR_IO_PENDING and is finished with GetOverlappedResult(bWait = TRUE).
//! Sockets go through recv/send, not read/write.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.io);
const posix = std.posix;
const w = std.os.windows;

const common = @import("./common.zig");
const wincompat = @import("./wincompat.zig");
const QueueType = @import("../queue.zig").QueueType;
const Time = @import("../time.zig").Time;
const DirectIO = @import("../io.zig").DirectIO;

/// aio's sockaddr carrier -- the one type every backend and forIO's async_io.zig
/// name (src/aio.zig). This file used to declare its own std.Io.net.IpAddress, a
/// connector rather than a sockaddr, which type-checked against neither
/// common.listen nor forIO's wrapper.
const Address = common.Address;

/// Internal: the overlapped call is in flight and the port owes a packet. Never
/// reaches a callback.
const Pending = error{IoPending};

const DWORD = wincompat.DWORD;
const BOOL = wincompat.BOOL;
const FALSE = wincompat.FALSE;
const TRUE = wincompat.TRUE;

/// The logical sector the Direct-I/O journal (`open_file`) aligns to. This file
/// referenced TigerBeetle's `constants.sector_size`, which aio's constants.zig
/// never carried. 4096 is the largest logical sector of common media, so an
/// alignment to it satisfies FILE_NO_INTERMEDIATE_BUFFERING on 512e and 4Kn
/// drives alike.
pub const sector_size = 4096;

/// AcceptEx writes the local and the remote address into one buffer, each slot
/// needing room for the address plus 16 bytes. A full sockaddr_storage keeps
/// IPv6 listeners working; the old sizing from a 16-byte Address did not.
const accept_address_len: DWORD = @sizeOf(posix.sockaddr.storage) + 16;

pub const IO = struct {
    iocp: wincompat.HANDLE,
    timer: Time = .{},
    /// Overlapped operations started and not yet reaped: the port owes exactly
    /// one packet for each, and each is on `inflight`.
    io_pending: usize = 0,
    timeouts: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_timeouts" }),
    completed: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_completed" }),
    inflight: Inflight = .{},
    cancel_state: std.atomic.Value(CancelState) = .init(.inactive),
    /// Thread id of the thread inside flush(), 0 when none. Thread ids are
    /// never 0 on Windows.
    flushing_thread: std.atomic.Value(DWORD) = .init(0),

    const CancelState = enum(u8) { inactive, requested, done };

    pub fn init(entries: u12, flags: u32) !IO {
        _ = entries;
        _ = flags;

        try ensure_winsock();
        const iocp = try wincompat.CreateIoCompletionPort(wincompat.INVALID_HANDLE_VALUE, null, 0, 0);
        return IO{ .iocp = iocp };
    }

    pub fn deinit(self: *IO) void {
        assert(self.iocp != wincompat.INVALID_HANDLE_VALUE);
        wincompat.CloseHandle(self.iocp);
        self.iocp = wincompat.INVALID_HANDLE_VALUE;
        // No WSACleanup: see ensure_winsock.
    }

    fn canceled(self: *const IO) bool {
        return self.cancel_state.load(.seq_cst) != .inactive;
    }

    /// Run ready completions and poll the port without waiting.
    pub fn tick(self: *IO) !void {
        return self.flush(.non_blocking);
    }

    /// Process pending completions (non-blocking).
    pub fn run(self: *IO) !void {
        return self.flush(.non_blocking);
    }

    pub fn run_for_ns(self: *IO, nanoseconds: u63) !void {
        const Callback = struct {
            fn on_timeout(timed_out: *bool, completion: *Completion, result: TimeoutError!void) void {
                _ = result catch unreachable;
                _ = completion;
                timed_out.* = true;
            }
        };

        var timed_out = false;
        var completion: Completion = undefined;
        self.timeout(*bool, &timed_out, Callback.on_timeout, &completion, nanoseconds);

        while (!timed_out) {
            // After cancel_all() nothing is called back, including the timeout
            // above, so waiting for it would never end.
            if (self.canceled()) return;
            try self.flush(.blocking);
        }
    }

    const FlushMode = enum { blocking, non_blocking };

    fn flush(self: *IO, mode: FlushMode) !void {
        if (self.canceled()) return;
        // Publish, then re-check: see "cancel_all() may run ..." in the header.
        const this_thread = wincompat.GetCurrentThreadId();
        const outer = self.flushing_thread.swap(this_thread, .seq_cst);
        defer self.flushing_thread.store(outer, .seq_cst);
        if (self.canceled()) return;

        if (self.completed.empty()) {
            // Expired timeouts move to `completed`; the rest bound the wait.
            var timeout_ms: ?DWORD = null;
            if (self.flush_timeouts()) |expires_ns| {
                assert(expires_ns != 0);
                // CEILING. Rounding to nearest made a 0.4 ms remainder a 0 ms
                // wait, and the loop spun until the deadline passed.
                const expires_ms = std.math.divCeil(u64, expires_ns, std.time.ns_per_ms) catch unreachable;
                const expires = std.math.cast(DWORD, expires_ms) orelse std.math.maxInt(DWORD);
                // DWORD max is INFINITE, which is not a deadline.
                timeout_ms = if (expires == wincompat.INFINITE) expires - 1 else expires;
            }

            // Wait on the port when nothing is runnable and either a packet is
            // owed or the caller is blocking on a timer.
            const worth_waiting = self.io_pending > 0 or (mode == .blocking and timeout_ms != null);
            if (self.completed.empty() and worth_waiting) {
                const wait_ms: DWORD = switch (mode) {
                    .blocking => timeout_ms orelse @panic("IO.flush blocking unbounded"),
                    .non_blocking => 0,
                };

                var entries: [64]wincompat.OVERLAPPED_ENTRY = undefined;
                const count = wincompat.GetQueuedCompletionStatusEx(self.iocp, &entries, wait_ms, false) catch |err| switch (err) {
                    error.Timeout => 0,
                    else => |e| return e,
                };
                self.reap(entries[0..count], .run);
            }
        }

        // Take the whole ready list first: callbacks may submit more work, and
        // that runs on the next flush rather than extending this one.
        var completed = self.completed;
        self.completed.reset();
        while (completed.pop()) |completion| {
            // cancel_all() from inside an earlier callback: the rest never run.
            if (self.canceled()) return;
            (completion.callback)(.{ .io = self, .completion = completion });
        }
    }

    const Disposition = enum { run, discard };

    /// Account for packets taken off the port.
    fn reap(self: *IO, entries: []const wincompat.OVERLAPPED_ENTRY, disposition: Disposition) void {
        assert(self.io_pending >= entries.len);
        self.io_pending -= entries.len;
        for (entries) |entry| {
            const overlapped: *Completion.Overlapped = @fieldParentPtr("raw", entry.lpOverlapped);
            const completion = overlapped.completion;
            self.inflight.remove(completion);
            switch (disposition) {
                .run => {
                    completion.link = .{};
                    self.completed.push(completion);
                },
                .discard => {},
            }
        }
    }

    fn flush_timeouts(self: *IO) ?u64 {
        var min_expires: ?u64 = null;
        var current_time: ?u64 = null;
        var link: ?*QueueType(Completion).Link = self.timeouts.any.out;

        while (link) |current| {
            const completion: *Completion = @alignCast(@fieldParentPtr("link", current));
            link = current.next; // before remove() clears it

            const now = current_time orelse self.timer.monotonic();
            current_time = now;

            if (now >= completion.operation.timeout.deadline) {
                self.timeouts.remove(completion);
                self.completed.push(completion);
                continue;
            }

            const expires = completion.operation.timeout.deadline - now;
            min_expires = if (min_expires) |min| @min(min, expires) else expires;
        }

        return min_expires;
    }

    /// Cancel should be invoked at most once, before any memory owned by
    /// read/recv buffers is freed (so lingering operations cannot write to it).
    /// A second call is a no-op.
    ///
    /// After it returns:
    /// - no completion callback runs;
    /// - no new IO starts (a later submit is dropped, never called back);
    /// - every overlapped operation the kernel held has completed.
    ///
    /// Safe to call from a completion callback, and from a thread other than
    /// the one running the loop (see the header).
    pub fn cancel_all(self: *IO) void {
        if (self.cancel_state.cmpxchgStrong(.inactive, .requested, .seq_cst, .seq_cst) != null) return;

        // Wait out another thread's flush. Our own (a callback calling us) is
        // already past its last touch of the queues it will look at.
        const this_thread = wincompat.GetCurrentThreadId();
        while (true) {
            const owner = self.flushing_thread.load(.seq_cst);
            if (owner == 0 or owner == this_thread) break;
            wincompat.Sleep(1);
        }

        // Never reached the kernel: nothing to wait for.
        self.completed.reset();
        self.timeouts.reset();

        // Reached it: ask for an abort. ERROR_NOT_FOUND means the operation
        // already finished and its packet is queued; the reap below takes it
        // either way.
        var next = self.inflight.head;
        while (next) |completion| {
            next = completion.inflight_next;
            const target = completion.pending_target();
            _ = wincompat.CancelIoEx(target.handle, target.overlapped);
        }

        // One packet per operation, then nothing the kernel holds can touch
        // caller memory. Unbounded, as linux.zig's is: returning early would
        // hand back buffers the kernel may still write into.
        var entries: [64]wincompat.OVERLAPPED_ENTRY = undefined;
        while (self.io_pending > 0) {
            const count = wincompat.GetQueuedCompletionStatusEx(self.iocp, &entries, null, false) catch |err| switch (err) {
                error.Timeout => 0,
                else => std.debug.panic("IO.cancel_all: GetQueuedCompletionStatusEx: {}", .{err}),
            };
            self.reap(entries[0..count], .discard);
        }
        assert(self.inflight.head == null);

        self.cancel_state.store(.done, .seq_cst);
    }

    /// This struct holds the data needed for a single IO operation.
    pub const Completion = struct {
        link: QueueType(Completion).Link = .{},
        context: ?*anyopaque,
        callback: *const fn (Context) void,
        operation: Operation,
        /// Links on IO.inflight while the port owes this operation a packet.
        inflight_prev: ?*Completion = null,
        inflight_next: ?*Completion = null,

        const Context = struct {
            io: *IO,
            completion: *Completion,
        };

        const Overlapped = struct {
            raw: wincompat.OVERLAPPED,
            completion: *Completion,
        };

        const Transfer = struct {
            socket: socket_t,
            buf: wincompat.WSABUF,
            overlapped: Overlapped,
            pending: bool,
        };

        const Operation = union(enum) {
            accept: struct {
                overlapped: Overlapped,
                listen_socket: socket_t,
                client_socket: socket_t,
                addr_buffer: [2 * accept_address_len]u8,
            },
            connect: struct {
                socket: socket_t,
                address: Address,
                overlapped: Overlapped,
                pending: bool,
            },
            send: Transfer,
            recv: Transfer,
            read: struct {
                fd: fd_t,
                buf: [*]u8,
                len: u32,
                offset: u64,
            },
            write: struct {
                fd: fd_t,
                buf: [*]const u8,
                len: u32,
                offset: u64,
            },
            fsync: struct {
                fd: fd_t,
            },
            close: struct {
                fd: fd_t,
            },
            timeout: struct {
                deadline: u64,
            },
        };

        const Target = struct { handle: wincompat.HANDLE, overlapped: *wincompat.OVERLAPPED };

        /// The handle and OVERLAPPED of an operation the kernel holds. Only
        /// socket operations ever go pending; file IO is synchronous.
        fn pending_target(completion: *Completion) Target {
            return switch (completion.operation) {
                .accept => |*op| .{ .handle = op.listen_socket, .overlapped = &op.overlapped.raw },
                .connect => |*op| .{ .handle = op.socket, .overlapped = &op.overlapped.raw },
                .send, .recv => |*op| .{ .handle = op.socket, .overlapped = &op.overlapped.raw },
                .read, .write, .fsync, .close, .timeout => unreachable,
            };
        }
    };

    /// Intrusive doubly-linked list of in-flight operations, O(1) both ways, so
    /// reaping a packet never walks it.
    const Inflight = struct {
        head: ?*Completion = null,

        fn push(list: *Inflight, completion: *Completion) void {
            assert(completion.inflight_prev == null);
            assert(completion.inflight_next == null);
            assert(list.head != completion);
            completion.inflight_next = list.head;
            if (list.head) |head| head.inflight_prev = completion;
            list.head = completion;
        }

        fn remove(list: *Inflight, completion: *Completion) void {
            if (completion.inflight_prev) |prev| {
                prev.inflight_next = completion.inflight_next;
            } else {
                assert(list.head == completion);
                list.head = completion.inflight_next;
            }
            if (completion.inflight_next) |next| next.inflight_prev = completion.inflight_prev;
            completion.inflight_prev = null;
            completion.inflight_next = null;
        }
    };

    fn submit(
        self: *IO,
        context: anytype,
        comptime callback: anytype,
        completion: *Completion,
        comptime op_tag: std.meta.Tag(Completion.Operation),
        operation: Completion.Operation,
        comptime OperationImpl: type,
    ) void {
        const Result = @typeInfo(@TypeOf(callback)).@"fn".params[2].type.?;
        const ErrorSet = @typeInfo(Result).error_union.error_set;

        const Callback = struct {
            fn on_complete(ctx: Completion.Context) void {
                const data = &@field(ctx.completion.operation, @tagName(op_tag));
                const outcome = OperationImpl.do_operation(ctx, data);

                const result: Result = if (outcome) |value| value else |err| blk: {
                    if (err == error.IoPending) {
                        ctx.io.io_pending += 1;
                        ctx.io.inflight.push(ctx.completion);
                        return;
                    }
                    break :blk @as(ErrorSet, @errorCast(err));
                };

                callback(@ptrCast(@alignCast(ctx.completion.context)), ctx.completion, result);
            }
        };

        // After cancel_all() nothing new starts, and nothing will call back.
        if (self.canceled()) return;

        completion.* = .{
            .context = @ptrCast(context),
            .callback = Callback.on_complete,
            .operation = operation,
        };

        switch (op_tag) {
            .timeout => self.timeouts.push(completion),
            else => self.completed.push(completion),
        }
    }

    pub const TCPOptions = common.TCPOptions;

    pub const socket_t = posix.socket_t;
    pub const INVALID_SOCKET = wincompat.INVALID_SOCKET;
    pub const fd_t = posix.fd_t;
    pub const INVALID_FILE = wincompat.INVALID_HANDLE_VALUE;

    // Error sets mirror io/linux.zig's, member for member, so a consumer that
    // switches exhaustively on one compiles against the other.

    pub const AcceptError = error{
        WouldBlock,
        FileDescriptorInvalid,
        ConnectionAborted,
        SocketNotListening,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        FileDescriptorNotASocket,
        OperationNotSupported,
        PermissionDenied,
        ProtocolFailure,
    } || posix.UnexpectedError;

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: AcceptError!socket_t,
        ) void,
        completion: *Completion,
        socket: socket_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .accept,
            .{ .accept = .{
                .overlapped = undefined,
                .listen_socket = socket,
                .client_socket = INVALID_SOCKET,
                .addr_buffer = undefined,
            } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (AcceptError || Pending)!socket_t {
                    var transferred: DWORD = 0;
                    var flags: DWORD = 0;
                    const resumed = op.client_socket != INVALID_SOCKET;

                    const rc: BOOL = if (!resumed) start: {
                        // AcceptEx takes the accepted socket up front, and it must
                        // be of the LISTENER's family: a fixed AF_INET broke every
                        // IPv6 listener.
                        const family = try socket_family(op.listen_socket);
                        op.client_socket = ctx.io.open_socket(family, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch
                            return switch (wincompat.WSAGetLastError()) {
                                .WSAEMFILE => error.ProcessFdQuotaExceeded,
                                .WSAENOBUFS => error.SystemResources,
                                else => error.Unexpected,
                            };
                        op.overlapped = .{
                            .raw = std.mem.zeroes(wincompat.OVERLAPPED),
                            .completion = ctx.completion,
                        };
                        break :start wincompat.AcceptEx(
                            op.listen_socket,
                            op.client_socket,
                            &op.addr_buffer,
                            0,
                            accept_address_len,
                            accept_address_len,
                            &transferred,
                            &op.overlapped.raw,
                        );
                    } else wincompat.WSAGetOverlappedResult(
                        op.listen_socket,
                        &op.overlapped.raw,
                        &transferred,
                        FALSE,
                        &flags,
                    );

                    if (rc != FALSE) {
                        // An AcceptEx socket inherits nothing from its listener
                        // until told to: without this getsockname, getpeername,
                        // setsockopt and shutdown fail on it. The option's value
                        // is the LISTENING socket; the old call passed null.
                        const listener = op.listen_socket;
                        _ = wincompat.setsockopt(
                            op.client_socket,
                            posix.SOL.SOCKET,
                            posix.SO.UPDATE_ACCEPT_CONTEXT,
                            std.mem.asBytes(&listener),
                            @sizeOf(socket_t),
                        );
                        return op.client_socket;
                    }

                    const code = wincompat.WSAGetLastError();
                    if (code == .WSA_IO_PENDING) return error.IoPending;

                    ctx.io.close_socket(op.client_socket);
                    op.client_socket = INVALID_SOCKET;
                    if (resumed and code == .WSAENOTSOCK) return closed_under_pending_op();
                    return switch (code) {
                        .WSAEWOULDBLOCK => error.WouldBlock,
                        .WSAENOTSOCK => error.FileDescriptorNotASocket,
                        .WSAEOPNOTSUPP => error.OperationNotSupported,
                        .WSAEINVAL => error.SocketNotListening,
                        .WSAECONNRESET, .WSAECONNABORTED => error.ConnectionAborted,
                        .WSAENOBUFS => error.SystemResources,
                        .WSAEMFILE => error.ProcessFdQuotaExceeded,
                        .WSAEACCES => error.PermissionDenied,
                        // The listener was closed under a pending accept.
                        .WSA_OPERATION_ABORTED, .WSA_INVALID_HANDLE => error.FileDescriptorInvalid,
                        else => unexpected_wsa(code),
                    };
                }

                fn socket_family(listener: socket_t) AcceptError!u32 {
                    var storage: posix.sockaddr.storage = undefined;
                    var len: c_int = @sizeOf(posix.sockaddr.storage);
                    if (wincompat.getsockname(listener, &storage, &len) != 0) {
                        return switch (wincompat.WSAGetLastError()) {
                            .WSAENOTSOCK => error.FileDescriptorNotASocket,
                            .WSAEINVAL => error.SocketNotListening, // never bound
                            else => |code| unexpected_wsa(code),
                        };
                    }
                    return storage.family;
                }
            },
        );
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
    } || posix.UnexpectedError;

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .close,
            .{ .close = .{ .fd = fd } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (CloseError || Pending)!void {
                    _ = ctx;
                    // A SOCKET and a file HANDLE share one type and must be closed
                    // differently. getsockopt answers WSAENOTSOCK for anything that
                    // is not a socket.
                    var socket_type: c_int = 0;
                    var len: c_int = @sizeOf(c_int);
                    if (wincompat.getsockopt(op.fd, posix.SOL.SOCKET, posix.SO.TYPE, std.mem.asBytes(&socket_type), &len) == 0) {
                        if (wincompat.closesocket(op.fd) == 0) return;
                        return switch (wincompat.WSAGetLastError()) {
                            .WSAENOTSOCK => error.FileDescriptorInvalid,
                            else => |code| unexpected_wsa(code),
                        };
                    }
                    // Not std's CloseHandle: that asserts success, and a stale
                    // handle is an error to report, not a crash.
                    return switch (w.ntdll.NtClose(op.fd)) {
                        .SUCCESS => {},
                        .INVALID_HANDLE => error.FileDescriptorInvalid,
                        else => |status| w.unexpectedStatus(status),
                    };
                }
            },
        );
    }

    pub const ConnectError = error{
        AccessDenied,
        AddressInUse,
        AddressNotAvailable,
        AddressFamilyNotSupported,
        WouldBlock,
        OpenAlreadyInProgress,
        FileDescriptorInvalid,
        ConnectionRefused,
        ConnectionResetByPeer,
        AlreadyConnected,
        NetworkUnreachable,
        HostUnreachable,
        FileNotFound,
        FileDescriptorNotASocket,
        PermissionDenied,
        ProtocolNotSupported,
        ConnectionTimedOut,
        SystemResources,
    } || posix.UnexpectedError;

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ConnectError!void,
        ) void,
        completion: *Completion,
        socket: socket_t,
        address: Address,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .connect,
            .{ .connect = .{
                .socket = socket,
                .address = address,
                .overlapped = undefined,
                .pending = false,
            } },
            struct {
                const LPFN_CONNECTEX = *const fn (
                    s: socket_t,
                    name: *const posix.sockaddr,
                    namelen: c_int,
                    lpSendBuffer: ?*const anyopaque,
                    dwSendDataLength: DWORD,
                    lpdwBytesSent: ?*DWORD,
                    lpOverlapped: *wincompat.OVERLAPPED,
                ) callconv(.winapi) BOOL;

                fn do_operation(ctx: Completion.Context, op: anytype) (ConnectError || Pending)!void {
                    var transferred: DWORD = 0;
                    var flags: DWORD = 0;
                    const resumed = op.pending;

                    const rc: BOOL = if (resumed) wincompat.WSAGetOverlappedResult(
                        op.socket,
                        &op.overlapped.raw,
                        &transferred,
                        FALSE,
                        &flags,
                    ) else start: {
                        // ConnectEx requires a BOUND socket: the wildcard address
                        // of the target's family, port 0. WSAEINVAL means the caller
                        // bound it already, which satisfies the requirement.
                        var local = std.mem.zeroes(posix.sockaddr.storage);
                        local.family = op.address.any.family;
                        const local_len: c_int = switch (op.address.any.family) {
                            posix.AF.INET => @sizeOf(posix.sockaddr.in),
                            posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
                            else => return error.AddressFamilyNotSupported,
                        };
                        if (wincompat.bind(op.socket, &local, local_len) != 0) {
                            switch (wincompat.WSAGetLastError()) {
                                .WSAEINVAL => {},
                                .WSAEADDRINUSE => return error.AddressInUse,
                                .WSAENOBUFS => return error.SystemResources,
                                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                                .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                                .WSAEACCES => return error.AccessDenied,
                                else => |code| return unexpected_wsa(code),
                            }
                        }

                        // ConnectEx is an extension: its entry point is looked up
                        // per socket, from the socket's provider.
                        var connect_ex: LPFN_CONNECTEX = undefined;
                        var num_bytes: DWORD = 0;
                        const guid = wincompat.WSAID_CONNECTEX;
                        if (wincompat.WSAIoctl(
                            op.socket,
                            wincompat.SIO_GET_EXTENSION_FUNCTION_POINTER,
                            @ptrCast(&guid),
                            @sizeOf(wincompat.GUID),
                            @ptrCast(&connect_ex),
                            @sizeOf(LPFN_CONNECTEX),
                            &num_bytes,
                            null,
                            null,
                        ) == wincompat.SOCKET_ERROR) {
                            return switch (wincompat.WSAGetLastError()) {
                                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                                .WSAEOPNOTSUPP, .WSAEINVAL => error.ProtocolNotSupported,
                                else => |code| unexpected_wsa(code),
                            };
                        }
                        assert(num_bytes == @sizeOf(LPFN_CONNECTEX));

                        op.pending = true;
                        op.overlapped = .{
                            .raw = std.mem.zeroes(wincompat.OVERLAPPED),
                            .completion = ctx.completion,
                        };
                        break :start connect_ex(
                            op.socket,
                            &op.address.any,
                            @intCast(op.address.getOsSockLen()),
                            null,
                            0,
                            &transferred,
                            &op.overlapped.raw,
                        );
                    };

                    if (rc != FALSE) {
                        // Without this getsockname, getpeername, setsockopt and
                        // shutdown fail on a ConnectEx socket. The option takes no
                        // value.
                        const none = [0]u8{};
                        _ = wincompat.setsockopt(op.socket, posix.SOL.SOCKET, posix.SO.UPDATE_CONNECT_CONTEXT, &none, 0);
                        return;
                    }

                    const code = wincompat.WSAGetLastError();
                    if (code == .WSA_IO_PENDING) return error.IoPending;
                    if (resumed and code == .WSAENOTSOCK) return closed_under_pending_op();
                    return switch (code) {
                        .WSAEWOULDBLOCK => error.WouldBlock,
                        .WSAEALREADY => error.OpenAlreadyInProgress,
                        .WSAEISCONN => error.AlreadyConnected,
                        .WSAEADDRINUSE => error.AddressInUse,
                        .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                        .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                        .WSAECONNREFUSED => error.ConnectionRefused,
                        .WSAECONNRESET, .WSAECONNABORTED => error.ConnectionResetByPeer,
                        .WSAEHOSTUNREACH, .WSAEHOSTDOWN => error.HostUnreachable,
                        .WSAENETUNREACH => error.NetworkUnreachable,
                        .WSAENOBUFS => error.SystemResources,
                        .WSAENOTSOCK => error.FileDescriptorNotASocket,
                        .WSAETIMEDOUT => error.ConnectionTimedOut,
                        .WSAEACCES => error.AccessDenied,
                        .WSA_OPERATION_ABORTED, .WSA_INVALID_HANDLE => error.FileDescriptorInvalid,
                        else => unexpected_wsa(code),
                    };
                }
            },
        );
    }

    pub const FsyncError = error{
        FileDescriptorInvalid,
        InputOutput,
    } || posix.UnexpectedError;

    pub fn fsync(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: FsyncError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .fsync,
            .{ .fsync = .{ .fd = fd } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (FsyncError || Pending)!void {
                    _ = ctx;
                    return file_io.flush(op.fd);
                }
            },
        );
    }

    pub const OpenatError = posix.OpenError || posix.UnexpectedError;

    pub const ReadError = error{
        WouldBlock,
        NotOpenForReading,
        ConnectionResetByPeer,
        Alignment,
        InputOutput,
        IsDir,
        SystemResources,
        Unseekable,
        ConnectionTimedOut,
    } || posix.UnexpectedError;

    pub fn read(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ReadError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .read,
            .{ .read = .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = transfer_len(buffer.len),
                .offset = offset,
            } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (ReadError || Pending)!usize {
                    _ = ctx;
                    return file_io.pread(op.fd, op.buf[0..op.len], op.offset);
                }
            },
        );
    }

    pub const WriteError = error{
        WouldBlock,
        NotOpenForWriting,
        NotConnected,
        DiskQuota,
        FileTooBig,
        Alignment,
        InputOutput,
        NoSpaceLeft,
        Unseekable,
        AccessDenied,
        BrokenPipe,
    } || posix.UnexpectedError;

    pub fn write(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: WriteError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []const u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .write,
            .{ .write = .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = transfer_len(buffer.len),
                .offset = offset,
            } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (WriteError || Pending)!usize {
                    _ = ctx;
                    return file_io.pwrite(op.fd, op.buf[0..op.len], op.offset);
                }
            },
        );
    }

    pub const RecvError = error{
        WouldBlock,
        FileDescriptorInvalid,
        ConnectionRefused,
        SystemResources,
        SocketNotConnected,
        FileDescriptorNotASocket,
        ConnectionResetByPeer,
        ConnectionTimedOut,
        OperationNotSupported,
    } || posix.UnexpectedError;

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .recv,
            .{ .recv = .{
                .socket = socket,
                .buf = .{ .len = transfer_len(buffer.len), .buf = buffer.ptr },
                .overlapped = undefined,
                .pending = false,
            } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (RecvError || Pending)!usize {
                    var transferred: DWORD = 0;
                    var flags: DWORD = 0; // in and out
                    const resumed = op.pending;

                    const rc: BOOL = if (resumed) wincompat.WSAGetOverlappedResult(
                        op.socket,
                        &op.overlapped.raw,
                        &transferred,
                        FALSE,
                        &flags,
                    ) else start: {
                        op.pending = true;
                        op.overlapped = .{
                            .raw = std.mem.zeroes(wincompat.OVERLAPPED),
                            .completion = ctx.completion,
                        };
                        break :start if (wincompat.WSARecv(
                            op.socket,
                            @ptrCast(&op.buf),
                            1,
                            &transferred,
                            &flags,
                            &op.overlapped.raw,
                            null,
                        ) == 0) TRUE else FALSE;
                    };

                    // 0 bytes is an orderly shutdown by the peer, as on POSIX.
                    if (rc != FALSE) return transferred;

                    const code = wincompat.WSAGetLastError();
                    if (code == .WSA_IO_PENDING) return error.IoPending;
                    if (resumed and code == .WSAENOTSOCK) return closed_under_pending_op();
                    return switch (code) {
                        // A datagram longer than the buffer: the buffer is full and
                        // the rest is discarded, which a POSIX recv reports as a
                        // short read rather than an error.
                        .WSAEMSGSIZE => transferred,
                        // Graceful close on a message-oriented socket.
                        .WSAEDISCON => 0,
                        .WSAEWOULDBLOCK => error.WouldBlock,
                        .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => error.ConnectionResetByPeer,
                        .WSAECONNREFUSED => error.ConnectionRefused,
                        .WSAENOTCONN, .WSAESHUTDOWN => error.SocketNotConnected,
                        .WSAETIMEDOUT => error.ConnectionTimedOut,
                        .WSAENOBUFS => error.SystemResources,
                        .WSAENOTSOCK => error.FileDescriptorNotASocket,
                        .WSAEOPNOTSUPP => error.OperationNotSupported,
                        // The socket was closed under a pending receive.
                        .WSA_OPERATION_ABORTED, .WSA_INVALID_HANDLE => error.FileDescriptorInvalid,
                        else => unexpected_wsa(code),
                    };
                }
            },
        );
    }

    pub const SendError = error{
        AccessDenied,
        WouldBlock,
        FastOpenAlreadyInProgress,
        AddressFamilyNotSupported,
        FileDescriptorInvalid,
        ConnectionResetByPeer,
        MessageTooBig,
        SystemResources,
        SocketNotConnected,
        FileDescriptorNotASocket,
        OperationNotSupported,
        BrokenPipe,
        ConnectionTimedOut,
        ConnectionRefused,
    } || posix.UnexpectedError;

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []const u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .send,
            .{ .send = .{
                .socket = socket,
                // WSABUF is shared by send and receive, hence the mutable
                // pointer; WSASend never writes through it.
                .buf = .{ .len = transfer_len(buffer.len), .buf = @constCast(buffer.ptr) },
                .overlapped = undefined,
                .pending = false,
            } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (SendError || Pending)!usize {
                    var transferred: DWORD = 0;
                    var flags: DWORD = 0;
                    const resumed = op.pending;

                    const rc: BOOL = if (resumed) wincompat.WSAGetOverlappedResult(
                        op.socket,
                        &op.overlapped.raw,
                        &transferred,
                        FALSE,
                        &flags,
                    ) else start: {
                        op.pending = true;
                        op.overlapped = .{
                            .raw = std.mem.zeroes(wincompat.OVERLAPPED),
                            .completion = ctx.completion,
                        };
                        break :start if (wincompat.WSASend(
                            op.socket,
                            @ptrCast(&op.buf),
                            1,
                            &transferred,
                            0,
                            &op.overlapped.raw,
                            null,
                        ) == 0) TRUE else FALSE;
                    };

                    if (rc != FALSE) return transferred;

                    const code = wincompat.WSAGetLastError();
                    if (code == .WSA_IO_PENDING) return error.IoPending;
                    if (resumed and code == .WSAENOTSOCK) return closed_under_pending_op();
                    return switch (code) {
                        .WSAEWOULDBLOCK => error.WouldBlock,
                        .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => error.ConnectionResetByPeer,
                        .WSAEMSGSIZE => error.MessageTooBig,
                        .WSAENOBUFS => error.SystemResources,
                        .WSAENOTCONN => error.SocketNotConnected,
                        .WSAESHUTDOWN => error.BrokenPipe,
                        .WSAENOTSOCK => error.FileDescriptorNotASocket,
                        .WSAEOPNOTSUPP => error.OperationNotSupported,
                        .WSAEACCES => error.AccessDenied,
                        .WSAETIMEDOUT => error.ConnectionTimedOut,
                        // The socket was closed under a pending send.
                        .WSA_OPERATION_ABORTED, .WSA_INVALID_HANDLE => error.FileDescriptorInvalid,
                        else => unexpected_wsa(code),
                    };
                }
            },
        );
    }

    /// Best effort to hand bytes to the kernel without waiting; null means "use
    /// send()", which is what null means on every backend.
    ///
    /// ALWAYS null on Windows, deliberately -- as on Darwin. Winsock has no
    /// per-call MSG_DONTWAIT. The alternatives each break something a caller can
    /// see: FIONBIO would make the socket non-blocking for EVERY user of it (forNet
    /// hands aio sockets to stream-handler threads that write blocking), and an
    /// overlapped WSASend that goes pending cannot be taken back, so a buffer the
    /// caller believes unsent would still go out -- or be written from after the
    /// caller freed it.
    pub fn send_now(_: *IO, socket: socket_t, buffer: []const u8) ?usize {
        _ = socket;
        _ = buffer;
        return null;
    }

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: TimeoutError!void,
        ) void,
        completion: *Completion,
        nanoseconds: u63,
    ) void {
        // A zero timeout is a yield: it runs on the next flush.
        if (nanoseconds == 0) {
            if (self.canceled()) return;
            completion.* = .{
                .context = @ptrCast(context),
                .operation = undefined,
                .callback = struct {
                    fn on_complete(ctx: Completion.Context) void {
                        const _context: Context = @ptrCast(@alignCast(ctx.completion.context));
                        callback(_context, ctx.completion, {});
                    }
                }.on_complete,
            };
            self.completed.push(completion);
            return;
        }

        self.submit(
            context,
            callback,
            completion,
            .timeout,
            .{ .timeout = .{ .deadline = self.timer.monotonic() + nanoseconds } },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) (TimeoutError || Pending)!void {
                    _ = ctx;
                    _ = op;
                }
            },
        );
    }

    /// Creates a TCP socket with options.
    pub fn open_socket_tcp(self: *IO, family: u32, options: TCPOptions) !socket_t {
        const fd = try self.open_socket(family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        errdefer self.close_socket(fd);
        try common.tcp_options(fd, options);
        return fd;
    }

    /// Creates a UDP socket.
    pub fn open_socket_udp(self: *IO, family: u32) !socket_t {
        return self.open_socket(family, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    }

    /// Bind and listen on a TCP socket (synchronous). Returns the resolved
    /// address, which names the real port when `address` asked for port 0.
    pub fn listen(_: *IO, fd: socket_t, address: Address, options: common.ListenOptions) !Address {
        return common.listen(fd, address, options);
    }

    /// Creates a socket that can be used for async operations with the IO
    /// instance: overlapped, not inheritable, bound to this port.
    pub fn open_socket(self: *IO, family: u32, sock_type: u32, protocol: u32) !socket_t {
        const socket = try wincompat.WSASocketW(
            @bitCast(family),
            @bitCast(sock_type),
            @bitCast(protocol),
            null,
            0,
            wincompat.WSA_FLAG_OVERLAPPED | wincompat.WSA_FLAG_NO_HANDLE_INHERIT,
        );
        errdefer self.close_socket(socket);

        const port = try wincompat.CreateIoCompletionPort(socket, self.iocp, 0, 0);
        assert(port == self.iocp);

        // A synchronous success queues no packet (the backend delivers it
        // directly), and no one waits on the handle's event.
        try wincompat.SetFileCompletionNotificationModes(
            socket,
            wincompat.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS | wincompat.FILE_SKIP_SET_EVENT_ON_HANDLE,
        );

        return socket;
    }

    /// Closes a socket opened by the IO instance.
    pub fn close_socket(self: *IO, socket: socket_t) void {
        _ = self;
        wincompat.closeSocket(socket);
    }

    /// Opens a directory with read-only access, for `open_file`'s dir_handle.
    pub fn open_dir(dir_path: []const u8) !fd_t {
        var path_w: [wincompat.PATH_MAX_WIDE:0]u16 = undefined;
        // UTF-16 never needs more units than WTF-8 has bytes.
        if (dir_path.len > wincompat.PATH_MAX_WIDE) return error.NameTooLong;
        const len = try std.unicode.wtf8ToWtf16Le(&path_w, dir_path);
        path_w[len] = 0;

        const handle = wincompat.CreateFileW(
            &path_w,
            wincompat.GENERIC_READ | wincompat.FILE_TRAVERSE,
            wincompat.FILE_SHARE_READ | wincompat.FILE_SHARE_WRITE | wincompat.FILE_SHARE_DELETE,
            null,
            wincompat.OPEN_EXISTING,
            // Required to open a directory at all.
            wincompat.FILE_FLAG_BACKUP_SEMANTICS,
            null,
        );
        if (handle == wincompat.INVALID_HANDLE_VALUE) {
            return switch (w.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
                .DIRECTORY => error.NotDir,
                else => |err| w.unexpectedError(err),
            };
        }
        return handle;
    }

    fn open_file_handle(
        dir_handle: fd_t,
        relative_path: []const u8,
        method: enum { create, open, open_read_only },
    ) !fd_t {
        var name_w: [wincompat.PATH_MAX_WIDE]u16 = undefined;
        const name = try nt_name(&name_w, relative_path);

        switch (method) {
            .create => log.info("creating \"{s}\"...", .{relative_path}),
            .open, .open_read_only => log.info("opening \"{s}\"...", .{relative_path}),
        }

        // O_RDWR, or O_RDONLY for open_read_only. SYNCHRONIZE is required by
        // FILE_SYNCHRONOUS_IO_NONALERT.
        var access: DWORD = wincompat.SYNCHRONIZE | wincompat.GENERIC_READ;
        if (method != .open_read_only) access |= wincompat.GENERIC_WRITE;

        // O_DIRECT | O_DSYNC, as NT create options: FILE_NO_INTERMEDIATE_BUFFERING
        // | FILE_WRITE_THROUGH. We rely on write-through for durability of every
        // write, as O_DSYNC does elsewhere.
        const options: w.ULONG = wincompat.FILE_NON_DIRECTORY_FILE |
            wincompat.FILE_SYNCHRONOUS_IO_NONALERT |
            wincompat.FILE_NO_INTERMEDIATE_BUFFERING |
            wincompat.FILE_WRITE_THROUGH;

        var unicode = w.UNICODE_STRING{
            .Length = @intCast(name.path.len * 2),
            .MaximumLength = @intCast(name.path.len * 2),
            .Buffer = name.path.ptr,
        };
        const attributes = w.OBJECT.ATTRIBUTES{
            .RootDirectory = if (name.absolute) null else dir_handle,
            .ObjectName = &unicode,
            // Exact-case lookup, as the original passed 0.
            .Attributes = .{ .CASE_INSENSITIVE = false },
        };

        var handle: w.HANDLE = undefined;
        var io_status: w.IO_STATUS_BLOCK = undefined;
        while (true) {
            const status = w.ntdll.NtCreateFile(
                &handle,
                @bitCast(access),
                &attributes,
                &io_status,
                null,
                @bitCast(@as(w.ULONG, wincompat.FILE_ATTRIBUTE_NORMAL)),
                @bitCast(@as(w.ULONG, 0)), // no sharing: O_EXCL
                if (method == .create) .CREATE else .OPEN,
                @bitCast(options),
                null,
                0,
            );
            switch (status) {
                .SUCCESS => return handle,
                .OBJECT_NAME_INVALID => return error.BadPathName,
                .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
                .BAD_NETWORK_PATH, .BAD_NETWORK_NAME => return error.NetworkNotFound,
                .NO_MEDIA_IN_DEVICE => return error.NoDevice,
                .SHARING_VIOLATION, .ACCESS_DENIED, .USER_MAPPED_FILE => return error.AccessDenied,
                .PIPE_BUSY => return error.PipeBusy,
                .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
                .FILE_IS_A_DIRECTORY => return error.IsDir,
                .NOT_A_DIRECTORY => return error.NotDir,
                .DELETE_PENDING => {
                    // A file was here and is being deleted; the name frees once
                    // the last handle to it closes.
                    wincompat.Sleep(1);
                    continue;
                },
                else => return w.unexpectedStatus(status),
            }
        }
    }

    const NtName = struct { path: []u16, absolute: bool };

    /// `path` as an NT object name. A relative path is opened against the
    /// directory handle, where NT wants it bare; an absolute one needs the
    /// `\??\` (or `\??\UNC\`) namespace prefix. NT does not accept `/`.
    fn nt_name(buffer: *[wincompat.PATH_MAX_WIDE]u16, path: []const u8) !NtName {
        const absolute = std.fs.path.isAbsoluteWindows(path);
        const unc = absolute and path.len >= 2 and is_sep(path[0]) and is_sep(path[1]);
        const prefix = if (!absolute) "" else if (unc) "\\??\\UNC" else "\\??\\";
        const body = if (unc) path[1..] else path;

        if (prefix.len + body.len > buffer.len) return error.NameTooLong;
        for (prefix, 0..) |c, i| buffer[i] = c;
        const len = prefix.len + try std.unicode.wtf8ToWtf16Le(buffer[prefix.len..], body);
        for (buffer[prefix.len..len]) |*c| {
            if (c.* == '/') c.* = '\\';
        }
        return .{ .path = buffer[0..len], .absolute = absolute };
    }

    fn is_sep(c: u8) bool {
        return c == '\\' or c == '/';
    }

    /// Opens or creates a journal file:
    /// - For reading and writing (read-only for .open_read_only).
    /// - For Direct I/O (required on Windows).
    /// - Obtains an advisory exclusive lock to the file descriptor.
    /// - Allocates the file contiguously on disk if the file system supports it.
    /// - Ensures that the file data is durable on disk.
    ///   The caller is responsible for ensuring that the parent directory inode is durable.
    /// - Verifies that the file size matches the expected file size before returning.
    ///
    /// Buffers read or written through the returned handle must be aligned to
    /// `sector_size`, at offsets that are multiples of it: Direct I/O.
    pub fn open_file(
        dir_handle: fd_t,
        relative_path: []const u8,
        size: u64,
        method: enum { create, create_or_open, open, open_read_only },
        direct_io: DirectIO,
    ) !fd_t {
        assert(relative_path.len > 0);
        assert(size >= sector_size);
        assert(size % sector_size == 0);
        // On Windows Direct I/O is always available.
        _ = direct_io;

        const handle = switch (method) {
            .open => try open_file_handle(dir_handle, relative_path, .open),
            .open_read_only => try open_file_handle(dir_handle, relative_path, .open_read_only),
            .create => try open_file_handle(dir_handle, relative_path, .create),
            .create_or_open => open_file_handle(dir_handle, relative_path, .open) catch |err| switch (err) {
                error.FileNotFound => try open_file_handle(dir_handle, relative_path, .create),
                else => return err,
            },
        };
        errdefer wincompat.CloseHandle(handle);

        // An advisory exclusive lock, even though no other process was given
        // shared access.
        fs_lock(handle, size) catch |err| switch (err) {
            error.WouldBlock => @panic("another process holds the data file lock"),
            else => return err,
        };

        // The file was just created (possibly by create_or_open): allocate it.
        const created = (wincompat.getFileSize(handle) catch 0) == 0 and method != .open and method != .open_read_only;
        if (created) {
            log.info("allocating {d} bytes...", .{size});
            fs_allocate(handle, size) catch {
                log.warn("file system failed to preallocate the file memory", .{});
                log.info("allocating by writing to the last sector of the file instead...", .{});

                const sector: [sector_size]u8 align(sector_size) = @splat(0);
                // Handle partial writes where the physical sector is less than a
                // logical sector.
                const write_offset = size - sector.len;
                var written: usize = 0;
                while (written < sector.len) {
                    written += try file_io.pwrite(handle, sector[written..], write_offset + written);
                }
            };
        }

        // Always fsync before reading: it stops decisions being made on data a
        // crashed process never durably wrote, and waits out any pending
        // write-through. FlushFileBuffers needs GENERIC_WRITE, which a read-only
        // handle does not carry; there is nothing of ours to flush through it.
        if (method != .open_read_only) try file_io.flush(handle);

        // The directory handle cannot be fsynced on Windows: a directory cannot
        // be opened with write access.

        const file_size = try wincompat.getFileSize(handle);
        if (file_size < size) @panic("data file inode size was truncated or corrupted");

        return handle;
    }

    fn fs_lock(handle: fd_t, size: u64) !void {
        var overlapped = std.mem.zeroes(wincompat.OVERLAPPED); // lock from offset 0
        if (wincompat.LockFileEx(
            handle,
            wincompat.LOCKFILE_EXCLUSIVE_LOCK | wincompat.LOCKFILE_FAIL_IMMEDIATELY,
            0,
            @truncate(size),
            @truncate(size >> 32),
            &overlapped,
        ) == FALSE) {
            return switch (w.GetLastError()) {
                // FAIL_IMMEDIATELY on a synchronous handle reports a held lock as
                // LOCK_VIOLATION; IO_PENDING is the overlapped-handle spelling.
                .LOCK_VIOLATION, .IO_PENDING => error.WouldBlock,
                else => |err| w.unexpectedError(err),
            };
        }
    }

    fn fs_allocate(handle: fd_t, size: u64) !void {
        // Move the file pointer to start + size and mark it end of file.
        if (wincompat.SetFilePointerEx(handle, @intCast(size), null, wincompat.FILE_BEGIN) == FALSE) {
            return w.unexpectedError(w.GetLastError());
        }
        if (wincompat.SetEndOfFile(handle) == FALSE) {
            return switch (w.GetLastError()) {
                .DISK_FULL, .HANDLE_DISK_FULL => error.NoSpaceLeft,
                else => |err| w.unexpectedError(err),
            };
        }
    }
};

var winsock_started = std.atomic.Value(bool).init(false);

/// WSAStartup once per process, never paired with WSACleanup -- the policy
/// forNet's sock.ensureWinsock already follows.
///
/// Pairing them per IO was expensive and dangerous. A WSACleanup that takes
/// Winsock's reference count to zero unloads the providers, and the next
/// WSAStartup reloads them. Measured on the winX86 build machine (200 pairs,
/// forTime clock): median 4.3 ms, min 2.1 ms, max 16.6 ms per pair, against ~0
/// with one reference held and ~1 us for the completion port itself. aio's
/// IO.init/deinit benchmark (min < 500 us) failed on exactly that once its clock
/// was real. And a socket can outlive the IO that opened it; tearing Winsock down
/// under it is the worse failure.
fn ensure_winsock() !void {
    if (winsock_started.load(.acquire)) return;
    try wincompat.WSAStartup(2, 2);
    // Two first callers racing each take a count; the loser returns its own, so
    // the process holds exactly one.
    if (winsock_started.swap(true, .acq_rel)) wincompat.WSACleanup() catch {};
}

/// Winsock transfer lengths are 32-bit.
fn transfer_len(len: usize) u32 {
    return @intCast(@min(len, std.math.maxInt(u32)));
}

/// The socket was a socket when its overlapped operation started, and the
/// packet has now come back -- but WSAGetOverlappedResult validates the handle
/// BEFORE it reports the operation's own status, so a socket closed under the
/// operation answers WSAENOTSOCK rather than the WSA_OPERATION_ABORTED the
/// kernel recorded. Either way the descriptor is gone: FileDescriptorInvalid, the
/// same answer io_uring gives for a closed fd (EBADF).
fn closed_under_pending_op() error{FileDescriptorInvalid} {
    return error.FileDescriptorInvalid;
}

fn unexpected_wsa(code: wincompat.WinsockError) error{Unexpected} {
    log.debug("unexpected Winsock error {d}", .{@intFromEnum(code)});
    return error.Unexpected;
}

/// Positional, synchronous file IO. See "FILE I/O" in the header for why aio
/// does not bind caller-owned file handles to its port.
const file_io = struct {
    fn overlapped_at(offset: u64) wincompat.OVERLAPPED {
        var overlapped = std.mem.zeroes(wincompat.OVERLAPPED);
        overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME = .{
            .Offset = @truncate(offset),
            .OffsetHigh = @truncate(offset >> 32),
        };
        return overlapped;
    }

    fn pread(fd: IO.fd_t, buffer: []u8, offset: u64) IO.ReadError!usize {
        var overlapped = overlapped_at(offset);
        var transferred: DWORD = 0;
        if (wincompat.ReadFile(fd, buffer.ptr, transfer_len(buffer.len), &transferred, &overlapped) != FALSE) {
            return transferred;
        }
        var err = w.GetLastError();
        if (err == .IO_PENDING) {
            // The owner opened this handle FILE_FLAG_OVERLAPPED.
            if (wincompat.GetOverlappedResult(fd, &overlapped, &transferred, TRUE) != FALSE) return transferred;
            err = w.GetLastError();
        }
        return switch (err) {
            .HANDLE_EOF, .BROKEN_PIPE => 0,
            .ACCESS_DENIED, .INVALID_HANDLE => error.NotOpenForReading,
            // Direct I/O with a buffer or offset off the sector boundary.
            .INVALID_PARAMETER => error.Alignment,
            .NOT_ENOUGH_MEMORY, .NO_SYSTEM_RESOURCES, .WORKING_SET_QUOTA => error.SystemResources,
            .IO_DEVICE, .CRC, .LOCK_VIOLATION, .OPERATION_ABORTED => error.InputOutput,
            else => w.unexpectedError(err),
        };
    }

    fn pwrite(fd: IO.fd_t, buffer: []const u8, offset: u64) IO.WriteError!usize {
        var overlapped = overlapped_at(offset);
        var transferred: DWORD = 0;
        if (wincompat.WriteFile(fd, buffer.ptr, transfer_len(buffer.len), &transferred, &overlapped) != FALSE) {
            return transferred;
        }
        var err = w.GetLastError();
        if (err == .IO_PENDING) {
            if (wincompat.GetOverlappedResult(fd, &overlapped, &transferred, TRUE) != FALSE) return transferred;
            err = w.GetLastError();
        }
        return switch (err) {
            .ACCESS_DENIED, .INVALID_HANDLE => error.NotOpenForWriting,
            .INVALID_PARAMETER => error.Alignment,
            .DISK_FULL, .HANDLE_DISK_FULL => error.NoSpaceLeft,
            .DISK_QUOTA_EXCEEDED => error.DiskQuota,
            .FILE_TOO_LARGE => error.FileTooBig,
            .BROKEN_PIPE, .NO_DATA => error.BrokenPipe,
            .LOCK_VIOLATION => error.AccessDenied,
            .IO_DEVICE, .CRC, .OPERATION_ABORTED, .NOT_ENOUGH_MEMORY, .NO_SYSTEM_RESOURCES => error.InputOutput,
            else => w.unexpectedError(err),
        };
    }

    fn flush(fd: IO.fd_t) IO.FsyncError!void {
        if (wincompat.FlushFileBuffers(fd) != FALSE) return;
        return switch (w.GetLastError()) {
            .INVALID_HANDLE, .ACCESS_DENIED => error.FileDescriptorInvalid,
            .IO_DEVICE, .CRC, .DISK_FULL, .HANDLE_DISK_FULL => error.InputOutput,
            else => |err| w.unexpectedError(err),
        };
    }
};
