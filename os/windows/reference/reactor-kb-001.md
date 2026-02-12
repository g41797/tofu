<!-- 

Resume this session with:                                                                                                                           
claude --resume 061c6fbc-00ba-4445-9bf7-752761fd801c 

-->


# Reactor-over-IOCP Knowledge Base

**Version:** 001
**Created:** 2026-02-12
**Purpose:** Comprehensive reference for tofu Windows port project
**Source Documents:**
- `reactor-over-iocp-prompt-005.md` — IOCP Reactor specification
- `reactor-addednum-1.md` — Reference corrections
- `reactor-questions-001.md` — Initial Q&A (partially answered)
- `reactor-questions-002.md` — Follow-up Q&A (pending answers)
- tofu documentation (`/home/g41797/dev/root/github.com/g41797/tofu/docs_site/docs/mds/`)

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [tofu Architecture](#2-tofu-architecture)
3. [Windows IOCP Technical Details](#3-windows-iocp-technical-details)
4. [Mapping: tofu ↔ IOCP Concepts](#4-mapping-tofu--iocp-concepts)
5. [Key Design Decisions](#5-key-design-decisions)
6. [Implementation Stages](#6-implementation-stages)
7. [Alternative Approaches](#7-alternative-approaches)
8. [API Reference](#8-api-reference)
9. [Reference Links](#9-reference-links)
10. [Open Questions](#10-open-questions)
11. [Session Context](#11-session-context)

---

## 1. Project Overview

### 1.1 What is tofu?

**tofu** is a Zig-based asynchronous messaging library implementing the Reactor pattern:
- **Protocol** and **library** for peer-to-peer messaging
- **100% native Zig** — no C dependencies
- **Stream-oriented transports**: TCP/IP and Unix Domain Sockets
- **Message-based**: discrete messages, not raw byte streams
- **Queue-based API**: no callbacks exposed to application

**GitHub:** https://github.com/g41797/tofu
**Local repo:** `/home/g41797/dev/root/github.com/g41797/tofu/`

### 1.2 Project Goal

Add **Windows 10+ support** to tofu by implementing a Windows-native Reactor using:
- **IOCP** (I/O Completion Ports) as the event notification mechanism
- **AFD_POLL** for socket readiness detection (Reactor semantics)
- **ntdll APIs** following Zig's NT-first philosophy

### 1.3 Current State

- tofu works on **Linux only** (uses epoll)
- Windows development environment is ready
- Specification document (`reactor-over-iocp-prompt-005.md`) drafted
- Architecture analysis complete
- Questions pending user answers

### 1.4 Constraints

| Constraint | Value |
|------------|-------|
| Zig version | 0.15.2 |
| Windows version | 10+ |
| Target scale | < 1000 connections |
| Message size limit | 128 KiB |
| Transports | TCP + Unix sockets (AF_UNIX) |
| Threading | Single I/O thread (Reactor model) |
| API style | Queue-based (no callbacks) |

---

## 2. tofu Architecture

### 2.1 Component Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        APPLICATION LAYER                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Ampe Interface                                                     │
│   ├── get(strategy) → ?*Message      // Get from pool               │
│   ├── put(&msg)                      // Return to pool              │
│   ├── create() → ChannelGroup        // Create channel group        │
│   └── destroy(chnls)                 // Destroy channel group       │
│                                                                      │
│   ChannelGroup Interface                                             │
│   ├── post(&msg) → BinaryHeader      // Submit message (async)      │
│   ├── waitReceive(timeout) → ?*Msg   // Wait for message            │
│   └── updateReceiver(&msg)           // Cross-thread signal         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ENGINE LAYER                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Reactor (Linux Implementation)                                     │
│   ├── Internal I/O thread with poll loop                            │
│   ├── epoll for socket readiness                                    │
│   ├── Internal socket for ChannelGroup communication                │
│   ├── Message pool management                                       │
│   └── Channel lifecycle management                                  │
│                                                                      │
│   [NEEDED: WindowsReactor implementing same Ampe interface]         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         NETWORK LAYER                                │
├─────────────────────────────────────────────────────────────────────┤
│   TCP Sockets    │    Unix Domain Sockets                           │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 Key Abstractions

| Component | Description | Platform-Specific |
|-----------|-------------|-------------------|
| **Ampe** | Interface to engine (get/put messages, create/destroy channel groups) | No (interface) |
| **Reactor** | Engine implementation (I/O thread, poll loop) | **YES** |
| **ChannelGroup** | Message queues, channel management | Likely reusable |
| **Message** | Binary header + text headers + body | Reusable |
| **Channel** | Virtual connection (listener or I/O) | Reusable |

### 2.3 Message Structure

```
┌─────────────────┐
│  BinaryHeader   │  ← Always present (16 bytes)
├─────────────────┤     - channel_number (u16)
│  TextHeaders    │     - proto (OpCode, origin, more flag)
├─────────────────┤     - status (u8)
│  Body           │     - message_id (u64)
└─────────────────┘

Max size: 64 KiB - 1 (TextHeaders + Body combined)
tofu limit: 128 KiB per message
```

### 2.4 OpCodes

| OpCode | Value | Purpose |
|--------|-------|---------|
| Request | 0 | Ask peer for something |
| Response | 1 | Answer to request |
| Signal | 2 | One-way notification |
| HelloRequest | 3 | Client: initiate connection |
| HelloResponse | 4 | Server: accept connection |
| ByeRequest | 5 | Start graceful close |
| ByeResponse | 6 | Acknowledge close |
| ByeSignal | 7 | Immediate close |
| WelcomeRequest | 8 | Server: start listening |
| WelcomeResponse | 9 | Engine: listener ready |

### 2.5 Message Flow

```
Application                    tofu Engine                    Network
    │                              │                             │
    ├──post()───► [Send Queue] ───►│──► socket.write() ─────────►│
    │                              │                             │
    │◄──waitReceive()◄─[Recv Queue]│◄── socket.read() ◄─────────│
    │                              │                             │
    ├──updateReceiver()───────────►│  (cross-thread wake-up)    │
```

### 2.6 Threading Model

- **Application threads**: Call `post()`, `waitReceive()`, `updateReceiver()`
- **I/O thread**: Single thread running poll loop, handles all socket operations
- **Thread safety**: `post()` and `updateReceiver()` are thread-safe
- **Constraint**: Only one thread should call `waitReceive()` per ChannelGroup

### 2.7 Memory Management

**Message Pool:**
- Pre-allocated messages for performance
- `get(.poolOnly)` — returns null if pool empty
- `get(.always)` — allocates if pool empty
- `put(&msg)` — returns to pool, sets msg to null

**Configuration:**
```zig
const Options = struct {
    initialPoolMsgs: ?u16 = null,  // Default: 16
    maxPoolMsgs: ?u16 = null,      // Default: 64
};
```

**Allocator requirement:** GPA-compatible (thread-safe, process lifetime)

---

## 3. Windows IOCP Technical Details

### 3.1 IOCP Overview

**I/O Completion Ports** — Windows kernel object for high-performance async I/O:
- Efficient thread wake-up mechanism
- Scalable to thousands of handles
- Natively a **Proactor** (completion-based), but can be used as **Reactor**

### 3.2 The Core Trick: AFD_POLL

**AFD** (Ancillary Function Driver) — kernel driver behind Winsock

**AFD_POLL** — issues a readiness query instead of actual I/O:
- "Notify me when this socket becomes readable/writable"
- Completion posts to IOCP when socket is ready
- Application then performs non-blocking I/O
- **One-shot**: must re-arm after each event (like EPOLLONESHOT)

```c
#define IOCTL_AFD_POLL 0x00012024

typedef struct _AFD_POLL_HANDLE_INFO {
    HANDLE Handle;
    ULONG Events;       // AFD_POLL_RECEIVE, AFD_POLL_SEND, etc.
    NTSTATUS Status;
} AFD_POLL_HANDLE_INFO;

typedef struct _AFD_POLL_INFO {
    LARGE_INTEGER Timeout;
    ULONG NumberOfHandles;
    ULONG Exclusive;
    AFD_POLL_HANDLE_INFO Handles[1];
} AFD_POLL_INFO;
```

### 3.3 AFD Event Flags

| Flag | Value | Meaning |
|------|-------|---------|
| AFD_POLL_RECEIVE | 0x0001 | Data available to read |
| AFD_POLL_RECEIVE_EXPEDITED | 0x0002 | OOB data available |
| AFD_POLL_SEND | 0x0004 | Socket is writable |
| AFD_POLL_DISCONNECT | 0x0008 | Peer disconnected (FIN) |
| AFD_POLL_ABORT | 0x0010 | Connection aborted (RST) |
| AFD_POLL_LOCAL_CLOSE | 0x0020 | Local close |
| AFD_POLL_ACCEPT | 0x0080 | Incoming connection |
| AFD_POLL_CONNECT_FAIL | 0x0100 | Outbound connect failed |

### 3.4 Key NT APIs (from ntdll.dll)

| API | Purpose | Win32 Equivalent |
|-----|---------|------------------|
| `NtCreateIoCompletion` | Create IOCP | `CreateIoCompletionPort` |
| `NtSetIoCompletion` | Post completion packet | `PostQueuedCompletionStatus` |
| `NtRemoveIoCompletion` | Dequeue single completion | `GetQueuedCompletionStatus` |
| `NtRemoveIoCompletionEx` | Dequeue multiple completions | `GetQueuedCompletionStatusEx` |
| `NtDeviceIoControlFile` | Issue AFD_POLL | N/A (uses DeviceIoControl) |
| `NtSetInformationFile` | Associate handle with IOCP | `CreateIoCompletionPort` |
| `NtCancelIoFileEx` | Cancel pending I/O | `CancelIoEx` |

### 3.5 Wait Completion Packet APIs (Windows 8+)

For waiting on NT objects (events, processes, etc.) via IOCP:

```c
NtCreateWaitCompletionPacket(
    PHANDLE WaitCompletionPacketHandle,
    ACCESS_MASK DesiredAccess,
    POBJECT_ATTRIBUTES ObjectAttributes
);

NtAssociateWaitCompletionPacket(
    HANDLE WaitCompletionPacketHandle,
    HANDLE IoCompletionHandle,      // IOCP
    HANDLE TargetObjectHandle,      // Waitable object
    PVOID KeyContext,               // Completion key
    PVOID ApcContext,               // lpOverlapped equivalent
    NTSTATUS IoStatus,
    ULONG_PTR IoStatusInformation,
    PBOOLEAN AlreadySignaled
);

NtCancelWaitCompletionPacket(
    HANDLE WaitCompletionPacketHandle,
    BOOLEAN RemoveSignaledPacket
);
```

### 3.6 Per-Socket AFD_POLL (Recommended Approach)

**Key insight from Len Holgate:** Issue `NtDeviceIoControlFile` with `IOCTL_AFD_POLL` **directly on the socket handle** (not on a separate `\Device\Afd` handle):

- No need to open `\Device\Afd`
- Per-socket independent polls
- No group poll cancellation complexity
- Validated by: wepoll, c-ares, mio, libuv

### 3.7 Base Provider Handle

Winsock LSPs can wrap socket handles. AFD needs the real handle:

```c
SOCKET base_socket;
DWORD bytes;
WSAIoctl(socket, SIO_BASE_HANDLE, NULL, 0,
         &base_socket, sizeof(base_socket), &bytes, NULL, NULL);
```

**Potential issue:** Some LSPs don't support this (antivirus, VPN, firewalls).

---

## 4. Mapping: tofu ↔ IOCP Concepts

### 4.1 Conceptual Mapping

| tofu (Linux) | Windows IOCP |
|--------------|--------------|
| epoll fd | IOCP handle |
| epoll_wait() | NtRemoveIoCompletionEx() |
| epoll_ctl(ADD/MOD/DEL) | AFD_POLL issue/cancel |
| EPOLLIN/EPOLLOUT | AFD_POLL_RECEIVE/AFD_POLL_SEND |
| EPOLLONESHOT | AFD_POLL (inherently one-shot) |
| eventfd / internal socket | NtSetIoCompletion (IOCP posting) |
| updateReceiver() | NtSetIoCompletion with user key |

### 4.2 Cross-Thread Signaling

**tofu's `updateReceiver()`:**
- Wakes up blocked `waitReceive()`
- Can pass a message or just signal (null)
- Thread-safe

**Windows equivalent:**
```zig
// Post user completion packet to IOCP
NtSetIoCompletion(
    iocp_handle,
    COMPLETION_KEY_USER_UPDATE,  // Distinguished key
    @intFromPtr(msg),            // Message pointer (or 0)
    .SUCCESS,
    0,
);
```

### 4.3 Poll Loop Mapping

**Linux (epoll):**
```
loop {
    events = epoll_wait(epfd, timeout)
    for event in events {
        if event.fd == internal_socket: handle_channel_commands()
        else: handle_socket_event(event)
    }
}
```

**Windows (IOCP + AFD_POLL):**
```
loop {
    completions = NtRemoveIoCompletionEx(iocp, timeout)
    for completion in completions {
        if completion.key == USER_COMMAND: handle_channel_commands()
        elif completion.key == SOCKET_EVENT: handle_socket_event(completion)
    }
    // Re-arm AFD_POLL for sockets that need it
}
```

---

## 5. Key Design Decisions

### 5.1 Confirmed Decisions (from Q&A)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Windows version | 10+ only | Simplifies implementation, modern APIs |
| Async model | Standalone (no Zig async) | Matches current tofu design |
| Timer approach | IOCP timeout parameter | Simpler than timer wheel |
| Broken Zig #31131 ref | Replace with devlog + #1840 | Reference validation |
| Add libevent wepoll.c ref | Yes | Additional validation |

### 5.2 Pending Decisions (need user input)

| Decision | Options | Impact |
|----------|---------|--------|
| Memory ownership | Embed in SocketState / Pool / Leave to impl | Affects buffer management |
| Completion key design | Pointer / Handle + lookup / Slot index | Affects socket identification |
| SIO_BASE_HANDLE failure | Fail / Fallback / Warn | Affects LSP compatibility |
| Re-arm timing | Before callback / After callback | Affects event delivery |
| AF_UNIX priority | Required / Defer / Not needed | Affects MVP scope |

### 5.3 Architecture Decision: No Callbacks

tofu uses **queue-based API**, not callbacks:
- Application calls `waitReceive()` to get messages
- Engine pushes to queue, doesn't invoke callbacks
- Windows implementation must maintain this model
- Internal implementation can use any mechanism

---

## 6. Implementation Stages

### 6.1 Original Spec Stages

| Stage | Description | tofu Relevance |
|-------|-------------|----------------|
| 0 | Feasibility & Environment Validation | Essential |
| 1 | Minimal IOCP Event Loop (No Sockets) | Essential |
| 2 | Cross-Thread Command Injection | Essential (maps to updateReceiver) |
| 3 | Single-Socket AFD_POLL Readiness | Essential |
| 4 | Multi-Socket Management | Essential |
| 5 | Non-Blocking Send/Recv with Buffering | Essential |
| 6 | TCP Echo Server Demo | Adapt to tofu demo |
| 7 | Alternatives Validation | Optional |

### 6.2 Proposed tofu-Specific Stages

**Phase 1: Foundation**
1. Verify ntdll API access from Zig 0.15.2
2. Create minimal IOCP wrapper
3. Test cross-thread posting (NtSetIoCompletion)

**Phase 2: Socket Readiness**
4. Implement AFD_POLL for single socket
5. Test readiness detection (accept, read, write)
6. Implement re-arming logic

**Phase 3: Integration**
7. Create WindowsReactor skeleton implementing Ampe
8. Integrate IOCP event loop
9. Connect to existing ChannelGroup (if reusable)

**Phase 4: Validation**
10. Port existing tofu tests
11. Run echo server example
12. Cross-platform verification

---

## 7. Alternative Approaches

### 7.1 Summary of Alternatives

| # | Approach | Verdict |
|---|----------|---------|
| 1 | Zero-byte WSARecv/WSASend | Possible fallback, undocumented behavior |
| 2 | WSAEventSelect + IOCP hybrid | 64-handle limit, extra threads |
| 3 | WSAPoll | No IOCP integration, doesn't scale |
| 4 | Registered I/O (RIO) | Proactor, complex, overkill |
| 5 | Self-pipe/loopback socket | Redundant with IOCP posting |
| 6 | Pure Proactor | Buffer ownership complexity |
| **7** | **WSAEventSelect + NtAssociateWaitCompletionPacket** | **Interesting alternative** |

### 7.2 Alternative 7 Details

**Mechanism:**
1. `WSAEventSelect(socket, hEvent, FD_READ | FD_WRITE | ...)` — register interest
2. `NtCreateWaitCompletionPacket()` — create wait packet per socket
3. `NtAssociateWaitCompletionPacket(waitPacket, iocp, hEvent, ...)` — bridge Event→IOCP
4. Event loop dequeues from IOCP
5. `WSAEnumNetworkEvents()` — determine which events fired
6. Re-arm wait packet

**Pros:**
- Uses documented Winsock readiness semantics
- Bypasses 64-handle limit
- No AFD structures

**Cons:**
- 2 kernel objects per socket (Event + WaitPacket)
- Indirection overhead
- Less battle-tested for sockets
- Windows 8+ only

**Verdict:** Prototype alongside AFD_POLL in Stage 7 if time permits.

---

## 8. API Reference

### 8.1 Proposed Reactor API (from spec)

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
    pub fn poll(self: *Reactor, timeout_ms: i32) !u32;

    // Cross-thread (thread-safe)
    pub fn postCommand(self: *Reactor, cmd: *Command) !void;
    pub fn wake(self: *Reactor) !void;
};

const EventFlags = packed struct {
    receive: bool = false,
    send: bool = false,
    accept: bool = false,
    disconnect: bool = false,
    abort: bool = false,
    connect_fail: bool = false,
};
```

**Note:** This callback-based API from the spec needs adaptation for tofu's queue-based model.

### 8.2 tofu's Ampe Interface (target)

```zig
pub const Ampe = struct {
    pub fn create(ampe: Ampe) status.AmpeError!ChannelGroup;
    pub fn destroy(ampe: Ampe, chnls: ChannelGroup) status.AmpeError!void;
    pub fn get(ampe: Ampe, strategy: AllocationStrategy) status.AmpeError!?*message.Message;
    pub fn put(ampe: Ampe, msg: *?*message.Message) void;
    pub fn getAllocator(ampe: Ampe) Allocator;
};

pub const ChannelGroup = struct {
    pub fn post(chnls: ChannelGroup, msg: *?*message.Message) status.AmpeError!message.BinaryHeader;
    pub fn waitReceive(chnls: ChannelGroup, timeout_ns: u64) status.AmpeError!?*message.Message;
    pub fn updateReceiver(chnls: ChannelGroup, update: *?*message.Message) status.AmpeError!void;
};
```

---

## 9. Reference Links

### 9.1 Primary — Zig & NT API

| Resource | URL |
|----------|-----|
| Zig ntdll.zig | https://codeberg.org/ziglang/zig/src/branch/master/lib/std/os/windows/ntdll.zig |
| Zig devlog (NT-first) | https://ziglang.org/devlog/2026/#2026-02-03 |
| Zig issue #1840 | https://github.com/ziglang/zig/issues/1840 |
| zigwin32 | https://github.com/marlersoft/zigwin32/tree/main/win32 |

### 9.2 NT Wait Completion Packet APIs

| Resource | URL |
|----------|-----|
| NtAssociateWaitCompletionPacket (MS) | https://learn.microsoft.com/en-us/windows/win32/devnotes/ntassociatewaitcompletionpacket |
| NtCreateWaitCompletionPacket (MS) | https://learn.microsoft.com/en-us/windows/win32/devnotes/ntcreatewaitcompletionpacket |
| NtDoc: NtAssociateWaitCompletionPacket | https://ntdoc.m417z.com/ntassociatewaitcompletionpacket |
| NtDoc: NtCreateWaitCompletionPacket | https://ntdoc.m417z.com/ntcreatewaitcompletionpacket |
| win32-iocp-events example | https://github.com/tringi/win32-iocp-events |
| .NET Runtime issue #90866 | https://github.com/dotnet/runtime/issues/90866 |

### 9.3 AFD_POLL & Socket Readiness

| Resource | URL |
|----------|-----|
| Len Holgate: Socket readiness without \Device\Afd | https://lenholgate.com/blog/2024/06/socket-readiness-without-device-afd.html |
| Len Holgate: Adventures with \Device\Afd | https://lenholgate.com/blog/2023/04/adventures-with-afd.html |
| wepoll | https://github.com/piscisaureus/wepoll |
| libevent wepoll.c | https://github.com/libevent/libevent/blob/master/wepoll.c |
| c-ares Windows event engine | https://github.com/c-ares/c-ares/blob/main/src/lib/ares_event_win32.c |

### 9.4 Reference Implementations

| Resource | URL |
|----------|-----|
| mio (Rust) Windows | https://github.com/tokio-rs/mio/tree/master/src/sys/windows |
| libuv Windows | https://github.com/libuv/libuv/tree/v1.x/src/win |
| Zig stdlib Windows I/O | https://codeberg.org/ziglang/zig/src/branch/master/lib/std/os/windows.zig |

### 9.5 Microsoft Documentation

| Resource | URL |
|----------|-----|
| I/O Completion Ports | https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports |
| PostQueuedCompletionStatus | https://learn.microsoft.com/en-us/windows/win32/fileio/postqueuedcompletionstatus |
| WSAEventSelect | https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaeventselect |
| WSAEnumNetworkEvents | https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaenumnetworkevents |
| Registered I/O | https://learn.microsoft.com/en-us/windows/win32/api/mswsock/ns-mswsock-rio_extension_function_table |

---

## 10. Open Questions

### 10.1 Architecture Questions (Need User Input)

| ID | Question | Status |
|----|----------|--------|
| Q7.1 | Is architecture understanding correct? | Pending |
| Q7.2 | What is "internal socket" (socketpair? eventfd?) | Pending |
| Q7.3 | Where is platform-specific code located? | Pending |
| Q7.4 | Is there already a platform abstraction layer? | Pending |

### 10.2 AF_UNIX Questions

| ID | Question | Status |
|----|----------|--------|
| Q8.1 | How does tofu use Unix sockets internally? | Pending |
| Q8.2 | Does tofu use fd passing or abstract namespace? | Pending |
| Q8.3 | AF_UNIX priority for Windows port? | Pending |

### 10.3 Development Questions

| ID | Question | Status |
|----|----------|--------|
| Q9.1 | Windows dev environment details? | Pending |
| Q9.2 | Current Linux test approach? | Pending |
| Q9.3 | Cross-platform testing strategy? | Pending |

### 10.4 Technical Decisions

| ID | Question | Status |
|----|----------|--------|
| Q10.1 | LSP/SIO_BASE_HANDLE failure handling? | Pending |
| Q11.1 | Callback vs queue model for Windows? | Pending |
| Q11.2 | updateReceiver ↔ IOCP posting mapping? | Pending |
| Q11.3 | Which spec stages apply to tofu? | Pending |

### 10.5 Priority Questions

| ID | Question | Status |
|----|----------|--------|
| Q12.1 | MVP definition for Windows support? | Pending |
| Q12.2 | Bottom-up vs top-down approach? | Pending |
| Q12.3 | Timeline/urgency? | Pending |
| Q12.4 | Biggest concerns? | Pending |

---

## 11. Session Context

### 11.1 Files Created This Session

| File | Purpose |
|------|---------|
| `reactor-questions-001.md` | Initial Q&A, partially answered by user |
| `reactor-questions-002.md` | Follow-up Q&A after reading tofu docs, pending |
| `reactor-kb-001.md` | This knowledge base file |

### 11.2 User's Answers from reactor-questions-001.md

**Q1.1 Use case:** tofu messaging for Windows (existing Linux-only project)

**Q1.2 Ownership:** User's own project

**Q1.3 Next steps:**
1. Refactor tofu to prepare for Windows (analyze Linux-specific code)
2. Think about development stages, feasibility, testing

**Q2.1 Scale:** Small to Medium (< 1000 connections), 128KiB message limit

**Q2.2 Transports:** TCP + Unix sockets (no UDP)

**Q2.3 Timers:** IOCP timeout parameter

**Q2.4 Windows version:** 10+ only

**Q2.5 Async model:** Standalone (callback-based as specified)

**Q3.1-3.2 Memory/Keys:** Decide during further thinking

**Q3.3 LSP handling:** Clarify with examples (provided in Q10.1)

**Q3.4 Re-arm timing:** tofu uses queues, no callbacks

**Q3.5 Performance:** No specific targets

**Q4.1 Build system:** Part of prep plan

**Q4.2 Logging:** Leave to implementation

**Q4.3 Testing:** Decide during plan negotiations

**Q5.1-5.2 References:** Accept fixes, add libevent

### 11.3 Key Insights from tofu Documentation

1. **Reactor implements Ampe interface** — WindowsReactor should do the same
2. **Queue-based, not callbacks** — `waitReceive()` pulls from queue
3. **updateReceiver() is cross-thread signaling** — maps to IOCP posting
4. **Internal socket connects ChannelGroups to Reactor** — need Windows equivalent
5. **Message pool with get/put** — reusable across platforms
6. **Channel abstraction** — likely reusable

### 11.4 To Resume This Session

1. Read this knowledge base file
2. Read `reactor-questions-002.md` for pending questions
3. User provides answers to Section 7-12 questions
4. Proceed with planning based on answers

### 11.5 Alternative Uses for This KB

- Reference during implementation
- Onboarding documentation for contributors
- Architecture decision record (ADR)
- Troubleshooting guide for IOCP issues
- Cross-reference with tofu documentation

---

## Appendix A: tofu Documentation Files

Location: `/home/g41797/dev/root/github.com/g41797/tofu/docs_site/docs/mds/`

| File | Content |
|------|---------|
| overview.md | Project introduction, philosophy |
| features.md | Feature list |
| key-ingredients.md | Core components (Ampe, ChannelGroup, Message) |
| sockets101.md | Socket fundamentals, addressing |
| message.md | Message structure, BinaryHeader, OpCodes |
| message-flows.md | Async flow, queues, ownership |
| channel-group.md | ChannelGroup interface |
| ampe.md | Ampe interface, message pool |
| advanced-topics.md | Channel lifecycle, threading, performance |
| patterns.md | Request/Response, streaming, heartbeat |
| callback-enabled.md | Philosophy on callbacks |
| allocator.md | GPA-compatible allocator requirements |
| address.md | Address formatting |
| statuses.md | Error codes and statuses |
| error-handling.md | Error handling patterns |
| your-first-server.md | Server tutorial |
| your-first-client.md | Client tutorial |

---

## Appendix B: Spec Document Structure

`reactor-over-iocp-prompt-005.md` sections:

1. Your Role (expert domains)
2. Background & Motivation (Proactor vs Reactor)
3. Key NT APIs (ntdll functions)
4. The Core Trick: AFD_POLL
5. Important Implementation Details
6. Task (requirements)
7. Cross-Thread Command Injection
8. Alternative Approaches (7 alternatives)
9. Staged Implementation Plan (7 stages)
10. API Surface (Zig)
11. Deliverables
12. Constraints
13. References

---

*End of Knowledge Base*
