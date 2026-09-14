//! Code shared across several IO implementations, because, e.g., it is expressible via POSIX layer.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

const assert = std.debug.assert;

const is_linux = builtin.target.os.tag == .linux;
const is_windows = builtin.target.os.tag == .windows;

pub const Address = @import("../zigcompat.zig").Address;

pub const TCPOptions = struct {
    rcvbuf: c_int,
    sndbuf: c_int,
    keepalive: ?struct {
        keepidle: c_int,
        keepintvl: c_int,
        keepcnt: c_int,
    },
    user_timeout_ms: c_int,
    nodelay: bool,
};

pub const ListenOptions = struct {
    backlog: u31,
};

pub fn listen(
    fd: posix.socket_t,
    address: Address,
    options: ListenOptions,
) !Address {
    // NOT on Windows. On POSIX SO_REUSEADDR lets a restarted server rebind a
    // port still in TIME_WAIT, which Windows permits without asking. Windows'
    // SO_REUSEADDR is a different option: it lets a SECOND socket bind a port
    // that is already LISTENING and take its connections. Setting it there
    // turns "restart quickly" into "hijackable listener". forNet's sock.zig
    // makes the same call for its own Winsock listeners.
    if (!is_windows) try setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
    try @import("../zigcompat.zig").bind(fd, &address.any, address.getOsSockLen());

    // Resolve port 0 to an actual port picked by the OS.
    var address_resolved: Address = undefined;
    var addrlen: posix.socklen_t = @sizeOf(Address);
    try @import("../zigcompat.zig").getSockName(fd, &address_resolved.any, &addrlen);
    assert(address_resolved.getOsSockLen() == addrlen);
    assert(address_resolved.any.family == address.any.family);

    try @import("../zigcompat.zig").listen(fd, options.backlog);

    return address_resolved;
}

/// Sets the socket options.
/// Although some options are generic at the socket level,
/// these settings are intended only for TCP sockets.
pub fn tcp_options(
    fd: posix.socket_t,
    options: TCPOptions,
) !void {
    if (options.rcvbuf > 0) rcvbuf: {
        if (is_linux) {
            // Requires CAP_NET_ADMIN privilege (settle for SO_RCVBUF in case of an EPERM):
            if (setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUFFORCE, options.rcvbuf)) |_| {
                break :rcvbuf;
            } else |err| switch (err) {
                error.PermissionDenied => {},
                else => |e| return e,
            }
        }
        try setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, options.rcvbuf);
    }

    if (options.sndbuf > 0) sndbuf: {
        if (is_linux) {
            // Requires CAP_NET_ADMIN privilege (settle for SO_SNDBUF in case of an EPERM):
            if (setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUFFORCE, options.sndbuf)) |_| {
                break :sndbuf;
            } else |err| switch (err) {
                error.PermissionDenied => {},
                else => |e| return e,
            }
        }
        try setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, options.sndbuf);
    }

    if (options.keepalive) |keepalive| {
        try setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, 1);
        if (is_linux) {
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, keepalive.keepidle);
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, keepalive.keepintvl);
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, keepalive.keepcnt);
        }
    }

    if (options.user_timeout_ms > 0) {
        if (is_linux) {
            const timeout_ms = options.user_timeout_ms;
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.USER_TIMEOUT, timeout_ms);
        }
    }

    // Set tcp no-delay
    if (options.nodelay) {
        if (is_linux) {
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, 1);
        }
    }
}

pub fn setsockopt(fd: posix.socket_t, level: i32, option: u32, value: c_int) !void {
    if (is_windows) return setsockoptWinsock(fd, level, option, value);
    try posix.setsockopt(fd, level, option, &std.mem.toBytes(value));
}

/// 0.16's std.posix.setsockopt is `@compileError("use std.Io instead")` on
/// Windows, and std.Io.net does not speak Winsock at all. aio's sockets ARE
/// Winsock sockets (WSASocketW, for IOCP), so they are configured through
/// Winsock. Failures map into posix.SetSockOptError, so callers see the same
/// error set on every platform.
fn setsockoptWinsock(fd: posix.socket_t, level: i32, option: u32, value: c_int) posix.SetSockOptError!void {
    const wincompat = @import("wincompat.zig");
    const bytes = std.mem.toBytes(value);
    if (wincompat.setsockopt(fd, level, @intCast(option), &bytes, @intCast(bytes.len)) == 0) return;
    return switch (wincompat.WSAGetLastError()) {
        .WSAENOTSOCK => error.FileDescriptorNotASocket,
        .WSAENOPROTOOPT, .WSAEINVAL => error.InvalidProtocolOption,
        .WSAEISCONN => error.AlreadyConnected,
        .WSAENOBUFS => error.SystemResources,
        .WSAENETDOWN => error.NetworkDown,
        .WSAEACCES => error.PermissionDenied,
        else => error.Unexpected,
    };
}
