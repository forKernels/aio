const std = @import("std");
const IO = @import("../aio.zig").IO;
const Time = @import("../aio.zig").Time;

test "basic IO initialization" {
    const testing = std.testing;

    var io = try IO.init(32, 0);
    defer io.deinit();

    try testing.expect(true);
}

test "basic Time functionality" {
    const testing = std.testing;

    var timer = Time{};
    const start_time = timer.monotonic();

    try testing.expect(start_time > 0);
}

test "accept function updated for Darwin" {
    const builtin = @import("builtin");
    const posix = std.posix;

    // Only test on Darwin since the update was specific to Darwin
    if (!builtin.target.os.tag.isDarwin()) return;

    var io = try IO.init(32, 0);
    defer io.deinit();

    // Create a TCP socket
    const socket = try io.open_socket_tcp(
        posix.AF.INET,
        .{
            .rcvbuf = 0,
            .sndbuf = 0,
            .keepalive = null,
            .user_timeout_ms = 0,
            .nodelay = false,
        },
    );
    defer io.close_socket(socket);

    // Set up socket to listen manually
    var addr: posix.sockaddr = std.mem.zeroes(posix.sockaddr);
    addr.family = posix.AF.INET;
    const addr_bytes = std.mem.asBytes(&addr);
    // Set port to 0 (network byte order) and address to INADDR_ANY
    addr_bytes[2] = 0;
    addr_bytes[3] = 0;
    addr_bytes[4] = 0;
    addr_bytes[5] = 0;
    addr_bytes[6] = 0;
    addr_bytes[7] = 0;

    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try @import("../zigcompat.zig").bind(socket, &addr, @sizeOf(posix.sockaddr));
    try @import("../zigcompat.zig").listen(socket, 1);

    // Test that accept can be called - this verifies the updated accept implementation
    // The update specifically uses posix.system.accept() for Darwin instead of accept4()
    var accept_completion: IO.Completion = undefined;
    var callback_called = false;
    var accepted_socket_opt: ?posix.socket_t = null;

    const Context = struct {
        called: *bool,
        socket: *?posix.socket_t,
        io_ptr: *IO,
    };

    var context = Context{ .called = &callback_called, .socket = &accepted_socket_opt, .io_ptr = &io };

    const callback = struct {
        fn on_accept(
            context_ptr: *Context,
            _: *IO.Completion,
            result: IO.AcceptError!posix.socket_t,
        ) void {
            context_ptr.called.* = true;
            // Store accepted socket if accept succeeded
            if (result) |accepted_socket| {
                context_ptr.socket.* = accepted_socket;
            } else |_| {
                // WouldBlock is expected when no connection is pending
            }
        }
    }.on_accept;

    // Call accept - this tests the updated accept implementation for Darwin
    // The key change is using posix.system.accept() for Darwin with proper error handling
    io.accept(*Context, &context, callback, &accept_completion, socket);

    // Run the IO loop once to queue the operation
    // The accept will be processed and either complete or be queued for async handling
    try io.run();

    // Clean up accepted socket if any
    if (accepted_socket_opt) |accepted_socket| {
        io.close_socket(accepted_socket);
    }
}

// ── IPv6, on every backend ────────────────────────────────────────
//
// Named os_posix because the Darwin test above declares a local `posix`, and a
// local may not shadow a container declaration.

const os_posix = std.posix;
const Address = @import("../aio.zig").Address;

const tcp_nodelay: IO.TCPOptions = .{
    .rcvbuf = 0,
    .sndbuf = 0,
    .keepalive = null,
    .user_timeout_ms = 0,
    .nodelay = true,
};

fn loopback6(port: u16) Address {
    var address: Address = .{ .storage = std.mem.zeroes(os_posix.sockaddr.storage) };
    if (@hasField(os_posix.sockaddr.in6, "len")) address.in6.len = @sizeOf(os_posix.sockaddr.in6);
    address.in6.family = os_posix.AF.INET6;
    address.in6.port = std.mem.nativeToBig(u16, port);
    address.in6.addr[15] = 1; // ::1
    return address;
}

test "Address holds every family: in6 fits, and getOsSockLen names its length" {
    try std.testing.expect(@sizeOf(Address) >= @sizeOf(os_posix.sockaddr.storage));
    const address = loopback6(443);
    try std.testing.expectEqual(@as(os_posix.socklen_t, @sizeOf(os_posix.sockaddr.in6)), address.getOsSockLen());
    try std.testing.expectEqual(@as(u8, 1), address.in6.addr[15]);
}

const Echo = struct {
    accepted: ?IO.socket_t = null,
    connected: bool = false,
    received: usize = 0,
    sent: usize = 0,
    failed: ?anyerror = null,
    buffer: [32]u8 = undefined,

    fn on_accept(self: *Echo, _: *IO.Completion, result: IO.AcceptError!IO.socket_t) void {
        self.accepted = result catch |err| {
            self.failed = err;
            return;
        };
    }
    fn on_connect(self: *Echo, _: *IO.Completion, result: IO.ConnectError!void) void {
        result catch |err| {
            self.failed = err;
            return;
        };
        self.connected = true;
    }
    fn on_send(self: *Echo, _: *IO.Completion, result: IO.SendError!usize) void {
        self.sent = result catch |err| {
            self.failed = err;
            return;
        };
    }
    fn on_recv(self: *Echo, _: *IO.Completion, result: IO.RecvError!usize) void {
        self.received = result catch |err| {
            self.failed = err;
            return;
        };
    }

    fn linked(self: *Echo) bool {
        return self.failed != null or (self.accepted != null and self.connected);
    }
    fn echoed(self: *Echo) bool {
        return self.failed != null or self.received > 0;
    }
};

/// Drive the loop until `done` holds, bounded so a broken backend fails the
/// test instead of hanging it.
fn run_until(io: *IO, ctx: *Echo, comptime done: fn (*Echo) bool) !void {
    var rounds: usize = 0;
    while (!done(ctx)) : (rounds += 1) {
        if (rounds > 2_000) return error.TestTimedOut;
        try io.run_for_ns(5 * std.time.ns_per_ms);
    }
    if (ctx.failed) |err| return err;
}

test "IPv6 loopback: listen resolves the port; connect, accept, send and recv" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    // A kernel built without IPv6 cannot open the socket at all. A bind that
    // fails afterwards is exactly the defect under test, so it is not skipped.
    const listener = io.open_socket_tcp(os_posix.AF.INET6, tcp_nodelay) catch |err| {
        if (std.mem.eql(u8, @errorName(err), "AddressFamilyNotSupported")) return error.SkipZigTest;
        return err;
    };
    defer io.close_socket(listener);

    const bound = try io.listen(listener, loopback6(0), .{ .backlog = 4 });
    try std.testing.expectEqual(@as(@TypeOf(bound.any.family), os_posix.AF.INET6), bound.any.family);
    const port = std.mem.bigToNative(u16, bound.in6.port);
    try std.testing.expect(port != 0);
    try std.testing.expectEqual(@as(u8, 1), bound.in6.addr[15]);

    const client = try io.open_socket_tcp(os_posix.AF.INET6, tcp_nodelay);
    defer io.close_socket(client);

    var ctx: Echo = .{};
    var accept_completion: IO.Completion = undefined;
    var connect_completion: IO.Completion = undefined;
    io.accept(*Echo, &ctx, Echo.on_accept, &accept_completion, listener);
    io.connect(*Echo, &ctx, Echo.on_connect, &connect_completion, client, loopback6(port));
    try run_until(&io, &ctx, Echo.linked);
    const server = ctx.accepted.?;
    defer io.close_socket(server);

    const message = "hello over ::1";
    io.send(*Echo, &ctx, Echo.on_send, &connect_completion, client, message);
    io.recv(*Echo, &ctx, Echo.on_recv, &accept_completion, server, &ctx.buffer);
    try run_until(&io, &ctx, Echo.echoed);
    try std.testing.expectEqualStrings(message, ctx.buffer[0..ctx.received]);
}
