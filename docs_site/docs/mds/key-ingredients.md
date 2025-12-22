

Tofu has only three main ingredients:

- **Ampe** — the Async Message Passing Engine (we call it the _engine_).
- **ChannelGroup**
- **Message**

Each ingredient depends on the others, so it’s hard to explain one without understanding the rest.  
Because of that, the short descriptions below give only the basic idea.

The examples later will help you understand how tofu really works.

---

## Separation of Concerns

### Logical Separation

The **_Engine_** owns all resources in Tofu software.  
It allocates and destroys **Message(s)** and **ChannelGroup(s)**.

The **_ChannelGroup_** handles async, two-way exchange of **Messages**.

The **_Message_** does two things:

- Holds business data and metadata.
- Works as a command for Tofu.

### Physical Separation

The **_Engine_** name shows the real work it does.  
Every engine runs one **_internal thread_** with a **poll loop**.  
This loop handles all socket operations.

The **_Ampe interface_** is implemented by the **_Reactor_** structure.

All **ChannelGroups** share **one internal socket** to talk to the engine thread.

Each **ChannelGroup** uses an **internal queue** for messages (from engine or application).

The **ChannelGroup** is a thin layer.  
It forwards messages between application and engine thread.

---

## Tofu-based Communication Flow

The steps below show how communication works between network participants, called **peers**:

- **Initialization:** The peer creates a **Reactor** to get the **Ampe interface**.
- **Channel Setup:** The peer creates a **ChannelGroup** to manage *channels* (connections to other peers).
- **Core Loop:** In the main application loop, the peer:
  - **Sends:** Gets **Messages** from Ampe, fills data, **enqueues** via ChannelGroup.
  - **Receives:** Gets and processes incoming messages from other peers.

This is a **simple overview**.  
Later sections show full logic and message lifecycle.
