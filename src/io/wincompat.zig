// wincompat.zig — Win32 bindings that Zig 0.16 removed from std.os.windows.
// Copyright The Fantastic Planet - By David Clabaugh
//
// 0.16 stripped most of std.os.windows and nearly all of its ws2_32 bindings
// (only SOCKET and sockaddr survive there). aio's IOCP backend is built on them,
// so it declares its own. These are fixed Win32 ABI values and entry points --
// declaring them is not a workaround, it is what a library depending on an OS
// API should have been doing.
//
// Anything 0.16 still provides is re-exported rather than redeclared, so there
// is exactly one definition of each in play.
//
// On 0.15.2 every declaration falls through to std, so behaviour there is
// unchanged.

const std = @import("std");
const w = std.os.windows;

pub const zig16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

// ── still provided by std, re-exported ──────────────────────────────────────
pub const HANDLE = w.HANDLE;
pub const DWORD = w.DWORD;
pub const BOOL = w.BOOL;
pub const ULONG = w.ULONG;
pub const BYTE = w.BYTE;
pub const GUID = w.GUID;
pub const TRUE = w.TRUE;
pub const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;
pub const IO_STATUS_BLOCK = w.IO_STATUS_BLOCK;
pub const UNICODE_STRING = w.UNICODE_STRING;
pub const kernel32 = w.kernel32;
pub const ntdll = w.ntdll;
pub const unexpectedError = w.unexpectedError;
pub const unexpectedStatus = w.unexpectedStatus;
pub const CloseHandle = w.CloseHandle;
pub const SOCKET = std.posix.socket_t;
pub const sockaddr = w.ws2_32.sockaddr;

// ── constants 0.16 dropped ──────────────────────────────────────────────────
/// 0.16 made BOOL an enum, so the false value is spelled as one.
pub const FALSE: BOOL = if (zig16) @enumFromInt(0) else w.FALSE;
pub const INFINITE: DWORD = if (zig16) 0xFFFF_FFFF else w.INFINITE;
pub const SYNCHRONIZE: DWORD = if (zig16) 0x0010_0000 else w.SYNCHRONIZE;
pub const OPEN_EXISTING: DWORD = if (zig16) 3 else w.OPEN_EXISTING;
pub const FILE_BEGIN: DWORD = if (zig16) 0 else w.FILE_BEGIN;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = if (zig16) 0x0000_0080 else w.FILE_ATTRIBUTE_NORMAL;
pub const FILE_FLAG_OVERLAPPED: DWORD = if (zig16) 0x4000_0000 else w.FILE_FLAG_OVERLAPPED;

// NT create/open options (NtCreateFile), not CreateFileW flags.
pub const FILE_DIRECTORY_FILE: ULONG = if (zig16) 0x0000_0001 else w.FILE_DIRECTORY_FILE;
pub const FILE_WRITE_THROUGH: ULONG = if (zig16) 0x0000_0002 else w.FILE_WRITE_THROUGH;
pub const FILE_NO_INTERMEDIATE_BUFFERING: ULONG = if (zig16) 0x0000_0008 else w.FILE_NO_INTERMEDIATE_BUFFERING;
pub const FILE_SYNCHRONOUS_IO_NONALERT: ULONG = if (zig16) 0x0000_0020 else w.FILE_SYNCHRONOUS_IO_NONALERT;
pub const FILE_NON_DIRECTORY_FILE: ULONG = if (zig16) 0x0000_0040 else w.FILE_NON_DIRECTORY_FILE;
pub const FILE_OPEN_REPARSE_POINT: ULONG = if (zig16) 0x0020_0000 else w.FILE_OPEN_REPARSE_POINT;
pub const FILE_CREATE: ULONG = if (zig16) 0x0000_0002 else w.FILE_CREATE;

pub const FILE_SKIP_COMPLETION_PORT_ON_SUCCESS: u8 = if (zig16) 0x1 else w.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS;
pub const FILE_SKIP_SET_EVENT_ON_HANDLE: u8 = if (zig16) 0x2 else w.FILE_SKIP_SET_EVENT_ON_HANDLE;

pub const INVALID_SOCKET: SOCKET = if (zig16) @ptrFromInt(std.math.maxInt(usize)) else w.ws2_32.INVALID_SOCKET;
pub const SOCKET_ERROR: c_int = if (zig16) -1 else w.ws2_32.SOCKET_ERROR;
pub const WSA_FLAG_OVERLAPPED: DWORD = if (zig16) 0x01 else w.ws2_32.WSA_FLAG_OVERLAPPED;
pub const WSA_FLAG_NO_HANDLE_INHERIT: DWORD = if (zig16) 0x80 else w.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;
pub const SIO_GET_EXTENSION_FUNCTION_POINTER: DWORD = if (zig16) 0xC800_6006 else w.ws2_32.SIO_GET_EXTENSION_FUNCTION_POINTER;

/// {25a207b9-ddf3-4660-8ee9-76e58c74063e} — the ConnectEx extension.
pub const WSAID_CONNECTEX: GUID = if (zig16) .{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
} else w.ws2_32.WSAID_CONNECTEX;

// ── structures 0.16 dropped ─────────────────────────────────────────────────
pub const OVERLAPPED = if (zig16) extern struct {
    Internal: usize,
    InternalHigh: usize,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?*anyopaque,
    },
    hEvent: ?HANDLE,
} else w.OVERLAPPED;

pub const OVERLAPPED_ENTRY = if (zig16) extern struct {
    lpCompletionKey: usize,
    lpOverlapped: *OVERLAPPED,
    Internal: usize,
    dwNumberOfBytesTransferred: DWORD,
} else w.OVERLAPPED_ENTRY;

pub const WSABUF = if (zig16) extern struct {
    len: ULONG,
    buf: [*]u8,
} else w.ws2_32.WSABUF;

pub const OBJECT_ATTRIBUTES = if (zig16) extern struct {
    Length: ULONG,
    RootDirectory: ?HANDLE,
    ObjectName: *UNICODE_STRING,
    Attributes: ULONG,
    SecurityDescriptor: ?*anyopaque,
    SecurityQualityOfService: ?*anyopaque,
} else w.OBJECT_ATTRIBUTES;

// ── entry points 0.16 dropped ───────────────────────────────────────────────
//
// Declared against the OS rather than re-exported, because 0.16 removed them
// from std entirely. The 0.15.2 side still re-exports, so there is one
// definition in play on each compiler.

const k32 = struct {
    extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: HANDLE,
        ExistingCompletionPort: ?HANDLE,
        CompletionKey: usize,
        NumberOfConcurrentThreads: DWORD,
    ) callconv(.winapi) ?HANDLE;

    extern "kernel32" fn GetQueuedCompletionStatusEx(
        CompletionPort: HANDLE,
        lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
        ulCount: ULONG,
        ulNumEntriesRemoved: *ULONG,
        dwMilliseconds: DWORD,
        fAlertable: BOOL,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn SetFileCompletionNotificationModes(
        FileHandle: HANDLE,
        Flags: u8,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
};

const ws2 = struct {
    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn WSASocketW(af: c_int, type: c_int, protocol: c_int, lpProtocolInfo: ?*anyopaque, g: u32, dwFlags: DWORD) callconv(.winapi) SOCKET;
    extern "ws2_32" fn WSARecv(s: SOCKET, lpBuffers: [*]WSABUF, dwBufferCount: DWORD, lpNumberOfBytesRecvd: ?*DWORD, lpFlags: *DWORD, lpOverlapped: ?*OVERLAPPED, lpCompletionRoutine: ?*const anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSASend(s: SOCKET, lpBuffers: [*]WSABUF, dwBufferCount: DWORD, lpNumberOfBytesSent: ?*DWORD, dwFlags: DWORD, lpOverlapped: ?*OVERLAPPED, lpCompletionRoutine: ?*const anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAIoctl(s: SOCKET, dwIoControlCode: DWORD, lpvInBuffer: ?*const anyopaque, cbInBuffer: DWORD, lpvOutBuffer: ?*anyopaque, cbOutBuffer: DWORD, lpcbBytesReturned: *DWORD, lpOverlapped: ?*OVERLAPPED, lpCompletionRoutine: ?*const anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetOverlappedResult(s: SOCKET, lpOverlapped: *OVERLAPPED, lpcbTransfer: *DWORD, fWait: BOOL, lpdwFlags: *DWORD) callconv(.winapi) BOOL;
    extern "ws2_32" fn getsockopt(s: SOCKET, level: c_int, optname: c_int, optval: [*]u8, optlen: *c_int) callconv(.winapi) c_int;
    // bind/listen/getsockname: typed exactly as forNet's sock.zig declares them,
    // so the one symbol has one type when aio and forNet share a compilation.
    extern "ws2_32" fn bind(s: SOCKET, addr: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(s: SOCKET, addr: *anyopaque, addrlen: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: ?[*]const u8, optlen: c_int) callconv(.winapi) c_int;
};

pub const GetFileSizeEx = if (zig16) k32.GetFileSizeEx else w.GetFileSizeEx;

/// Winsock error codes (winerror.h). 0.16 removed ws2_32.WinsockError along with
/// every Winsock function; these are fixed ABI values, and the backend switches
/// on them by name. Non-exhaustive, so an unlisted code is a value, not UB.
pub const WinsockError = if (zig16) enum(u16) {
    WSA_INVALID_HANDLE = 6,
    WSA_NOT_ENOUGH_MEMORY = 8,
    WSA_INVALID_PARAMETER = 87,
    WSA_OPERATION_ABORTED = 995,
    WSA_IO_INCOMPLETE = 996,
    WSA_IO_PENDING = 997,
    WSAEINTR = 10004,
    WSAEBADF = 10009,
    WSAEACCES = 10013,
    WSAEFAULT = 10014,
    WSAEINVAL = 10022,
    WSAEMFILE = 10024,
    WSAEWOULDBLOCK = 10035,
    WSAEINPROGRESS = 10036,
    WSAEALREADY = 10037,
    WSAENOTSOCK = 10038,
    WSAEDESTADDRREQ = 10039,
    WSAEMSGSIZE = 10040,
    WSAEPROTOTYPE = 10041,
    WSAENOPROTOOPT = 10042,
    WSAEPROTONOSUPPORT = 10043,
    WSAESOCKTNOSUPPORT = 10044,
    WSAEOPNOTSUPP = 10045,
    WSAEPFNOSUPPORT = 10046,
    WSAEAFNOSUPPORT = 10047,
    WSAEADDRINUSE = 10048,
    WSAEADDRNOTAVAIL = 10049,
    WSAENETDOWN = 10050,
    WSAENETUNREACH = 10051,
    WSAENETRESET = 10052,
    WSAECONNABORTED = 10053,
    WSAECONNRESET = 10054,
    WSAENOBUFS = 10055,
    WSAEISCONN = 10056,
    WSAENOTCONN = 10057,
    WSAESHUTDOWN = 10058,
    WSAETOOMANYREFS = 10059,
    WSAETIMEDOUT = 10060,
    WSAECONNREFUSED = 10061,
    WSAELOOP = 10062,
    WSAENAMETOOLONG = 10063,
    WSAEHOSTDOWN = 10064,
    WSAEHOSTUNREACH = 10065,
    WSASYSNOTREADY = 10091,
    WSAVERNOTSUPPORTED = 10092,
    WSANOTINITIALISED = 10093,
    WSAEDISCON = 10101,
    _,
} else w.ws2_32.WinsockError;

/// The raw entry point returns an int; every aio call site switches on the
/// named code, as it did against 0.15.2's typed wrapper.
pub fn WSAGetLastError() WinsockError {
    if (!zig16) return w.ws2_32.WSAGetLastError();
    const code = ws2.WSAGetLastError();
    return @enumFromInt(std.math.cast(u16, code) orelse std.math.maxInt(u16));
}

pub const bind = ws2.bind;
pub const listen = ws2.listen;
pub const getsockname = ws2.getsockname;
pub const WSARecv = if (zig16) ws2.WSARecv else w.ws2_32.WSARecv;
pub const WSASend = if (zig16) ws2.WSASend else w.ws2_32.WSASend;
pub const WSAIoctl = if (zig16) ws2.WSAIoctl else w.ws2_32.WSAIoctl;
pub const WSAGetOverlappedResult = if (zig16) ws2.WSAGetOverlappedResult else w.ws2_32.WSAGetOverlappedResult;
pub const getsockopt = if (zig16) ws2.getsockopt else w.ws2_32.getsockopt;
pub const setsockopt = if (zig16) ws2.setsockopt else w.ws2_32.setsockopt;

// ── wrappers matching std 0.15.2's SHAPES ───────────────────────────────────
//
// std did not just expose the raw Win32 entry points; it wrapped several with
// error unions and slice arguments. These keep those shapes so aio's call sites
// do not have to change -- the point is to replace what std removed, not to
// rewrite the caller.

/// 0.16 made BOOL an enum; 0.15.2 had it as an int.
fn boolTo(v: bool) BOOL {
    if (zig16) {
        return @enumFromInt(@intFromBool(v));
    } else {
        return @intFromBool(v);
    }
}

pub const GetQueuedCompletionStatusError = error{ Aborted, Cancelled, EOF, Timeout, Unexpected };

pub fn GetQueuedCompletionStatusEx(
    completion_port: HANDLE,
    entries: []OVERLAPPED_ENTRY,
    timeout_ms: ?DWORD,
    alertable: bool,
) GetQueuedCompletionStatusError!u32 {
    if (!zig16) return w.GetQueuedCompletionStatusEx(completion_port, entries, timeout_ms, alertable);
    var removed: ULONG = 0;
    const ok = k32.GetQueuedCompletionStatusEx(
        completion_port,
        entries.ptr,
        @intCast(entries.len),
        &removed,
        timeout_ms orelse INFINITE,
        boolTo(alertable),
    );
    if (ok == FALSE) return switch (w.GetLastError()) {
        .ABANDONED_WAIT_0 => error.Aborted,
        .OPERATION_ABORTED => error.Cancelled,
        .HANDLE_EOF => error.EOF,
        .TIMEOUT => error.Timeout,
        else => |e| unexpectedError(e),
    };
    return removed;
}

pub fn CreateIoCompletionPort(
    file_handle: HANDLE,
    existing_completion_port: ?HANDLE,
    completion_key: usize,
    concurrent_thread_count: DWORD,
) !HANDLE {
    if (!zig16) return w.CreateIoCompletionPort(file_handle, existing_completion_port, completion_key, concurrent_thread_count);
    const handle = k32.CreateIoCompletionPort(file_handle, existing_completion_port, completion_key, concurrent_thread_count) orelse
        return switch (w.GetLastError()) {
            .INVALID_PARAMETER => unreachable,
            else => |e| unexpectedError(e),
        };
    return handle;
}

/// std's wrapper took the version as two bytes and returned WSADATA; aio
/// discards the result, so this returns void.
pub fn WSAStartup(major: u8, minor: u8) !void {
    if (!zig16) {
        _ = try w.WSAStartup(major, minor);
        return;
    }
    var data: [512]u8 align(8) = undefined;
    const ver: u16 = (@as(u16, minor) << 8) | major;
    if (ws2.WSAStartup(ver, @ptrCast(&data)) != 0) return error.WinsockStartupFailed;
}

pub fn WSACleanup() !void {
    if (!zig16) return w.WSACleanup();
    if (ws2.WSACleanup() != 0) return error.WinsockCleanupFailed;
}

/// std.posix.close is gone in 0.16; a socket closes with closesocket.
pub fn closeSocket(s: SOCKET) void {
    if (!zig16) {
        std.posix.close(s);
    } else {
        _ = ws2c.closesocket(s);
    }
}

const ws2c = struct {
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
};

/// std.posix.AcceptError / SetSockOptError are gone in 0.16.
pub const AcceptError = error{
    ConnectionAborted,   FileDescriptorNotASocket, ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded, SystemResources,        SocketNotListening,
    ProtocolFailure,     BlockedByFirewall,        WouldBlock,
    ConnectionResetByPeer, NetworkSubsystemFailed, OperationNotSupported,
    Unexpected,
};

pub const SetSockOptError = error{
    AlreadyConnected, InvalidProtocolOption, TimeoutTooBig, PermissionDenied,
    NetworkSubsystemFailed, FileDescriptorNotASocket, SocketNotBound,
    NoDevice, SystemResources, Unexpected,
};

/// std's wrapper returned an error union; the raw entry point returns
/// INVALID_SOCKET on failure.
pub fn WSASocketW(
    af: i32,
    socket_type: i32,
    protocol: i32,
    protocolInfo: ?*anyopaque,
    g: u32,
    dwFlags: DWORD,
) !SOCKET {
    if (!zig16) {
        // 0.15.2's GROUP is a plain u32, so it passes straight through.
        return w.WSASocketW(af, socket_type, protocol, @ptrCast(@alignCast(protocolInfo)), g, dwFlags);
    }
    const s = ws2.WSASocketW(af, socket_type, protocol, protocolInfo, g, dwFlags);
    if (s == INVALID_SOCKET) return error.SocketCreateFailed;
    return s;
}

/// std's wrapper returned an error union; the raw entry point returns BOOL.
pub fn SetFileCompletionNotificationModes(handle: HANDLE, flags: u8) !void {
    if (!zig16) return w.SetFileCompletionNotificationModes(handle, flags);
    if (k32.SetFileCompletionNotificationModes(handle, flags) == FALSE) {
        return switch (w.GetLastError()) {
            else => |e| unexpectedError(e),
        };
    }
}
