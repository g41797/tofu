# Type Reference for Zig Refactoring

This document lists common types discovered in the tofu codebase for use during refactoring.

## Core Engine Types

```zig
var rtr: *Reactor = try Reactor.Create(...)
const ampe: Ampe = try rtr.*.ampe()
const chnls: ChannelGroup = try ampe.create()
```

## Message Types

```zig
var msg: ?*Message = try ampe.get(...)
var recvMsg: ?*Message = try chnls.waitReceive(...)
var next: ?*Message = msgq.dequeue()
```

## Protocol Types

```zig
const bhdr: BinaryHeader = try chnls.enqueueToPeer(...)
const st: u8 = msg.?.*.bhdr.status
const sts: AmpeStatus = status.raw_to_status(...)
const ampeSts: AmpeStatus = ...
const lstChannel: message.ChannelNumber = bhdr.channel_number
const cnumber: u16 = bhdr.channel_number
```

## System Types

```zig
const allocator: Allocator = engine.getAllocator()
const gpa: Allocator = std.heap.GeneralPurposeAllocator(...)
const port: u16 = try tofu.FindFreeTcpPort()
const filePath: []u8 = try tup.buildPath(...)
const path: []const u8 = ...
```

## Thread Types

```zig
const thread: std.Thread = try std.Thread.spawn(...)
```

## Configuration Types

```zig
var cfg: Configurator = .{ .tcp_server = ... }
var srvCfg: Configurator = ...
var cltCfg: Configurator = ...
```

## Client/Server Pattern Types

```zig
var client: *TofuClient = try TofuClient.create(...)
var server: *TofuServer = try TofuServer.create(...)
const result: *Self = try allocator.create(Self)
var mh: *MultiHomed = try MultiHomed.run(...)
```

## Services Types

```zig
var svc: Services = ...
var echoSvc: EchoService = .{}
```

## Pool/Channel Types

```zig
var pool: *Pool = try Pool.create(...)
var notifier: *Notifier = try Notifier.create(...)
var achnls: *ActiveChannels = try ActiveChannels.create(...)
var triggeredChns: *TriggeredChannels = try TriggeredChannels.init(...)
```

## Socket Types

```zig
var skt: *Skt = try Skt.create(...)
const sockfd: std.posix.socket_t = ...
```

## Common Primitives

```zig
const count: usize = ...
const size: usize = ...
const timeout: i64 = ...
const flag: bool = ...
const err: AmpeError = ...
```

## Array/Slice Types

```zig
var array: []Message = ...
var slice: []const u8 = ...
var buffer: [128]u8 = ...
```

## Optional Types

```zig
var optMsg: ?*Message = null
var optAllocator: ?Allocator = null
```

## Struct-Specific Types

```zig
// From MultiHomed
const allocator: Allocator = mh.*.allocator.?
var next: ?*Message = mh.*.msgq.dequeue()

// From Services
const allocator: Allocator = self.*.gpa

// From cookbook
var rtr: *Reactor = try Reactor.Create(gpa, options)
const ampe: Ampe = try rtr.*.ampe()
```

## Return Value Types

```zig
// enqueueToPeer returns BinaryHeader
const bhdr: BinaryHeader = try chnls.enqueueToPeer(...)

// waitReceive returns ?*Message
var response: ?*Message = try chnls.waitReceive(...)

// get returns ?*Message
var msg: ?*Message = try ampe.get(...)

// create returns ChannelGroup
const chnls: ChannelGroup = try ampe.create()

// ampe returns Ampe
const ampe: Ampe = try rtr.*.ampe()

// getAllocator returns Allocator
const allocator: Allocator = engine.getAllocator()

// raw_to_status returns AmpeStatus
const ampeSts: AmpeStatus = status.raw_to_status(st)

// status_to_error returns AmpeError
const err: AmpeError = status.status_to_error(ampeSts)
```

## Edge Cases

### Already Explicit (DO NOT CHANGE)
```zig
msg.?.*.bhdr  // Already explicit - correct
var msg: ?*Message = ...  // Already typed - correct
```

### Method Chains
```zig
// Method return values don't need dereference unless assigning to variable
const bhdr: BinaryHeader = try chnls.enqueueToPeer(&msg)
_ = try chnls.enqueueToPeer(&msg)  // Underscore assignment
```

### Complex Expressions
```zig
// Step-by-step dereference
msg.?.*.bhdr.status
msg.?.*.copyBh2Body()
self.*.engine.*.pool.put()
```

## Files by Category

### Source Files (18 files)
- src/tofu.zig
- src/ampe.zig
- src/message.zig
- src/status.zig
- src/configurator.zig
- src/ampe/Reactor.zig
- src/ampe/MchnGroup.zig
- src/ampe/Pool.zig
- src/ampe/Notifier.zig
- src/ampe/channels.zig
- src/ampe/Skt.zig
- src/ampe/SocketCreator.zig
- src/ampe/IntrusiveQueue.zig
- src/ampe/poller.zig
- src/ampe/triggeredSkts.zig
- src/ampe/vtables.zig
- src/ampe/internal.zig
- src/ampe/testHelpers.zig

### Recipe Files (3 files)
- recipes/cookbook.zig
- recipes/services.zig
- recipes/MultiHomed.zig

### Test Files (8 files)
- tests/configurator_tests.zig
- tests/message_tests.zig
- tests/reactor_tests.zig
- tests/tofu_tests.zig
- tests/ampe/Pool_tests.zig
- tests/ampe/Notifier_tests.zig
- tests/ampe/channels_tests.zig
- tests/ampe/sockets_tests.zig

### Build Files (2 files)
- build.zig
- testRunner.zig

**Total: 31 files to refactor**
