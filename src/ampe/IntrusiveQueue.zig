// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

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

        /// Adds a item to the end of the queue.
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

        /// Removes and returns the item at the front of the queue, or null if empty.
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

        /// Checks if the queue is empty.
        pub fn empty(fifo: *Self) bool {
            return (fifo.first == null);
        }

        /// Returns the number of items in the queue.
        pub fn count(fifo: *Self) usize {
            var ret: usize = 0;
            var next = fifo.first;
            while (next != null) : (ret += 1) {
                next = next.?.next;
            }
            return ret;
        }

        /// Moves all items from one queue to another.
        pub fn move(src: *Self, dest: *Self) void {
            var next = src.dequeue();
            while (next != null) {
                dest.enqueue(next.?);
                next = src.dequeue();
            }
        }
    };
}
