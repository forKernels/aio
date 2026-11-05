//! msvc_root.zig -- the root of aio.lib, the x86_64-windows-msvc twin of
//! libaio.a. The exports are src/c_abi.zig's, unchanged; this root only
//! force-references them and changes where std.debug writes.
//!
//! Taken from forIO's src/zig/msvc_pack_root.zig (origin/main), which measured
//! the reason by disassembling its archive:
//!
//! link.exe has no compiler-rt. std.debug's default Io is Io.Threaded, and
//! taking that Io's vtable links every Io.Threaded operation; two of them
//! divide an i96 nanosecond count through compiler-rt's __divti3. A Zig static
//! library does not bundle compiler-rt, and bundling it into an MSVC archive
//! breaks link.exe (LNK1143), so an MSVC consumer stopped on an unresolved
//! __divti3 that arrived only through the panic handler.
//!
//! So std.debug gets Io.failing, and the panic handler writes its message to
//! the process's stderr handle and aborts. ReleaseSafe's checks stay on: a
//! violated check still stops the process at the C ABI and says why. What is
//! lost relative to the GNU archive is the stack trace.
//!
//! Not sealed: tools/wrap.zig's MinGW `ld -r` emits COFF that link.exe rejects.
//! A single-root Zig static library gives everything that is not `export`
//! internal linkage, so its global set is already the zaio_* C ABI (plus
//! MSVC's COMDAT `__xmm@` literal-pool constants, which are "pick any").

const std = @import("std");

pub const exports = @import("c_abi.zig");

comptime {
    _ = exports;
}

pub const std_options_debug_io: std.Io = std.Io.failing;

pub const panic = std.debug.FullPanic(panicToStderr);

const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(
    hFile: *anyopaque,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

fn writeStderr(handle: *anyopaque, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        var written: u32 = 0;
        const chunk: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
        if (WriteFile(handle, rest.ptr, chunk, &written, null) == 0 or written == 0) return;
        rest = rest[written..];
    }
}

fn panicToStderr(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_addr;
    const invalid: usize = std.math.maxInt(usize);
    if (GetStdHandle(STD_ERROR_HANDLE)) |handle| {
        if (@intFromPtr(handle) != invalid) {
            writeStderr(handle, "aio panic: ");
            writeStderr(handle, msg);
            writeStderr(handle, "\n");
        }
    }
    std.process.abort();
}
