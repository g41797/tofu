/*
 * Platform utilities for the posix_net module.
 * Supplements bun-usockets with functions not provided by bsd.c.
 */

#include "bsd.h"

#ifndef _WIN32
#include <sys/socket.h>
#endif

extern LIBUS_SOCKET_DESCRIPTOR bsd_create_listen_socket(const char *host, int port, int options);
extern LIBUS_SOCKET_DESCRIPTOR bsd_create_listen_socket_unix(const char *path, size_t pathlen, int options);

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
