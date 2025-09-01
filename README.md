# YAAAMP - Yet Another Asynchronous Application Messaging Protocol
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Linux](https://github.com/g41797/yaaamp/actions/workflows/linux.yml/badge.svg)](https://github.com/g41797/yaaamp/actions/workflows/linux.yml)
<!-- [![MacOS](https://github.com/g41797/yaaamp/actions/workflows/mac.yml/badge.svg)](https://github.com/g41797/yaaamp/actions/workflows/mac.yml) -->

## Overview

YAAAMP (Yet Another Asynchronous Application Messaging Protocol) is a lightweight protocol designed for application-layer communication, with the following characteristics:

- **Duplex**: Supports two-way communication.
- **Asynchronous**: Enables non-blocking message exchanges.
- **Peer-to-Peer**: Allows equal roles after connection establishment.
- **Transport-Agnostic**: Operates over reliable transports like TCP or WebSocket.
- **Message-Based**: Uses discrete messages for communication.

> **Note**: TCP/IP terminology (e.g., client, server) is used for clarity, but YAAAMP is not tied to TCP/IP.

## Unified Communication Approach

YAAAMP’s unified communication approach simplifies interaction between the protocol and application by:  
- Treating both protocol tasks (e.g., setting up or closing connections) and application data exchanges in the same way, reducing complexity.  
- Supporting an asynchronous mindset:  
  - Communication between the protocol software and the application is non-blocking, allowing both to work independently without waiting for each other.  
  - This ensures efficient, seamless interaction, aligning with YAAAMP’s asynchronous design.  
- Enabling a consistent workflow that:  
  - Makes it easier to handle both protocol and application tasks.  
  - Improves development and maintainability with a unified, intuitive approach.

## Message Classification

Messages are classified as:

- **`request`**: Expects one or more `response` message.
- **`response`**: Sent in reply to a `request`.
- **`signal`**: One-way notification; no reply expected.

## Message Categories

Messages are categorized into:

- **Protocol Messages**:
  - Handle protocol-level coordination (e.g., connection setup, teardown).
  - Created by the application but processed by both protocol and application layers.
  - Types:
    - `welcome`: Used during initial handshake (typically `request`/`response` pair).
    - `hello`: Initiates client-server contact (typically `request`/`response` pair).
    - `bye`: Signals disconnection (can be `request`/`response` or `signal`).
    - `status`: Contains status of processing (`signal`).
  

- **Application Messages**:
  - Created and consumed solely by the application.
  - Transmitted transparently by the protocol.

## Message Structure

A YAAAMP message consists of:

1. **Binary Fixed-Size Header** (16 bytes, required).
2. **Text Headers Section** (Optional, HTTP-style key-value pairs).
3. **Body** (Optional, application-specific payload, opaque to the protocol).

### Binary Header Format

The binary header is 16 bytes, encoded in the sender’s native byte order, with the following fields:

- **Channel Number**:
  - **Size**: 2 bytes.
  - **Description**: Identifies a logical peer or channel (native byte order). The Channel Number is unique because it is assigned by the protocol, with its uniqueness maintained within the scope of the process lifecycle.
- **Type**:
  - **Size**: 3 bits.
  - **Description**: Specifies the message type:
    - `0`: Application message.
    - `1`: `welcome`.
    - `2`: `hello`.
    - `3`: `bye`.
    - `4`: `status`.
    - `5-7`: Reserved.
- **Mode**:
  - **Size**: 2 bits.
  - **Description**: Defines the message kind:
    - `0`: Invalid.
    - `1`: `request`.
    - `2`: `response`.
    - `3`: `signal`.
- **Origin**:
  - **Size**: 1 bit.
  - **Description**: Indicates the message’s creator:
    - `0`: Application-created.
    - `1`: Protocol-created.
- **More Messages Expected**:
  - **Size**: 1 bit.
  - **Description**: For sequence of **APPLICATION** messages with the same **Message ID**:
    - `0`: Last or only message in the sequence.
    - `1`: More messages with the same **Message ID** expected.
- **Protocol Control Bit (PCB)**:
  - **Size**: 1 bit.
  - **Description**: Used and filled exclusively by the protocol for housekeeping purposes. Completely opaque to the application and must not be modified by it.
- **Status**:
  - **Size**: 1 byte.
  - **Description**: Indicates the status of a `response`, but may be placed within `signal`:
    - `0`: OK (Success).
    - Non-zero: Error status:
      - For `Origin = 0`: Application-defined error.
      - For `Origin = 1`: Protocol-defined error.
- **Message ID**:
  - **Size**: 8 bytes.
  - **Description**: Unique identifier for `request` and `signal` messages, assigned sequentially by the protocol layer by default. `response` messages copy the `request`’s ID. Must be unique during the process lifecycle. Application may provide its own value for enhanced security.
- **Text Headers Length**:
  - **Size**: 2 bytes.
  - **Description**: Length of text headers (native byte order). `0` means no headers.
- **Body Length**:
  - **Size**: 2 bytes.
  - **Description**: Length of body (native byte order). `0` means no body.

## Roles

### During Handshake
- **Client**: Initiates contact.
- **Server**: Accepts contact.

### Post-Handshake
- **Peer**: Both sides act as equals, sending/receiving messages per application logic.

### Protocol Layers
- **ClPr**: Client-side protocol logic during handshake.
- **SrPr**: Server-side protocol logic during handshake.
- **PrPr**: Peer protocol logic after connection establishment.

## API Operations

Protocol provides:

- **Start Send Message**:
  - Initiates sending a message (non-blocking).
  - Parameters: Message type, mode, headers, body, optional application-provided Message ID.
- **Wait With Timeout**:
  - Waits for incoming messages or status updates (e.g., delivery confirmation, errors).
  - Returns: Status code or received message.
  - Includes a timeout to prevent indefinite blocking.

## Message Flow Examples

### Welcome Sequence
Server announces its presence or readiness:

1. Server creates a `welcome` `request` with a unique `Message ID` and optional capabilities in headers/body.
2. Server sends the `request` to its SrPr.
3. SrPr processes it (e.g., opens a listening socket) and sends a `welcome` `response` with the same `Message ID`.
4. Server receives the `response` via `Wait With Timeout`.

### Hello Sequence (Client Initiates Connection)
Typical client-server connection establishment:

1. Client creates a `hello` `request` with a unique `Message ID` and optional identity/parameters.
2. Client sends the `request` to its ClPr.
3. ClPr connects to the server’s SrPr and forwards the `request`.
4. SrPr passes the `request` to the server.
5. Server processes it and sends a `hello` `response` with the same `Message ID` (`Status = OK` if accepted).
6. ClPr passes the `response` to the client.
7. On success, both transition to `Peer` role.
8. If `Status` is non-`OK`, the connection fails, and ClPr notifies the client.

- `hello` `request` and `response` may include application-specific data in headers/body, transmitted transparently.
- A non-`OK` `hello` `response` indicates a failed connection.

### Bye Sequence (Disconnection)

#### Application-Initiated
1. A peer creates a `bye` message (`request` or `signal`) with a unique `Message ID`.
2. The `bye` is sent to the local PrPr and transmitted to the remote peer.
3. For a `request`, the remote peer responds with a `bye` `response` with the same `Message ID`. The connection closes.

#### Protocol-Initiated
1. PrPr detects a transport failure or timeout.
2. PrPr creates a `bye` `signal` with a `Message ID` and delivers it locally.
3. PrPr attempts to send a `bye` to the remote peer (if possible) and cleans up resources.

## Extensibility

YAAAMP supports future extensions via **Text Headers**: Flexible key-value pairs for metadata or parameters.

## Implementation Considerations

- YAAAMP’s asynchronous nature requires a multithreaded environment to support non-blocking message exchanges.
- Unsuitable languages include:
  - PHP: Lacks native multithreading support.
  - Python: Limited by the Global Interpreter Lock (GIL) in CPython.
  - JavaScript: Constrained by its single-threaded event-loop model (even in Node.js).
- YAAAMP is unlikely to be used in browsers or web clients due to:
  - Reliance on binary headers and low-level transport-agnostic communication.
  - Web environment security and threading limitations.
- Suitable programming environments:
  - C++: Offers fine-grained thread management and performance optimization.
  - Rust: Provides safe concurrency with its ownership model.
  - Go: Features goroutines and channels for scalable concurrency.
  - Zig: Supports manual memory management and multithreading with low-level control.
- Niche use-cases for YAAAMP:
  - Real-time multiplayer game servers.
  - Distributed system messaging.
  - IoT device networks.

## DIY (Do It Yourself)

YAAAMP provides flexibility for developers to customize features via its extensible design:  
- Supports custom features, such as:  
  - Authentication using credentials or tokens in `hello` message text headers.  
  - Body compression by specifying a compression type (e.g., `Content-Encoding: gzip`) in text headers.  
  - Additional features like custom error codes, session management, or priority handling via text headers or message body.  
- Allows freedom in data serialization:  
  - No enforced marshalling scheme.  
  - Developers can choose formats like JSON or Protobuf.  
- Enables tailoring YAAAMP to application needs while the protocol:  
  - Focuses on efficient and reliable message transmission.

## Message Flow Diagrams

The following ASCII diagrams illustrate the message flows described in the **Message Flow Examples** section. These diagrams depict the interactions between entities (e.g., Server, Client, protocol layers) for the **Welcome Sequence**, **Hello Sequence**, and **Bye Sequence** (both application-initiated and protocol-initiated cases). They use simple text-based representations suitable for Markdown rendering.

### Welcome Sequence Diagram
```
Server          SrPr
  |               |
  |  welcome req  |
  |-------------->|
  |               |
  |  welcome res  |
  |<--------------|
  |               |
```

### Hello Sequence Diagram
```
Client    ClPr        SrPr       Server
  |        |           |           |
  | hello  |           |           |
  | req    |           |           |
  |------->|           |           |
  |        | hello     |           |
  |        |   req---->|---------->|
  |        |           |           |
  |        |           | hello res |
  |        | hello<----|<----------|
  |        |   res     |           |
  |        |<----------|           |
  |<-------|           |           |
  |        |           |           |
```

### Bye Sequence Diagrams

#### Application-Initiated
```
Peer1     PrPr1       PrPr2     Peer2
  |          |          |          |
  | bye req  |          |          |
  |--------->|--------->|--------->|
  |          |          |          |
  |          | bye res  |          |
  |          |<---------|<---------|
  |<---------|
  
```

#### Protocol-Initiated
```
Peer1     PrPr1       PrPr2     Peer2
  |          |          |          |
  |          |(failure) |          |
  | bye      |          |  bye     |
  | signal   |          |  signal  |
  |<---------|          |--------->|
  ```
