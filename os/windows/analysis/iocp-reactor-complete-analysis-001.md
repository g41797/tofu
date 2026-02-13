# IOCP Reactor Complete Architectural Analysis

Version: 001\
Target: Windows 10+ (IOCP)\
Context: tofu Windows Port

------------------------------------------------------------------------

# Executive Summary

This document provides a complete architectural analysis of the proposed
IOCP-based Reactor design for the tofu Windows port.

The design direction is fundamentally correct and aligns with
high-performance Windows networking architecture. However, correctness
depends on several mandatory IOCP invariants being respected.

IOCP is a completion-based model (Proactor), not a readiness-based model
(Reactor like epoll). Any attempt to treat it as epoll will introduce
correctness flaws.

------------------------------------------------------------------------

# 1. IOCP Architectural Model

IOCP (I/O Completion Ports):

-   Completion-based
-   Kernel-queued completion packets
-   Overlapped I/O only
-   Scalable to thousands of handles
-   Thread-pool friendly

Unlike epoll:

-   No readiness polling
-   No EWOULDBLOCK loops
-   No need for non-blocking mode

------------------------------------------------------------------------

# 2. Mandatory Correctness Requirements

A production-grade IOCP reactor MUST satisfy ALL of the following:

## 2.1 Socket Creation

Sockets must be created with:

    WSASocket(..., WSA_FLAG_OVERLAPPED)

Then associated with IOCP:

    CreateIoCompletionPort(socket, iocp, key, 0)

Missing either results in undefined behavior.

------------------------------------------------------------------------

## 2.2 AcceptEx Pattern

Correct pattern:

1.  Pre-allocate accept socket
2.  Pre-allocate address buffer
3.  Issue AcceptEx with OVERLAPPED
4.  On completion:
    -   Call setsockopt(SO_UPDATE_ACCEPT_CONTEXT)
    -   Associate new socket with IOCP
    -   Immediately repost AcceptEx

Failure to repost → accept starvation.

------------------------------------------------------------------------

## 2.3 Per-Operation OVERLAPPED Context

Each asynchronous operation must have its own structure:

    struct IoOp {
        OVERLAPPED overlapped;
        OperationType type;
        Connection* conn;
    };

Never reuse OVERLAPPED structures across different operations.

------------------------------------------------------------------------

## 2.4 Receive Handling

Rules:

-   Completion with bytes \> 0 → process data, repost WSARecv
-   Completion with bytes == 0 → peer closed connection
-   ERROR_IO_PENDING → normal async path

Never treat zero bytes as retry condition.

------------------------------------------------------------------------

## 2.5 Partial Send Handling

WSASend does NOT guarantee full buffer transmission.

Correct logic:

    if bytes_sent < requested:
        advance buffer
        repost WSASend

Failure to handle partial sends → data corruption.

------------------------------------------------------------------------

# 3. Threading Model

Correct IOCP usage:

-   One IOCP handle
-   N worker threads
-   All calling GetQueuedCompletionStatus
-   No per-socket threads
-   No blocking syscalls

Incorrect patterns:

-   One IOCP per thread
-   Mixing blocking send/recv
-   Per-connection mutexes

------------------------------------------------------------------------

# 4. Non-Blocking Mode Under IOCP

Important clarification:

For IOCP:

-   Non-blocking mode (ioctlsocket FIONBIO) is NOT required.
-   Blocking mode does not affect overlapped operations.
-   IOCP completion is independent of socket blocking state.

Linux epoll requires O_NONBLOCK.\
Windows IOCP does not.

These models are fundamentally different.

------------------------------------------------------------------------

# 5. Cross-Platform Reactor Comparison

  Feature                 Linux epoll       Windows IOCP
  ----------------------- ----------------- -------------------
  Model                   Readiness         Completion
  Must set non-blocking   Yes               No
  Loop until EAGAIN       Yes               No
  Must repost I/O         No                Yes
  Partial send handling   Loop write        Reissue WSASend
  Close detection         EPOLLHUP/0 read   0-byte completion

Attempting to unify internal logic across both models will introduce
subtle bugs.

------------------------------------------------------------------------

# 6. Common IOCP Bugs

1.  Posting only one AcceptEx
2.  Reusing OVERLAPPED
3.  Ignoring partial sends
4.  Not handling 0-byte receive as close
5.  Forgetting SO_UPDATE_ACCEPT_CONTEXT
6.  Calling recv/send instead of WSARecv/WSASend

------------------------------------------------------------------------

# 7. Performance Characteristics

Correct IOCP design provides:

-   O(1) wakeups
-   Kernel-managed lock-free completion queue
-   High scalability (100k+ connections possible)
-   Minimal context switches

Poor design patterns eliminate IOCP benefits.

------------------------------------------------------------------------

# 8. Reactor Compatibility with tofu

tofu uses queue-based API (not callbacks).

IOCP can be adapted by:

-   Translating completion packets into internal message queue pushes
-   Using IOCP as wake mechanism
-   Preserving single I/O thread model if desired

However:

Windows IOCP implementation must not mimic epoll semantics internally.

------------------------------------------------------------------------

# 9. Architectural Verdict

If implementation includes:

-   WSA_FLAG_OVERLAPPED
-   CreateIoCompletionPort
-   AcceptEx reposting
-   Per-operation OVERLAPPED structs
-   Partial send handling
-   Zero-byte close handling
-   Proper worker thread model

Then the architecture is:

✓ Correct\
✓ Production-grade\
✓ High-performance\
✓ Scalable\
✓ Compatible with cross-platform abstraction

If any are missing → correctness risk.

------------------------------------------------------------------------

End of Document
