
**_Ampe_** or **_engine_** is the "holder" (owner) and allocator of all tofu resources

- ChannelGroups
- Messages

Consider it the GPA of tofu. 

---


## Ampe creation

```zig title="Example of Ampe creation"
pub fn createDestroyAmpe(gpa: Allocator) !void {
    // Create engine implementation object
    const rtr: *Reactor = try Reactor.Create(gpa, DefaultOptions);

    // Destroy it after return or on error
    defer rtr.*.Destroy();

    // Create ampe interface
    const ampe: Ampe = try rtr.*.ampe();

    _ = ampe;

    // No need to destroy ampe itself.
    // It is an interface provided by Reactor.
    // It will be destroyed via  rtr.*.Destroy().
}
```

!!! note 
    You can create _multiple engines_ per process.


---

## Interface

Ampe is represented by the following interface: 

```zig  title="Brief version of the Interface"
pub const Ampe = struct {
    pub fn create(ampe: Ampe) status.AmpeError!ChannelGroup {...}
    pub fn destroy(ampe: Ampe, chnls: ChannelGroup) status.AmpeError!void {...}

    pub fn get(ampe: Ampe, strategy: AllocationStrategy) status.AmpeError!?*message.Message {...}
    pub fn put(ampe: Ampe, msg: *?*message.Message) void {...}

    pub fn getAllocator(ampe: Ampe) Allocator {...}
```

Just a reminder: all methods are thread-safe.

The first two methods, create/destroy, manage a ChannelGroup. You don't need to know what that is yet; just make a note of it.

The next two methods require additional explanation, so let's move on to the _Message Pool_.


---


## Message Pool

Ampe supports a Message Pool mechanism to improve system performance.

The **_get_** operation retrieves an existing message from the pool or creates a new one. 
The choice is determined by the _strategy: AllocationStrategy_ parameter:
```zig
pub const AllocationStrategy = enum {
    poolOnly, // Tries to get a message from the pool. Returns null if the pool is empty.
    always,   // Gets a message from the pool or creates a new one if the pool is empty.
};
```
!!! warn "null isn't error"
    Returned by get null is absolutely valid value, _null_ returned if the _pool is empty_ and the strategy is _poolOnly_. 


**_get_** returns error if

- allocation failed
- engine performs shutdown

Opposite **_put_** operation returns message to the pool and sets it's value to _null_.
If engine performs shutdown or **_pool is full_**, message will be destroyed, means
all allocated memory silently will be released.

```zig 
    var msg: ?*Message = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);
```

Because null returned by **_get_** is valid value , it's also valid value for **_put_**:
if msg == null, put does nothing.

!!! question "NAQ: \*?\*message.Message - WTH???"
    \*?\* (address of optional pointer) idiom allows to prevent
    reusing of released or moved to other thread objects(structs).
    In our case - Messages.
    
`#!zig ampe.put(&msg)`:

 - returns msg to the pool
 - set msg to null

As result:

 - every further put will be successful
 - every further attempt to use msg without check will fail

You will see usage of ****?**** in different places during our journey.


### Pool configuration

Pool configuration is determined by 
```zig
pub const Options = struct {
    initialPoolMsgs: ?u16 = null,
    maxPoolMsgs: ?u16 = null,
};
```
**_initialPoolMsgs_** - is the number of messages in the pool created during initialization of engine

**_maxPoolMsgs_** - is the maximal number of the messages 

Do you remember ? 
>If ... **_pool is full_**, message will be destroyed

means if number of the messages in the pool == maxPoolMsgs, message will be destroyed.

<a id="default-configuration-anchor"></a>Tofu provides default pool configuration:
```zig title="Just example of configuration, it isn't recommendation"
    pub const DefaultOptions: Options = .{
        .initialPoolMsgs = 16,
        .maxPoolMsgs = 64,
    };
```

Pool configuration is used during creation of engine:
```zig
    // Create engine implementation object with default pool configuration 
    var rtr: *Reactor = try Reactor.Create(gpa, DefaultOptions);
```

Just clarification - you don't deal with pool destroy, it will be destroyed during destroy of engine. 

## Allocator

Tofu's relationship with Allocators is similar to Henry Ford's famous quote about car color:

> "Customers can have any color they want, so long as it is black."

Similarly, allocators for Tofu can be anything, provided they are '**GPA** compatible'.

Allocator names in Zig change often. This reminds me of an old Unix joke:
> "Unix is an operating system where nobody knows what the print command is called today"

I'll use **GPA** (General Purpose Allocator) because I expect that the name GPA will persist in common use.

<a id="gpa-compatible-anchor"></a>
'**GPA** compatible' means:

- It is **thread-safe**.
- Its **life cycle** is the same as the life cycle of the process.
- The memory it **releases** truly allows for further reuse of that released memory.

For example, `std.heap.c_allocator` satisfies these requirements, but `std.heap.ArenaAllocator` does not.

t's no surprise that ampe.getAllocator() returns GPA compatible allocator used during ampe's creation. 

---
