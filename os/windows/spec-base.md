# Implementing a Reactor Pattern over Windows IOCP using ntdll APIs

**Version:** 005
**Target Language:** Zig 0.15.2
**Platform:** Windows 10+

---

## Your Role

You are an **architect and expert** in the following domains:

- **Windows internals**: NT kernel APIs, ntdll.dll, IOCP architecture, I/O manager, AFD driver, handle tables, NT object model, wait completion packets
- **Windows networking**: Winsock2, AFD (Ancillary Function Driver), TDI/WSK, socket handle layering (LSPs, base provider handles), non-blocking socket I/O
- **Asynchronous programming**: Proactor vs Reactor patterns, event loop design, completion ports, readiness notification, I/O multiplexing (select, poll, epoll, kqueue, IOCP)
- **Multithreading & concurrency**: lock-free queues, cross-thread signaling, thread-safe command injection, single-threaded event loop with multi-threaded producers
- **Systems programming languages**: C (Win32/NT API), Zig (0.15.2 — comptime, error unions, async patterns, `std.os.windows`)
- **API design**: clean layered abstractions, platform abstraction layers, idiomatic Zig patterns

You approach problems methodically: analyze feasibility first, prototype critical unknowns, build incrementally, test at each stage.

---

## Background & Motivation

Windows provides two fundamental I/O models:

- **Proactor pattern** (native IOCP model): You initiate an async operation (e.g., `WSASend`, `WSARecv`), and the OS notifies you **upon completion**. The kernel performs the I/O; you react to finished work.
- **Reactor pattern** (select/epoll/poll model): You register interest in **readiness** (e.g., "socket is readable"), and the OS notifies you when the socket is **ready for a non-blocking operation**. You then perform the I/O yourself.

Windows IOCP is inherently a Proactor. However, the **ntdll.dll** layer exposes lower-level NT APIs that allow us to use IOCP as a **generic notification/queuing mechanism** — not tied to actual async I/O completions. This makes it possible to build a **Reactor (readiness-based) event loop** on top of IOCP, combining the efficiency of IOCP's thread-wakeup mechanism with the Reactor's programming model.

### Why would you want this?

- Single-threaded event loops (like libuv, mio, or Zig's `std.os.windows`) benefit from a Reactor model where the application controls when and how I/O happens.
- Reactor semantics are simpler for non-blocking socket programming: check readiness → do non-blocking `send()`/`recv()` → handle partial results → re-register interest.
- Avoids the Proactor complexity of managing overlapped buffers, cancellation semantics, and buffer lifetime issues.
- Enables a unified cross-platform abstraction (epoll on Linux, kqueue on macOS/BSD, IOCP-as-Reactor on Windows).

---

## Key NT APIs (from ntdll.dll)

These are the undocumented/semi-documented APIs that make this possible:

### 1. `NtDeviceIoControlFile` + AFD_POLL (Primary Approach)

Can issue AFD (Ancillary Function Driver) poll requests on sockets. AFD is the kernel driver behind Winsock.

**This is the critical API.** Instead of initiating a read/write, you issue an **AFD_POLL** request that asks: *"Notify me when this socket becomes readable/writable/has errors."* This is a readiness notification — exactly what a Reactor needs.

### 2. AFD_POLL mechanism

```c
#define IOCTL_AFD_POLL 0x00012024

typedef struct _AFD_POLL_HANDLE_INFO {
    HANDLE Handle;
    ULONG Events;      // Requested events (AFD_POLL_RECEIVE, AFD_POLL_SEND, etc.)
    NTSTATUS Status;    // Result status per handle
} AFD_POLL_HANDLE_INFO;

typedef struct _AFD_POLL_INFO {
    LARGE_INTEGER Timeout;          // Timeout for the poll
    ULONG NumberOfHandles;          // How many handles to poll
    ULONG Exclusive;                // Exclusive poll flag
    AFD_POLL_HANDLE_INFO Handles[1]; // Variable-length array
} AFD_POLL_INFO;
```

**Event flags:**
```c
#define AFD_POLL_RECEIVE           0x0001  // Data available to read
#define AFD_POLL_RECEIVE_EXPEDITED 0x0002  // OOB data available
#define AFD_POLL_SEND              0x0004  // Socket is writable
#define AFD_POLL_DISCONNECT        0x0008  // Peer disconnected (FIN received)
#define AFD_POLL_ABORT             0x0010  // Connection aborted (RST)
#define AFD_POLL_LOCAL_CLOSE       0x0020  // Local close
#define AFD_POLL_ACCEPT            0x0080  // Incoming connection (for listeners)
#define AFD_POLL_CONNECT_FAIL      0x0100  // Outbound connect failed
```

### 3. `NtSetInformationFile` (with `FileCompletionInformation`)
Used to associate a file handle with an IOCP and set a completion key. Alternative to `CreateIoCompletionPort`.

### 4. `NtRemoveIoCompletion` / `NtRemoveIoCompletionEx`
Equivalent to `GetQueuedCompletionStatus` / `GetQueuedCompletionStatusEx`. Dequeues completion packets from the IOCP.

### 5. `NtCreateIoCompletion` / `NtSetIoCompletion`
- `NtCreateIoCompletion`: Creates an IOCP (alternative to `CreateIoCompletionPort(INVALID_HANDLE_VALUE,...)`).
- `NtSetIoCompletion`: Posts a manual completion packet (alternative to `PostQueuedCompletionStatus`). Useful for waking the event loop or posting user events.

### 6. Wait Completion Packet APIs (Windows 8+)

These APIs allow **any waitable NT object** (events, mutexes, processes, threads, etc.) to post a completion packet to an IOCP when it becomes signaled — bypassing the 64-handle `WaitForMultipleObjects` limit entirely:

```c
// Create a reusable wait completion packet object
NTSTATUS NtCreateWaitCompletionPacket(
    _Out_    PHANDLE WaitCompletionPacketHandle,
    _In_     ACCESS_MASK DesiredAccess,
    _In_opt_ POBJECT_ATTRIBUTES ObjectAttributes
);

// Associate: "when TargetObjectHandle becomes signaled,
//             post a completion packet to IoCompletionHandle"
NTSTATUS NtAssociateWaitCompletionPacket(
    _In_     HANDLE WaitCompletionPacketHandle,
    _In_     HANDLE IoCompletionHandle,       // The IOCP
    _In_     HANDLE TargetObjectHandle,       // Waitable object (Event, etc.)
    _In_opt_ PVOID  KeyContext,               // Returned as CompletionKey
    _In_opt_ PVOID  ApcContext,               // Returned as lpOverlapped
    _In_     NTSTATUS IoStatus,               // Custom status
    _In_     ULONG_PTR IoStatusInformation,   // Custom info
    _Out_opt_ PBOOLEAN AlreadySignaled        // Was it already signaled?
);

// Cancel a pending association
NTSTATUS NtCancelWaitCompletionPacket(
    _In_ HANDLE WaitCompletionPacketHandle,
    _In_ BOOLEAN RemoveSignaledPacket
);
```

**Key characteristics:**
- Available since **Windows 8** (internally used by the Windows thread pool since Win8).
- The `TargetObjectHandle` must be a **waitable NT object** — this includes Event objects but **NOT** raw socket handles directly. Sockets are file objects backed by AFD; they are not inherently waitable in the NT sense.
- Each wait completion packet is **one-shot**: after firing, it must be re-associated (re-armed).
- This is the same mechanism the Win32 thread pool (`CreateThreadpoolWait`) uses internally.

---

## The Core Trick: AFD_POLL as Readiness Notification

The primary approach flow:

1. **Create an IOCP** (`CreateIoCompletionPort` or `NtCreateIoCompletion`).
2. **For each socket you want to monitor:**
   a. Obtain the base socket handle (underlying NT handle). You may need `SIO_BASE_HANDLE` via `WSAIoctl`.
   b. Associate it with the IOCP.
   c. Issue an `AFD_POLL` request via `NtDeviceIoControlFile` with `IOCTL_AFD_POLL`, specifying which events you care about (e.g., `AFD_POLL_RECEIVE | AFD_POLL_SEND`), using an `OVERLAPPED`/`IO_STATUS_BLOCK`.
   d. This request is now **pending** in the kernel.
3. **Event loop:**
   a. Call `GetQueuedCompletionStatusEx` (or `NtRemoveIoCompletionEx`) to wait for completions.
   b. When an AFD_POLL completes, it tells you **which events fired** (readable? writable? error?).
   c. You then perform the **non-blocking** `send()`/`recv()` yourself.
   d. **Re-arm:** Issue a new `AFD_POLL` for that socket to continue monitoring (one-shot semantics, similar to `EPOLLONESHOT`).

This is **exactly** how [mio](https://github.com/tokio-rs/mio) (Rust), [libuv](https://github.com/libuv/libuv), and Zig's I/O event loop implement Reactor semantics on Windows.

### Per-Socket AFD_POLL (Without Opening \Device\Afd)
### Architectural Validation Note (Version 005 Clarification)

The direct-socket `AFD_POLL` approach described above (issuing `NtDeviceIoControlFile`
with `IOCTL_AFD_POLL` directly on the base socket handle, without opening
`\Device\Afd`) is not experimental. It is validated by:

- **Len Holgate's research and working examples**
- **wepoll** (epoll emulation for Windows)
- **c-ares Windows event engine**
- Production-grade async runtimes that rely on AFD-based readiness

This project intentionally standardizes on the direct-socket approach to:

- Avoid global AFD device handles
- Avoid group-poll cancellation complexity
- Reduce kernel object count
- Simplify lifecycle and re-arm logic
- Align with modern, battle-tested implementations

This clarification strengthens architectural positioning but does not alter
any stage requirements or mechanics defined in Version 004.


A key simplification discovered by Len Holgate and used in c-ares: instead of opening a separate `\Device\Afd` handle and polling socket *sets*, you can issue `NtDeviceIoControlFile` with `IOCTL_AFD_POLL` **directly on the socket handle itself** (after associating it with the IOCP). This eliminates the need to open `\Device\Afd`, simplifies bookkeeping, and allows per-socket independent polls — no need to cancel and restart a group poll when adding/removing sockets.

See: [Socket readiness without \Device\Afd](https://lenholgate.com/blog/2024/06/socket-readiness-without-device-afd.html)

---

## Important Implementation Details

### Base Provider Handle
Winsock LSPs (Layered Service Providers) can wrap socket handles. AFD operations require the **base provider handle**:
```c
SOCKET base_socket;
DWORD bytes;
WSAIoctl(socket, SIO_BASE_HANDLE, NULL, 0,
         &base_socket, sizeof(base_socket), &bytes, NULL, NULL);
```

### One-Shot Semantics
Each `AFD_POLL` request completes **once** and must be re-issued. This is equivalent to `EPOLLONESHOT`. You must re-arm after each event.

### Overlapped / IO_STATUS_BLOCK Management
Each pending `AFD_POLL` needs its own `IO_STATUS_BLOCK` (or `OVERLAPPED`) that must remain valid until the operation completes or is cancelled. Typically, embed this in a per-socket state structure.

### Cancellation
Use `CancelIoEx` or `NtCancelIoFileEx` to cancel a pending `AFD_POLL` when removing a socket from the event loop or changing the event mask. Wait for the cancellation completion before freeing resources.

### Socket State Machine
For each socket, maintain:
- Current interest set (read, write, or both)
- Whether an AFD_POLL is currently pending
- Application-level send/receive buffers
- Connection state (connecting, connected, half-closed, etc.)

### Thread Safety
For a single-threaded Reactor, cross-thread wake-up can be done via `NtSetIoCompletion` (posts a user-defined completion packet to the IOCP), unblocking the event loop.

---

## Task

Implement a **single-threaded Reactor event loop** for Windows in **Zig 0.15.2** with the following:

### Core Requirements
1. **IOCP-backed event loop** using AFD_POLL for readiness notifications.
2. **Non-blocking socket I/O**: all `send()`/`recv()` calls are non-blocking, driven by readiness events.
3. **Support for multiple concurrent sockets** (TCP clients and/or a TCP listener with accepted connections).
4. **Clean per-socket state management** with proper re-arming of AFD_POLL after each event.
5. **Graceful shutdown and resource cleanup** including pending I/O cancellation.
6. **Prefer NT Native API over Win32** — use ntdll functions directly where possible, following the Zig standard library's own direction (see references below).

---

### Requirement: Cross-Thread Command Injection via IOCP

The Reactor event loop runs on a single dedicated thread. External threads (application logic, worker threads, UI thread, etc.) must be able to **submit arbitrary commands/messages into the event loop** for processing, without breaking the single-threaded execution model.

#### Motivation
In real-world applications, the event loop thread owns all socket state and performs all I/O. But application logic often lives elsewhere — a worker thread computes a response, a UI thread wants to initiate a new connection, a management thread wants to shut down a specific socket. These threads **must not** touch socket state directly (race conditions). Instead, they post a command into the event loop, which processes it on the next iteration — safely, single-threaded.

#### Design

Use IOCP itself as the cross-thread command queue. The mechanism:

1. **Command structure** — A tagged union representing internal commands:
   ```zig
   const CommandType = enum {
       send_data,        // Enqueue data for sending on a socket
       close_socket,     // Request graceful close of a socket
       connect,          // Initiate a new outbound connection
       register_socket,  // Register a new socket from another thread
       custom,           // Application-defined command with opaque payload
       shutdown,         // Shut down the entire event loop
   };

   const Command = struct {
       type: CommandType,
       target_socket: ?windows.HANDLE,
       data: ?[]const u8,
       callback: ?*const fn (?*anyopaque) void,
       user_context: ?*anyopaque,
   };
   ```

2. **Posting from external thread** — Use `NtSetIoCompletion` (or `PostQueuedCompletionStatus`) to inject the command into the same IOCP that the event loop waits on:
   ```zig
   // Called from ANY thread — thread-safe by IOCP design
   pub fn postCommand(self: *Reactor, cmd: *Command) !void {
       // cmd must be heap-allocated; ownership transfers to event loop
       const status = ntdll.NtSetIoCompletion(
           self.iocp_handle,
           COMPLETION_KEY_USER_COMMAND,  // distinguished key
           @ptrToInt(cmd),              // smuggle command pointer
           .SUCCESS,
           0,
       );
       if (status != .SUCCESS) return error.PostFailed;
   }
   ```

3. **Event loop dispatch** — In `poll()`, after dequeuing a completion, check the completion key:
   ```zig
   if (entry.lpCompletionKey == COMPLETION_KEY_USER_COMMAND) {
       const cmd: *Command = @ptrFromInt(entry.lpOverlapped);
       self.dispatchCommand(cmd);
       // Free or recycle command struct
   } else {
       // Normal AFD_POLL readiness event — handle as before
   }
   ```

4. **Key invariant**: All socket state mutation happens on the event loop thread. External threads only allocate a command struct, fill it in, and post it. The event loop processes it serially alongside I/O events.

#### Required Command Flow Examples
- **Send from worker thread**: Worker computes response → allocates `send_data` command with buffer → posts to IOCP → event loop receives it → appends to socket's send buffer → arms `AFD_POLL_SEND` if not already armed → data goes out on next writable event.
- **Graceful shutdown from main thread**: Main thread posts `shutdown` → event loop receives it → cancels all pending AFD_POLLs → closes all sockets → exits poll loop.
- **Dynamic connection from management thread**: Posts `connect` with target address → event loop creates socket, sets non-blocking, calls `connect()`, registers with AFD_POLL for `AFD_POLL_SEND` (connect completion) and `AFD_POLL_CONNECT_FAIL`.

---

### Requirement: Evaluate Alternative IOCP-Based Approaches

Before implementing the AFD_POLL Reactor, **analyze and document** alternative approaches to building a readiness-based or hybrid event loop on Windows using IOCP. For each alternative, describe the mechanism, its trade-offs versus AFD_POLL, and why it was accepted or rejected.

#### Alternatives to consider

**Alternative 1: Zero-byte WSARecv / WSASend as readiness probe**

Issue a `WSARecv` with a zero-length buffer via IOCP. The completion fires when data is *available* (readable) without actually consuming any data. Then perform the real non-blocking `recv()`. Similarly, a zero-byte `WSASend` can probe writability.

- *Pros*: Uses only documented Winsock APIs. No ntdll dependency.
- *Cons*: Behavior is not officially guaranteed as a "readiness" signal — it's an implementation artifact. Does not cover all event types (accept, connect failure, disconnect detection) as cleanly. Separate probes needed for read vs. write. Some LSPs may not handle it correctly.

**Alternative 2: WSAEventSelect + IOCP hybrid (traditional)**

Use `WSAEventSelect` to get readiness notifications on `WSAEVENT` objects, then have a dedicated thread `WaitForMultipleObjects` on those events and post results to IOCP via `PostQueuedCompletionStatus`.

- *Pros*: Fully documented. Clean readiness semantics.
- *Cons*: `WaitForMultipleObjects` limited to 64 handles — requires thread fan-out for more sockets. Extra bridging thread(s). Adds latency. Defeats the purpose of using IOCP directly.

**Alternative 3: WSAPoll (Windows poll)**

Windows provides `WSAPoll()` (similar to POSIX `poll()`).

- *Pros*: Familiar API. Documented.
- *Cons*: Does not integrate with IOCP at all. Has known bugs in older Windows versions. Does not scale — O(n) per call. Cannot be woken externally without a self-pipe trick. Not viable for high-concurrency.

**Alternative 4: Registered I/O (RIO)**

Windows 8+ provides Registered I/O — a high-performance API with pre-registered buffers and completion queues.

- *Pros*: Extremely high performance. Kernel bypass-like semantics. Has its own completion queue mechanism.
- *Cons*: Still fundamentally a Proactor (you post sends/receives, get completions). Complex buffer registration. Not a Reactor model. Windows 8+ only. Massive API surface for little gain if you want Reactor semantics.

**Alternative 5: Self-pipe / loopback socket trick**

Create a loopback TCP or UDP socket pair. To wake the event loop or inject commands, write a byte to the pipe. The event loop's `select()`/`WSAPoll()` or AFD_POLL detects readability on the pipe socket.

- *Pros*: Portable pattern (used everywhere on Unix). Works with any readiness API.
- *Cons*: Introduces a synthetic socket just for signaling. Adds system call overhead. With IOCP, `PostQueuedCompletionStatus`/`NtSetIoCompletion` is strictly superior for wake-up — no need for a pipe. May be useful as a **fallback** in environments where `PostQueuedCompletionStatus` is not available, but on Windows IOCP it's redundant.

**Alternative 6: Pure Proactor (standard IOCP with WSASend/WSARecv)**

Don't fight IOCP — use it as designed. Issue overlapped reads/writes and process completions.

- *Pros*: The "intended" Windows way. Well-documented. Battle-tested.
- *Cons*: Buffer ownership complexity (who owns the buffer between issue and completion?). Hard to integrate with single-threaded application logic. Difficult to unify cross-platform with epoll/kqueue which are inherently Reactor. Cancellation semantics are complex.

**Alternative 7: WSAEventSelect + NtAssociateWaitCompletionPacket (Event-to-IOCP Bridge)**

This is a hybrid approach that uses **documented Winsock readiness semantics** combined with **undocumented NT wait completion packets** to bridge the two worlds without the 64-handle limit:

*Mechanism:*
1. For each socket, call `WSAEventSelect(socket, hEvent, FD_READ | FD_WRITE | FD_CLOSE | ...)` to register interest — Winsock will signal the `WSAEVENT` (an NT Event object) when the socket becomes ready.
2. Call `NtCreateWaitCompletionPacket()` to create a wait packet for each socket.
3. Call `NtAssociateWaitCompletionPacket(waitPacket, iocp, hEvent, socketContext, ...)` — this tells the kernel: *"when this event object becomes signaled, post a completion packet to my IOCP with the given key/context."*
4. The event loop calls `GetQueuedCompletionStatus(Ex)` / `NtRemoveIoCompletionEx` on the IOCP as usual.
5. When a readiness event fires, the wait packet posts to the IOCP. The event loop retrieves the socket context from the completion key.
6. The event loop calls `WSAEnumNetworkEvents()` on the socket to determine *which* events fired (FD_READ, FD_WRITE, etc.) and clear the event record.
7. Perform non-blocking `send()`/`recv()` as appropriate.
8. **Re-arm:** Call `NtAssociateWaitCompletionPacket` again (one-shot, must re-associate after each signal).

*Pros:*
- Uses **documented** Winsock readiness semantics (`WSAEventSelect` / `WSAEnumNetworkEvents`) — well-understood, battle-tested FD_READ/FD_WRITE/FD_CLOSE semantics.
- Bypasses the **64-handle limit** of `WaitForMultipleObjects` — thousands of sockets on a single IOCP.
- No `\Device\Afd` or AFD structures — avoids the undocumented AFD_POLL_INFO format.
- Same code path used by the Windows Thread Pool internally (`CreateThreadpoolWait`), so it's stable despite being "undocumented."
- Clean separation: Winsock handles readiness detection, NT handles efficient delivery.

*Cons:*
- **Two undocumented APIs required** (`NtCreateWaitCompletionPacket`, `NtAssociateWaitCompletionPacket`) — same level of "undocumented" as AFD_POLL, but with less community precedent in this specific socket context.
- **Requires one Event object + one WaitCompletionPacket per socket** — more kernel objects than AFD_POLL (which needs only an IO_STATUS_BLOCK per socket). With 10,000 connections, that's 20,000 additional kernel handles.
- **Indirection overhead**: socket readiness → Event signal → WaitPacket → IOCP completion → `WSAEnumNetworkEvents` call. AFD_POLL delivers events directly on the IOCP in one step.
- **`WSAEventSelect` has quirks**: it forces the socket into non-blocking mode (acceptable for Reactor), but it also has edge-triggered-like re-enabling semantics that must be understood (e.g., FD_WRITE fires once after connect, then only after WSAEWOULDBLOCK + buffer space).
- **Race condition risk**: Between the Event being signaled and `WSAEnumNetworkEvents` being called, the event state may change. Must handle spurious wake-ups gracefully.
- **Windows 8+ only** for the wait completion packet APIs (same as if we used RIO).
- **Not proven for sockets at scale** — while `NtAssociateWaitCompletionPacket` is proven for Event objects (thread pool, process waits), its use combined with `WSAEventSelect` for high-frequency socket I/O is novel and untested in production. AFD_POLL is battle-tested in mio, libuv, wepoll, c-ares.

*Architecture sketch (Zig-like pseudocode):*
```zig
const SocketState = struct {
    socket: SOCKET,
    event: HANDLE,          // from WSACreateEvent()
    wait_packet: HANDLE,    // from NtCreateWaitCompletionPacket()
    // ... buffers, state
};

fn registerSocket(self: *Reactor, sock: SOCKET, interests: u32) !void {
    var state = try self.allocator.create(SocketState);
    state.socket = sock;
    state.event = WSACreateEvent();
    
    // Register readiness interest via documented Winsock API
    WSAEventSelect(sock, state.event, interests);
    
    // Create wait completion packet
    NtCreateWaitCompletionPacket(&state.wait_packet, MAXIMUM_ALLOWED, null);
    
    // Bridge: Event signal → IOCP completion
    var already_signaled: bool = false;
    NtAssociateWaitCompletionPacket(
        state.wait_packet,
        self.iocp,
        state.event,        // waitable target
        @ptrCast(state),    // completion key = socket context
        null,               // APC context
        0, 0,
        &already_signaled,
    );
    
    if (already_signaled) {
        // Event was already signaled — handle immediately
    }
}

fn handleCompletion(self: *Reactor, key: *SocketState) void {
    // Determine WHICH events fired (documented API)
    var network_events: WSANETWORKEVENTS = undefined;
    WSAEnumNetworkEvents(key.socket, key.event, &network_events);
    
    if (network_events.lNetworkEvents & FD_READ != 0) {
        // Socket is readable — do non-blocking recv()
    }
    if (network_events.lNetworkEvents & FD_WRITE != 0) {
        // Socket is writable — do non-blocking send()
    }
    // ... FD_CLOSE, FD_ACCEPT, etc.
    
    // Re-arm the wait completion packet (one-shot)
    NtAssociateWaitCompletionPacket(
        key.wait_packet, self.iocp, key.event,
        @ptrCast(key), null, 0, 0, null,
    );
}
```

*Verdict:* This is a **legitimate and interesting alternative** that should be prototyped alongside AFD_POLL in Stage 7. Its advantage is relying on documented Winsock readiness semantics (no AFD structs). Its main risks are the kernel object overhead at scale and the lack of production validation in the socket-specific use case. If kernel handle overhead is acceptable and `WSAEnumNetworkEvents` performance is adequate, this could be a viable **fallback path** for environments where AFD_POLL access is restricted or for simpler applications that don't need 10,000+ connections.

#### Deliverable
Include a companion document (`ALTERNATIVES.md`) that summarizes the above analysis with a clear rationale for choosing AFD_POLL as the primary mechanism, while noting where other approaches (especially Alternative 7) could serve as fallback or complement. Include empirical data from Stage 7 if available.

---

## Staged Implementation Plan

Implementation must follow a staged approach. Each stage has a clear goal, deliverable, and acceptance criteria. **Do not advance to the next stage until the current stage is verified and tested.** Report feasibility issues immediately if discovered at any stage.

### Stage 0: Feasibility & Environment Validation

**Goal:** Confirm that all required NT APIs are accessible from Zig 0.15.2 and that AFD_POLL works at all.

**Tasks:**
1. Set up a Zig 0.15.2 project on Windows 10+.
2. Resolve ntdll function pointers dynamically (or use `std.os.windows.ntdll` where available):
   - `NtCreateIoCompletion`
   - `NtSetIoCompletion`
   - `NtRemoveIoCompletion` / `NtRemoveIoCompletionEx`
   - `NtDeviceIoControlFile`
   - `NtCancelIoFileEx`
   - `NtSetInformationFile`
3. Create a minimal test: open a TCP listener socket, obtain its base handle via `SIO_BASE_HANDLE`, create an IOCP, associate the socket, issue a single `AFD_POLL` for `AFD_POLL_ACCEPT`.
4. From a second thread (or a separate test process), connect to the listener.
5. Verify that the AFD_POLL completion fires on the IOCP with `AFD_POLL_ACCEPT` set.

**Acceptance criteria:**
- All ntdll function pointers resolve successfully.
- AFD_POLL completion is received with correct event flags.
- No crashes, no undefined behavior, clean Zig compilation with no `@cImport` hacks (prefer `std.os.windows` or manual extern declarations).

**Feasibility gate:** If `NtDeviceIoControlFile` with `IOCTL_AFD_POLL` does not work from Zig (e.g., handle type mismatch, missing definitions), document the blocker and evaluate whether thin C shim or `zigwin32` bindings can resolve it before proceeding.

---

### Stage 1: Minimal IOCP Event Loop (No Sockets)

**Goal:** Build the event loop skeleton with IOCP create, wait, and cross-thread wake-up.

**Tasks:**
1. Implement `Reactor.init()` — creates IOCP via `NtCreateIoCompletion`.
2. Implement `Reactor.poll(timeout_ms)` — calls `NtRemoveIoCompletionEx`, returns list of completions.
3. Implement `Reactor.wake()` — posts a wake-up sentinel via `NtSetIoCompletion`.
4. Implement `Reactor.deinit()` — closes IOCP handle.
5. **Test:** Spawn a thread that sleeps 100ms then calls `wake()`. Main thread blocks in `poll()`. Verify it unblocks.
6. **Test:** Call `poll(50)` with no pending work. Verify it times out after ~50ms.

**Acceptance criteria:**
- Event loop blocks and unblocks correctly.
- Timeout behavior is accurate (±10ms tolerance).
- No resource leaks (handle leak checker).

---

### Stage 2: Cross-Thread Command Injection

**Goal:** External threads can post typed commands that the event loop dispatches.

**Tasks:**
1. Define the `Command` tagged union.
2. Implement `Reactor.postCommand(cmd)` — allocates (or accepts pre-allocated) command, posts via `NtSetIoCompletion` with `COMPLETION_KEY_USER_COMMAND`.
3. In `poll()`, distinguish user commands from I/O completions by completion key. Dispatch commands to a handler.
4. Implement command pool or arena allocator for commands to avoid per-command heap allocation.
5. **Test:** Spawn 4 threads, each posting 1000 `custom` commands with unique IDs. Event loop collects all 4000 commands. Verify none lost, none duplicated, all processed on the event loop thread.
6. **Test:** Post a `shutdown` command. Verify event loop exits cleanly.

**Acceptance criteria:**
- All commands arrive and are processed.
- No race conditions (verify with thread sanitizer or stress test).
- Command throughput > 100,000 commands/sec under stress.

---

### Stage 3: Single-Socket AFD_POLL Readiness

**Goal:** Register one TCP socket for readiness and receive AFD_POLL completions.

**Tasks:**
1. Implement `SocketState` struct: base handle, interest set, `IO_STATUS_BLOCK`, `AFD_POLL_INFO`, connection state.
2. Implement `Reactor.register(socket, events, callback)`:
   - Get base handle via `SIO_BASE_HANDLE`.
   - Associate with IOCP via `NtSetInformationFile` + `FileCompletionInformation`.
   - Issue `AFD_POLL` via `NtDeviceIoControlFile`.
3. In `poll()`, when AFD_POLL completes, extract fired events from `AFD_POLL_INFO.Handles[0].Events`, invoke callback.
4. Implement re-arm: after callback returns, re-issue `AFD_POLL` if socket still registered.
5. **Test:** Create a TCP listener, register for `AFD_POLL_ACCEPT`. Connect from another thread. Verify accept readiness fires. Accept the connection (non-blocking). Re-arm. Connect again. Verify second notification.
6. **Test:** Create a connected TCP pair. Register client side for `AFD_POLL_RECEIVE`. Send data from server side. Verify readiness fires. `recv()` the data. Verify data correct.

**Acceptance criteria:**
- Readiness callbacks fire for correct events.
- Re-arming works repeatedly (100+ cycles without leak or hang).
- No stale completions after deregister.

---

### Stage 4: Multi-Socket Management

**Goal:** Handle many concurrent sockets with register/modify/deregister lifecycle.

**Tasks:**
1. Implement socket registry (HashMap or slot allocator keyed by handle).
2. Implement `Reactor.modify(socket, new_events)` — cancel current AFD_POLL via `NtCancelIoFileEx`, wait for cancellation completion, re-issue with new event mask.
3. Implement `Reactor.deregister(socket)` — cancel pending AFD_POLL, remove from registry, handle inflight cancellation completion gracefully.
4. Handle cancellation edge case: AFD_POLL may complete *between* your cancel request and the cancel taking effect. Must handle both "cancelled" and "completed normally" after a cancel call.
5. **Test:** Register 100 sockets. Deregister 50 randomly. Modify 25 of the remaining. Verify no leaks, no stale callbacks, no crashes.
6. **Test:** Rapid register/deregister cycling on the same socket. Stress test cancel races.

**Acceptance criteria:**
- All lifecycle operations are clean under stress.
- No use-after-free on `IO_STATUS_BLOCK` or `AFD_POLL_INFO`.
- Memory is stable after 10,000 register/deregister cycles.

---

### Stage 5: Non-Blocking Send/Recv with Buffering

**Goal:** Full bidirectional data flow with per-socket send/receive buffers.

**Tasks:**
1. Add per-socket send ring buffer (or growable list). When `send_data` command arrives or application wants to send, append to buffer. Arm `AFD_POLL_SEND` if not armed.
2. On `AFD_POLL_SEND` readiness: call non-blocking `send()`, handle partial sends (advance buffer pointer), handle `WSAEWOULDBLOCK` (re-arm and wait). Disarm `AFD_POLL_SEND` when buffer is empty.
3. On `AFD_POLL_RECEIVE` readiness: call non-blocking `recv()`, deliver data to application callback. Handle zero-length recv (peer closed). Handle `WSAEWOULDBLOCK`.
4. Handle `AFD_POLL_DISCONNECT`, `AFD_POLL_ABORT` — invoke error/close callbacks.
5. **Test:** Echo test — connect, send 1MB of data, verify echo matches. Verify with multiple concurrent connections.
6. **Test:** Partial send test — send large buffers that exceed socket buffer size, verify all data eventually transmitted.
7. **Test:** Peer disconnect — close client mid-transfer, verify server detects and cleans up.

**Acceptance criteria:**
- Zero data loss in echo test (byte-for-byte match).
- Handles backpressure (slow consumer) without unbounded memory growth.
- Clean detection and handling of all disconnect/error conditions.

---

### Stage 6: TCP Echo Server Demo

**Goal:** Complete working demo combining all stages.

**Tasks:**
1. TCP listener accepts connections via AFD_POLL readiness.
2. Each accepted connection registered for `AFD_POLL_RECEIVE`.
3. On data received, echo it back (append to send buffer, arm write).
4. A separate "injector" thread periodically posts `send_data` commands with heartbeat messages to random connected clients — demonstrating cross-thread command injection.
5. A management thread posts `shutdown` after N seconds — demonstrating graceful shutdown flow.
6. Handle all edge cases from Stage 5.

**Acceptance criteria:**
- Handles 100+ concurrent connections single-threaded.
- Cross-thread heartbeat messages arrive correctly at clients.
- Graceful shutdown closes all connections and frees all resources.
- Can be tested with standard tools (`telnet`, `nc`, or a simple Zig TCP client).

---

### Stage 7: Alternatives Validation (Recommended)

**Goal:** Empirically validate the most promising alternatives by prototyping them.

**Tasks:**
1. **Alternative 7 prototype** — Implement the `WSAEventSelect` + `NtAssociateWaitCompletionPacket` approach for single-socket readiness (equivalent to Stage 3). This validates:
   - Can `NtAssociateWaitCompletionPacket` reliably deliver `WSAEventSelect` signals to the IOCP?
   - What is the latency overhead of the Event→IOCP bridge vs. direct AFD_POLL?
   - Does `WSAEnumNetworkEvents` correctly report events after the wait packet fires?
   - Are there race conditions between Event signal and enumeration?
2. **Zero-byte WSARecv prototype** — Implement a zero-byte recv variant for read readiness (Alternative 1).
3. **Benchmark**: Compare latency and throughput across all three approaches for 100 and 1000 sockets with continuous traffic:
   - AFD_POLL (primary)
   - WSAEventSelect + NtAssociateWaitCompletionPacket (Alternative 7)
   - Zero-byte WSARecv (Alternative 1)
4. **Document results** in `ALTERNATIVES.md` alongside the theoretical analysis.

**Acceptance criteria:**
- Side-by-side benchmark with reproducible results.
- Clear recommendation with data backing.
- Document any Alternative 7 failure modes or limitations discovered.

---

## API Surface (Zig)

```zig
const Reactor = struct {
    // Lifecycle
    pub fn init(allocator: std.mem.Allocator) !Reactor;
    pub fn deinit(self: *Reactor) void;

    // Socket registration
    pub fn register(self: *Reactor, socket: windows.HANDLE, events: EventFlags,
                    callback: ReadinessCallback, user_data: ?*anyopaque) !void;
    pub fn modify(self: *Reactor, socket: windows.HANDLE, new_events: EventFlags) !void;
    pub fn deregister(self: *Reactor, socket: windows.HANDLE) !void;

    // Event loop
    pub fn poll(self: *Reactor, timeout_ms: i32) !u32;  // returns number of events processed

    // Cross-thread command injection (thread-safe)
    pub fn postCommand(self: *Reactor, cmd: *Command) !void;

    // Wake (lightweight — no command, just unblock poll)
    pub fn wake(self: *Reactor) !void;
};

const EventFlags = packed struct {
    receive: bool = false,
    send: bool = false,
    accept: bool = false,
    disconnect: bool = false,
    abort: bool = false,
    connect_fail: bool = false,
    // maps to AFD_POLL_* constants
};

const ReadinessCallback = *const fn (
    socket: windows.HANDLE,
    fired_events: EventFlags,
    user_data: ?*anyopaque,
) void;
```

---

## Deliverables

1. **Source code** in Zig 0.15.2 — modular, with separate files for:
   - `reactor.zig` — core event loop
   - `afd.zig` — AFD structures, constants, ntdll bindings
   - `socket_state.zig` — per-socket state management
   - `command.zig` — cross-thread command definitions and pool
   - `demo_echo_server.zig` — TCP echo server demo
2. **`ALTERNATIVES.md`** — analysis of all 7 alternative IOCP-based approaches with rationale, including empirical data from Stage 7.
3. **`STAGES.md`** — implementation log: what was done at each stage, what was tested, what issues were found.
4. **Test suite** — at minimum, the tests described in each stage above.
5. **Inline comments** explaining the AFD_POLL mechanism, lifecycle, and non-obvious Windows internals.
6. Handle edge cases: partial sends, `WSAEWOULDBLOCK`, connection reset, half-close, cancel races.

---

## Constraints

- **Zig 0.15.2** — no nightly, no older versions.
- No third-party libraries (no libuv, no mio — build from scratch). `zigwin32` bindings may be used for type definitions only if `std.os.windows` is insufficient.
- **Prefer NT Native API over Win32** — follow the Zig project's direction of bypassing kernel32.dll where possible. Use ntdll functions directly. Win32 wrappers acceptable only where NT equivalent does not exist or offers no advantage.
- ntdll function pointers should be resolved via `std.os.windows.ntdll` where available, or dynamically via `GetProcAddress(GetModuleHandle("ntdll.dll"), ...)` for functions not yet in Zig's stdlib.
- Target: Windows 10+.

---

## References

### Primary — Zig & NT API
- **Zig ntdll.zig** — ntdll.h ported to Zig, the authoritative source for NT function signatures in Zig:
  <https://codeberg.org/ziglang/zig/src/branch/master/lib/std/os/windows/ntdll.zig>

- **"Bypassing Kernel32.dll for Fun and Nonprofit"** — Zig devlog entry explaining *why* Zig prefers NT Native API over Win32, with implementation rationale:
  <https://ziglang.org/devlog/2026/#2026-02-03>

- **Zig issue #31131: "Windows: Prefer the Native API over Win32"** — tracking issue and design discussion for Zig's NT-first Windows strategy:
  <https://codeberg.org/ziglang/zig/issues/31131>

- **zigwin32** — Community-maintained Zig bindings for the full Windows API surface, useful for type definitions and constants not yet in std:
  <https://github.com/marlersoft/zigwin32/tree/main/win32>

### NT Wait Completion Packet APIs
- **NtAssociateWaitCompletionPacket** — Microsoft semi-documented reference:
  <https://learn.microsoft.com/en-us/windows/win32/devnotes/ntassociatewaitcompletionpacket>

- **NtCreateWaitCompletionPacket** — Microsoft semi-documented reference:
  <https://learn.microsoft.com/en-us/windows/win32/devnotes/ntcreatewaitcompletionpacket>

- **NtDoc: NtAssociateWaitCompletionPacket** — community documentation with full signatures and header references from Process Hacker / System Informer:
  <https://ntdoc.m417z.com/ntassociatewaitcompletionpacket>

- **NtDoc: NtCreateWaitCompletionPacket**:
  <https://ntdoc.m417z.com/ntcreatewaitcompletionpacket>

- **win32-iocp-events** — Minimal working example of using NtAssociateWaitCompletionPacket to wait on Event objects via IOCP, bypassing the 64-handle limit:
  <https://github.com/tringi/win32-iocp-events>

- **.NET Runtime issue #90866** — Discussion of using NtAssociateWaitCompletionPacket for scalable registered waits, with analysis of Win32 thread pool internals:
  <https://github.com/dotnet/runtime/issues/90866>

### AFD_POLL & Socket Readiness
- **"Socket readiness without \Device\Afd"** — Len Holgate's discovery that AFD_POLL can be issued directly on the socket handle (no \Device\Afd open required), with working C code and test suite:
  <https://lenholgate.com/blog/2024/06/socket-readiness-without-device-afd.html>

- **"Adventures with \Device\Afd"** — Full blog series on AFD_POLL from first principles:
  <https://lenholgate.com/blog/2023/04/adventures-with-afd.html>

- **wepoll** — Compact epoll emulation for Windows using AFD_POLL (~1500 lines of C):
  <https://github.com/piscisaureus/wepoll>

- **c-ares Windows event engine** — Uses AFD_POLL without opening \Device\Afd (the approach Brad House described to Len Holgate):
  <https://github.com/c-ares/c-ares/blob/main/src/lib/ares_event_win32.c>

### Secondary — Reference Implementations
- **mio Windows implementation** — Rust's async I/O on Windows, Reactor over IOCP:
  <https://github.com/tokio-rs/mio/tree/master/src/sys/windows>

- **libuv Windows core** — Node.js's event loop on Windows:
  <https://github.com/libuv/libuv/tree/v1.x/src/win>

- **Zig stdlib Windows I/O** — Zig's own approach to Windows async I/O:
  <https://codeberg.org/ziglang/zig/src/branch/master/lib/std/os/windows.zig>

### Tertiary — Windows Documentation
- ReactOS source for AFD structure definitions.
- Microsoft: [Registered I/O](https://learn.microsoft.com/en-us/windows/win32/api/mswsock/ns-mswsock-rio_extension_function_table).
- Microsoft: [PostQueuedCompletionStatus](https://learn.microsoft.com/en-us/windows/win32/fileio/postqueuedcompletionstatus).
- Microsoft: [I/O Completion Ports](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports).
- Microsoft: [WSAEventSelect](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaeventselect).
- Microsoft: [WSAEnumNetworkEvents](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaenumnetworkevents).
