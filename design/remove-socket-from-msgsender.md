# Remove raw Socket from MsgSender/MsgReceiver

## Context

`MsgSender` and `MsgReceiver` stored a raw `Socket` handle (extracted from `IoSkt.skt.socket.?`)
solely to pass it to `Skt.sendBuf()` / `Skt.recvToBuf()`. This leaked the OS-specific
`Socket` type into business logic and would block usockets migration (where the handle is
`*us_socket_t`, not an fd).

`Reactor.zig` also had a hardcoded `const Socket = std.posix.socket_t` instead of
`internal.Socket`.

## Changes

### All four Skt.zig files (`linux/`, `windows/`, `mac/`, `usockets/`)
- Deleted `sendBufTo` (zero callers)
- Renamed `sendBuf(socket, buf)` → `sendBufFd(socket, buf)`
- Renamed `recvToBuf(socket, buf)` → `recvToBufFd(socket, buf)`
- Added instance methods `sendBuf(*Skt, buf)` and `recvToBuf(*Skt, buf)`

### `triggeredSkts.zig`
- `MsgSender.socket: Socket` → `MsgSender.skt: *Skt`
- `MsgReceiver.socket: Socket` → `MsgReceiver.skt: *Skt`
- `set(cn, socket: Socket)` → `set(cn, skt: *Skt)` in both structs
- Send loop: `Skt.sendBuf(ms.socket, ...)` → `ms.skt.sendBuf(...)`
- Recv loop: `Skt.recvToBuf(mr.socket, ...)` → `mr.skt.recvToBuf(...)`
- `IoSkt.initServerSide()`: pass `&ret.skt` instead of `sskt.socket.?`
- `IoSkt.postConnect()`: pass `&ioskt.skt` instead of `ioskt.skt.socket.?`
- `IoSkt.refreshPointers()`: refresh `*Skt` pointers before message buffer pointers

### `Reactor.zig`
- Fixed `const Socket = std.posix.socket_t` → `const Socket = internal.Socket`

## Verification

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseFast` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseSmall` | ✅ PASS (35/35) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |
