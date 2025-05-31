# Zig’s Yet Another Messaging Protocol


## Software Requirements

### 1. Peer-to-Peer Communication
Designed for equal peers communicating directly, without central servers or fixed roles.

### 2. Message-Based Communication
Uses discrete, self-contained messages to structure communication.

### 3. Asynchronous and Duplex
Either side can send messages independently at any time.

### 4. Role Symmetry
No strict client/server model after initial contact - both peers behave equally.

### 5. Supports Text and Binary Data
Messages can include both readable and encoded content.

### 6. Transport Independence
Works over any reliable byte-stream transport, not tied to a specific protocol.

### 7. Explicit Message Boundaries
Messages are clearly separated using CRLF delimiters for headers and a declared body length.

### 8. Lightweight and Minimal
No external dependencies or complex runtime behavior - easy to embed and understand.

### 9. Flexible for Applications
Applications can define and interpret messages freely, adapting the protocol to their needs.

### 10. Asynchronous API Design
Communication is managed via:
- A non-blocking start-send operation  
- A wait operation with timeout support  

This encourages cooperative, event-driven processing.

### 11. Native Zig Implementation
Fully written in Zig using only the standard library - no C libraries or FFI required.

### 12. Interoperable Across Languages
The protocol can be reimplemented in other languages, with possible adjustments for asynchronous behavior depending on language features.

---

#  Addendum: Protocol Comparisons

Each table below compares ZYAMP to another messaging protocol.

##  ZYAMP vs HTTP

| Feature                 | ZYAMP          | HTTP                  |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | No                 |
| Asynchronous Messaging | Yes          | No Synchronous        |
| Duplex Communication   | Yes          | No One-way per req    |
| Transport Agnostic     | Yes         | No TCP/IP only        |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | Supported          |
| Use Case               | Embedded, P2P  | Web, APIs             |

##  ZYAMP vs MQTT

| Feature                 | ZYAMP          | MQTT                  |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | No Broker-based       |
| Asynchronous Messaging | Yes         | Yes               |
| Duplex Communication   | Yes          | No Via broker         |
| Transport Agnostic     | Yes          | No Mostly TCP         |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | Yes               |
| Use Case               | P2P, Embedded  | IoT, Telemetry        |

##  ZYAMP vs AMQP

| Feature                 | ZYAMP          | AMQP                  |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | No Broker-based       |
| Asynchronous Messaging | Yes         | Yes               |
| Duplex Communication   | Yes          | Broker-mediated    |
| Transport Agnostic     | Yes          |TCP only           |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | Yes               |
| Use Case               | Custom, IPC    | Enterprise Messaging  |

##  ZYAMP vs NNG

| Feature                 | ZYAMP          | NNG                   |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | Yes               |
| Asynchronous Messaging | Yes          | Yes               |
| Duplex Communication   | Yes         | Yes               |
| Transport Agnostic     | Yes         | Yes               |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | Yes               |
| Use Case               | Lightweight    | Scalable Messaging    |

##  ZYAMP vs gRPC

| Feature                 | ZYAMP          | gRPC                  |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | No Client-server      |
| Asynchronous Messaging | Yes         | Via Streams            |
| Duplex Communication   | Yes         | Via Streams            |
| Transport Agnostic     | Yes         | No HTTP/2 Only        |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | Protobuf           |
| Use Case               | Embedded, P2P  | Service APIs          |

##  ZYAMP vs CoAP (UDP)

| Feature                 | ZYAMP          | CoAP                  |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | UDP peer           |
| Asynchronous Messaging | Yes         | No Mostly Req-Res     |
| Duplex Communication   | Yes         | Not duplex         |
| Transport Agnostic     | Yes         | UDP Only           |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | Yes               |
| Use Case               | Custom Systems | Constrained Devices   |

##  ZYAMP vs CoAP over TCP

| Feature                 | ZYAMP          | CoAP over TCP         |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | No Mostly client/server |
| Asynchronous Messaging | Yes         | No Mostly Req-Res     |
| Duplex Communication   | Yes          | Yes          |
| Transport Agnostic     | Yes         | TCP Only           |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | Yes               |
| Use Case               | P2P, Zig Apps  | Reliable IoT Messaging |

##  ZYAMP vs CAN

| Feature                 | ZYAMP          | CAN                   |
|------------------------|----------------|-----------------------|
| Peer-to-Peer           | Yes         | Yes               |
| Asynchronous Messaging | Yes         | Yes               |
| Duplex Communication   | Yes         | No Half-duplex        |
| Transport Agnostic     | Yes         | No Hardware tied      |
| Message Boundaries     | Framed      | Framed             |
| Binary Payloads        | Yes      | No Very limited (<=8B) |
| Use Case               | Software Apps  | Vehicles, Automation  |---

