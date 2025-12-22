**_ChannelGroup_** provides full-duplex, asynchronous message exchange between _peers_. 

??? question "NAQ: Why "peers" instead of "client/server"?"
    Tofu uses client and server terms to describe the initial handshake.
    After the handshake, both sides are called peers because they have equal 
    functionality and roles.

Simplest description of **_ChannelGroup_** you can get from its name - _Group Of Channels_ :smile:.

## Channel

Think of a _channel_ as a _virtual socket_.

There are two kinds of channels:

- Listener – Analog of a listener socket.
- IO – Analog of client socket or accepted server socket.

??? question "NAQ: Why not just Socket/SocketGroup?"
    You cannot send messages to an unconnected socket, but it ok with _channel_.

Channels are identified by a _channel number_ in the range [1-65534].

Two channel number values are reserved:

- 0 – Unassigned channel number
- 65535 – Tofu internal channel number

Channel numbers are unique within the engine that created them, from **_creation_** until **_closure_**.

!!! warn
    Another engine in the same process or an engine in a different process may assign the same channel number simultaneously.

Every channel has 3 internal states:

- opened - engine assigned channel number
- ready 
  - IO channel - ready for send/receive messages
  - Listener channel - ready for accept incoming connections
- closed

## ChannelGroup create/destroy

Let's create and destroy a ChannelGroup—still without fully understanding what it is.

```zig
    const rtr: *Reactor = try Reactor.Create(gpa, DefaultOptions);
    defer rtr.*.Destroy();

    const ampe: Ampe = try rtr.*.ampe();

    const chnls: ChannelGroup = try ampe.create();

    defer { 
        _ = ampe.destroy(chnls) catch | err | {
            std.log.err("destroy channel group failed with error {any}", .{err});
        };
    }
```

There are two ways to release resources (messages, channels etc.) of ChannelGroup

- explicit - via  **ampe.destroy**(...) [PREFERRED]
- implicit - during destroy of engine - **rtr.*.Destroy**() [FOR SIMPLE GO/NO GO]

!!! warn
    ampe.destroy(chngrp) cannot be used directly in defer because defer does not allow try or error unions.  

## ChannelGroup interface

```zig
/// Defines the ChannelGroup interface for async message passing.
/// Supports two-way message exchange between peers.
pub const ChannelGroup = struct {

    /// Submits a message for async processing:
    /// - most cases: send to peer
    /// - others: internal network related processing
    ///
    /// On success:
    /// - Sets `msg.*` to null (prevents reuse).
    /// - Returns `BinaryHeader` for tracking.
    ///
    /// On error:
    /// - Returns an error.
    /// - If the engine cannot use the message (internal failure),
    ///   also sets `msg.*` to null.
    ///
    /// Thread-safe.
    pub fn enqueueToPeer(
        chnls: ChannelGroup,
        msg: *?*message.Message,
    ) status.AmpeError!message.BinaryHeader {...}

    /// Waits for the next message from the internal queue.
    ///
    /// Timeout is in nanoseconds. Returns `null` if no message arrives in time.
    ///
    /// Message sources:
    /// - Remote peer (via `enqueueToPeer` on their side).
    /// - Application (via `updateReceiver` on this ChannelGroup).
    /// - Ampe (status/control messages).
    ///
    /// Check `BinaryHeader` to identify the source.
    ///
    /// On error: stop using this ChannelGroup and call `ampe.destroy` on it.
    ///
    /// Call in a loop from **one thread only**.
    pub fn waitReceive(
        chnls: ChannelGroup,
        timeout_ns: u64,
    ) status.AmpeError!?*message.Message {...}

    /// Adds a message to the internal queue for `waitReceive`.
    ///
    /// If `msg.*` is not null:
    /// - Engine sets status to `'receiver_update'`.
    /// - Sets `msg.*` to null after success.
    /// - No need for `channel_number` or similar fields.
    ///
    /// If `msg.*` is null:
    /// - Creates a `'receiver_update'` Signal and adds it.
    ///
    /// Returns error if shutting down.
    ///
    /// Use from another thread to:
    /// - Wake the receiver (`msg.*` = null).
    /// - Send info/commands/notifications.
    ///
    /// FIFO order only. No priority queues.
    ///
    /// Thread-safe.
    pub fn updateReceiver(
        chnls: ChannelGroup,
        update: *?*message.Message,
    ) status.AmpeError!void {...}
}
```

Caller of every function/method has "non-formal" role:

 - enqueueToPeer caller → Producer
 - waitReceive caller → Consumer
 - updateReceiver caller → Notifier

??? question "NAQ: No methods use channel numbers. How to handle channels?"
    You also won't see IP addresses or port numbers. All this info is in the messages.


Without details about Message, it is hard to explain how to use this interface. A full description will come later.

