# Investigation Plan: Reactor, Poller, and Triggered Sockets Negotiation (COMPLETE)

## Objective
**STATUS: SUCCESS.** Root cause of random panics identified as pointer instability in `AutoArrayHashMap` conflicting with stateful `AFD_POLL`.

## Approved Implementation Strategy
1.  **Remove Stateful Fields from `Skt`:** `io_status` and `poll_info` move to the `Poller`.
2.  **Stable Pool in `Poller`:** The `Poller` will manage a stable storage (pinned) for `IO_STATUS_BLOCK` and `AFD_POLL_INFO` objects.
3.  **Indirection:** `ApcContext` will pass the `ChannelNumber` (ID) instead of a pointer.
4.  **Safe Completion:** Completions will look up the current `TriggeredChannel` address in the Reactor's map using the returned ID.

## Documentation
- See `os/windows/analysis/doc-reactor-poller-negotiation.md` for full details.

## Next Phase
Implementation of the Stable Poller Pool and Indirection logic.
