#pragma once
// Adapter: emulate eventfd for Windows builds.
// Uses a dummy WinSock UDP socket so wepoll can register it via epoll_ctl.
// The socket never sends or receives data. usockets' async-wakeup path is never
// triggered because tofu runs a single-threaded reactor and never calls us_loop_wakeup.
#include <winsock2.h>

#define EFD_NONBLOCK 0
#define EFD_CLOEXEC  0

static inline int eventfd(unsigned int initval, int flags) {
    (void)initval; (void)flags;
    return (int)socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
}

static inline int eventfd_write(int fd, uint64_t val) {
    (void)fd; (void)val; return 0;
}

static inline int eventfd_read(int fd, uint64_t *val) {
    (void)fd; *val = 0; return 0;
}
