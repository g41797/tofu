# Investigation Plan: Reactor, Poller, and Triggered Sockets Negotiation

## Objective
To deeply understand and document the interaction model between the generic Reactor, the OS-specific Poller, and the Triggered Sockets/Channels, with a focus on state management, memory layout (growable structures), and the boundaries of OS independence.

## Scope
1.  **Generic Reactor Logic:** `src/ampe/Reactor.zig`
2.  **Triggered Sockets Abstraction:** `src/ampe/triggeredSkts.zig`
3.  **Linux Implementation (Reference):** `src/ampe/os/linux/poller.zig` and `src/ampe/os/linux/Skt.zig`
4.  **Windows Implementation (Target):** `src/ampe/os/windows/poller.zig`, `src/ampe/os/windows/afd.zig`, and `src/ampe/os/windows/Skt.zig`

## Investigation Steps

### 1. Analyze Generic Reactor & Data Structures
*   **Goal:** Understand how the Reactor manages the lifecycle and storage of `TriggeredChannel` objects.
*   **Key Questions:**
    *   How is `trgrd_map` (TriggeredChannelsMap) implemented? (Is it stable? Do pointers move?)
    *   How does the `Iterator` passed to the poller work?
    *   What exact state does the Reactor expect the Poller to update in `TriggeredChannel` (e.g., `.act` field)?
    *   What constitutes the "single thread" guarantee?

### 2. Analyze Linux Poller (The "Stateless" Model)
*   **Goal:** Determine how Linux maps the persistent Reactor state to the ephemeral `poll()` syscall.
*   **Key Questions:**
    *   Does the Linux `Skt` struct hold any polling state?
    *   How does `linux/poller.zig` build the `pollfd` array? Is it rebuilt every iteration?
    *   How does it map `pollfd.revents` back to `TriggeredChannel`?
    *   Does it rely on `TriggeredChannel` pointers remaining stable during the `poll` call?

### 3. Analyze Windows Poller (The "Stateful/Async" Model)
*   **Goal:** Determine how the current Windows implementation attempts to map persistent Reactor state to the asynchronous `AFD_POLL`/IOCP model.
*   **Key Questions:**
    *   What state is stored in `windows/Skt.zig`? (`is_pending`, `poll_info`, `io_status`, `base_handle`).
    *   How does `windows/poller.zig` manage the lifecycle of an `AFD_POLL` request?
    *   **Crucial Point:** If `TriggeredChannel`s are stored in an `AutoArrayHashMap` (growable), and `AFD_POLL` requires stable pointers for `ApcContext` or `IO_STATUS_BLOCK`, where is the mismatch?
    *   How does the poller handle the mismatch between the Reactor's "readiness" expectation and IOCP's "completion" model?

### 4. Cross-Platform Abstraction Analysis
*   **Goal:** Identify where the abstraction leaks.
*   **Key Questions:**
    *   The code outside `os/` is supposed to be OS-independent. However, `TriggeredSkt` unions different `Skt` types.
    *   How does the size/alignment difference of `Skt` (Linux vs Windows) affect the `TriggeredChannel` layout?

## Output
A document `os/windows/analysis/doc-reactor-poller-negotiation.md` covering:
1.  **Reactor - Poller - Triggered Sockets negotiation on Linux.**
2.  **Reactor - Poller - Triggered Sockets negotiation on Windows.**
3.  **Analysis of State Storage:** Inside `Skt` vs. inside `Poller` struct.
4.  **Impact of Growable Maps:** Pointer stability analysis.
5.  **Conclusion on Abstraction:** How the OS-specific `Skt` fits into the generic design.
