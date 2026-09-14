pub const IO = @import("io.zig").IO;
pub const Time = @import("time.zig").Time;
pub const QueueType = @import("queue.zig").QueueType;

/// The address type aio's socket operations take.
///
/// Exported because consumers must NAME it, not re-derive it. Under 0.15.2 it
/// is std.net.Address and every repo that guessed got the same answer; under
/// 0.16 std.net is gone and there is more than one defensible replacement —
/// std.Io.net.IpAddress (a connector: it listens and connects) or a raw
/// sockaddr carrier. aio needs the carrier, because it hands &addr.any and
/// getOsSockLen() straight to io_uring SQEs.
///
/// forIO's async_io.zig independently declared `Address = std.Io.net.IpAddress`
/// and passed it to aio's listen. Both choices were right locally and the
/// boundary did not compile. One definition, exported, is the fix — a
/// conversion at the edge would have worked and left the next consumer free to
/// guess again.
pub const Address = @import("zigcompat.zig").Address;

// Include all tests from testing directory
test {
    _ = @import("testing/benchmark.zig");
    _ = @import("testing/aio_test.zig");
    // The IOCP backend against the real kernel. Windows-only, so the Linux and
    // Darwin test counts are exactly what they were.
    if (@import("builtin").os.tag == .windows) _ = @import("testing/windows_io_test.zig");
}
