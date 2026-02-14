# Windows Port: Consolidated Questions

This document tracks all unanswered technical and architectural questions for the tofu Windows port.

---

## 1. Phase I: Feasibility & POC (Current)

### Q1.1: Stage 3 Stress Parameters
For the Stage 3 Stress POC, how many concurrent connections should be tested to satisfy the feasibility requirement? Is the current target of 20 enough, or should we aim for a higher number (e.g., 100+)?

### Q1.2: NtCancelIoFile Reliability
During the Stage 3 POC, `NtCancelIoFileEx` returned `.NOT_FOUND`, while the base `NtCancelIoFile` worked but often returned `SUCCESS` immediately (meaning the operation completed before cancellation). 
- Should we continue investigating the `Ex` version's failure, or is the base `NtCancelIoFile` sufficient for our Reactor's needs?

### Q1.3: LSP Compatibility Examples
Can you provide examples of specific Layered Service Providers (LSPs) or environment configurations where `SIO_BASE_HANDLE` is known to fail? This will help in documenting unsupported environments.

---

## 2. Phase II: Structural Refactoring (Upcoming)

### Q2.1: Memory Management for Channels
In the production Reactor, should we use a pre-allocated pool of `Channel` structures (similar to the message pool) to avoid runtime allocations during the I/O loop?

### Q2.2: AF_UNIX Path Handling
Since Windows AF_UNIX requires a valid filesystem path (no abstract namespace), do you have a preferred directory for temporary socket files on Windows (e.g., `%TEMP%`)?

### Q2.3: Integration with `std.net`
To what extent should the Windows backend rely on `std.net` versus raw `ws2_32` calls? Our current strategy is "Standard Library First," but many Reactor-specific optimizations (like `SIO_BASE_HANDLE`) require raw WinSock.

---

## 3. General Project Coordination

### Q3.1: Minimum Functionality for MVP
What constitutes the absolute minimum "Working on Windows" milestone? 
- [ ] Reactor starts/stops
- [ ] Single TCP echo
- [ ] Multiple concurrent connections
- [+] Full parity with Linux test suite

---
*Last Updated: 2026-02-13*
