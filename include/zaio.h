/*
 * zaio.h — aio's completion loop as a C ABI (prefix zaio_)
 *
 * Link the sealed archive beside this header: prebuilt/<short>/libaio.a.
 * Mirrors src/c_abi.zig exactly. Its only public symbols are the zaio_* below.
 *
 *   macos:            libaio.a                    (libSystem)
 *   linX86 / thor:    libaio.a -lc                (memcpy/memset/getauxval)
 *   winX86 (GNU ABI): libaio.a ../forTime/prebuilt/winX86/libfortime.a
 *                     -lws2_32 -lmswsock -lntdll -lkernel32
 *   winX86 (MSVC):    aio.lib ../forTime/prebuilt/winX86/fortime.lib
 *                     ws2_32.lib mswsock.lib ntdll.lib kernel32.lib (unsealed)
 *
 * The archive also needs compiler-rt (__divti3; __zig_probe_stack on x86_64,
 * ___chkstk_ms on MinGW), which a Zig final link always supplies. A C-only
 * final link must add Zig's compiler-rt; libgcc lacks __zig_probe_stack.
 *
 * Prefix zaio_, header zaio.h: POSIX owns aio_* and <aio.h>.
 *
 * The status values, struct layouts, 512-byte completion and callback type are
 * IDENTICAL to forIO's fio_net_* (include/forio_net.h), so those can forward
 * here one for one.
 *
 * Model: completion-based. A submission (accept, connect, recv, send, timeout)
 * returns ZAIO_PENDING and its callback runs EXACTLY ONCE, on the thread inside
 * zaio_loop_run / zaio_loop_run_for -- unless zaio_loop_cancel_all or
 * zaio_loop_destroy comes first, after which it never runs. A submission that
 * fails returns the error and never calls its callback.
 *
 * Threading: one thread runs a loop at a time. Only zaio_loop_wake and
 * zaio_loop_cancel_all may be called from other threads; every other call
 * comes from the running thread (usually a callback) or while no run is active.
 *
 * Conventions:
 *   - zaio_status: 0 OK, 1 PENDING, negative = error.
 *   - The loop is an opaque handle: zaio_loop_create(..., **out) / _destroy.
 *   - zaio_completion is caller-owned fixed-layout storage; no init needed.
 *   - Structs passed in carry struct_size first.
 *   - Families are 4 and 6, never AF_* (whose values differ per OS).
 *   - Sockets are the raw OS handle (SOCKET / fd) widened to uint64_t. bind,
 *     listen and datagram connect are the caller's own socket calls on it.
 */
#ifndef ZAIO_H
#define ZAIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Status ---------------------------------------------------------------- */

typedef int32_t zaio_status;

enum {
    ZAIO_OK                 =   0,
    ZAIO_PENDING            =   1,  /* submitted; the callback runs once      */
    ZAIO_WOULD_BLOCK        =  -1,  /* send_now: use zaio_send                */
    ZAIO_CLOSED             =  -2,  /* closed (also under a pending op)       */
    ZAIO_CANCELED           =  -3,  /* loop canceled                          */
    ZAIO_TIMED_OUT          =  -4,
    ZAIO_REFUSED            =  -5,
    ZAIO_UNREACHABLE        =  -6,  /* network or host                        */
    ZAIO_RESET              =  -7,  /* reset, aborted, broken pipe            */
    ZAIO_ADDR_IN_USE        =  -8,
    ZAIO_ADDR_NOT_AVAILABLE =  -9,
    ZAIO_ACCESS_DENIED      = -10,
    ZAIO_NOT_CONNECTED      = -11,
    ZAIO_MESSAGE_TOO_BIG    = -12,
    ZAIO_INVALID            = -13,  /* NULL, bad family, short struct_size... */
    ZAIO_BUSY               = -14,  /* another thread runs it / destroy in run */
    ZAIO_NO_MEMORY          = -15,
    ZAIO_RESOURCES          = -16,  /* fd quota, socket buffers               */
    ZAIO_UNSUPPORTED        = -17,
    ZAIO_SYSTEM             = -18   /* any other OS failure                   */
};

enum {
    ZAIO_FAMILY_IPV4 = 4,
    ZAIO_FAMILY_IPV6 = 6
};

#define ZAIO_INVALID_SOCKET UINT64_MAX

/* ---- Types ----------------------------------------------------------------- */

typedef struct zaio_loop zaio_loop;

/* 512 bytes, align 8, on every target. Must not move while an operation is
 * pending on it; one operation at a time; may be resubmitted from inside its
 * own callback. Layout guards: zaio_completion_size / _alignment. */
typedef struct zaio_completion {
    uint64_t _opaque[64];
} zaio_completion;

/* 32 bytes, align 4. */
typedef struct zaio_sock_addr {
    uint32_t struct_size;   /* = sizeof(zaio_sock_addr)                      */
    uint16_t family;        /* ZAIO_FAMILY_IPV4 / _IPV6                      */
    uint16_t port;          /* host byte order                               */
    uint32_t flowinfo;      /* IPv6                                          */
    uint32_t scope_id;      /* IPv6                                          */
    uint8_t  addr[16];      /* IPv4 in addr[0..3], network order: {127,0,0,1} */
} zaio_sock_addr;

/* 32 bytes, align 4. NULL options = all defaults. */
typedef struct zaio_tcp_options {
    uint32_t struct_size;
    uint8_t  nodelay;               /* TCP_NODELAY (every platform)            */
    uint8_t  keepalive;             /* SO_KEEPALIVE                            */
    uint16_t _reserved;
    int32_t  rcvbuf;                /* 0 = OS default                          */
    int32_t  sndbuf;                /* 0 = OS default                          */
    uint32_t keepalive_idle_s;      /* Linux; 0 = 7200                         */
    uint32_t keepalive_interval_s;  /* Linux; 0 = 75                           */
    uint32_t keepalive_count;       /* Linux; 0 = 9                            */
    uint32_t user_timeout_ms;       /* Linux TCP_USER_TIMEOUT; 0 = off         */
} zaio_tcp_options;

/* 16 bytes. NULL options = all defaults. */
typedef struct zaio_loop_options {
    uint32_t struct_size;
    uint32_t entries;       /* io_uring queue depth: 0 = 256, else a power of two <= 2048 */
    uint32_t flags;         /* 0 */
    uint32_t _reserved;
} zaio_loop_options;

/* status: ZAIO_OK or an error. value: the accepted socket (accept), bytes
 * moved (recv / send; 0 from recv on a stream = orderly close), 0 otherwise. */
typedef void (*zaio_callback)(void *user, zaio_completion *completion,
                              zaio_status status, uint64_t value);

/* ---- Loop ------------------------------------------------------------------ */

zaio_status zaio_loop_create(const zaio_loop_options *opts, zaio_loop **out_loop);

/* Cancels outstanding operations (no callbacks), closes the backend, frees.
 * BUSY while any thread is inside a run: cancel_all, join, then destroy. */
zaio_status zaio_loop_destroy(zaio_loop *loop);

/* Non-blocking: submit queued work, run the callbacks that are ready. */
zaio_status zaio_loop_run(zaio_loop *loop);

/* Run callbacks as work completes for timeout_ns (<= INT64_MAX); return early
 * after zaio_loop_wake or zaio_loop_cancel_all. */
zaio_status zaio_loop_run_for(zaio_loop *loop, uint64_t timeout_ns);

/* THREAD-SAFE. The current -- or next -- run_for returns promptly. Coalesces. */
zaio_status zaio_loop_wake(zaio_loop *loop);

/* THREAD-SAFE, idempotent. From another thread: wakes the loop, waits for the
 * running run to return, cancels; on return no callback runs and no backend
 * operation can touch caller memory. From a callback: no further callback runs,
 * and the enclosing run returns ZAIO_CANCELED once the backend has let go --
 * free buffers only after that. Afterwards runs and submissions are CANCELED. */
zaio_status zaio_loop_cancel_all(zaio_loop *loop);

size_t zaio_completion_size(void);
size_t zaio_completion_alignment(void);

/* ---- Sockets (synchronous) ------------------------------------------------- */

zaio_status zaio_tcp_open(zaio_loop *loop, uint16_t family,
                          const zaio_tcp_options *opts, uint64_t *out_sock);
zaio_status zaio_udp_open(zaio_loop *loop, uint16_t family, uint64_t *out_sock);

/* POSIX: shutdown + close; Windows: closesocket. Linux (io_uring) and Windows
 * (IOCP): an operation pending on the socket completes once -- ZAIO_CLOSED, or
 * ZAIO_OK with value 0 from a recv; treat both as end of stream.
 *
 * macOS (kqueue): it does NOT. close() drops the kqueue registration and the
 * pending operation is stranded: its callback never runs. And an operation
 * submitted but not yet run when the socket closes reaches the kernel as EBADF,
 * which aio's kqueue backend treats as unreachable (a trap). On macOS, end
 * pending operations first: shutdown(fd, SHUT_RDWR) on the raw socket, run the
 * loop until their callbacks have run, then call this. A pending ACCEPT is not
 * woken that way (shutdown on a listener fails with ENOTCONN): end it with
 * zaio_loop_cancel_all or zaio_loop_destroy, which run no callback, then
 * close the listener.
 *
 * Call it from the loop's thread; another thread may call it only while no
 * operation is pending on, or being submitted to, that socket (it touches no
 * loop state, but the descriptor number can be reused). */
zaio_status zaio_socket_close(zaio_loop *loop, uint64_t sock);

/* ---- Submissions: ZAIO_PENDING + one callback, or an error and none -------- */

zaio_status zaio_accept(zaio_loop *loop, uint64_t sock,
                        zaio_completion *completion, zaio_callback callback, void *user);

zaio_status zaio_connect(zaio_loop *loop, uint64_t sock, const zaio_sock_addr *addr,
                         zaio_completion *completion, zaio_callback callback, void *user);

/* Buffers are caller-owned and must outlive the callback. len is clamped to
 * 0x7ffff000; value reports what moved. A short send is possible. */
zaio_status zaio_recv(zaio_loop *loop, uint64_t sock, uint8_t *buf, size_t len,
                      zaio_completion *completion, zaio_callback callback, void *user);

zaio_status zaio_send(zaio_loop *loop, uint64_t sock, const uint8_t *buf, size_t len,
                      zaio_completion *completion, zaio_callback callback, void *user);

/* OK with *out_sent bytes if the kernel took some without waiting, else
 * ZAIO_WOULD_BLOCK: use zaio_send. Always WOULD_BLOCK on Windows and macOS. */
zaio_status zaio_send_now(zaio_loop *loop, uint64_t sock, const uint8_t *buf, size_t len,
                          size_t *out_sent);

/* Fires no earlier than timeout_ns (<= INT64_MAX); 0 yields to the next run.
 * Deadlines fire in order. IOCP waits round up to 1 ms and may run one system
 * timer tick late. */
zaio_status zaio_timeout(zaio_loop *loop, uint64_t timeout_ns,
                         zaio_completion *completion, zaio_callback callback, void *user);

/* ---- Files ----------------------------------------------------------------- */
/* fd is the OS file descriptor (a HANDLE on Windows) carried in uint64_t, as
 * sockets are; ZAIO_INVALID_SOCKET is never a valid fd. The async calls return
 * ZAIO_PENDING and the callback runs once: value = bytes moved for read and
 * write (0 from read = end of file), 0 for fsync and close. File errors use
 * the same statuses as sockets: disk full or quota -> ZAIO_RESOURCES, I/O
 * error -> ZAIO_SYSTEM, a bad path or a directory where a file belongs ->
 * ZAIO_INVALID, read-only filesystem -> ZAIO_ACCESS_DENIED. On macOS a write
 * is followed by F_FULLFSYNC before the callback runs. */
zaio_status zaio_read(zaio_loop *loop, uint64_t fd, uint8_t *buf, size_t len, uint64_t offset,
                      zaio_completion *completion, zaio_callback callback, void *user);
zaio_status zaio_write(zaio_loop *loop, uint64_t fd, const uint8_t *buf, size_t len,
                       uint64_t offset, zaio_completion *completion, zaio_callback callback,
                       void *user);
zaio_status zaio_fsync(zaio_loop *loop, uint64_t fd,
                       zaio_completion *completion, zaio_callback callback, void *user);
/* Closes a FILE fd; sockets keep zaio_socket_close. */
zaio_status zaio_close(zaio_loop *loop, uint64_t fd,
                       zaio_completion *completion, zaio_callback callback, void *user);

/* Synchronous. Opens a directory read-only so its entries can be fsync'd.
 * path is path_len bytes, not NUL-terminated. *out_fd = ZAIO_INVALID_SOCKET
 * on failure. */
zaio_status zaio_open_dir(const char *path, size_t path_len, uint64_t *out_fd);

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(zaio_completion) == 512, "zaio_completion is 512 bytes");
_Static_assert(sizeof(zaio_sock_addr) == 32, "zaio_sock_addr is 32 bytes");
_Static_assert(sizeof(zaio_tcp_options) == 32, "zaio_tcp_options is 32 bytes");
_Static_assert(sizeof(zaio_loop_options) == 16, "zaio_loop_options is 16 bytes");
#endif

#ifdef __cplusplus
}
#endif

#endif /* ZAIO_H */
