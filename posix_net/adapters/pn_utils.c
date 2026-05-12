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
