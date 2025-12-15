![](_logo/Ziggy_And_Zero_Are_Cooking_Tofu.png)
# **_Tofu - Sync your devs, Async your apps_**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Linux](https://github.com/g41797/yaaamp/actions/workflows/linux.yml/badge.svg)](https://github.com/g41797/yaaamp/actions/workflows/linux.yml)
<!-- [![MacOS](https://github.com/g41797/yaaamp/actions/workflows/mac.yml/badge.svg)](https://github.com/g41797/yaaamp/actions/workflows/mac.yml) -->

---

##

What does **tofu** have to do with _asynchronous message communication_?

I spent a long time breaking my head trying to explain the _point_ of this project.

There are already tons of networking libraries out there. 

Well, let’s say at least several kilograms for Zig. 

And then it hit me — **tofu**!

Tofu is a simple product with almost no flavor. You can

- eat it plain 
- add a little spice and make something slightly better
- or go all the way and create culinary masterpieces.

And what I especially like:
>[tofu is as good as you are a cook](https://www.reddit.com/r/vegan/comments/hguwpc/tofu_is_as_good_as_you_are_a_cook/)

You'll use the tofu library in a similar way:

- from minimal setups 
- to more complex flows
- and eventually distributed applications.

---


## Features
 
- **Message-Based**: Uses discrete messages for communication.
- **Asynchronous**: Enables non-blocking message exchanges.
- **Duplex**: Supports two-way communication.
- **Peer-to-Peer**: Allows equal roles after connection establishment.
- **Stream oriented transport** - TCP/IP and **U**nix **D**omain **S**ockets
- **Multithread-friendly** - All APIs are safe for concurrent access.
- **Memory management for messages** - internal message pool
- **Backpressure management** - allows to control receive of messages
- **Customizable application flows** - allows to build various application flows not restricted to request/response or pub/sub
- **Simplest API** - you don't have to bother with or know the "guts" of socket interfaces


---



## A bit of history

**tofu** wasn’t just "pulled out of thin air."

I started developing a similar system back in 2008, maintained it, and kept it running for years.

That system powered all data transfer in a serious distributed environment

- from basic IPC 
- to communication in a proprietary distributed file system.

We parted ways a few years ago, but I haven't heard any complaints yet.

Corporate lawyers can relax — from that system I only took the _smell_
([precedent case about paying for smell](http://fable1001.blogspot.com/2009/11/nasreddin-hodja-smell-of-soup-and-sound.html))

By '_smell_' I mean the idea itself:

- message as the _**data**_ and _**API**_
- the philosophy of _**gradual evolution**_ 
  - starting from something simple 
  - and steadily growing into more advanced and powerful systems.

---


## API

**_Stripped Interface Definitions_**:

```zig
/// Defines the async message passing engine interface.
/// "Ampe" and "engine" mean the same thing.
///
/// Provides methods to:
/// - Get/return messages from the internal pool.
/// - Create/destroy ChannelGroups.
/// - Access the shared allocator for memory management.
pub const Ampe = struct {

    /// Gets a message from the internal pool.
    ///
    /// Uses the given `strategy` to decide how to allocate.
    /// Returns `null` if pool is empty and `strategy` is `poolOnly`.
    ///
    /// Returns error if engine is shutting down or allocation fails.
    ///
    /// Thread-safe.
    pub fn get(
        ampe: Ampe,
        strategy: AllocationStrategy,
    ) status.AmpeError!?*message.Message {...}

    /// Returns a message to the internal pool.
    /// If pool is closed, destroys the message instead.
    ///
    /// Always sets `msg.*` to `null` to prevent reuse.
    ///
    /// Thread-safe.
    pub fn put(
        ampe: Ampe,
        msg: *?*message.Message,
    ) void {...}

    /// Creates a new `ChannelGroup`.
    ///
    /// Call `destroy` on result to stop communication and free memory.
    ///
    /// Thread-safe.
    pub fn create(
        ampe: Ampe,
    ) status.AmpeError!ChannelGroup {...}

    /// Destroys `ChannelGroup`, stops communication, frees memory.
    ///
    /// Thread-safe.
    pub fn destroy(
        ampe: Ampe,
        chnls: ChannelGroup,
    ) status.AmpeError!void {...}

    /// Returns the allocator used by the engine for all memory.
    ///
    /// Thread-safe.
    pub fn getAllocator(
        ampe: Ampe,
    ) Allocator {...}
};

/// Defines how messages are allocated from the pool.
pub const AllocationStrategy = enum {
    /// Tries to get a message from the pool. Returns null if the pool is empty.
    poolOnly,
    /// Gets a message from the pool or creates a new one if the pool is empty.
    always,
};

//////////////////////////////////////////////////////////////////////////
// Client and server terms are used only during the initial handshake.
// After the handshake, both sides are equal. We call them **peers**.
// They send and receive messages based on application logic.
//////////////////////////////////////////////////////////////////////////

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
};
```

Documentation and examples are available on the [Tofu documentation site](https://g41797.github.io/tofu/) (**_work in progress_**).

---


## NAQ or **N**ever **A**sked **Q**uestions

<details><summary><i>Why not use another library?</i></summary>
  Why not? Go ahead and use it.
</details>


---


## Credits
- [Karl Seguin](https://github.com/karlseguin) — for introducing me to [Zig networking](https://www.openmymind.net/TCP-Server-In-Zig-Part-1-Single-Threaded/)
- [tardy](https://github.com/tardy-org/tardy) — I peeked into 2 files of the project (the author will guess which ones)
- [temp.zig](https://github.com/abhinav/temp.zig) — helped me (and will help you) work with temporary files
- [Gemini AI image generator](https://gemini.google.com/app) — the only one out of six I managed to convince to seat Ziggy and Zero at the same table
- Zig Community Forums (in order of my registration) - for your help and patience with my posts
  - [Zig on Reddit](https://www.reddit.com/r/Zig/)
  - [Zig on Discord](https://discord.com/invite/zig)
  - [Zig on Discourse](https://ziggit.dev/)

---


## Last but not least
⭐️ Like, share, and don’t forget to [subscribe to the channel](https://github.com/g41797/tofu) !



