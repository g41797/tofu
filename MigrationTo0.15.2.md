# Migration from Zig 0.14.1 to Zig 0.15.2

## Overview

This document describes all changes made to migrate the tofu project from Zig 0.14.1 to Zig 0.15.2.

## Date

2025-12-21

## Dependencies Updated

All dependencies were updated using `zig fetch --save`:

| Dependency | Old Commit | New Commit |
|------------|------------|------------|
| mailbox | 5e2a00e7af3d27be9f40dc03aeca204bb8973fce | 09ce9a443d17a36df47925e8927252fcde3c6940 |
| nats | 5028b8772a15b84a9c7ff959db93ac74ac2c754b | b4655d4154457b8f4af31a34f93ef4445da66fd3 |
| temp | 382a711f253d54a88f222650e6c03b62411373c6 | cf2317e06d32f3f0abdfc743c7a5950d9fdb2d19 |
| datetime | (unchanged) | 3a39a21e6e34dcb0ade0ff828d0914d40ba535f3 |

## Files Modified

### build.zig.zon

- Changed `minimum_zig_version` from `"0.14.0"` to `"0.15.0"`
- Updated all dependency URLs and hashes

### build.zig

Major API changes:

1. **Explicit pointer dereferencing**: All `b.method()` calls changed to `b.*.method()`

2. **Library creation**: `addStaticLibrary()` replaced with `addLibrary()`:
   ```zig
   // Old (0.14)
   const lib = b.addStaticLibrary(.{
       .name = "tofu",
       .root_source_file = b.path("src/ampe.zig"),
       .target = target,
       .optimize = optimize,
   });

   // New (0.15)
   const libMod = b.*.createModule(.{
       .root_source_file = b.*.path("src/ampe.zig"),
       .target = target,
       .optimize = optimize,
   });
   const lib = b.*.addLibrary(.{
       .linkage = .static,
       .name = "tofu",
       .root_module = libMod,
   });
   ```

3. **Module creation**: `addModule()` replaced with `createModule()` for internal modules

4. **Test configuration**:
   - Removed `.error_tracing = true` (no longer supported in TestOptions)
   - Changed to use `.root_module` instead of `.root_source_file`

### recipes/cookbook.zig

- Replaced `std.time.sleep` with `std.Thread.sleep` (5 occurrences at lines 1341, 1677, 1910, 1914, 1918)

### src/ampe/Reactor.zig

1. **ArrayList.deinit()** now requires allocator argument:
   ```zig
   // Old
   rtr.allChnN.deinit();

   // New
   rtr.allChnN.deinit(rtr.allocator);
   ```

2. **ArrayList.resize()** now requires allocator argument:
   ```zig
   // Old
   chns.resize(0)

   // New
   chns.resize(rtr.allocator, 0)
   ```

3. **ArrayList.append()** now requires allocator argument:
   ```zig
   // Old
   chns.append(item)

   // New
   chns.append(rtr.allocator, item)
   ```

4. Replaced `std.time.sleep` with `std.Thread.sleep`

### src/ampe/channels.zig

1. **ArrayList initialization**: `.init(allocator)` replaced with `.empty`:
   ```zig
   // Old
   var chns = std.ArrayList(ChannelNumber).init(cns.allocator);

   // New
   var chns: std.ArrayList(ChannelNumber) = .empty;
   ```

2. **ArrayList.deinit()** and **ArrayList.append()** now require allocator argument

### src/ampe/poller.zig

1. **ArrayList.deinit()** requires allocator:
   ```zig
   // Old
   pl.pollfdVtor.deinit();

   // New (with constCast for const self)
   var mutablePl: *Poll = @constCast(pl);
   mutablePl.pollfdVtor.deinit(mutablePl.allocator);
   ```

2. **ArrayList.append()** requires allocator:
   ```zig
   // Old
   pl.pollfdVtor.append(.{ .fd = tc.getSocket(), .events = events, .revents = 0 })

   // New
   pl.pollfdVtor.append(pl.allocator, .{ .fd = tc.getSocket(), .events = events, .revents = 0 })
   ```

### src/ampe/triggeredSkts.zig

Fixed default struct initialization to use safe values instead of `undefined`:

1. **IoSkt struct**:
   ```zig
   // Old
   skt: Skt = undefined,
   connected: bool = undefined,
   sendQ: MessageQueue = undefined,
   currSend: MsgSender = undefined,
   byeWasSend: bool = undefined,
   currRecv: MsgReceiver = undefined,
   byeResponseReceived: bool = undefined,

   // New
   skt: Skt = .{},
   connected: bool = false,
   sendQ: MessageQueue = .{},
   currSend: MsgSender = .{},
   byeWasSend: bool = false,
   currRecv: MsgReceiver = .{},
   byeResponseReceived: bool = false,
   ```

2. **MsgSender struct**:
   ```zig
   // Old
   ready: bool = undefined,
   msg: ?*Message = undefined,
   vind: usize = undefined,
   sndlen: usize = undefined,
   iovPrepared: bool = undefined,

   // New
   ready: bool = false,
   msg: ?*Message = null,
   vind: usize = 3,
   sndlen: usize = 0,
   iovPrepared: bool = false,
   ```

3. **MsgReceiver struct**:
   ```zig
   // Old
   ready: bool = undefined,
   ptrg: Trigger = undefined,
   vind: usize = undefined,
   rcvlen: usize = undefined,
   msg: ?*Message = undefined,

   // New
   ready: bool = false,
   ptrg: Trigger = .off,
   vind: usize = 3,
   rcvlen: usize = 0,
   msg: ?*Message = null,
   ```

### testRunner.zig

1. **std.zig.Server initialization** changed:
   ```zig
   // Old
   var server = try std.zig.Server.init(.{
       .gpa = fba.allocator(),
       .in = std.io.getStdIn(),
       .out = std.io.getStdOut(),
       .zig_version = builtin.zig_version_string,
   });
   defer server.deinit();

   // New
   var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
   var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
   var server = try std.zig.Server.init(.{
       .in = &stdin_reader.interface,
       .out = &stdout_writer.interface,
       .zig_version = builtin.zig_version_string,
   });
   // Note: server.deinit() removed - no longer exists
   ```

2. Added buffer variables for streaming I/O:
   ```zig
   var stdin_buffer: [4096]u8 = undefined;
   var stdout_buffer: [4096]u8 = undefined;
   ```

3. **std.io.getStdErr()** replaced with **std.fs.File.stderr()**

## Key Zig 0.15.2 Breaking Changes Summary

| Change | Old API | New API |
|--------|---------|---------|
| ArrayList init | `.init(allocator)` | `.empty` |
| ArrayList deinit | `.deinit()` | `.deinit(allocator)` |
| ArrayList append | `.append(item)` | `.append(allocator, item)` |
| ArrayList resize | `.resize(len)` | `.resize(allocator, len)` |
| Sleep | `std.time.sleep()` | `std.Thread.sleep()` |
| Stderr | `std.io.getStdErr()` | `std.fs.File.stderr()` |
| Build addStaticLibrary | `b.addStaticLibrary()` | `b.*.addLibrary(.{.linkage = .static})` |
| Build addModule | `b.addModule()` | `b.*.createModule()` |

## Verification

- All 35 unit tests pass
- Build completes successfully with `zig build`

## Sources

- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
- [Ziggit: ArrayList and allocator updating code to 0.15](https://ziggit.dev/t/arraylist-and-allocator-updating-code-to-0-15/12167)
- [Ziggit: How to convert addStaticLibrary to addLibrary](https://ziggit.dev/t/how-to-convert-addstaticlibrary-to-addlibrary/12753)
- [GitHub: Mailbox migrated to 0.15.2](https://ziggit.dev/t/mailbox-migrated-to-0-15-2/13590)
