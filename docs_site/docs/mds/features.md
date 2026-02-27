
- **Cross-platform**: Linux (epoll), Windows 10+ (wepoll), macOS/BSD (kqueue) — automatic, zero code changes
- **Message-Based**: Uses discrete messages for communication.
- **Asynchronous**: Non-blocking message exchange.
- **Duplex**: Two-way communication.
- **Peer-to-Peer**: Equal roles after connection.
- **Stream oriented transport** - TCP/IP and **U**nix **D**omain **S**ockets
- **Multithread-friendly** - All APIs are thread-safe.
- **Memory management for messages** - Internal message pool
- **Backpressure management** - Flow control for incoming messages
- **Customizable application flows** - Any flow — not just request/response or pub/sub
- **Simplest API** - You don't have to bother with or know the "guts" of socket interfaces
- **DIY** - No enforced authentication or serialization; provides features to design and implement your own.
- **Callback enabled** - This will be explained later. 

