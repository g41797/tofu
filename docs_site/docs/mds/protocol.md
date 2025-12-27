

Well, calling it a “**_protocol_**” might be saying too much. 
It’s more like a description that doesn’t depend on any specific implementation.

There are 3 participants :

- Messages
- Channels
- Engine


## Engine

The Engine’s API is not defined — it depends on the implementation. 

What matters is that when the engine gets a message from the application, it

- checks the message’s metadata 
- creates a channel if needed
- sends the message to that channel’s outgoing queue

Also

- receives messages from the network
- returning them through the right channel.

It also analyzes network issues and notifies the client code.

All of these runs asynchronously, independent of the rest of the process code.

Engine contains a set of channels (zero or more). The maximum number depends on the implementation.

## Channel

Think of a _channel_ as a _virtual socket_.

There are two kinds of channels:

- Listener – Analog of a listener socket.
- IO – Analog of client socket or accepted server socket.

??? question "NAQ: Why not just Socket"
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

