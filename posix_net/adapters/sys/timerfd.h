#pragma once
// Adapter: emulate timerfd for Windows builds.
// Uses a dummy WinSock UDP socket so wepoll can register it via epoll_ctl.
// The socket never fires events. usockets' sweep-timer callback is never called,
// which is acceptable because tofu does not use usockets' timeout mechanism.
#include <winsock2.h>
#include <sys/types.h>  // struct timespec and struct itimerspec

#define TFD_NONBLOCK  0
#define TFD_CLOEXEC   0
#define CLOCK_REALTIME  0
#define CLOCK_MONOTONIC 1

static inline int timerfd_create(int clockid, int flags) {
    (void)clockid; (void)flags;
    return (int)socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
}

static inline int timerfd_settime(int fd, int flags,
    const struct itimerspec *new_value, struct itimerspec *old_value) {
    (void)fd; (void)flags; (void)new_value; (void)old_value;
    return 0;
}
