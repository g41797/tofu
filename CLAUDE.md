# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Tofu is an asynchronous message passing library for Zig, providing peer-to-peer, duplex communication over TCP/IP and Unix Domain Sockets. The library uses a message-based architecture where discrete messages are exchanged between peers in a non-blocking manner.

**Core Philosophy:**
- Message as both data and API
- Gradual evolution: from simple to complex use cases
- Stream-oriented transport (TCP/IP and UDS)
- Multithread-friendly with thread-safe APIs
- Internal message pool for memory management
- Backpressure management via pool control

## Build and Test Commands

### Build
```bash
zig build                    # Build the library
```

### Test
```bash
zig build test              # Run all unit tests
```

### Requirements
- Zig 0.14.0 or later (see `build.zig.zon`)
- libc and ws2_32 on Windows for sockets

## Architecture

### Core Components

**1. Ampe (Async Message Passing Engine)**
- Interface defined in `src/ampe.zig`
- Concrete implementation: `Reactor` in `src/ampe/Reactor.zig`
- Provides:
  - `get()`: Obtain message from pool (with `AllocationStrategy`: `poolOnly` or `always`)
  - `put()`: Return message to pool
  - `create()`: Create new ChannelGroup
  - `destroy()`: Destroy ChannelGroup
  - `getAllocator()`: Access shared allocator
- All methods are thread-safe
- Uses vtable-based polymorphism for flexibility

**2. Reactor**
- Single-threaded, event-driven engine using Reactor pattern
- Runs dedicated thread with poll-style I/O loop (`src/ampe/poller.zig`)
- Components:
  - `Pool`: Message pool with configurable min/max size (`src/ampe/Pool.zig`)
  - `Notifier`: Thread notification mechanism using socketpair (`src/ampe/Notifier.zig`)
  - `ActiveChannels`: Thread-safe channel registry with random channel numbers (`src/ampe/channels.zig`)
  - `TriggeredChannels`: Map of channels with I/O events
  - Two `MSGMailBox` arrays: one for engine, one for application messages
  - Mutexes: `sndMtx` (send operations), `crtMtx` (create/destroy operations)

**3. Message** (`src/message.zig`)
- Central data structure with three parts:
  - **Persistent fields** (transferred between peers):
    - `bhdr`: BinaryHeader (16 bytes) with metadata
    - `thdrs`: TextHeaders for configuration/app headers
    - `body`: Appendable buffer for payload
  - **Transient fields** (not transferred):
    - `@"<void*>"`: Application-specific pointer
    - `@"<ctx>"`: Engine-internal context pointer
  - **Intrusive list nodes**: `prev`/`next` for zero-allocation queuing
- Lifecycle: pool → get → configure → send (ownership transfer) → receive → put → pool
- Validation via `check_and_prepare()` before sending

**4. BinaryHeader** (`src/message.zig`)
- 16-byte packed struct, big-endian on wire
- Fields:
  - `channel_number`: u16 (random, non-zero for active channels)
  - `proto`: ProtoFields (8 bits: message type, role, origin, more flag, oob flag)
  - `status`: u8 (AmpeStatus enum value)
  - `message_id`: u64 (unique, auto-generated if 0)
  - `@"<thl>"`: u16 (text headers length, engine-managed)
  - `@"<bl>"`: u16 (body length, engine-managed)
- Big-endian serialization with `toBytes()`/`fromBytes()`

**5. ChannelGroup** (`src/ampe.zig`)
- Interface for message exchange
- Implemented by `MchnGroup` (`src/ampe/MchnGroup.zig`)
- Methods:
  - `enqueueToPeer()`: Submit message for async send (thread-safe)
  - `waitReceive()`: Block waiting for message (SINGLE THREAD ONLY)
  - `updateReceiver()`: Wake receiver or send notification (thread-safe)
- Each group has two mailboxes: [0] for send queue, [1] for receive queue
- One group can manage multiple channels (listener + connected clients)

**6. ActiveChannels** (`src/ampe/channels.zig`)
- Thread-safe registry of active channels
- Random u16 channel numbers (excluding 0 and u16::MAX)
- Maps channel number → `ActiveChannel` (channel, message_id, proto, context)
- Validates channel ownership (channel must belong to correct ChannelGroup)
- Removed channels tracked in circular buffer to avoid immediate reuse

**7. Pool** (`src/ampe/Pool.zig`)
- Thread-safe LIFO message pool (mutex-protected)
- Configurable: `initialPoolMsgs` (pre-allocated), `maxPoolMsgs` (max size)
- `get()`: Returns pooled message or creates new one (based on strategy)
- `put()`: Returns message to pool or destroys if pool full/closed
- Alerts engine on pool-empty condition via `Alerter` callback

**8. Notifier** (`src/ampe/Notifier.zig`)
- Thread communication via socketpair (or UDS on Linux)
- Sender socket for app threads → Receiver socket for Reactor thread
- Notification types:
  - `message`: New message to process
  - `alert`: Pool freed memory or shutdown started
- Packed 8-bit notification with kind, oob flag, ValidCombination hint, alert type

### Message Flow Architecture

**Connection Establishment:**
1. Server sends `WelcomeRequest` (channel_number=0) with server address in TextHeaders
2. Engine creates listener socket, returns `WelcomeResponse` (success/error status)
3. Client sends `HelloRequest` (channel_number=0) with server address in TextHeaders
4. Engine connects to server, sends HelloRequest on wire
5. Server receives `HelloRequest` as new message (new channel_number for this client)
6. Server replies with `HelloResponse`
7. Client receives `HelloResponse` confirming connection

**Message Exchange:**
- Application messages use `MessageType.regular` with:
  - `MessageRole.request`: Expects response with same message_id
  - `MessageRole.response`: Reply to request (same message_id)
  - `MessageRole.signal`: One-way message (no response expected)
- Engine validates via `check_and_prepare()`:
  - Valid type/role combinations
  - Non-zero channel_number (except hello/welcome)
  - Response must have non-zero message_id
  - Headers/body lengths fit in u16
- OOB flag: High-priority messages (inserted at queue head)

**Disconnection:**
- Graceful: `ByeRequest` → `ByeResponse` (client/server handshake)
- Force: `ByeSignal` with `oob=.on` (immediate close)
- Channel closed: Engine sends `ChannelClosed` signal on disconnect/error

**Error Handling:**
- Status byte in BinaryHeader carries AmpeStatus enum
- Engine sets `origin=.engine` for error messages
- Application can use status byte for app-specific values (with `origin=.application`)
- Common statuses:
  - `pool_empty`: Add messages to pool or wait
  - `connect_failed`: Retry connection
  - `channel_closed`: Socket closed
  - `receiver_update`: Wake signal from `updateReceiver()`

### Key Patterns

**1. Vtable-Based Polymorphism**
- `AmpeVTable` and `ChannelGroupVTable` in `src/ampe/vtables.zig`
- Allows multiple Ampe implementations (currently only Reactor)
- Interface pattern: struct with `ptr: ?*anyopaque` + `vtable: *const VTable`

**2. Intrusive Data Structures**
- Messages have `prev`/`next` fields for intrusive linked lists
- Zero-allocation queuing via `IntrusiveQueue` (`src/ampe/IntrusiveQueue.zig`)
- Mailboxes use intrusive queues for message passing

**3. Thread Safety Model**
- Reactor runs on dedicated thread (handles I/O, notifications)
- Application threads:
  - Can call `get()`, `put()`, `enqueueToPeer()`, `updateReceiver()` (thread-safe)
  - Must call `waitReceive()` from ONE thread only per ChannelGroup
  - Multiple ChannelGroups can be used from different threads
- Mutexes protect: Pool, ActiveChannels, Reactor create/destroy/send paths

**4. Configuration via TextHeaders**
- Socket addresses injected as "name: value\r\n" headers
- `Configurator` union (`src/configurator.zig`):
  - `.tcp_server`: TCPServerConfigurator (IP, port)
  - `.tcp_client`: TCPClientConfigurator (IP, port)
  - `.uds_server`: UDSServerConfigurator (file path)
  - `.uds_client`: UDSClientConfigurator (file path)
- Call `prepareRequest()` to add headers to message

**5. MultiHomed Servers** (`recipes/MultiHomed.zig`)
- Single thread handles multiple listeners (TCP + UDS)
- One `waitReceive()` loop dispatches to all channels
- Dispatch by channel_number or proto fields
- Uses Services interface for pluggable message processing

**6. Services Interface** (`recipes/services.zig`)
- Cooperative message processing pattern
- Methods:
  - `start()`: Initialize with engine and ChannelGroup
  - `onMessage()`: Process message, return true to continue
  - `stop()`: Cleanup
- Example: `EchoService` (request→response echo)

### Directory Structure

- `src/ampe/`: Core engine implementation
  - `Reactor.zig`: Main event loop (967 lines)
  - `MchnGroup.zig`: ChannelGroup implementation
  - `channels.zig`: ActiveChannels registry
  - `Pool.zig`: Message pool
  - `Skt.zig`: Socket abstraction
  - `poller.zig`: I/O polling (poll/epoll/kqueue)
  - `Notifier.zig`: Thread notifications
  - `IntrusiveQueue.zig`: Lock-free intrusive queue
  - `triggeredSkts.zig`: Triggered channel map
  - `vtables.zig`: Vtable definitions
  - `testHelpers.zig`: Test utilities

- `src/`:
  - `tofu.zig`: Public API exports
  - `ampe.zig`: Ampe/ChannelGroup interfaces
  - `message.zig`: Message, BinaryHeader, TextHeaders
  - `status.zig`: AmpeStatus/AmpeError, conversion functions
  - `configurator.zig`: TCP/UDS configuration helpers

- `recipes/`: Usage examples and patterns
  - `cookbook.zig`: Comprehensive examples (1900+ lines)
  - `services.zig`: Services interface and EchoService
  - `MultiHomed.zig`: Multi-listener server pattern

- `tests/`: Unit tests
  - `reactor_tests.zig`: Reactor tests
  - `message_tests.zig`: Message tests
  - `configurator_tests.zig`: Configurator tests
  - `ampe/`: Ampe component tests

### Dependencies (build.zig.zon)

- `nats`: Provides `Appendable` dynamically growing buffer
- `mailbox`: Intrusive mailbox (`MailBoxIntrusive`) for message queues
- `temp`: Temporary file utilities for UDS testing
- `datetime`: Date/time handling (not core to message passing)

## Code Style and Conventions

### Pointer Dereferencing
This codebase uses **explicit pointer dereferencing**:
- Use `ptr.*` to dereference pointers (NOT automatic)
- Use `optional.?.*` for optional pointers accessing fields/methods
- Examples:
  - `msg.?.*.bhdr.status` (correct)
  - `msg.?.bhdr.status` (incorrect, old style)
  - `self.*.engine.*.pool.put()` (correct)
  - `self.engine.pool.put()` (incorrect)

### Type Annotations
Variables should have **explicit type annotations**:
- Example: `var msg: ?*Message = try ampe.get(...)`
- Not: `var msg = try ampe.get(...)`
- Rationale: Readability without IDE type hints

### Message Lifecycle
- **Acquire**: `var msg: ?*Message = try ampe.get(strategy)`
- **Configure**: Set bhdr fields, thdrs, body
- **Send**: `_ = try chnls.enqueueToPeer(&msg)` (msg becomes null)
- **Receive**: `var recvd: ?*Message = try chnls.waitReceive(timeout)`
- **Release**: `defer ampe.put(&msg)` pattern
- **Never** use message after ownership transfer (null check)

### Error Handling
- Use `AmpeError` error set (not raw errors)
- Check message status after `waitReceive()`:
  ```zig
  const st: u8 = msg.?.*.bhdr.status;
  const ampeSt: AmpeStatus = status.raw_to_status(st);
  try status.raw_to_error(st);  // Converts to AmpeError
  ```
- Engine messages have `origin=.engine`, app messages `origin=.application`

### Thread Safety
- **Thread-safe**: `get()`, `put()`, `enqueueToPeer()`, `updateReceiver()`, `create()`, `destroy()`
- **Single-threaded**: `waitReceive()` (one thread per ChannelGroup)
- Use `defer` for cleanup in all code paths
- Reactor methods called from Reactor thread only (no external locking)

### Naming Conventions
- Types: PascalCase (`Message`, `BinaryHeader`, `ActiveChannels`)
- Functions: camelCase (`enqueueToPeer`, `waitReceive`, `check_and_prepare`)
- Private functions: `_functionName` (underscore prefix)
- Constants: lowercase with underscores (`waitReceive_INFINITE_TIMEOUT`)
- Special fields: `@"<name>"` (quoted identifiers for reserved or special names)

## Testing Utilities (src/ampe/testHelpers.zig)

- `TempUdsPath`: Generate temporary UDS file paths
- `FindFreeTcpPort()`: Find available TCP port for testing
- `DestroyChannels()`: Simplified cleanup helper
- `RunTasks()`: Multi-threaded test coordination

## Common Patterns

### Creating Basic Client-Server

```zig
// 1. Create engine
var rtr: *Reactor = try Reactor.Create(gpa, options);
defer rtr.*.Destroy();

// 2. Get interface
const ampe: Ampe = try rtr.*.ampe();

// 3. Create channel group
const chnls: ChannelGroup = try ampe.create();
defer tofu.DestroyChannels(ampe, chnls);

// 4. Server: start listener
var welcomeMsg: ?*Message = try ampe.get(.always);
defer ampe.put(&welcomeMsg);
var srvCfg: Configurator = .{ .tcp_server = TCPServerConfigurator.init("0.0.0.0", port) };
try srvCfg.prepareRequest(welcomeMsg.?);
const srvBh: BinaryHeader = try chnls.enqueueToPeer(&welcomeMsg);
var welcomeResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
defer ampe.put(&welcomeResp);

// 5. Client: connect
var helloMsg: ?*Message = try ampe.get(.always);
defer ampe.put(&helloMsg);
var cltCfg: Configurator = .{ .tcp_client = TCPClientConfigurator.init("127.0.0.1", port) };
try cltCfg.prepareRequest(helloMsg.?);
const cltBh: BinaryHeader = try chnls.enqueueToPeer(&helloMsg);
var helloReq: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&helloReq);

// 6. Exchange messages...

// 7. Close: ByeSignal with oob=.on for force close
var byeMsg: ?*Message = try ampe.get(.always);
byeMsg.?.*.bhdr.proto.mtype = .bye;
byeMsg.?.*.bhdr.proto.role = .signal;
byeMsg.?.*.bhdr.proto.oob = .on;
byeMsg.?.*.bhdr.channel_number = cltBh.channel_number;
_ = try chnls.enqueueToPeer(&byeMsg);
```

### Handling Reconnection

```zig
// Reconnection loop (see cookbook.zig:handleReConnectST)
for (0..maxRetries) |_| {
    var helloRequest: ?*Message = try ampe.get(.always);
    defer ampe.put(&helloRequest);
    try cfg.prepareRequest(helloRequest.?);
    const bhdr: BinaryHeader = try chnls.enqueueToPeer(&helloRequest);

    var response: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&response);

    if (response == null) continue;  // Timeout

    switch (status.raw_to_status(response.?.*.bhdr.status)) {
        .success => return,  // Connected!
        .connect_failed, .communication_failed => continue,  // Retry
        .invalid_address => return error.InvalidAddress,  // Fatal
        .pool_empty => try addMessagesToPool(3),  // Add messages
        else => |st| return status.status_to_error(st),  // Other error
    }
}
```

### Multi-Homed Server Pattern

```zig
// Create server with multiple listeners (see MultiHomed.zig)
var listeners: [2]Configurator = [_]Configurator{
    .{ .tcp_server = TCPServerConfigurator.init("0.0.0.0", tcpPort) },
    .{ .uds_server = UDSServerConfigurator.init(udsPath) },
};
var echoSvc: EchoService = .{};
var mh: *MultiHomed = try MultiHomed.run(ampe, &listeners, echoSvc.services());
defer mh.*.stop();

// Single waitReceive() loop handles all listeners + clients
```

### Using updateReceiver()

```zig
// Wake receiver thread (send null)
var nullMsg: ?*Message = null;
try chnls.updateReceiver(&nullMsg);

// Send notification with data
var notifyMsg: ?*Message = try ampe.get(.always);
// ... configure notifyMsg ...
try chnls.updateReceiver(&notifyMsg);  // notifyMsg becomes null

// Receiver side
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);
if (status.raw_to_status(msg.?.*.bhdr.status) == .receiver_update) {
    // Handle notification
}
```

## Important Notes

- **Never** modify or remove comments in the codebase
- Zero functionality changes in refactorings (syntax only)
- In-place editing: modify files directly, don't create copies
- Explicit types and dereferencing: ongoing transition, both styles may exist
- Channel numbers are random u16 (not sequential)
- Messages are pooled: always use `get()`/`put()`
- Reactor is single-instance per engine (no multi-Reactor support yet)
- Windows requires libc + ws2_32 for socket support

## Documentation

- Online: https://g41797.github.io/tofu/ (work in progress)
- Examples: `recipes/cookbook.zig` (comprehensive)
- Tests: `tests/` directory (usage patterns)

## Credits (from README)

- Karl Seguin: Zig networking introduction
- tardy: Reference for I/O patterns
- temp.zig: Temporary file handling
- mailbox: Intrusive queue implementation
- Zig community: Reddit, Discord, Discourse
