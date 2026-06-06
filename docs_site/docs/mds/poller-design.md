# Cross-Platform Design

Every platform(os+used libs) supports following "objects":

- Skt
- SocketCreator
- Triggers
- PollBackend

Actual implementation is selected via comptime switch.

High-level code knows nothing about specifics of "_network_".

---


## Skt

`Skt` encapsulates:

- socket handle
- address
- connect/accept
- send/recv
- close

High level code never cares socket specifics: errors, settings, modes, and so on...


For integration with the poller Skt supports
```zig
rawFd()
socketHandle()
```


## SocketCreator

Responsibilities:

```text
Address
   ↓
SocketCreator
   ↓
Skt
```

The rest of the system never cares how sockets are created.

## Triggers

At the heart of tofu's portability is `Triggers` — a packed `u8` struct with named fields:

```zig
pub const Triggers = packed struct(u8) {
    notify:  bool = false,
    accept:  bool = false,
    connect: bool = false,
    send:    bool = false,
    recv:    bool = false,
    pool:    bool = false,
    err:     bool = false,
    timeout: bool = false,
};
```

Because all Reactor logic speaks only `Triggers`, **the event loop code is identical across all platforms** — there are zero OS-specific branches inside `Reactor.zig` itself. Adding a new OS backend requires implementing one module (`*_backend.zig`) and one translation pair in `triggers.zig`. Nothing else changes.

---

## PollBackend

tofu is single-thread Reactor, based on _poll_ abstraction - PollBackend.

PollBackend supports:

- register
- modify
- unregister
- wait

First 3 work as "configurators" of internal poll backend (epoll/kqueue/wepoll)
Last is actual poll operation.

