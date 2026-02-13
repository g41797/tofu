// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

//! This file contains extended, manually-defined bindings for ntdll.dll functions
//! and structures that are not yet available in the Zig standard library.
//! These declarations follow the style of Zig's standard library ntdll.zig.
//!
//! This file is intended to contain only truly missing definitions not found
//! in `std.os.windows.ntdll` or other `std.os.windows` modules.

const std = @import("std");
const windows = std.os.windows;

// Re-export common types from windows.zig for convenience
pub const NTSTATUS = windows.NTSTATUS;
pub const HANDLE = windows.HANDLE;
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const PVOID = ?*anyopaque; // Often used for opaque pointers or optional void*


/// FILE_COMPLETION_INFORMATION structure as used by NtRemoveIoCompletionEx
/// This structure is not directly in std.os.windows.ntdll.zig, although IO_COMPLETION_INFORMATION is.
/// This specific structure matches the format expected by NtRemoveIoCompletionEx for the returned completion information.
pub const FILE_COMPLETION_INFORMATION = extern struct {
    Key: PVOID, // Matches CompletionKey from NtSetIoCompletion
    ApcContext: PVOID, // Matches ApcContext from NtSetIoCompletion
    IoStatus: windows.IO_STATUS_BLOCK,
};

// Keeping this alias for now, as stage0_wake.zig uses FILE_COMPLETION_INFORMATION_EX
pub const FILE_COMPLETION_INFORMATION_EX = FILE_COMPLETION_INFORMATION;

// Core IOCP Native APIs (Nt*IoCompletion*) not in std.os.windows.ntdll.zig
pub extern "ntdll" fn NtCreateIoCompletion(
    IoCompletionHandle: *HANDLE,
    DesiredAccess: ACCESS_MASK,
    ObjectAttributes: ?*windows.OBJECT_ATTRIBUTES, // Use std lib's OBJECT_ATTRIBUTES
    NumberOfConcurrentThreads: ULONG,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtSetIoCompletion(
    IoCompletionHandle: HANDLE,
    CompletionKey: ULONG_PTR,
    ApcContext: PVOID,
    IoStatus: NTSTATUS, // The NTSTATUS here is the status code for the operation
    IoStatusInformation: ULONG_PTR,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtRemoveIoCompletionEx(
    IoCompletionHandle: HANDLE,
    CompletionInformation: [*]FILE_COMPLETION_INFORMATION,
    Count: ULONG,
    NumEntriesRemoved: *ULONG,
    Timeout: ?*LARGE_INTEGER,
    Alertable: windows.BOOLEAN,
) callconv(.winapi) NTSTATUS;

// AFD (Ancillary Function Driver for WinSock) definitions
// These are specific to AFD_POLL and not found in std.os.windows.ntdll.zig

// IOCTL for AFD_POLL
pub const IOCTL_AFD_POLL: ULONG = 0x00012024; // FSCTL_AFD_POLL

// AFD_POLL event flags
pub const AFD_POLL_RECEIVE: ULONG = 0x0001;
pub const AFD_POLL_RECEIVE_EXPEDITED: ULONG = 0x0002;
pub const AFD_POLL_SEND: ULONG = 0x0004;
pub const AFD_POLL_DISCONNECT: ULONG = 0x0008;
pub const AFD_POLL_ABORT: ULONG = 0x0010;
pub const AFD_POLL_LOCAL_CLOSE: ULONG = 0x0020;
pub const AFD_POLL_CONNECT: ULONG = 0x0040;
pub const AFD_POLL_ACCEPT: ULONG = 0x0080;
pub const AFD_POLL_CONNECT_FAIL: ULONG = 0x0100;

pub const AFD_POLL_HANDLE_INFO = extern struct {
    Handle: HANDLE,
    Events: ULONG,
    Status: NTSTATUS,
};

pub const AFD_POLL_INFO = extern struct {
    Timeout: LARGE_INTEGER,
    NumberOfHandles: ULONG,
    Exclusive: windows.BOOLEAN,
    Handles: [1]AFD_POLL_HANDLE_INFO,
};

// Kernel32 functions for Event and WaitForSingleObject
pub extern "kernel32" fn CreateEventA(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?[*:0]const u8,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: ULONG, // ULONG (u32) for milliseconds
) callconv(.winapi) ULONG;

// Constants for WaitForSingleObject return values
pub const WAIT_OBJECT_0: ULONG = 0x00000000;
pub const WAIT_ABANDONED: ULONG = 0x00000080;
pub const WAIT_TIMEOUT: ULONG = 0x00000102;
pub const WAIT_FAILED: ULONG = 0xFFFFFFFF;
pub const INFINITE: ULONG = 0xFFFFFFFF;