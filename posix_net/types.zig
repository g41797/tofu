//
// Core types and constants for the posix_net module.

const builtin = @import("builtin");

/// Platform-specific socket descriptor type.
pub const Fd = if (builtin.os.tag == .windows) usize else c_int;

/// Sentinel value for an unset or invalid socket descriptor.
pub const INVALID_FD: Fd = if (builtin.os.tag == .windows) @import("std").math.maxInt(usize) else -1;

/// Unix socket path size: sun_path field of sockaddr_un (Linux=108, macOS/BSD=104).
pub const UDS_PATH_SIZE: usize = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) 104 else 108;

/// Address families. AF_UNIX=1 and AF_INET=2 are identical everywhere.
/// AF_INET6 differs: Linux=10, macOS/BSD=30, Windows=23.
pub const AF_UNIX: c_int = 1;
pub const AF_INET: c_int = 2;
pub const AF_INET6: c_int = if (builtin.os.tag == .windows) 23 else if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) 30 else 10;

/// Socket types.
pub const SOCK_STREAM: c_int = 1;

/// Opaque address structure from bun-usockets.
pub const Addr = extern struct {
    mem: [128]u8, // sockaddr_storage size
    len: u32,     // socklen_t size
    ip: ?[*]u8,
    ip_length: c_int,
    port: c_int,
};

/// Module-specific error union.
pub const PnError = error{
    AllocationFailed,
    CommunicationFailed,
    InvalidAddress,
    PeerDisconnected,
    WouldBlock,
    UDSPathNotFound,
};

// POLL_TYPE constants from bun-usockets (internal/internal.h)
pub const POLL_TYPE_SOCKET: c_int = 0;
pub const POLL_TYPE_SOCKET_SHUT_DOWN: c_int = 1;

// LIBUS_SOCKET events — must match epoll_kqueue.h: EPOLLIN=1, EPOLLOUT=4. (WINDOWS/LINUX)
// But mac uses bsd kqueue - values are 1 & 2
pub const LIBUS_SOCKET_READABLE: c_int = 1;
pub const LIBUS_SOCKET_WRITABLE: c_int = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) 2 else 4;


