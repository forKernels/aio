//! Windows backend (io/windows.zig) tests against the real kernel: loopback
//! sockets, timers, cancellation, positional file IO and the Direct-I/O
//! journal. Imported by src/aio.zig only when the target is Windows, so Linux
//! and Darwin test counts are unchanged.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const posix = std.posix;

const aio = @import("../aio.zig");
const IO = aio.IO;
const Address = aio.Address;
const wincompat = @import("../io/wincompat.zig");

comptime {
    std.debug.assert(builtin.os.tag == .windows);
}

const tcp_defaults: IO.TCPOptions = .{
    .rcvbuf = 0,
    .sndbuf = 0,
    .keepalive = null,
    .user_timeout_ms = 0,
    .nodelay = false,
};

fn loopback(port: u16) Address {
    var address: Address = undefined;
    const in: *posix.sockaddr.in = @ptrCast(&address.any);
    in.* = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    return address;
}

fn port_of(address: Address) u16 {
    const in: *const posix.sockaddr.in = @ptrCast(&address.any);
    return std.mem.bigToNative(u16, in.port);
}

/// Drive the loop until `done` holds, bounded so a broken backend fails the
/// test instead of hanging it.
fn run_until(io: *IO, comptime Ctx: type, ctx: *Ctx, comptime done: fn (*Ctx) bool) !void {
    var rounds: usize = 0;
    while (!done(ctx)) : (rounds += 1) {
        if (rounds > 2_000) return error.TestTimedOut;
        try io.run_for_ns(5 * std.time.ns_per_ms);
    }
}

test "windows: timeouts fire in deadline order, and run_for_ns waits rather than spins" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    const Ctx = struct {
        order: [3]u8 = undefined,
        count: usize = 0,

        const Self = @This();

        fn tag(comptime id: u8) fn (*Self, *IO.Completion, IO.TimeoutError!void) void {
            return struct {
                fn cb(ctx: *Self, _: *IO.Completion, result: IO.TimeoutError!void) void {
                    result catch unreachable;
                    ctx.order[ctx.count] = id;
                    ctx.count += 1;
                }
            }.cb;
        }
    };
    var ctx: Ctx = .{};
    var c30: IO.Completion = undefined;
    var c10: IO.Completion = undefined;
    var c0: IO.Completion = undefined;

    const start = io.timer.monotonic();
    io.timeout(*Ctx, &ctx, Ctx.tag(30), &c30, 30 * std.time.ns_per_ms);
    io.timeout(*Ctx, &ctx, Ctx.tag(10), &c10, 10 * std.time.ns_per_ms);
    io.timeout(*Ctx, &ctx, Ctx.tag(0), &c0, 0);

    try io.run_for_ns(80 * std.time.ns_per_ms);
    const elapsed = io.timer.monotonic() - start;

    try testing.expectEqual(@as(usize, 3), ctx.count);
    try testing.expectEqualSlices(u8, &.{ 0, 10, 30 }, &ctx.order);
    // Never early.
    try testing.expect(elapsed >= 80 * std.time.ns_per_ms);
    // And not wildly late (generous: a loaded CI box and a 15.6 ms tick).
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
}

const Loopback = struct {
    io: IO,
    listener: IO.socket_t,
    port: u16,

    fn open() !Loopback {
        var io = try IO.init(32, 0);
        errdefer io.deinit();
        const listener = try io.open_socket_tcp(posix.AF.INET, tcp_defaults);
        errdefer io.close_socket(listener);
        const bound = try io.listen(listener, loopback(0), .{ .backlog = 4 });
        return .{ .io = io, .listener = listener, .port = port_of(bound) };
    }

    fn close(self: *Loopback) void {
        self.io.close_socket(self.listener);
        self.io.deinit();
    }
};

const Pair = struct {
    accepted: ?IO.socket_t = null,
    accept_err: ?IO.AcceptError = null,
    connected: bool = false,
    connect_err: ?IO.ConnectError = null,

    fn on_accept(self: *Pair, _: *IO.Completion, result: IO.AcceptError!IO.socket_t) void {
        if (result) |socket| self.accepted = socket else |err| self.accept_err = err;
    }
    fn on_connect(self: *Pair, _: *IO.Completion, result: IO.ConnectError!void) void {
        if (result) |_| self.connected = true else |err| self.connect_err = err;
    }
    fn done(self: *Pair) bool {
        return (self.accepted != null or self.accept_err != null) and
            (self.connected or self.connect_err != null);
    }
};

/// Accept + connect over loopback through aio. Returns (server side, client side).
fn connect_pair(lb: *Loopback) ![2]IO.socket_t {
    const client = try lb.io.open_socket_tcp(posix.AF.INET, tcp_defaults);
    errdefer lb.io.close_socket(client);

    var pair: Pair = .{};
    var accept_completion: IO.Completion = undefined;
    var connect_completion: IO.Completion = undefined;
    lb.io.accept(*Pair, &pair, Pair.on_accept, &accept_completion, lb.listener);
    lb.io.connect(*Pair, &pair, Pair.on_connect, &connect_completion, client, loopback(lb.port));
    try run_until(&lb.io, Pair, &pair, Pair.done);

    if (pair.accept_err) |err| return err;
    if (pair.connect_err) |err| return err;
    try testing.expect(pair.connected);
    return .{ pair.accepted.?, client };
}

const Transfer = struct {
    sent: ?usize = null,
    received: ?usize = null,
    send_err: ?IO.SendError = null,
    recv_err: ?IO.RecvError = null,

    fn on_send(self: *Transfer, _: *IO.Completion, result: IO.SendError!usize) void {
        if (result) |n| self.sent = n else |err| self.send_err = err;
    }
    fn on_recv(self: *Transfer, _: *IO.Completion, result: IO.RecvError!usize) void {
        if (result) |n| self.received = n else |err| self.recv_err = err;
    }
    fn done(self: *Transfer) bool {
        return (self.sent != null or self.send_err != null) and
            (self.received != null or self.recv_err != null);
    }
    fn received_or_failed(self: *Transfer) bool {
        return self.received != null or self.recv_err != null;
    }
};

test "windows: loopback accept, connect, send and recv both ways, then orderly close" {
    var lb = try Loopback.open();
    defer lb.close();

    const sockets = try connect_pair(&lb);
    const server = sockets[0];
    const client = sockets[1];
    var server_open = true;
    defer if (server_open) lb.io.close_socket(server);
    defer lb.io.close_socket(client);

    // The accepted socket inherited its listener's context: getsockname works.
    var local: posix.sockaddr.storage = undefined;
    var local_len: c_int = @sizeOf(posix.sockaddr.storage);
    try testing.expectEqual(@as(c_int, 0), wincompat.getsockname(server, &local, &local_len));

    var send_c: IO.Completion = undefined;
    var recv_c: IO.Completion = undefined;
    var buffer: [16]u8 = undefined;

    // Receive posted FIRST, so it goes pending and completes through the port.
    var ping: Transfer = .{};
    lb.io.recv(*Transfer, &ping, Transfer.on_recv, &recv_c, server, &buffer);
    try lb.io.run(); // starts the overlapped receive
    try testing.expect(lb.io.io_pending >= 1);
    lb.io.send(*Transfer, &ping, Transfer.on_send, &send_c, client, "ping");
    try run_until(&lb.io, Transfer, &ping, Transfer.done);
    try testing.expectEqual(@as(?usize, 4), ping.sent);
    try testing.expectEqual(@as(?usize, 4), ping.received);
    try testing.expectEqualStrings("ping", buffer[0..4]);

    var pong: Transfer = .{};
    lb.io.send(*Transfer, &pong, Transfer.on_send, &send_c, server, "pong!");
    lb.io.recv(*Transfer, &pong, Transfer.on_recv, &recv_c, client, &buffer);
    try run_until(&lb.io, Transfer, &pong, Transfer.done);
    try testing.expectEqual(@as(?usize, 5), pong.received);
    try testing.expectEqualStrings("pong!", buffer[0..5]);

    // Peer closes: a pending receive completes with 0 bytes, as on POSIX.
    var eof: Transfer = .{};
    lb.io.recv(*Transfer, &eof, Transfer.on_recv, &recv_c, client, &buffer);
    try lb.io.run();
    lb.io.close_socket(server);
    server_open = false;
    try run_until(&lb.io, Transfer, &eof, Transfer.received_or_failed);
    try testing.expectEqual(@as(?IO.RecvError, null), eof.recv_err);
    try testing.expectEqual(@as(?usize, 0), eof.received);
    try testing.expectEqual(@as(usize, 0), lb.io.io_pending);
}

test "windows: many connects on one IO -- SO_UPDATE_CONNECT_CONTEXT after each ConnectEx" {
    // forIO's loopback benchmark faulted at address 0x1 inside MSWSOCK on its
    // second connect: the option value was a zero-length array, whose address
    // Zig is free to make 0x1, and Winsock reads through the pointer even with
    // a length of 0. One connect per test (above) did not expose it.
    var lb = try Loopback.open();
    defer lb.close();
    for (0..64) |_| {
        const sockets = try connect_pair(&lb);
        // The context update took effect: getpeername-class calls work.
        var peer: posix.sockaddr.storage = undefined;
        var peer_len: c_int = @sizeOf(posix.sockaddr.storage);
        try testing.expectEqual(@as(c_int, 0), wincompat.getsockname(sockets[1], &peer, &peer_len));
        lb.io.close_socket(sockets[1]);
        lb.io.close_socket(sockets[0]);
    }
}

test "windows: connect to a closed port reports ConnectionRefused" {
    // Find a port nothing listens on: bind, read it back, close.
    var lb = try Loopback.open();
    const dead_port = lb.port;
    lb.close();

    var io = try IO.init(32, 0);
    defer io.deinit();
    const client = try io.open_socket_tcp(posix.AF.INET, tcp_defaults);
    defer io.close_socket(client);

    var pair: Pair = .{ .accept_err = error.Unexpected }; // no accept side
    var completion: IO.Completion = undefined;
    io.connect(*Pair, &pair, Pair.on_connect, &completion, client, loopback(dead_port));
    try run_until(&io, Pair, &pair, Pair.done);
    try testing.expectEqual(@as(?IO.ConnectError, error.ConnectionRefused), pair.connect_err);
}

test "windows: a socket closed under a pending recv reports FileDescriptorInvalid, not a crash" {
    var lb = try Loopback.open();
    defer lb.close();
    const sockets = try connect_pair(&lb);
    defer lb.io.close_socket(sockets[1]);

    var buffer: [8]u8 = undefined;
    var t: Transfer = .{};
    var recv_c: IO.Completion = undefined;
    lb.io.recv(*Transfer, &t, Transfer.on_recv, &recv_c, sockets[0], &buffer);
    try lb.io.run();
    try testing.expectEqual(@as(usize, 1), lb.io.io_pending);

    lb.io.close_socket(sockets[0]);
    try run_until(&lb.io, Transfer, &t, Transfer.received_or_failed);
    try testing.expectEqual(@as(?IO.RecvError, error.FileDescriptorInvalid), t.recv_err);
    try testing.expectEqual(@as(usize, 0), lb.io.io_pending);
}

test "windows: cancel_all aborts pending IO, drops queued work, calls nothing back" {
    var lb = try Loopback.open();
    defer lb.close();
    const sockets = try connect_pair(&lb);
    defer lb.io.close_socket(sockets[0]);
    defer lb.io.close_socket(sockets[1]);

    const Never = struct {
        called: usize = 0,
        fn on_recv(self: *@This(), _: *IO.Completion, _: IO.RecvError!usize) void {
            self.called += 1;
        }
        fn on_accept(self: *@This(), _: *IO.Completion, _: IO.AcceptError!IO.socket_t) void {
            self.called += 1;
        }
        fn on_timeout(self: *@This(), _: *IO.Completion, _: IO.TimeoutError!void) void {
            self.called += 1;
        }
    };
    var never: Never = .{};
    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    var r0: IO.Completion = undefined;
    var r1: IO.Completion = undefined;
    var acc: IO.Completion = undefined;
    var tmo: IO.Completion = undefined;
    var queued: IO.Completion = undefined;

    // Three operations the kernel holds: two receives and an accept.
    lb.io.recv(*Never, &never, Never.on_recv, &r0, sockets[0], &b0);
    lb.io.recv(*Never, &never, Never.on_recv, &r1, sockets[1], &b1);
    lb.io.accept(*Never, &never, Never.on_accept, &acc, lb.listener);
    try lb.io.run();
    try testing.expectEqual(@as(usize, 3), lb.io.io_pending);
    // One timer and one operation that never reached the kernel.
    lb.io.timeout(*Never, &never, Never.on_timeout, &tmo, std.time.ns_per_s);
    lb.io.recv(*Never, &never, Never.on_recv, &queued, sockets[0], &b0);

    lb.io.cancel_all();
    try testing.expectEqual(@as(usize, 0), lb.io.io_pending);
    try testing.expectEqual(@as(usize, 0), never.called);

    // Idempotent, and the loop is inert afterwards: nothing starts, nothing fires.
    lb.io.cancel_all();
    lb.io.timeout(*Never, &never, Never.on_timeout, &tmo, 0);
    try lb.io.run();
    try lb.io.run_for_ns(10 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 0), never.called);
}

test "windows: cancel_all from another thread while the loop is running" {
    var lb = try Loopback.open();
    defer lb.close();
    const sockets = try connect_pair(&lb);
    defer lb.io.close_socket(sockets[0]);
    defer lb.io.close_socket(sockets[1]);

    const Loop = struct {
        io: *IO,
        called: std.atomic.Value(usize) = .init(0),
        exited: std.atomic.Value(bool) = .init(false),
        buffer: [8]u8 = undefined,
        completion: IO.Completion = undefined,

        fn on_recv(self: *@This(), _: *IO.Completion, _: IO.RecvError!usize) void {
            _ = self.called.fetchAdd(1, .seq_cst);
        }
        fn run(self: *@This()) void {
            // run_for_ns returns once cancel_all has been requested.
            while (!self.exited.load(.seq_cst)) {
                self.io.run_for_ns(2 * std.time.ns_per_ms) catch break;
                if (self.io.cancel_state.load(.seq_cst) == .done) break;
            }
            self.exited.store(true, .seq_cst);
        }
    };
    var loop: Loop = .{ .io = &lb.io };
    lb.io.recv(*Loop, &loop, Loop.on_recv, &loop.completion, sockets[0], &loop.buffer);

    const thread = try std.Thread.spawn(.{}, Loop.run, .{&loop});
    // Let it get into GetQueuedCompletionStatusEx with the receive pending.
    var spins: usize = 0;
    while (lb.io.io_pending == 0) : (spins += 1) {
        if (spins > 10_000) return error.TestTimedOut;
        wincompat.Sleep(1);
    }

    lb.io.cancel_all();
    thread.join();

    try testing.expect(loop.exited.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), loop.called.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), lb.io.io_pending);
}

/// A scratch file in %TEMP%, named per process so parallel runs do not collide.
/// Returns the WHOLE path, NUL-terminated: directory from GetTempPathA, then the
/// name printed after it.
fn temp_path(buf: []u8, comptime stem: []const u8) ![:0]const u8 {
    const k32 = struct {
        extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
        extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    };
    const n = k32.GetTempPathA(@intCast(buf.len), buf.ptr);
    if (n == 0 or n >= buf.len) return error.NoTempDir;
    const name = std.fmt.bufPrintZ(buf[n..], stem ++ "-{d}.dat", .{k32.GetCurrentProcessId()}) catch
        return error.NameTooLong;
    return buf[0 .. n + name.len :0];
}

const k32file = struct {
    extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?*anyopaque) callconv(.winapi) wincompat.HANDLE;
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) wincompat.BOOL;
    const CREATE_ALWAYS = 2;
};

const FileOps = struct {
    written: ?usize = null,
    read_n: ?usize = null,
    synced: bool = false,
    closed: bool = false,
    err: ?anyerror = null,

    fn on_write(self: *FileOps, _: *IO.Completion, result: IO.WriteError!usize) void {
        if (result) |n| self.written = n else |e| self.err = e;
    }
    fn on_read(self: *FileOps, _: *IO.Completion, result: IO.ReadError!usize) void {
        if (result) |n| self.read_n = n else |e| self.err = e;
    }
    fn on_fsync(self: *FileOps, _: *IO.Completion, result: IO.FsyncError!void) void {
        if (result) |_| self.synced = true else |e| self.err = e;
    }
    fn on_close(self: *FileOps, _: *IO.Completion, result: IO.CloseError!void) void {
        if (result) |_| self.closed = true else |e| self.err = e;
    }
    fn all_done(self: *FileOps) bool {
        return self.err != null or (self.written != null and self.read_n != null and self.synced);
    }
    fn close_done(self: *FileOps) bool {
        return self.err != null or self.closed;
    }
};

test "windows: positional write, read, fsync and close on a caller-owned file handle" {
    var name_buf: [512]u8 = undefined;
    const name_z = (try temp_path(&name_buf, "aio-win-file")).ptr;

    // A plain synchronous handle, as forIO's std.Io.File hands aio.
    const handle = k32file.CreateFileA(name_z, wincompat.GENERIC_READ | wincompat.GENERIC_WRITE, 0, null, k32file.CREATE_ALWAYS, wincompat.FILE_ATTRIBUTE_NORMAL, null);
    try testing.expect(handle != wincompat.INVALID_HANDLE_VALUE);
    defer _ = k32file.DeleteFileA(name_z);

    var io = try IO.init(32, 0);
    defer io.deinit();

    var ops: FileOps = .{};
    var wc: IO.Completion = undefined;
    var rc: IO.Completion = undefined;
    var fc: IO.Completion = undefined;
    var cc: IO.Completion = undefined;
    var buffer: [5]u8 = undefined;

    // Past the end: offsets are honoured, not the file pointer.
    io.write(*FileOps, &ops, FileOps.on_write, &wc, handle, "hello", 70_000);
    io.fsync(*FileOps, &ops, FileOps.on_fsync, &fc, handle);
    try io.run();
    io.read(*FileOps, &ops, FileOps.on_read, &rc, handle, &buffer, 70_000);
    try run_until(&io, FileOps, &ops, FileOps.all_done);
    if (ops.err) |err| return err;
    try testing.expectEqual(@as(?usize, 5), ops.written);
    try testing.expectEqual(@as(?usize, 5), ops.read_n);
    try testing.expectEqualStrings("hello", &buffer);

    // Reading at end of file is 0 bytes, not an error.
    ops.read_n = null;
    io.read(*FileOps, &ops, FileOps.on_read, &rc, handle, &buffer, 70_005);
    try run_until(&io, FileOps, &ops, FileOps.all_done);
    try testing.expectEqual(@as(?usize, 0), ops.read_n);

    // close() tells a file HANDLE from a SOCKET and closes it the right way.
    io.close(*FileOps, &ops, FileOps.on_close, &cc, handle);
    try run_until(&io, FileOps, &ops, FileOps.close_done);
    if (ops.err) |err| return err;
    try testing.expect(ops.closed);
}

test "windows: open_dir + open_file Direct-I/O journal: create, aligned write/read, reopen" {
    var dir_buf: [512]u8 = undefined;
    const k32 = struct {
        extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
        extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    };
    const dir_len = k32.GetTempPathA(@intCast(dir_buf.len), &dir_buf);
    try testing.expect(dir_len > 0 and dir_len < dir_buf.len);
    const dir_path = dir_buf[0..dir_len];

    var file_buf: [64]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_buf, "aio-win-journal-{d}.dat", .{k32.GetCurrentProcessId()});

    var full_buf: [600]u8 = undefined;
    const full = try std.fmt.bufPrintZ(&full_buf, "{s}{s}", .{ dir_path, file_name });
    defer _ = k32file.DeleteFileA(full.ptr);

    const dir = try IO.open_dir(dir_path);
    defer wincompat.CloseHandle(dir);

    const size = 16 * aio_windows.sector_size;
    const journal = try IO.open_file(dir, file_name, size, .create_or_open, .direct_io_optional);

    var io = try IO.init(32, 0);
    defer io.deinit();

    var sector: [aio_windows.sector_size]u8 align(aio_windows.sector_size) = undefined;
    for (&sector, 0..) |*b, i| b.* = @truncate(i *% 31);
    var readback: [aio_windows.sector_size]u8 align(aio_windows.sector_size) = undefined;

    var ops: FileOps = .{};
    var wc: IO.Completion = undefined;
    var rc: IO.Completion = undefined;
    var fc: IO.Completion = undefined;
    io.write(*FileOps, &ops, FileOps.on_write, &wc, journal, &sector, 3 * aio_windows.sector_size);
    io.fsync(*FileOps, &ops, FileOps.on_fsync, &fc, journal);
    try io.run();
    io.read(*FileOps, &ops, FileOps.on_read, &rc, journal, &readback, 3 * aio_windows.sector_size);
    try run_until(&io, FileOps, &ops, FileOps.all_done);
    if (ops.err) |err| return err;
    try testing.expectEqual(@as(?usize, aio_windows.sector_size), ops.read_n);
    try testing.expectEqualSlices(u8, &sector, &readback);

    // Misaligned Direct I/O is reported, not silently buffered.
    var small: [100]u8 = undefined;
    ops = .{};
    io.read(*FileOps, &ops, FileOps.on_read, &rc, journal, &small, 1);
    try run_until(&io, FileOps, &ops, FileOps.all_done);
    try testing.expectEqual(@as(?anyerror, error.Alignment), ops.err);

    // The exclusive lock is held: a second open_file of the same journal from
    // this process would panic by design, so only reopen after closing.
    wincompat.CloseHandle(journal);
    const reopened = try IO.open_file(dir, file_name, size, .open, .direct_io_optional);
    wincompat.CloseHandle(reopened);
}

const aio_windows = @import("../io/windows.zig");
