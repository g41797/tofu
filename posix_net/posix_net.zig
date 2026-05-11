// Module root and facade for the posix_net module.
// This module provides a safe Zig interface over bun-usockets C functions.

// Types
pub const Fd = types.Fd;
pub const INVALID_FD = types.INVALID_FD;
pub const Addr = types.Addr;
pub const PnError = types.PnError;
pub const POLL_TYPE_SOCKET = types.POLL_TYPE_SOCKET;
pub const POLL_TYPE_SOCKET_SHUT_DOWN = types.POLL_TYPE_SOCKET_SHUT_DOWN;
pub const LIBUS_SOCKET_READABLE = types.LIBUS_SOCKET_READABLE;
pub const LIBUS_SOCKET_WRITABLE = types.LIBUS_SOCKET_WRITABLE;
pub const UDS_PATH_SIZE = types.UDS_PATH_SIZE;
pub const AF_UNIX = types.AF_UNIX;
pub const AF_INET = types.AF_INET;
pub const AF_INET6 = types.AF_INET6;
pub const SOCK_STREAM = types.SOCK_STREAM;

// Socket operations
pub const sendBuf = socket.sendBuf;
pub const recvToBuf = socket.recvToBuf;
pub const acceptSocket = socket.acceptSocket;
pub const closeSocket = socket.closeSocket;
pub const shutdownSocket = socket.shutdownSocket;
pub const shutdownSocketRead = socket.shutdownSocketRead;
pub const connectSocketUnix = socket.connectSocketUnix;
pub const nodelay = socket.nodelay;
pub const keepalive = socket.keepalive;
pub const wouldBlock = socket.wouldBlock;
pub const localAddr = socket.localAddr;
pub const remoteAddr = socket.remoteAddr;
pub const addrFamily = socket.addrFamily;
pub const addrPort = socket.addrPort;
pub const addrUnixPath = socket.addrUnixPath;
pub const deleteUnixPath = socket.deleteUnixPath;

// Socket creation and resolution
pub const createSocket = creator.createSocket;
pub const createListenSocket = creator.createListenSocket;
pub const createListenSocketUnix = creator.createListenSocketUnix;
pub const createConnectSocket = creator.createConnectSocket;
pub const createConnectSocketUnix = creator.createConnectSocketUnix;
pub const findFreeTcpPort = creator.findFreeTcpPort;
pub const resolveConnect = creator.resolveConnect;

// Event loop and polling
pub const poll = @import("poll.zig");

const types = @import("types.zig");
const socket = @import("socket.zig");
const creator = @import("creator.zig");
