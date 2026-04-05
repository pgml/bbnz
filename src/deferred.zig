const std = @import("std");

const FnCtx = struct {
    func: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};

pub const Event = struct {
    /// Key for debouncing.
    key: ?[]const u8 = null,

    /// Timestamp in ms when this event should be executed.
    due: i64,

    /// Main callback.
    cb: FnCtx,

    /// Optional callback after `cb`.
    onAfterExecution: ?FnCtx = null,
};

pub const Queue = struct {
    alloc: std.mem.Allocator,

    /// Internal list of queued events.
    list: std.ArrayList(Event) = .empty,

    /// Tick rate in Hz.
    /// Used to calculate `tick_ms`
    framerate: u128 = 60,

    /// Milliseconds per tick.
    /// Derived from `framerate`.
    tick_ms: u128 = 0,

    /// Next scheduled execution time in ms.
    next_frame_ms: u128 = 0,

    pub fn init(alloc: std.mem.Allocator) Queue {
        var self: Queue = .{
            .alloc = alloc,
            .next_frame_ms = @intCast(std.time.milliTimestamp()),
        };

        self.tick_ms = @divFloor(std.time.ms_per_s, self.framerate);

        return self;
    }

    /// Collects and runs all deferred events at a specific time.
    /// This should be executed in a non-blocking environment.
    pub fn run(self: *Queue) !void {
        const now: u128 = @intCast(std.time.milliTimestamp());

        if (now >= self.next_frame_ms) {
            // Deadline exceeded. Schedule the next frame
            self.next_frame_ms = now + self.tick_ms;
        } else {
            // Sleep until the deadline
            std.Thread.sleep(
                @intCast((self.next_frame_ms - now) * std.time.ns_per_ms),
            );
            self.next_frame_ms += self.tick_ms;
        }

        var schedule_events: std.ArrayListUnmanaged(Event) = .empty;
        defer schedule_events.deinit(self.alloc);

        var i: usize = 0;
        while (i < self.len()) {
            const event = self.get(i) orelse continue;

            if (now >= event.due) {
                try schedule_events.append(self.alloc, event);
                _ = self.removeAt(i);
                continue;
            }

            i += 1;
        }

        for (schedule_events.items) |*event| {
            event.cb.func(event.cb.ctx);
            if (event.onAfterExecution) |hook| {
                hook.func(hook.ctx);
            }
        }
    }

    /// Extends the queue by 1 event.
    pub fn append(self: *Queue, event: Event) !void {
        var ev = event;
        ev.due += std.time.milliTimestamp();
        try self.list.append(self.alloc, ev);
    }

    /// Inserts or replaces an event in the queue.
    ///
    /// If an event with the same `key` already exists, it is overwritten.
    /// Otherwise, the event is appended.
    pub fn put(self: *Queue, event: Event) !void {
        for (self.list.items) |*existing| {
            const existing_key = existing.key orelse continue;
            const event_key = event.key orelse continue;

            if (std.mem.eql(u8, existing_key, event_key)) {
                var ev = event;
                ev.due += std.time.milliTimestamp();
                existing.* = ev;
                return;
            }
        }
        try self.append(event);
    }

    /// Returns the event at `index` or null.
    ///
    /// Asserts that the list is not empty.
    /// Asserts that the index is in bounds.
    pub fn get(self: Queue, index: usize) ?Event {
        if (index > self.len() or self.len() == 0) {
            return null;
        }
        return self.list.items[index];
    }

    /// Returns whether an event with `key` is in the queue.
    pub fn contains(self: Queue, key: []const u8) bool {
        for (self.list.items) |ev| {
            if (std.mem.eql(u8, ev.key, key)) {
                return true;
            }
        }
        return false;
    }

    pub fn removeAt(self: *Queue, index: usize) Event {
        return self.list.swapRemove(index);
    }

    pub fn remove(self: *Queue, key: []const u8) ?Event {
        for (self.list.items, 0..) |ev, i| {
            if (std.mem.eql(u8, ev.key, key)) {
                return self.list.swapRemove(i);
            }
        }
        return null;
    }

    pub fn len(self: Queue) usize {
        return self.list.items.len;
    }

    pub fn deinit(self: *Queue) void {
        // just to be sure.
        self.list.deinit(self.alloc);
    }
};
