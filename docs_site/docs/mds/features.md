
- **Cross-platform**: Linux (epoll), Windows 10+ (wepoll), macOS/BSD (kqueue) — automatic, zero code changes
- **Message-Based**: Uses discrete messages for communication.
- **Asynchronous**: Enables non-blocking message exchanges.
- **Duplex**: Supports two-way communication.
- **Peer-to-Peer**: Allows equal roles after connection establishment.
- **Stream oriented transport** - TCP/IP and **U**nix **D**omain **S**ockets
- **Multithread-friendly** - All APIs are safe for concurrent access.
- **Memory management for messages** - Internal message pool
- **Backpressure management** - Allows to control receive of messages
- **Customizable application flows** - Allows to build various application flows not restricted to request/response or pub/sub
- **Simplest API** - You don't have to bother with or know the "guts" of socket interfaces
- **DIY** - No enforced authentication or serialization; provides features to design and implement your own.
- **Callback enabled** - This will be explained later. 

