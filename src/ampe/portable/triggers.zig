//! Trigger mapping for the portable (uSockets) backend.
//! Converts between application-level Triggers and uSockets LIBUS_SOCKET_* event masks.

/// usockets-specific trigger mappings.
pub const usockets = struct {
    pub fn toEvents(exp: Triggers) c_int {
        var ev: c_int = 0;
        if (exp.recv == .on or exp.accept == .on or exp.notify == .on)
            ev |= pn.LIBUS_SOCKET_READABLE;
        if (exp.send == .on or exp.connect == .on)
            ev |= pn.LIBUS_SOCKET_WRITABLE;
        return ev;
    }

    pub fn fromEvents(events: c_int, err: c_int, exp: Triggers) Triggers {
        var act = Triggers{ .pool = exp.pool };
        if (err != 0) act.err = .on;
        if (events & pn.LIBUS_SOCKET_READABLE != 0) {
            if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
        }
        if (events & pn.LIBUS_SOCKET_WRITABLE != 0) {
            if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
        }
        return act;
    }
};

const pn = @import("posix_net");

const internal = @import("../internal.zig");
const Triggers = internal.triggeredSkts.Triggers;
