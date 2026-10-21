/*
 * zaio_test.c — the zaio_* C ABI from a C consumer's side: the DELIVERED
 * header (prebuilt/<short>/zaio.h) against the SEALED archive
 * (prebuilt/<short>/libaio.a). `zig build test-cabi`.
 *
 * Every export is called at least once. Listening is the consumer's own socket
 * call, as zaio.h says; this file makes it with BSD sockets / Winsock.
 */
#ifdef __linux__
/* mkstemp is POSIX.1-2008. glibc declares it only under a POSIX feature macro,
 * which strict -std=c11 leaves off, so it must come before every include.
 * Linux only: on Darwin the same macro hides INADDR_LOOPBACK, and Darwin
 * declares mkstemp without it. */
#define _POSIX_C_SOURCE 200809L
#endif
#include "zaio.h"

#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
typedef SOCKET os_socket;
typedef int os_socklen;
#define OS_SHUT_BOTH SD_BOTH
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <stdlib.h> /* mkstemp */
#include <unistd.h> /* close, unlink */
typedef int os_socket;
typedef socklen_t os_socklen;
#define OS_SHUT_BOTH SHUT_RDWR
#endif

static int g_failed = 0;
static int g_checks = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        g_checks++;                                                              \
        if (!(cond)) {                                                           \
            g_failed++;                                                          \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
        }                                                                        \
    } while (0)

#define CHECK_EQ(a, b) CHECK((long long)(a) == (long long)(b))

typedef struct {
    int calls;
    zaio_status status;
    uint64_t value;
} seen;

static void on_op(void *user, zaio_completion *completion, zaio_status status, uint64_t value) {
    (void)completion;
    seen *s = (seen *)user;
    s->calls++;
    s->status = status;
    s->value = value;
}

static int run_until(zaio_loop *loop, const seen *s) {
    for (int i = 0; i < 200 && s->calls == 0; i++) {
        if (zaio_loop_run_for(loop, 10u * 1000u * 1000u) != ZAIO_OK) return 0;
    }
    return s->calls != 0;
}

static void test_layout(void) {
    CHECK_EQ(zaio_completion_size(), sizeof(zaio_completion));
    CHECK_EQ(zaio_completion_alignment(), 8);
}

static void test_loop(void) {
    zaio_loop *loop = NULL;
    CHECK_EQ(zaio_loop_create(NULL, NULL), ZAIO_INVALID);
    zaio_loop_options bad = { sizeof(zaio_loop_options), 100, 0, 0 };
    CHECK_EQ(zaio_loop_create(&bad, &loop), ZAIO_INVALID);
    CHECK(loop == NULL);
    zaio_loop_options opts = { sizeof(zaio_loop_options), 64, 0, 0 };
    CHECK_EQ(zaio_loop_create(&opts, &loop), ZAIO_OK);
    CHECK_EQ(zaio_loop_run(loop), ZAIO_OK);
    CHECK_EQ(zaio_loop_wake(loop), ZAIO_OK);
    CHECK_EQ(zaio_loop_run_for(loop, 1000000), ZAIO_OK);
    CHECK_EQ(zaio_loop_run(NULL), ZAIO_INVALID);
    CHECK_EQ(zaio_loop_destroy(loop), ZAIO_OK);
}

static void test_timeout_and_cancel(void) {
    zaio_loop *loop = NULL;
    CHECK_EQ(zaio_loop_create(NULL, &loop), ZAIO_OK);
    zaio_completion c;
    seen s = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_timeout(loop, 1000000, &c, on_op, &s), ZAIO_PENDING);
    CHECK(run_until(loop, &s));
    CHECK_EQ(s.calls, 1);
    CHECK_EQ(s.status, ZAIO_OK);
    CHECK_EQ(zaio_timeout(loop, 1, &c, NULL, &s), ZAIO_INVALID);

    seen never = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_timeout(loop, 5000000, &c, on_op, &never), ZAIO_PENDING);
    CHECK_EQ(zaio_loop_cancel_all(loop), ZAIO_OK);
    CHECK_EQ(zaio_loop_cancel_all(loop), ZAIO_OK);
    CHECK_EQ(zaio_loop_run_for(loop, 20000000), ZAIO_CANCELED);
    CHECK_EQ(never.calls, 0);
    CHECK_EQ(zaio_timeout(loop, 1, &c, on_op, &never), ZAIO_CANCELED);
    CHECK_EQ(zaio_loop_destroy(loop), ZAIO_OK);
}

static void test_udp(void) {
    zaio_loop *loop = NULL;
    CHECK_EQ(zaio_loop_create(NULL, &loop), ZAIO_OK);
    uint64_t sock = 0;
    CHECK_EQ(zaio_udp_open(loop, 2 /* AF_INET's value, not 4 */, &sock), ZAIO_INVALID);
    CHECK(sock == ZAIO_INVALID_SOCKET);
    CHECK_EQ(zaio_udp_open(loop, ZAIO_FAMILY_IPV4, &sock), ZAIO_OK);
    CHECK(sock != ZAIO_INVALID_SOCKET);
    CHECK_EQ(zaio_socket_close(loop, sock), ZAIO_OK);
    CHECK_EQ(zaio_loop_destroy(loop), ZAIO_OK);
}

static void test_tcp_loopback(void) {
    zaio_loop *loop = NULL;
    CHECK_EQ(zaio_loop_create(NULL, &loop), ZAIO_OK);

    zaio_tcp_options opts;
    memset(&opts, 0, sizeof opts);
    opts.struct_size = sizeof opts;
    opts.nodelay = 1;
    uint64_t listener = ZAIO_INVALID_SOCKET, client = ZAIO_INVALID_SOCKET;
    CHECK_EQ(zaio_tcp_open(loop, ZAIO_FAMILY_IPV4, &opts, &listener), ZAIO_OK);
    CHECK_EQ(zaio_tcp_open(loop, ZAIO_FAMILY_IPV4, &opts, &client), ZAIO_OK);

    /* The consumer's own bind + listen on the raw socket. */
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof sin);
    sin.sin_family = AF_INET;
    sin.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    os_socket ls = (os_socket)listener;
    CHECK_EQ(bind(ls, (struct sockaddr *)&sin, sizeof sin), 0);
    CHECK_EQ(listen(ls, 4), 0);
    os_socklen len = sizeof sin;
    CHECK_EQ(getsockname(ls, (struct sockaddr *)&sin, &len), 0);

    zaio_sock_addr to;
    memset(&to, 0, sizeof to);
    to.struct_size = sizeof to;
    to.family = ZAIO_FAMILY_IPV4;
    to.port = ntohs(sin.sin_port);
    to.addr[0] = 127;
    to.addr[3] = 1;

    zaio_completion ca, cc, cs, cr;
    seen accepted = { 0, ZAIO_PENDING, 0 }, connected = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_accept(loop, listener, &ca, on_op, &accepted), ZAIO_PENDING);
    CHECK_EQ(zaio_connect(loop, client, &to, &cc, on_op, &connected), ZAIO_PENDING);
    CHECK(run_until(loop, &accepted));
    CHECK(run_until(loop, &connected));
    CHECK_EQ(accepted.status, ZAIO_OK);
    CHECK_EQ(connected.status, ZAIO_OK);
    uint64_t server = accepted.value;

    static const char msg[] = "zaio from C";
    uint8_t in[64];
    seen sent = { 0, ZAIO_PENDING, 0 }, got = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_recv(loop, server, in, sizeof in, &cr, on_op, &got), ZAIO_PENDING);
    CHECK_EQ(zaio_send(loop, client, (const uint8_t *)msg, sizeof msg - 1, &cs, on_op, &sent), ZAIO_PENDING);
    CHECK(run_until(loop, &sent));
    CHECK(run_until(loop, &got));
    CHECK_EQ(sent.value, sizeof msg - 1);
    CHECK_EQ(got.value, sizeof msg - 1);
    CHECK(memcmp(in, msg, sizeof msg - 1) == 0);

    size_t now = 99;
    zaio_status st = zaio_send_now(loop, client, (const uint8_t *)msg, sizeof msg - 1, &now);
#ifdef __linux__
    CHECK_EQ(st, ZAIO_OK);
    CHECK_EQ(now, sizeof msg - 1);
    seen drained = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_recv(loop, server, in, sizeof in, &cr, on_op, &drained), ZAIO_PENDING);
    CHECK(run_until(loop, &drained));
#else
    CHECK_EQ(st, ZAIO_WOULD_BLOCK);
    CHECK_EQ(now, 0);
#endif

    /* End a pending recv the portable way: shut the socket down, run the loop
     * until the recv reports end of stream, then close (zaio.h: kqueue strands
     * an operation whose socket is closed under it). */
    seen orphan = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_recv(loop, server, in, sizeof in, &cr, on_op, &orphan), ZAIO_PENDING);
    CHECK_EQ(zaio_loop_run_for(loop, 30u * 1000u * 1000u), ZAIO_OK);
    CHECK_EQ(orphan.calls, 0);
    CHECK_EQ(shutdown((os_socket)server, OS_SHUT_BOTH), 0);
    CHECK(run_until(loop, &orphan));
    CHECK(orphan.status == ZAIO_CLOSED || (orphan.status == ZAIO_OK && orphan.value == 0));

    CHECK_EQ(zaio_socket_close(loop, server), ZAIO_OK);
    CHECK_EQ(zaio_socket_close(loop, client), ZAIO_OK);
    CHECK_EQ(zaio_socket_close(loop, listener), ZAIO_OK);
    CHECK_EQ(zaio_socket_close(loop, ZAIO_INVALID_SOCKET), ZAIO_INVALID);
    CHECK_EQ(zaio_loop_destroy(loop), ZAIO_OK);
}

static void test_files(void) {
#ifdef _WIN32
    /* A file HANDLE here must be opened FILE_FLAG_OVERLAPPED and associated
     * with the loop's IOCP. The winX86 delivery runs this half on Windows. */
    printf("zaio C-ABI: file tests are POSIX-only in this build\n");
#else
    char path[] = "/tmp/zaio_test_XXXXXX";
    int fd = mkstemp(path);
    CHECK(fd >= 0);
    if (fd < 0) return;
    zaio_loop *loop = NULL;
    CHECK_EQ(zaio_loop_create(NULL, &loop), ZAIO_OK);
    zaio_completion c;
    const uint8_t msg[] = "zaio file round trip";

    seen w = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_write(loop, (uint64_t)fd, msg, sizeof msg, 0, &c, on_op, &w), ZAIO_PENDING);
    CHECK(run_until(loop, &w));
    CHECK_EQ(w.status, ZAIO_OK);
    CHECK_EQ(w.value, sizeof msg);

    seen f = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_fsync(loop, (uint64_t)fd, &c, on_op, &f), ZAIO_PENDING);
    CHECK(run_until(loop, &f));
    CHECK_EQ(f.status, ZAIO_OK);

    uint8_t back[sizeof msg] = { 0 };
    seen r = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_read(loop, (uint64_t)fd, back, sizeof back, 0, &c, on_op, &r), ZAIO_PENDING);
    CHECK(run_until(loop, &r));
    CHECK_EQ(r.status, ZAIO_OK);
    CHECK_EQ(r.value, sizeof msg);
    CHECK(memcmp(back, msg, sizeof msg) == 0);

    /* Reading at the end of the file moves 0 bytes. */
    seen eof = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_read(loop, (uint64_t)fd, back, sizeof back, sizeof msg, &c, on_op, &eof), ZAIO_PENDING);
    CHECK(run_until(loop, &eof));
    CHECK_EQ(eof.status, ZAIO_OK);
    CHECK_EQ(eof.value, 0);

    seen k = { 0, ZAIO_PENDING, 0 };
    CHECK_EQ(zaio_close(loop, (uint64_t)fd, &c, on_op, &k), ZAIO_PENDING);
    CHECK(run_until(loop, &k));
    CHECK_EQ(k.status, ZAIO_OK);
    unlink(path);

    /* Bad arguments are refused before anything is submitted. */
    CHECK_EQ(zaio_read(loop, ZAIO_INVALID_SOCKET, back, 1, 0, &c, on_op, &r), ZAIO_INVALID);
    CHECK_EQ(zaio_write(loop, 3, NULL, 1, 0, &c, on_op, &w), ZAIO_INVALID);
    CHECK_EQ(zaio_fsync(loop, 3, &c, NULL, &f), ZAIO_INVALID);
    CHECK_EQ(zaio_close(NULL, 3, &c, on_op, &k), ZAIO_INVALID);

    uint64_t dir = 0;
    CHECK_EQ(zaio_open_dir("/tmp", 4, &dir), ZAIO_OK);
    CHECK(dir != ZAIO_INVALID_SOCKET);
    if (dir != ZAIO_INVALID_SOCKET) close((int)dir);
    CHECK_EQ(zaio_open_dir("/no/such/dir", 12, &dir), ZAIO_SYSTEM); /* FileNotFound */
    CHECK_EQ(dir, ZAIO_INVALID_SOCKET);
    CHECK_EQ(zaio_open_dir(NULL, 0, &dir), ZAIO_INVALID);
    CHECK_EQ(zaio_open_dir("/tmp", 4, NULL), ZAIO_INVALID);
    CHECK_EQ(zaio_loop_destroy(loop), ZAIO_OK);
#endif
}

int main(void) {
    test_layout();
    test_loop();
    test_timeout_and_cancel();
    test_udp();
    test_tcp_loopback();
    test_files();
    printf("zaio C-ABI: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
