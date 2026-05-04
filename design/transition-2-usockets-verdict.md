# Verdict: transition-2-usockets.md Analysis

**Date:** 2026-05-04
**Reviewer:** Claude Sonnet 4.6
**Source verified against:**
- `/home/g41797/dev/root/github.com/uNetworking/uSockets/` (upstream)
- `/home/g41797/dev/root/github.com/g41797/tofu/vendor/bun-usockets/` (bun fork)

---

## Overall Assessment

The document is well-structured and architecturally sound at a high level.
Most claims about tofu's own design (PollerCore, Notifier, Triggers, Reactor model) are accurate and consistent with the current codebase.

However, several concrete API claims are incorrect or misleading when checked against actual source code.
The verdict in §14 understates bun-usockets' practical advantages.

---

## Issue 1 — Key APIs Are Not in Public Headers (Both Versions)

The document treats several functions as straightforwardly available when they are in **internal headers only**.

| Function | Where documented | Actual location |
| :--- | :--- | :--- |
| `POLL_TYPE_CALLBACK` | §5.2, §11.4 | `src/internal/internal.h` (both) |
| `us_internal_dispatch_ready_poll` | §11.1 | `src/internal/internal.h` (upstream) |
| `bsd_recv` / `bsd_send` | §6, §7, §11.2 | `src/internal/networking/bsd.h` (bun) |
| `bsd_create_listen_socket` | §11.3 | `src/internal/networking/bsd.h` (bun) |
| `bsd_create_connect_socket` | §11.3 | `src/internal/networking/bsd.h` (bun) |
| `bsd_accept_socket` | §11.3 | `src/internal/networking/bsd.h` (bun) |

**Impact:** The approach depends on including internal headers. This is workable — tofu vendors the full source, so it has access. But the document does not acknowledge this. Any future contributor (human or AI) will be surprised when `#include <libusockets.h>` does not expose these symbols.

**Recommendation:** Document explicitly that tofu will include `src/internal/internal.h` and `src/internal/networking/bsd.h` from the vendored source.

---

## Issue 2 — `us_loop_run_bun_tick` Is Not in `libusockets.h`

The document (§5.1) calls this the primary advantage of bun-usockets over upstream.
The function exists in `src/eventing/epoll_kqueue.c` (defined at line 349, forward-declared at line 35) but is **absent from `libusockets.h`**.

- It is an exported (non-static) symbol — linkable if you forward-declare it.
- But it is not an official public API.

**Impact:** The framing "native Tick Support" in §14.1 is slightly misleading. Both approaches require going beyond the public header.

---

## Issue 3 — `us_socket_local_address` Is Bun-Only (Critical for `getPort`)

Section 2.3 states `us_socket_local_address` is the uSockets analog for `getsockname` and is used for `getPort()`.

Verified:
- **bun-usockets:** `us_socket_local_address` is in `libusockets.h` at line 536. ✅
- **upstream uSockets:** `us_socket_local_address` is **absent** from `libusockets.h`. ❌

If tofu switches to upstream uSockets, `Skt.getPort()` has no direct equivalent in the public API.
The implementation would need raw `getsockname` (reintroducing posix) or access to internal socket structures.

**This is the strongest concrete argument against upstream uSockets that the document does not surface.**

---

## Issue 4 — Accept Mapping Is Inconsistent

Section 7.1 maps `posix.accept` → `on_open callback registered with us_socket_group`.
Section 9.2 repeats: "Marks readiness; Tofu accepts manually if needed."

But Section 6 says tofu will **not** use `us_socket_t` and will use `POLL_TYPE_CALLBACK` instead.
With `POLL_TYPE_CALLBACK`, there is no `on_open` callback — only a raw readability event on the listening socket's FD.

The correct mapping for tofu's actual approach:

| posix call | Tofu's uSockets approach |
| :--- | :--- |
| `posix.accept` / `accept4` | `bsd_accept_socket(us_poll_fd(p), &addr)` called manually when readable event fires on listener poll |

The bun-usockets `loop.c:394` confirms this: `bsd_accept_socket` is called inside the dispatch loop when a listener `us_poll_t` gets a readable event.

**Impact:** The tables in §7 and §9 mix the high-level socket model (us_socket_context / on_open) with the low-level poll model (POLL_TYPE_CALLBACK). These are mutually exclusive paths. The tables should reflect only the path tofu will actually take.

---

## Issue 5 — Template Approach (§12.2) Is Architecturally Confused

The document says: "Implementation begins in the `usockets/` folder using a generic approach. Verified logic is then 'ported' to `linux/`, `windows/`, and `mac/`."

This is backwards. The `usockets/` folder IS the uSockets backend. The `linux/`, `windows/`, `mac/` folders are the POSIX backend — they remain unchanged for `-Dnetwork=posix` builds.

There is nothing to "port" from usockets/ to the posix folders. The correct workflow is:

1. Implement `src/ampe/usockets/` fully.
2. Wire it into `internal.zig` and `poller.zig` under `-Dnetwork=usockets`.
3. Verify with contract tests (`sockets_tests.zig`, `Notifier_tests.zig`).
4. The posix folders stay intact for posix builds.

The confusion likely stems from the "Forced Epoll" Windows strategy — which requires platform-specific glue inside usockets/, not inside the posix `windows/` folder.

---

## Issue 6 — eventfd Shim Reasoning Is Incomplete (§13.2)

The document states `sys/eventfd.h` is needed to emulate `eventfd` for `us_wakeup_loop`, then notes tofu retains its socket-pair Notifier.

But `us_wakeup_loop` is irrelevant because tofu will not call it.

**However, the shim IS still needed** — uSockets internally creates an `eventfd` file descriptor when creating the epoll loop (bun-usockets `epoll_kqueue.c:710`). Even if tofu never calls `us_wakeup_loop`, the loop initialization will call `eventfd()` internally.

Similarly, `timerfd` is created internally at loop init time (`epoll_kqueue.c:594`).

**Conclusion:** Both shims are required, but for different reasons than stated. The document's logic is wrong; the conclusion is correct.

---

## Issue 7 — §14 Verdict Understates bun-usockets' Advantages

The document recommends upstream uSockets for "long-term health." This is defensible as a strategic preference, but the practical tradeoffs are not balanced.

**Factors favoring bun-usockets:**

1. `us_socket_local_address` is **public** in bun-usockets (`libusockets.h:536`). Essential for `Skt.getPort()`.
   Upstream uSockets has no public equivalent — workaround reintroduces posix or requires internal struct access.

2. `us_loop_run_bun_tick` exists in `epoll_kqueue.c` and is an exported symbol — linkable with a forward declaration.
   The upstream alternative (`us_internal_dispatch_ready_poll` + manual `epoll_wait`) is more complex and uses an explicitly internal API.

3. bun-usockets is already vendored at `vendor/bun-usockets/`. Upstream would require a new vendor path, build.zig changes, and full re-verification.

4. bun-usockets is battle-tested on Windows with forced epoll via wepoll — the Bun team has already solved the Windows edge cases that upstream delegates to libuv.

5. The API surface tofu uses (poll primitives, loop creation) is the stable low-level core — drift risk from Bun's maintenance cycle is low.

**Factors favoring upstream that hold up:**

1. Long-term independence from Bun's maintenance cycle.
2. Architectural purity: no external runtime dependency.

**Both choices require including internal headers.** Since tofu vendors the full source, this is not a real distinction — it is a documentation concern, not an implementation barrier.

---

## Final Verdict: bun-usockets

**bun-usockets is the recommended implementation for all platforms including Windows.**

- `getPort()` works via the public `us_socket_local_address`.
- The tick model (`us_loop_run_bun_tick`) matches tofu's Reactor exactly.
- Windows forced-epoll is already proven by the Bun team.
- Zero additional vendor setup — already at `vendor/bun-usockets/`.

Upstream uSockets should be revisited only if Bun's fork diverges in ways that break tofu's poll primitives, or if tofu needs to track official uSockets releases for external reasons.

---

## Summary Table

| Claim | Status | Notes |
| :--- | :--- | :--- |
| PollerCore, ABA protection, pointer stability | ✅ Accurate | Matches AGENT_STATE.md |
| Notifier retained as socket-pair | ✅ Accurate | Already implemented |
| `POLL_TYPE_CALLBACK` hook-back pattern | ✅ Correct pattern, ⚠️ internal header | Works; include `internal/internal.h` |
| `us_loop_run_bun_tick` as public bun API | ⚠️ Not in libusockets.h | Exported symbol; forward-declare to call |
| `us_internal_dispatch_ready_poll` for upstream tick | ⚠️ Internal API | Requires `internal/internal.h`; upstream only |
| `bsd_recv` / `bsd_send` as direct mapping | ✅ Correct, ⚠️ internal header | Include `internal/networking/bsd.h` |
| `us_socket_local_address` for `getPort` | ✅ bun public, ❌ upstream missing | Decisive factor for bun-usockets |
| `posix.accept` → `on_open callback` | ❌ Wrong for POLL_TYPE_CALLBACK path | Use `bsd_accept_socket(us_poll_fd(p), &addr)` |
| Template approach (usockets/ → linux/ etc.) | ❌ Architecturally backwards | usockets/ IS the backend, not a template |
| eventfd shim needed for Notifier wakeup | ❌ Wrong reason, ✅ correct conclusion | Shim needed for loop init, not Notifier |
| Upstream uSockets is the recommended path | ❌ Overturned | **bun-usockets is the recommended implementation** |
