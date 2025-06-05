# YAAAMP - Yet Another Application Asynchronous Messaging Protocol

## Overview

YAAAMP is a lightweight, asynchronous, peer-to-peer, transport-agnostic, message-based protocol designed for application-layer communication.

- **Duplex**: Supports two-way communication.
- **Asynchronous**: Enables non-blocking message exchanges.
- **Peer-to-Peer**: Equal roles after connection establishment.
- **Transport-Agnostic**: Operates over reliable transports (e.g., TCP, WebSocket).
- **Message-Based**: Uses discrete messages.

> **Note**: TCP/IP terminology (e.g., client, server) is used for clarity, but YAAAMP is not tied to TCP/IP.

## Unified Communication Approach

YAAAMP’s unified communication approach enhances simplicity and consistency through:  
- Using the same **Start Send Message** operation for:  
  - Protocol operations (e.g., setting up or closing connections).  
  - Application data exchanges.  
- Enabling a shared mindset that:  
  - Simplifies working with protocol and application tasks.  
  - Provides a consistent, intuitive workflow.  
- Streamlining development and improving maintainability.

## Message Classification

Messages are classified as:

- **`request`**: Expects one or more `response` messages.
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
    - `control`: For future extensions (can be `request`, `response`, or `signal`).

- **Application Messages**:
  - Created and consumed solely by the application.
  - Transmitted transparently by the protocol.

## Message Structure

A YAAAMP message consists of:

1. **Binary Fixed-Size Header** (16 bytes, required).
2. **Text Headers Section** (Optional, HTTP-style key-value pairs).
3. **Body** (Optional, application-specific payload, opaque to the protocol).

### Binary Header Format

The binary header is 16 bytes, encoded in the sender’s native byte order.

| Field                     | Size       | Description                                                                 |
|---------------------------|------------|-----------------------------------------------------------------------------|
| Channel Number            | 2 bytes    | Identifies a logical peer or channel (native byte order).                   |
| Type                      | 3 bits     | Message type: <br> - `0`: Application message <br> - `1`: `welcome` <br> - `2`: `hello` <br> - `3`: `bye` <br> - `4`: `control` <br> - `5-7`: Reserved |
| Mode                      | 2 bits     | Message kind: <br> - `0`: Invalid <br> - `1`: `request` <br> - `2`: `response` <br> - `3`: `signal` |
| Origin                    | 1 bit      | Indicates whether the message was created by the application or protocol layer: <br> - `0`: Application-created <br> - `1`: Protocol-created |
| More Responses Expected   | 1 bit      | For `response` messages: <br> - `0`: Last or only response <br> - `1`: More responses expected |
| Reserved Bit              | 1 bit      | Reserved; set to `0` by senders, ignored by receivers.                      |
| Status                    | 1 byte     | Indicates the status of a `response`, but may be placed within `signal`: <br> - `0`: OK (Success) <br> - Non-zero: Error status <br>     - For `Origin = 0`: Application-defined error <br>     - For `Origin = 1`: Protocol-defined error |
| Message ID                | 8 bytes    | Unique identifier for `request` and `signal` messages, assigned sequentially by the protocol layer by default. `response` messages copy the `request`’s ID. Must be unique during the process lifecycle. Application may provide its own value for enhanced security. |
| Text Headers Length       | 2 bytes    | Length of text headers (native byte order). `0` means no headers.           |
| Body Length               | 2 bytes    | Length of body (native byte order). `0` means no body.                      |

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

Each protocol layer (ClPr, SrPr, PrPr) provides:

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

YAAAMP supports future extensions via:

- **`control` Messages**: For new features.
- **Text Headers**: Flexible key-value pairs for metadata or parameters.

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

The following ASCII diagrams illustrate the message flows described in the **Message Flow Examples** section. These diagrams depict the interactions between entities (e.g., Server, Client, protocol layers) for the **Welcome Sequence**, **Hello Sequence**, and **Bye Sequence** (both application-initiated and protocol-initiated cases). 

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
  |        |   req---->|------->|
  |        |           |           |
  |        |           | hello res |
  |        | hello<----|<-------|
  |        |   res     |           |
  |        |<---------|           |
  |<-------|           |           |
  |        |           |           |
```

### Bye Sequence Diagrams

#### Application-Initiated
```
Peer1     PrPr1       PrPr2     Peer2
  |          |          |          |
  | bye req  |          |          |
  |--------->|---------->|-------->|
  |          |          |          |
  |          | bye res  |          |
  |          |<---------|<-------|
  |<--------|---------|           |
  |          |          |          |
```

#### Protocol-Initiated
```
Peer1     PrPr1       PrPr2     Peer2
  |          |          |          |
  |          | (failure) |          |
  | bye      |          |          |
  | signal   |          |          |
  |<--------|          |          |
  |          | bye      |          |
  |          | signal-->|-------->|
  |          |          |          |
```
