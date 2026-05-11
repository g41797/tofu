#pragma once
// POSIX I/O compatibility for Windows builds.
// Included transitively by sys/epoll.h so all usockets C files see it.
#include <windows.h>
#include <winsock2.h>
#include <io.h>      // declares close (_close), read (_read), write (_write)

// close is declared by <io.h> as _close alias.
// At runtime _close on a WinSock socket returns EBADF silently; acceptable for tests.

// Missing POSIX errno constants on Windows
#ifndef ENAMETOOLONG
#define ENAMETOOLONG 38
#endif

#ifndef EAFNOSUPPORT
#define EAFNOSUPPORT 102
#endif

#ifndef EINPROGRESS
#define EINPROGRESS 115
#endif
