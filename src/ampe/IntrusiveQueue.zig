// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Zero-allocation FIFO using intrusive linked lists.

/// In order to use IntrusiveQueue, T should look like
/// pub const T = struct {
///     prev: ?*T = null,
///     next: ?*T = null,
///     ....................................
///     }
/// };
pub fn IntrusiveQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        first: ?*T = null,
        last: ?*T = null,

        pub fn enqueue(fifo: *Self, msg: *T) void {
            msg.prev = null;
            msg.next = null;

            if (fifo.last) |last| {
                last.next = msg;
                msg.prev = last;
            } else {
                fifo.first = msg;
            }

            fifo.last = msg;

            return;
        }

        pub fn pushFront(fifo: *Self, msg: *T) void {
            msg.prev = null;
            msg.next = null;

            if (fifo.first) |first| {
                // The current first item's previous pointer must point to the new message.
                first.prev = msg;
                // The new message's next pointer must point to the current first item.
                msg.next = first;
            } else {
                // If the queue is empty, the new message is also the last item.
                fifo.last = msg;
            }

            // The new message is now the first item.
            fifo.first = msg;

            return;
        }

        pub fn dequeue(fifo: *Self) ?*T {
            if (fifo.first == null) {
                return null;
            }

            var result = fifo.first;
            fifo.first = result.?.next;

            if (fifo.first == null) {
                fifo.last = null;
            } else {
                fifo.first.?.prev = fifo.first;
            }

            result.?.prev = null;
            result.?.next = null;

            return result;
        }

        pub fn empty(fifo: *Self) bool {
            return (fifo.first == null);
        }

        pub fn count(fifo: *Self) usize {
            var ret: usize = 0;
            var next = fifo.first;
            while (next != null) : (ret += 1) {
                next = next.?.next;
            }
            return ret;
        }

        pub fn move(src: *Self, dest: *Self) void {
            var next = src.dequeue();
            while (next != null) {
                dest.enqueue(next.?);
                next = src.dequeue();
            }
        }
    };
}
