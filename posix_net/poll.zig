// src/ampe/posix_net/poll.zig
//
// Wrappers for usockets (forked) event loop and polling.

const ffi = @import("ffi.zig");
const types = @import("types.zig");

/// Create a new event loop.
pub fn createLoop() ?*anyopaque {
    return ffi.us_create_loop(null, null, null, null, 0);
}

/// Free an event loop.
pub fn freeLoop(loop: *anyopaque) void {
    ffi.us_loop_free(loop);
}

/// Create a new poll handle.
pub fn createPoll(loop: *anyopaque, ext_size: usize) ?*anyopaque {
    return ffi.us_create_poll(loop, 0, @intCast(ext_size));
}

/// Free a poll handle.
pub fn freePoll(p: *anyopaque, loop: *anyopaque) void {
    ffi.us_poll_free(p, loop);
}

/// Initialize a poll handle with an fd and type.
pub fn initPoll(p: *anyopaque, fd: types.Fd, poll_type: i32) void {
    ffi.us_poll_init(p, fd, @intCast(poll_type));
}

/// Start polling for events.
pub fn startPoll(p: *anyopaque, loop: *anyopaque, events: i32) void {
    ffi.us_poll_start(p, loop, @intCast(events));
}

/// Change the events we are polling for.
pub fn changePoll(p: *anyopaque, loop: *anyopaque, events: i32) void {
    ffi.us_poll_change(p, loop, @intCast(events));
}

/// Stop polling.
pub fn stopPoll(p: *anyopaque, loop: *anyopaque) void {
    ffi.us_poll_stop(p, loop);
}

/// Get the extension memory of a poll handle.
pub fn pollExt(p: *anyopaque) *anyopaque {
    return ffi.us_poll_ext(p);
}

/// Run a single tick of the event loop. timeout_ms < 0 means wait indefinitely.
pub fn tick(loop: *anyopaque, timeout_ms: c_int) void {
    ffi.us_loop_run_tick(loop, timeout_ms);
}

/// Return the poll type (lower 2 bits: POLL_TYPE_SOCKET=0, POLL_TYPE_SOCKET_SHUT_DOWN=1,
/// POLL_TYPE_SEMI_SOCKET=2, POLL_TYPE_CALLBACK=3).
pub fn pollType(p: *anyopaque) c_int {
    return ffi.us_internal_poll_type(p) & 3;
}
