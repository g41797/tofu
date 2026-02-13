// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

//! This file contains extended, manually-defined bindings for ntdll.dll functions
//! and structures that are not yet available in the Zig standard library.
//! These declarations follow the style of Zig's standard library ntdll.zig.

const std = @import("std");
const windows = std.os.windows;

pub const NTSTATUS = windows.NTSTATUS;
pub const HANDLE = windows.HANDLE;
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const PVOID = ?*anyopaque; // Often used for opaque pointers or optional void*

/// Structure for NtCreateIoCompletion
pub const OBJECT_ATTRIBUTES = extern struct {
    Length: ULONG,
    RootDirectory: HANDLE,
    ObjectName: ?*windows.UNICODE_STRING,
    Attributes: ULONG,
    SecurityDescriptor: PVOID,
    SecurityQualityOfService: PVOID,
};

/// FILE_COMPLETION_INFORMATION structure as used by NtRemoveIoCompletionEx
pub const FILE_COMPLETION_INFORMATION = extern struct {
    Key: PVOID, // Matches CompletionKey from NtSetIoCompletion
    ApcContext: PVOID, // Matches ApcContext from NtSetIoCompletion
    IoStatus: windows.IO_STATUS_BLOCK,
};

// Keeping this alias for now, as stage0_wake.zig uses FILE_COMPLETION_INFORMATION_EX
pub const FILE_COMPLETION_INFORMATION_EX = FILE_COMPLETION_INFORMATION;


pub extern "ntdll" fn NtCreateIoCompletion(
    IoCompletionHandle: *HANDLE,
    DesiredAccess: ACCESS_MASK,
    ObjectAttributes: ?*OBJECT_ATTRIBUTES,
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
