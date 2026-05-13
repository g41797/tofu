/*
 * Platform utilities for the posix_net module.
 * Supplements bun-usockets with functions not provided by bsd.c.
 */

#include "bsd.h"

#ifdef _WIN32
#include <afunix.h>
#include <stddef.h>
#include <string.h>
#else
#include <errno.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stddef.h>
#include <string.h>
#endif

extern LIBUS_SOCKET_DESCRIPTOR bsd_create_listen_socket(const char *host, int port, int options);
extern LIBUS_SOCKET_DESCRIPTOR bsd_create_listen_socket_unix(const char *path, size_t pathlen, int options);
extern LIBUS_SOCKET_DESCRIPTOR bsd_create_connect_socket_unix(const char *path, size_t pathlen, int options);
extern LIBUS_SOCKET_DESCRIPTOR bsd_create_socket(int domain, int type, int protocol);
extern void bsd_close_socket(LIBUS_SOCKET_DESCRIPTOR fd);

/* Set SO_LINGER with l_linger=0: close sends RST instead of FIN, no TIME_WAIT. */
void bsd_set_linger_abort(LIBUS_SOCKET_DESCRIPTOR fd) {
    struct linger l;
    l.l_onoff  = 1;
    l.l_linger = 0;
#ifdef _WIN32
    setsockopt((SOCKET)fd, SOL_SOCKET, SO_LINGER, (const char *)&l, (int)sizeof(l));
#else
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, (socklen_t)sizeof(l));
#endif
}

/*
 * Wait for a non-blocking connect to complete (fd becomes writable).
 * Uses select() + getsockopt(SO_ERROR). Returns 0 on success, -1 on timeout or error.
 * timeout_ms < 0 means wait indefinitely.
 */
int pn_wait_writable(LIBUS_SOCKET_DESCRIPTOR fd, int timeout_ms) {
#ifdef _WIN32
    fd_set wset, eset;
    FD_ZERO(&wset); FD_ZERO(&eset);
    FD_SET((SOCKET)fd, &wset);
    FD_SET((SOCKET)fd, &eset);
    struct timeval tv;
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (select(0, NULL, &wset, &eset, timeout_ms < 0 ? NULL : &tv) <= 0) return -1;
    if (FD_ISSET((SOCKET)fd, &eset)) return -1;
    int err = 0; int len = sizeof(err);
    if (getsockopt((SOCKET)fd, SOL_SOCKET, SO_ERROR, (char *)&err, &len) != 0 || err != 0) return -1;
    return 0;
#else
    fd_set wset;
    FD_ZERO(&wset);
    FD_SET(fd, &wset);
    struct timeval tv;
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (select(fd + 1, NULL, &wset, NULL, timeout_ms < 0 ? NULL : &tv) <= 0) return -1;
    int err = 0; socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) return -1;
    return 0;
#endif
}

/* Create a TCP listen socket with explicit backlog. */
LIBUS_SOCKET_DESCRIPTOR pn_create_listen_socket(const char *host, int port, int options, int backlog) {
    LIBUS_SOCKET_DESCRIPTOR fd = bsd_create_listen_socket(host, port, options);
    if (fd != LIBUS_SOCKET_ERROR) {
#ifdef _WIN32
        listen((SOCKET)fd, backlog);
#else
        listen(fd, backlog);
#endif
    }
    return fd;
}

/* Create a UDS listen socket with explicit backlog. */
LIBUS_SOCKET_DESCRIPTOR pn_create_listen_socket_unix(const char *path, size_t pathlen, int options, int backlog) {
    LIBUS_SOCKET_DESCRIPTOR fd = bsd_create_listen_socket_unix(path, pathlen, options);
    if (fd != LIBUS_SOCKET_ERROR) {
#ifdef _WIN32
        listen((SOCKET)fd, backlog);
#else
        listen(fd, backlog);
#endif
    }
    return fd;
}

/*
 * Create a TCP/IP listen socket from an existing sockaddr (IPv4 or IPv6).
 * Sets SO_REUSEADDR, binds, and listens. Used by the portable backend to
 * avoid reformatting std.net.Address back to a host string.
 */
LIBUS_SOCKET_DESCRIPTOR pn_create_listen_socket_from_sockaddr(const struct sockaddr *addr, int addrlen, int backlog) {
#ifdef _WIN32
    LIBUS_SOCKET_DESCRIPTOR fd = bsd_create_socket(addr->sa_family, SOCK_STREAM, 0);
    if (fd == LIBUS_SOCKET_ERROR) return LIBUS_SOCKET_ERROR;
    int opt = 1;
    setsockopt((SOCKET)fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&opt, sizeof(opt));
    if (bind((SOCKET)fd, addr, addrlen) != 0) { bsd_close_socket(fd); return LIBUS_SOCKET_ERROR; }
    if (listen((SOCKET)fd, backlog) != 0) { bsd_close_socket(fd); return LIBUS_SOCKET_ERROR; }
    return fd;
#else
    LIBUS_SOCKET_DESCRIPTOR fd = bsd_create_socket(addr->sa_family, SOCK_STREAM, 0);
    if (fd == LIBUS_SOCKET_ERROR) return LIBUS_SOCKET_ERROR;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
#endif
    if (bind(fd, addr, (socklen_t)addrlen) != 0) { bsd_close_socket(fd); return LIBUS_SOCKET_ERROR; }
    if (listen(fd, backlog) != 0) { bsd_close_socket(fd); return LIBUS_SOCKET_ERROR; }
    return fd;
#endif
}

/*
 * Non-blocking connect on an existing fd.
 * TCP equivalent of bsd_connect_socket_unix.
 * Returns 0 if immediately connected.
 * Returns 1 if in progress (EINPROGRESS / WSAEWOULDBLOCK) — caller waits for WRITABLE.
 * Returns -1 on hard error.
 */
int pn_connect_socket(LIBUS_SOCKET_DESCRIPTOR fd, const struct sockaddr *addr, int addrlen) {
#ifdef _WIN32
    if (connect((SOCKET)fd, addr, addrlen) != 0) {
        int err = WSAGetLastError();
        /* WSAEWOULDBLOCK: in progress; WSAEINPROGRESS/WSAEALREADY: already connecting */
        if (err == WSAEWOULDBLOCK || err == WSAEINPROGRESS || err == WSAEALREADY) return 1;
        /* WSAEISCONN: connection already established (retry after WouldBlock) */
        if (err == WSAEISCONN) return 0;
        return -1;
    }
    return 0;
#else
    if (connect(fd, addr, (socklen_t)addrlen) != 0) {
        /* EINPROGRESS: in progress; EALREADY: already connecting (retry call) */
        if (errno == EINPROGRESS || errno == EALREADY) return 1;
        /* EISCONN: already connected (retry call after connect completed) */
        if (errno == EISCONN) return 0;
        return -1;
    }
    return 0;
#endif
}

/*
 * Create a connecting UDS socket.
 * On Linux: delegates to bsd_create_connect_socket_unix (errno EINPROGRESS = in progress).
 * On Windows: bsd_create_connect_socket_unix checks errno != EINPROGRESS, but non-blocking
 * connect on Windows sets WSAGetLastError() = WSAEWOULDBLOCK, not errno = EINPROGRESS.
 * Re-implement the connect here with the correct Windows error check.
 */
LIBUS_SOCKET_DESCRIPTOR pn_create_connect_socket_unix(const char *path, size_t pathlen, int options) {
#ifdef _WIN32
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    if (pathlen >= sizeof(addr.sun_path)) {
        return LIBUS_SOCKET_ERROR;
    }
    memcpy(addr.sun_path, path, pathlen);

    int addrlen = (int)(offsetof(struct sockaddr_un, sun_path) + strlen(addr.sun_path) + 1);

    LIBUS_SOCKET_DESCRIPTOR fd = bsd_create_socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd == LIBUS_SOCKET_ERROR) return LIBUS_SOCKET_ERROR;

    if (connect((SOCKET)fd, (struct sockaddr *)&addr, addrlen) != 0) {
        if (WSAGetLastError() != WSAEWOULDBLOCK) {
            bsd_close_socket(fd);
            return LIBUS_SOCKET_ERROR;
        }
    }
    return fd;
#else
    return bsd_create_connect_socket_unix(path, pathlen, options);
#endif
}
