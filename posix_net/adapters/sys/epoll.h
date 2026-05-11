#pragma once
// Adapter: redirect epoll symbols to wepoll for Windows builds.
// wepoll uses HANDLE for its epoll descriptor; usockets stores it as int.
// Windows kernel handles fit in the lower 32 bits; the cast is safe.
#include "wepoll.h"
#include "win_compat.h"

static inline int epoll_create1_win(int flags) {
    (void)flags;
    return (int)(intptr_t)epoll_create(1);
}
static inline int epoll_close_win(int ephnd) {
    return epoll_close((HANDLE)(intptr_t)ephnd);
}
static inline int epoll_ctl_win(int ephnd, int op, int sock, struct epoll_event *event) {
    return epoll_ctl((HANDLE)(intptr_t)ephnd, op, (SOCKET)(uintptr_t)sock, event);
}
static inline int epoll_wait_win(int ephnd, struct epoll_event *events, int maxevents, int timeout) {
    return epoll_wait((HANDLE)(intptr_t)ephnd, events, maxevents, timeout);
}

#ifndef EPOLL_CLOEXEC
#define EPOLL_CLOEXEC 0
#endif

#undef epoll_create1
#define epoll_create1(f) epoll_create1_win(f)
#undef epoll_ctl
#define epoll_ctl        epoll_ctl_win
#undef epoll_wait
#define epoll_wait       epoll_wait_win
