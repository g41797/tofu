
All examples assume that the snippet below is added to your code.

```zig
const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const testing = std.testing;

// Import of module 'tofu'
pub const tofu = @import("tofu");

// Reactor: The single-threaded, event-driven implementation
// of the Ampe interface. It utilizes the Reactor pattern to multiplex
// non-blocking socket I/O via an internal poll-style loop.
pub const Reactor = tofu.Reactor;

pub const Ampe = tofu.Ampe;

// Contains settings for the internal message pool.
pub const Options = tofu.Options;

// The default configuration options for the pool.
pub const DefaultOptions = tofu.DefaultOptions;

// A grouping mechanism for managing a collection of related channels.
pub const ChannelGroup = tofu.ChannelGroup;

pub const message = tofu.message;

// The core Message structure processed by the engine.
pub const Message = tofu.Message;

// Meta-data for the Message.
// Used internally by the engine for routing and by the application for context.
pub const BinaryHeader = message.BinaryHeader;

pub const status = tofu.status;
// An enum representation of the status byte
// (part of BinaryHeader) for clear status tracking.
pub const AmpeStatus = status.AmpeStatus;
// An error type corresponding to the status above,
// used for conveying failure states.
pub const AmpeError = status.AmpeError;

// Helpers - for convenient injection of socket addresses
// to the message.
pub const address = tofu.address;
pub const Address = address.Address;
```

And don't forget to assign suitable allocator, e.g.:
```zig
    var dbalctr = std.heap.DebugAllocator(.{}).init;
    defer {
        const deinit_status = dbalctr.deinit();
        // fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak detected", .{});
        }
    }
    
    const gpa: Allocator = dbalctr.allocator();
```

