//
// Core types and constants for the posix_net module.

const builtin = @import("builtin");

/// Platform-specific socket descriptor type.
pub const Fd = if (builtin.os.tag == .windows) usize else c_int;

/// Unix socket path size: sun_path field of sockaddr_un (Linux=108, macOS/BSD=104).
pub const UDS_PATH_SIZE: usize = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) 104 else 108;

/// Address families (POSIX values; identical on Linux, macOS, Windows).
pub const AF_UNIX: c_int = 1;
pub const AF_INET: c_int = 2;
pub const AF_INET6: c_int = if (builtin.os.tag == .windows) 23 else 10;

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

// LIBUS_SOCKET events — must match epoll_kqueue.h: EPOLLIN=1, EPOLLOUT=4.
// (Not the ASIO/GCD header values of 1/2; those are for different backends.)
pub const LIBUS_SOCKET_READABLE: c_int = 1; // EPOLLIN on Linux, EVFILT_READ on macOS
pub const LIBUS_SOCKET_WRITABLE: c_int = 4; // EPOLLOUT on Linux, EVFILT_WRITE on macOS
