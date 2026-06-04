# Tofu Architecture & Test Relations Analysis

This document provides a layered architecture diagram of the `tofu` Zig messaging library implementation and visualizes the relationships between its test groups, excluding the platform-independent/no-socket tests requested.

---

## 1. Layered Architecture Diagram

```mermaid
graph TD
    %% Colors and Styles
    classDef facade fill:#2d3748,stroke:#4a5568,stroke-width:2px,color:#fff;
    classDef engine fill:#1a365d,stroke:#2b6cb0,stroke-width:2px,color:#fff;
    classDef adapter fill:#2c5282,stroke:#4299e1,stroke-width:2px,color:#fff;
    classDef platform fill:#22543d,stroke:#48bb78,stroke-width:2px,color:#fff;
    classDef wrapper fill:#744210,stroke:#dd6b20,stroke-width:2px,color:#fff;

    subgraph Layer1["1. Public API / Facade Layer"]
        tofu_zig["tofu.zig<br>(Public Facade)"]
        ampe_zig["ampe.zig<br>(Ampe & ChannelGroup Interfaces)"]
        address_zig["address.zig<br>(Address Formats & Resolution)"]
        message_zig["message.zig<br>(Message Layout & Queue)"]
        status_zig["status.zig<br>(Status & Errors)"]
    end
    class tofu_zig,ampe_zig,address_zig,message_zig,status_zig facade;

    subgraph Layer2["2. Core Engine / AMPE Layer"]
        reactor["Reactor.zig<br>(Event Loop & State Machine)"]
        channels["channels.zig<br>(ChannelGroup Imp.)"]
        core["core.zig<br>(PollerCore, SeqnTrcMap)"]
        pool["Pool.zig<br>(Memory/Buffer Pool)"]
        notifier["Notifier.zig<br>(Self-Pipe/Eventfd Wakeup)"]
        triggered["triggeredSkts.zig<br>(Trigger Structures)"]
        vtables["vtables.zig<br>(Ampe/Channels Interfaces)"]
    end
    class reactor,channels,core,pool,notifier,triggered,vtables engine;

    subgraph Layer3["3. Compile-Time Abstraction Adapter Layer"]
        internal_zig["internal.zig<br>(Dispatches Skt/SocketCreator)"]
        poller_zig["poller.zig<br>(Dispatches Poller Backend)"]
    end
    class internal_zig,poller_zig adapter;

    subgraph Layer4a["4a. Direct OS stdposix Backends (isPosixNet = false)"]
        linux_std["stdposix/linux/<br>(Direct epoll, Skt, Triggers)"]
        mac_std["stdposix/mac/<br>(Direct kqueue, Skt, Triggers)"]
        win_std["stdposix/windows/<br>(wepoll Wrapper, Skt, Triggers)"]
    end
    class linux_std,mac_std,win_std platform;

    subgraph Layer4b["4b. Bun-uSockets posixnet Backends (isPosixNet = true)"]
        wrapper_c["posixnet/wrapper/<br>(Zig FFI bindings over C usockets)"]
        linux_pn["posixnet/linux/<br>(Skt & SocketCreator)"]
        mac_pn["posixnet/mac/<br>(Skt & SocketCreator)"]
        win_pn["posixnet/windows/<br>(Skt & SocketCreator)"]
        pn_backend["posixnet_backend.zig / triggers.zig<br>(Poller & Trigger mapping)"]
    end
    class wrapper_c,linux_pn,mac_pn,win_pn,pn_backend wrapper;

    %% Dependencies / Flows
    tofu_zig --> ampe_zig
    ampe_zig --> reactor
    reactor --> core
    reactor --> pool
    reactor --> notifier
    channels --> core
    core --> poller_zig
    core --> triggered
    internal_zig --> linux_std & mac_std & win_std
    internal_zig --> linux_pn & mac_pn & win_pn
    poller_zig --> win_std & linux_std & mac_std
    poller_zig --> pn_backend
    linux_pn & mac_pn & win_pn --> wrapper_c
    pn_backend --> wrapper_c
```

---

## 2. Test Groups & Relations Diagram

The diagram below shows the relationships between active test groups. High-level integration tests build on engine integration, which builds on poller backends, which in turn build on low-level wrappers and socket layers.

*Note: As requested, platform-independent non-socket tests (`Pool_tests`, `channels_tests`, `address_tests`, and `message_tests`) are excluded from this analysis.*

```mermaid
graph TD
    %% Colors and Styles
    classDef recipe fill:#3b0066,stroke:#805ad5,stroke-width:2px,color:#fff;
    classDef integration fill:#0f172a,stroke:#475569,stroke-width:2px,color:#fff;
    classDef poller fill:#1e3a8a,stroke:#3b82f6,stroke-width:2px,color:#fff;
    classDef sockets fill:#064e3b,stroke:#10b981,stroke-width:2px,color:#fff;

    subgraph RecipesGroup["4. Recipes / High-Level Workflows"]
        cookbook_zig["recipes/cookbook.zig<br>(Examples & Workflows)"]
        services_zig["recipes/services.zig<br>(Message Processing)"]
        multihomed_zig["recipes/MultiHomed.zig<br>(Multi-listener Server)"]
    end
    class cookbook_zig,services_zig,multihomed_zig recipe;

    subgraph IntegrationGroup["3. Reactor / Engine Integration Tests"]
        reactor_tests["reactor_tests.zig<br>(Reactor, connections, and reconnects)"]
    end
    class reactor_tests integration;

    subgraph PollerGroup["2. Poller & Event Backend Tests"]
        pollercore_tests["pollercore_tests.zig<br>(Replaces windows_poller_tests)<br>(Integration with Notifier & Sockets)"]
        poller_tests["ampe/poller_tests.zig<br>(Contract tests for active backend)"]
        portable_poller["ampe/portable_poller_tests.zig<br>(posixnet portable polling)"]
    end
    class pollercore_tests,poller_tests,portable_poller poller;

    subgraph SocketsGroup["1. Low-Level Wrapper & Socket Tests"]
        posix_net_tests["posix_net_tests.zig<br>(uSockets C FFI Direct Tests)"]
        sockets_tests["ampe/sockets_tests.zig<br>(Linux Skt/SocketCreator Tests)"]
        notifier_tests["ampe/Notifier_tests.zig<br>(Non-blocking Notifier Wakeups)"]
        temp_uds_path["ampe/temp_uds_path_tests.zig<br>(UDS Utilities)"]
    end
    class posix_net_tests,sockets_tests,notifier_tests,temp_uds_path sockets;

    %% Relations
    reactor_tests --> cookbook_zig & services_zig & multihomed_zig
    reactor_tests --> pollercore_tests
    pollercore_tests --> poller_tests
    poller_tests --> sockets_tests & notifier_tests & temp_uds_path
    portable_poller --> posix_net_tests
```

---

## 3. Detail of Implementation Layers

### 1. Public API / Facade Layer
- **`tofu.zig`**: The entrypoint, re-exporting key types (`Ampe`, `ChannelGroup`, `Options`, `Reactor`, `Skt`, `SocketCreator`, and platform initialization/destruction helpers) to keep the client interface clean and unified.
- **`ampe.zig`**: Houses the abstract `Ampe` and `ChannelGroup` interfaces. These interfaces route calls through runtime virtual method tables (`AmpeVTable` and `CHNLSVTable`).
- **`address.zig` & `message.zig`**: Handles structure layouts, TCP/IP/Unix domain addresses, frame structures (`BinaryHeader`), `OpCode` state, and internal `MessageQueue`.

### 2. Core Engine / AMPE Layer
- **`Reactor.zig`**: The event-driven heart. It orchestrates the asynchronous flow using state transitions and non-blocking I/O.
- **`channels.zig`**: Bridges `ChannelGroup` to the core polling/queuing components.
- **`core.zig`**: Holds the `PollerCore` event loop and structures like `SeqnTrcMap` (mapping sequence numbers to channels to protect against ABA issues).
- **`Pool.zig`**: A highly optimized message block allocator that keeps memory allocations predictable.
- **`Notifier.zig`**: Provides a thread-safe, cross-platform notifier (self-pipe/loopback/eventfd) to safely wake the `waitReceive` thread.

### 3. Compile-Time Abstraction Adapter Layer
- **`internal.zig`**: Resolves `Skt` and `SocketCreator` compile-time mappings based on the chosen network backend (`posixnet` vs. `stdposix`) and OS.
- **`poller.zig`**: Selects the active `Poller` backend implementation, dispatching to epoll, kqueue, wepoll, or posixnet.

### 4. Platform-Specific Implementations
- **`stdposix` Backend**: Native, zero-dependency Zig standard library implementation tailored specifically to the host system (`epoll` for Linux, `kqueue` for macOS/BSDs, and `wepoll` for Windows).
- **`posixnet` Backend**: Interfaces through C FFI wrappers (`posix_net`) over `bun-usockets` (originally from the Bun project), facilitating portable socket handling.

---

## 4. Summary of Analyzed Test Groups

1. **Low-Level Wrapper & Socket Tests**:
   - **`posix_net_tests.zig`**: Direct testing of the low-level `bun-usockets` FFI.
   - **`sockets_tests.zig`**: Directly exercises the platform `Skt` / `SocketCreator` interface on Linux.
   - **`Notifier_tests.zig`**: Verifies that the notifier correctly wakes up polling loops thread-safely.
   - **`temp_uds_path_tests.zig`**: Tests generation and clean-up of temporary UDS file system paths.

2. **Poller / Event Backend Tests**:
   - **`poller_tests.zig`**: Runs contract tests validating timeouts, readability/writability transitions, unregistering event loops, and sequence-based ABA protection.
   - **`portable_poller_tests.zig`**: Validates the portable event loop abstraction for `posixnet`.
   - **`pollercore_tests.zig`**: Runs full integration of `PollerCore`, validating Notifier interrupts, socket attachment, connection acceptance, and raw network data roundtrips.

3. **Reactor / Engine Integration Tests**:
   - **`reactor_tests.zig`**: High-level system integration tests covering connection/disconnection lifecycles, reconnect flows, illegal frame handling, and concurrent/multithreaded simulation tasks.

4. **Recipes / Workflows (High-Level Workflows)**:
   - **`MultiHomed.zig`**, **`cookbook.zig`**, and **`services.zig`**: Demonstrates the real-world usage patterns of the tofu framework, serving as complex operational validation tests.
