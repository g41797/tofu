# Reactor-over-IOCP Specification: Questions & Clarifications

**Document:** reactor-over-iocp-prompt-005.md
**Date:** 2026-02-12
**Purpose:** Gather input to improve and finalize the specification

---

## Instructions

For each question, add your answer below the `**Answer:**` line.
Use `N/A` or `Skip` if a question doesn't apply.
Feel free to add additional context or new questions at the end.

---

## Section 1: Scope & Intent

### Q1.1: What is the intended use case?

- [ ] General-purpose reusable library
- [ ] Specific application's networking layer
- [ ] Educational/reference implementation
- [+] Other

**Answer:** my zig based [tofu](https://github.com/g41797/tofu) messaging implemented as Reactor.
But runs only on Linux. Intent - add Windows 10+ implementation. Development invironment already created.


---

### Q1.2: Is this your specification that you're refining, or reviewing someone else's work?

**Answer:**

My work
Above see url to repo.
local repo - /home/g41797/dev/root/github.com/g41797/tofu/

---

### Q1.3: What is the next step after the document is finalized?

- [ ] Implementation on Windows
- [ ] Further technical review
- [ ] Share with team/community
- [ ] Other

**Answer:**
- First of all re-factoring current tofu implementation in order to prepare it to convinient adding
windows implementation - analyze linux "hard coded" functionality and so on. It will need additional plan, not related to IPCP per se.

- Think about stages of the development, feasibility, testing - THINKING HOW TO CONTINUE

---

## Section 2: Technical Scope

### Q2.1: Target connection scale?

This affects data structure choices (HashMap vs slot allocator, buffer sizes).

- [+] Small (< 100 connections)
- [+] Medium (100 - 1,000 connections)
- [ ] Large (1,000 - 10,000 connections)
- [ ] Very large (10,000+ connections)

**Answer:** tofu has restriction - no more 128KiB message. Also it has message pool for limitation of used memory.


---

### Q2.2: Is UDP support in scope?

AFD_POLL works for UDP sockets too. Currently the spec is TCP-only.

- [ ] TCP only (current)
- [ ] TCP + UDP
- [+] TCP + Unix sockets (AF_UNIX on Windows 10+)

**Answer:**


---

### Q2.3: Is timer functionality required?

Many applications need scheduled callbacks (timeouts, keepalives, retries).

- [ ] Yes, timers are essential
- [ ] Nice to have, but not required for initial version
- [ ] No, out of scope

**If yes, preferred approach:**
- [ ] Timer wheel
- [+] IOCP timeout parameter
- [ ] NtSetTimer integration
- [ ] No preference / leave to implementation

**Answer:**


---

### Q2.4: Windows version floor?

Spec says Windows 10+. Some NT APIs (Wait Completion Packets) are Windows 8+.

- [+] Windows 10+ only (current)
- [ ] Windows 8+ (includes Server 2012)
- [ ] Need graceful degradation for older versions

**Answer:**


---

### Q2.5: Zig async integration?

Should this integrate with Zig's async/await model or be standalone?

- [+] Standalone (callback-based, as currently specified)
- [ ] Integrate with Zig async
- [ ] Support both modes
- [ ] No opinion

**Answer:**


---

## Section 3: Technical Details

### Q3.1: Memory ownership for AFD_POLL_INFO

The struct must remain valid until operation completes. Preferred strategy:

- [ ] Embed in SocketState struct
- [ ] Separate memory pool
- [ ] Arena allocator per poll cycle
- [+] Leave to implementation

**Answer:** Decide during further thinking


---

### Q3.2: Completion key design

How to identify which socket a completion belongs to:

- [ ] Pointer to SocketState (requires stable addresses)
- [ ] Socket handle as key + lookup table
- [ ] Slot index into socket array
- [ ] Leave to implementation

**Answer:** Decide during further thinking 


---

### Q3.3: SIO_BASE_HANDLE failure handling

Some LSPs don't support this. What should happen?

- [ ] Fail registration with error
- [ ] Fall back to original handle (may not work)
- [ ] Document as unsupported configuration
- [ ] Other

**Answer:** Clarify - provide examples of LSPs


---

### Q3.4: Re-arm timing

When to re-issue AFD_POLL after an event:

- [ ] Before invoking callback (ensures no missed events)
- [ ] After callback returns (simpler, callback can modify interest)
- [ ] Configurable per-socket
- [ ] Leave to implementation

**Answer:** tufu io uses only one thread, every information for caller pushed to queue.
No callbacks at all


---

### Q3.5: Performance targets

Any specific goals to validate against?

- Latency target (e.g., < 1ms event-to-callback):
- Throughput target (e.g., > 100k events/sec):
- Memory budget per connection:

**Answer:** No clue - try to do our best


---

## Section 4: Documentation & Deliverables

### Q4.1: Should the spec include build.zig example?

- [ ] Yes, include project structure and build.zig
- [ ] No, leave to implementer

**Answer:** Will be part of plan for preparing for windows implementation. I'd like stress the fact that project already exists (just for linux only - think implifications)


---

### Q4.2: Logging/debugging infrastructure

- [ ] Include structured logging design
- [ ] Include debug/trace mode specification
- [+] Leave to implementation
- [ ] Not needed

**Answer:**


---

### Q4.3: Test harness details

Current spec describes per-stage tests. Should it include:

- [ ] Integration test framework design
- [ ] Fuzz testing for race conditions
- [ ] Load testing methodology
- [ ] Benchmark suite specification
- [ ] Current level of detail is sufficient

**Answer:** Should be desided during plan negotiations


---

## Section 5: Reference Fixes (from addendum)

### Q5.1: Zig Issue #31131 reference is broken

The URL `https://codeberg.org/ziglang/zig/issues/31131` appears invalid.

Proposed fix — replace with:
- `https://ziglang.org/devlog/2026/` (NT-first philosophy)
- `https://github.com/ziglang/zig/issues/1840` (related policy)

- [+] Accept proposed fix
- [ ] Use different reference
- [ ] Remove this reference entirely

**Answer:**


---

### Q5.2: Add libevent wepoll.c as additional reference?

URL: `https://github.com/libevent/libevent/blob/master/wepoll.c`

Another production implementation that validates the AFD_POLL approach.

- [+] Yes, add it
- [ ] No, current references are sufficient

**Answer:**


---

## Section 6: Additional Information

### Q6.1: Any additional context, constraints, or requirements?

**Answer:**


---

### Q6.2: Any sections of the spec you're uncertain about or want deeper analysis?

**Answer:**


---

### Q6.3: Your additional questions or notes

**Answer:**


---

## End of Questions

When complete, save this file and confirm to resume the planning session.
