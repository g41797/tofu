/*
 * Windows replacement for epoll_kqueue.c (epoll path only).
 *
 * Upstream uSockets does not compile epoll_kqueue.c on Windows.
 * This file provides all us_* functions for the epoll path on Windows,
 * backed by wepoll (src/ampe/windows/wepoll/wepoll.c).
 * sys/epoll.h redirects epoll_create1/epoll_ctl/epoll_wait to wepoll.
 *
 * kqueue path omitted — not applicable on Windows.
 *
 * License: Apache 2.0 — same as epoll_kqueue.c.
 */

#include "libusockets.h"
#include "internal/internal.h"
#include <stdlib.h>

#ifdef LIBUS_USE_EPOLL

#define GET_READY_POLL(loop, index) (struct us_poll_t *) loop->ready_polls[index].data.ptr
#define SET_READY_POLL(loop, index, poll) loop->ready_polls[index].data.ptr = poll

/* Loop */
void us_loop_free(struct us_loop_t *loop) {
    us_internal_loop_data_free(loop);
    epoll_close_win(loop->fd);
    free(loop);
}

/* Poll */
struct us_poll_t *us_create_poll(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    if (!fallthrough) {
        loop->num_polls++;
    }
    return malloc(sizeof(struct us_poll_t) + ext_size);
}

void us_poll_free(struct us_poll_t *p, struct us_loop_t *loop) {
    loop->num_polls--;
    free(p);
}

void *us_poll_ext(struct us_poll_t *p) {
    return p + 1;
}

void us_poll_init(struct us_poll_t *p, LIBUS_SOCKET_DESCRIPTOR fd, int poll_type) {
    p->state.fd = fd;
    p->state.poll_type = poll_type;
}

int us_poll_events(struct us_poll_t *p) {
    return ((p->state.poll_type & POLL_TYPE_POLLING_IN) ? LIBUS_SOCKET_READABLE : 0) | ((p->state.poll_type & POLL_TYPE_POLLING_OUT) ? LIBUS_SOCKET_WRITABLE : 0);
}

LIBUS_SOCKET_DESCRIPTOR us_poll_fd(struct us_poll_t *p) {
    return p->state.fd;
}

int us_internal_poll_type(struct us_poll_t *p) {
    return p->state.poll_type & 3;
}

void us_internal_poll_set_type(struct us_poll_t *p, int poll_type) {
    p->state.poll_type = poll_type | (p->state.poll_type & 12);
}

/* Timer */
void *us_timer_ext(struct us_timer_t *timer) {
    return ((struct us_internal_callback_t *) timer) + 1;
}

struct us_loop_t *us_timer_loop(struct us_timer_t *t) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;
    return internal_cb->loop;
}

/* Loop */
struct us_loop_t *us_create_loop(void *hint, void (*wakeup_cb)(struct us_loop_t *loop), void (*pre_cb)(struct us_loop_t *loop), void (*post_cb)(struct us_loop_t *loop), unsigned int ext_size) {
    struct us_loop_t *loop = (struct us_loop_t *) malloc(sizeof(struct us_loop_t) + ext_size);
    loop->num_polls = 0;
    loop->num_ready_polls = 0;
    loop->current_ready_poll = 0;
    loop->fd = epoll_create1(EPOLL_CLOEXEC);
    us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb);
    return loop;
}

void us_loop_run(struct us_loop_t *loop) {
    us_loop_integrate(loop);
    while (loop->num_polls) {
        us_internal_loop_pre(loop);
        loop->num_ready_polls = epoll_wait(loop->fd, loop->ready_polls, 1024, -1);
        for (loop->current_ready_poll = 0; loop->current_ready_poll < loop->num_ready_polls; loop->current_ready_poll++) {
            struct us_poll_t *poll = GET_READY_POLL(loop, loop->current_ready_poll);
            if (poll) {
                int events = loop->ready_polls[loop->current_ready_poll].events;
                int error = loop->ready_polls[loop->current_ready_poll].events & (EPOLLERR | EPOLLHUP);
                events &= us_poll_events(poll);
                if (events || error) {
                    us_internal_dispatch_ready_poll(poll, error, events);
                }
            }
        }
        us_internal_loop_post(loop);
    }
}

void us_internal_loop_update_pending_ready_polls(struct us_loop_t *loop, struct us_poll_t *old_poll, struct us_poll_t *new_poll, int old_events, int new_events) {
    int num_entries_possibly_remaining = 1;
    for (int i = loop->current_ready_poll; i < loop->num_ready_polls && num_entries_possibly_remaining; i++) {
        if (GET_READY_POLL(loop, i) == old_poll) {
            SET_READY_POLL(loop, i, new_poll);
            num_entries_possibly_remaining--;
        }
    }
}

/* Poll */
struct us_poll_t *us_poll_resize(struct us_poll_t *p, struct us_loop_t *loop, unsigned int ext_size) {
    int events = us_poll_events(p);
    struct us_poll_t *new_p = realloc(p, sizeof(struct us_poll_t) + ext_size);
    if (p != new_p && events) {
        new_p->state.poll_type = us_internal_poll_type(new_p);
        us_poll_change(new_p, loop, events);
        us_internal_loop_update_pending_ready_polls(loop, p, new_p, events, events);
    }
    return new_p;
}

void us_poll_start(struct us_poll_t *p, struct us_loop_t *loop, int events) {
    p->state.poll_type = us_internal_poll_type(p) | ((events & LIBUS_SOCKET_READABLE) ? POLL_TYPE_POLLING_IN : 0) | ((events & LIBUS_SOCKET_WRITABLE) ? POLL_TYPE_POLLING_OUT : 0);
    struct epoll_event event;
    event.events = events;
    event.data.ptr = p;
    epoll_ctl(loop->fd, EPOLL_CTL_ADD, p->state.fd, &event);
}

void us_poll_change(struct us_poll_t *p, struct us_loop_t *loop, int events) {
    int old_events = us_poll_events(p);
    if (old_events != events) {
        p->state.poll_type = us_internal_poll_type(p) | ((events & LIBUS_SOCKET_READABLE) ? POLL_TYPE_POLLING_IN : 0) | ((events & LIBUS_SOCKET_WRITABLE) ? POLL_TYPE_POLLING_OUT : 0);
        struct epoll_event event;
        event.events = events;
        event.data.ptr = p;
        epoll_ctl(loop->fd, EPOLL_CTL_MOD, p->state.fd, &event);
    }
}

void us_poll_stop(struct us_poll_t *p, struct us_loop_t *loop) {
    int old_events = us_poll_events(p);
    int new_events = 0;
    struct epoll_event event;
    epoll_ctl(loop->fd, EPOLL_CTL_DEL, p->state.fd, &event);
    us_internal_loop_update_pending_ready_polls(loop, p, 0, old_events, new_events);
}

unsigned int us_internal_accept_poll_event(struct us_poll_t *p) {
    int fd = us_poll_fd(p);
    uint64_t buf;
    int read_length = read(fd, &buf, 8);
    (void)read_length;
    return buf;
}

/* Timer */
struct us_timer_t *us_create_timer(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_poll_t *p = us_create_poll(loop, fallthrough, sizeof(struct us_internal_callback_t) - sizeof(struct us_poll_t) + ext_size);
    int timerfd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
    if (timerfd == -1) {
        return NULL;
    }
    us_poll_init(p, timerfd, POLL_TYPE_CALLBACK);
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) p;
    cb->loop = loop;
    cb->cb_expects_the_loop = 0;
    cb->leave_poll_ready = 0;
    return (struct us_timer_t *) cb;
}

void us_timer_close(struct us_timer_t *timer) {
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) timer;
    us_poll_stop(&cb->p, cb->loop);
    closesocket(us_poll_fd(&cb->p));
    us_poll_free((struct us_poll_t *) timer, cb->loop);
}

void us_timer_set(struct us_timer_t *t, void (*cb)(struct us_timer_t *t), int ms, int repeat_ms) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) t;
    internal_cb->cb = (void (*)(struct us_internal_callback_t *)) cb;
    struct itimerspec timer_spec = {
        {repeat_ms / 1000, (long) (repeat_ms % 1000) * (long) 1000000},
        {ms / 1000, (long) (ms % 1000) * (long) 1000000}
    };
    timerfd_settime(us_poll_fd((struct us_poll_t *) t), 0, &timer_spec, NULL);
    us_poll_start((struct us_poll_t *) t, internal_cb->loop, LIBUS_SOCKET_READABLE);
}

/* Async */
struct us_internal_async *us_internal_create_async(struct us_loop_t *loop, int fallthrough, unsigned int ext_size) {
    struct us_poll_t *p = us_create_poll(loop, fallthrough, sizeof(struct us_internal_callback_t) - sizeof(struct us_poll_t) + ext_size);
    us_poll_init(p, eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC), POLL_TYPE_CALLBACK);
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) p;
    cb->loop = loop;
    cb->cb_expects_the_loop = 1;
    cb->leave_poll_ready = 0;
    return (struct us_internal_async *) cb;
}

void us_internal_async_close(struct us_internal_async *a) {
    struct us_internal_callback_t *cb = (struct us_internal_callback_t *) a;
    us_poll_stop(&cb->p, cb->loop);
    closesocket(us_poll_fd(&cb->p));
    us_poll_free((struct us_poll_t *) a, cb->loop);
}

void us_internal_async_set(struct us_internal_async *a, void (*cb)(struct us_internal_async *)) {
    struct us_internal_callback_t *internal_cb = (struct us_internal_callback_t *) a;
    internal_cb->cb = (void (*)(struct us_internal_callback_t *)) cb;
    us_poll_start((struct us_poll_t *) a, internal_cb->loop, LIBUS_SOCKET_READABLE);
}

void us_internal_async_wakeup(struct us_internal_async *a) {
    uint64_t one = 1;
    int written = eventfd_write(us_poll_fd((struct us_poll_t *) a), one);
    (void)written;
}

/* Single-iteration poll for external reactor */
void us_loop_run_tick(struct us_loop_t *loop, int timeout_ms) {
    int num_ready = 0;
    us_internal_loop_pre(loop);
    num_ready = epoll_wait(loop->fd, loop->ready_polls, 1024, timeout_ms);
    if (num_ready > 0) {
        loop->num_ready_polls = num_ready;
        for (int i = 0; i < num_ready; i++) {
            struct us_poll_t *poll = GET_READY_POLL(loop, i);
            if (poll) {
                int events = loop->ready_polls[i].events;
                int error = loop->ready_polls[i].events & (EPOLLERR | EPOLLHUP);
                events &= us_poll_events(poll);
                if (events || error) {
                    us_internal_dispatch_ready_poll(poll, error, events);
                }
            }
        }
    }
    us_internal_loop_post(loop);
}

#endif /* LIBUS_USE_EPOLL */
