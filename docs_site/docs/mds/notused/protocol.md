

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

