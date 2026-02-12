# Reactor-over-IOCP: Follow-up Questions (Updated)

**Based on:** reactor-questions-001.md answers + tofu documentation
**Date:** 2026-02-12
**Purpose:** Clarify tofu-specific requirements for Windows port

---

## What I Learned from tofu Documentation

Before the questions, here's what I now understand:

### Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                      Application Thread(s)                       │
├─────────────────────────────────────────────────────────────────┤
│  ampe.get() ──► Message ──► chnls.post() ──► [Send Queue]       │
│                                                                  │
│  chnls.waitReceive() ◄── [Recv Queue] ◄── Messages              │
│                                                                  │
│  chnls.updateReceiver() ──► [Recv Queue]  (cross-thread wake)   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Reactor (I/O Thread)                          │
├─────────────────────────────────────────────────────────────────┤
│  Poll Loop: epoll_wait() ──► process events ──► socket I/O      │
│                                                                  │
│  Internal socket connects ChannelGroups to Reactor thread       │
└─────────────────────────────────────────────────────────────────┘
```

### Key Abstractions

| Component | Role | Platform-Specific? |
|-----------|------|-------------------|
| **Ampe** | Interface for engine | No (interface) |
| **Reactor** | Linux implementation | **Yes - needs Windows version** |
| **ChannelGroup** | Message queues + channels | Likely reusable |
| **Message** | Data container | Reusable |

### Windows Port Strategy (my understanding)

Create `WindowsReactor` implementing `Ampe` interface:
- Replace `epoll` poll loop with **IOCP + AFD_POLL**
- `updateReceiver()` maps to **NtSetIoCompletion** (IOCP posting)
- Same queue-based model, no changes to `waitReceive()` semantics
- Same Message pool mechanism

---

## Section 7: Architecture Clarifications

### Q7.1: Is my understanding of the architecture correct?

Based on docs, the Reactor:
1. Runs a single I/O thread with poll loop (epoll on Linux)
2. ChannelGroups communicate with Reactor via internal socket
3. `post()` sends to Reactor, `waitReceive()` receives from queue
4. `updateReceiver()` is cross-thread signaling (similar to IOCP posting)

**Is this accurate? Any corrections?**

**Answer:**


---

### Q7.2: What is the "internal socket" between ChannelGroup and Reactor?

Docs mention: "All ChannelGroups share one internal socket to talk to the engine thread."

- Is this a Unix domain socket pair (socketpair)?
- Or eventfd?
- Or something else?

This affects Windows port - need equivalent mechanism.

**Answer:**


---

### Q7.3: Where is the platform-specific code located?

Which files/modules contain Linux-specific code that needs Windows alternatives?

- `src/reactor.zig`?
- Specific subdirectories?
- epoll wrappers?

**Answer:**


---

### Q7.4: Is there already a platform abstraction layer?

Or is epoll used directly throughout?

**Answer:**


---

## Section 8: AF_UNIX on Windows (Refined)

### Q8.1: How does tofu use Unix sockets currently?

From docs, UDS is supported. Questions:

- Is it used for the internal ChannelGroup-to-Reactor communication?
- Just for external connections?
- Both?

**Answer:**


---

### Q8.2: Windows AF_UNIX limitations - impact assessment

Windows 10 AF_UNIX limitations:
- No `SCM_RIGHTS` (fd passing)
- No abstract namespace
- Path must be valid filesystem path

Does tofu use any of these features?

- [ ] Yes, uses fd passing (will need redesign)
- [ ] Yes, uses abstract namespace (will need redesign)
- [ ] No, just basic stream sockets (should work)
- [ ] Not sure

**Answer:**


---

### Q8.3: AF_UNIX priority for Windows port

- [ ] Required from day one
- [ ] Can defer to later phase (TCP first)
- [ ] Not needed on Windows

**Answer:**


---

## Section 9: Development & Testing

### Q9.1: Windows development environment

You mentioned "Development environment already created." Details:

- [ ] Native Windows machine
- [ ] Windows VM
- [ ] Remote Windows server
- [ ] Cross-compile from Linux
- [ ] Other

**Answer:**


---

### Q9.2: Current test approach in tofu

What testing exists for the Linux version?

- [ ] Unit tests (zig test)
- [ ] Integration tests
- [ ] Examples that serve as tests
- [ ] Manual testing
- [ ] CI/CD

**Answer:**


---

### Q9.3: Cross-platform testing strategy

How do you envision testing both Linux and Windows?

- [ ] Same test suite, conditional compilation
- [ ] Separate platform-specific tests
- [ ] Test on Linux, then port and test on Windows
- [ ] Not decided yet

**Answer:**


---

## Section 10: LSP Clarification (from Q3.3)

### Q10.1: LSP handling decision

**Context:** LSP (Layered Service Provider) is Windows middleware that can wrap socket handles. AFD operations need the real handle via `SIO_BASE_HANDLE`. Some LSPs don't support this properly.

**Common problematic software:**
- Older antivirus network filters
- Some VPN split-tunneling
- Legacy firewall products

Given this context, preferred handling:

- [ ] Fail loudly if `SIO_BASE_HANDLE` fails (clean error, document incompatibility)
- [ ] Try original handle as fallback (may work, may cause subtle bugs)
- [ ] Detect and warn, but attempt to proceed
- [ ] Other

**Answer:**


---

## Section 11: Spec Adaptation for tofu

### Q11.1: The spec's callback API vs tofu's queue model

The IOCP spec defines:
```zig
const ReadinessCallback = *const fn (socket, events, user_data) void;
```

But tofu's Reactor doesn't expose callbacks - it puts messages in queues that `waitReceive()` reads.

**Question:** The Windows Reactor implementation should:

- [ ] Match tofu's queue model exactly (no callbacks in API)
- [ ] Use callbacks internally but expose queue interface
- [ ] Doesn't matter - implementation detail

**Answer:**


---

### Q11.2: Command injection mapping

The spec defines cross-thread command posting via `NtSetIoCompletion`.

tofu already has `updateReceiver()` for cross-thread signaling.

**Question:** Are these equivalent concepts?

- [ ] Yes, `updateReceiver()` on Windows should use IOCP posting internally
- [ ] No, they serve different purposes
- [ ] Need to understand better

**Answer:**


---

### Q11.3: Which spec stages apply to tofu?

The spec has 7 stages. For tofu Windows port, which are relevant?

| Stage | Description | Relevant? |
|-------|-------------|-----------|
| 0 | Feasibility & API access | [ ] Yes [ ] No |
| 1 | Minimal IOCP event loop | [ ] Yes [ ] No |
| 2 | Cross-thread command injection | [ ] Yes [ ] No |
| 3 | Single-socket AFD_POLL | [ ] Yes [ ] No |
| 4 | Multi-socket management | [ ] Yes [ ] No |
| 5 | Non-blocking send/recv | [ ] Yes [ ] No |
| 6 | TCP Echo Server demo | [ ] Yes [ ] No |
| 7 | Alternatives validation | [ ] Yes [ ] No |

**Or should we define tofu-specific stages instead?**

**Answer:**


---

## Section 12: Priorities & Constraints

### Q12.1: MVP for Windows support

Minimum functionality for "it works on Windows":

- [ ] Reactor starts and stops cleanly
- [ ] Single TCP connection (client or server)
- [ ] Bidirectional message exchange
- [ ] Multiple connections
- [ ] Listener accepting connections
- [ ] Full parity with Linux Reactor
- [ ] Other (specify)

**Answer:**


---

### Q12.2: Approach preference

- [ ] **Bottom-up**: Build IOCP primitives first, then integrate into tofu
- [ ] **Top-down**: Start from tofu's Reactor interface, implement Windows underneath
- [ ] **Parallel**: Prototype IOCP separately while analyzing tofu code
- [ ] **Other**

**Answer:**


---

### Q12.3: Timeline/urgency

- [ ] Exploratory / learning, no deadline
- [ ] Want prototype in weeks
- [ ] Production requirement
- [ ] Other

**Answer:**


---

### Q12.4: Biggest concerns about Windows port

What worries you most?

- [ ] IOCP/AFD_POLL complexity
- [ ] Undocumented APIs stability
- [ ] Testing on Windows
- [ ] Maintaining two platform implementations
- [ ] Performance parity
- [ ] AF_UNIX support
- [ ] Other (specify)

**Answer:**


---

## Section 13: Reference Fixes (Confirmed)

### Q13.1: Zig Issue #31131

Accept proposed fix: Replace broken URL with:
- `https://ziglang.org/devlog/2026/`
- `https://github.com/ziglang/zig/issues/1840`

**Confirmed:** [+] Yes (from reactor-questions-001.md)

---

### Q13.2: Add libevent wepoll.c reference

URL: `https://github.com/libevent/libevent/blob/master/wepoll.c`

**Confirmed:** [+] Yes (from reactor-questions-001.md)

---

## Section 6: Additional Information

### Q6.1: Any additional context, constraints, or requirements?

**Answer:**


---

### Q6.2: Sections of the spec you want deeper analysis on?

Now that I understand tofu's architecture, any specific areas?

**Answer:**


---

### Q6.3: Your additional questions or notes

**Answer:**


---

## End of Questions

Save and confirm when ready to continue.
