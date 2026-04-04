// @todo, undo and redoing patches fills memory
const History = @This();
const std = @import("std");

const Dmp = @import("diffmatchpatch");

const Buffer = @import("Buffer.zig");
const CursorPos = Buffer.CursorPos;

const HistoryError = error{
    EntryNotFound,
    NoUndoEntry,
};

alloc: std.mem.Allocator,

// EntryIndex is the current index in the history
entry_index: i16 = -1,

// entries holds all recorded undo/redo history entries.
entries: std.ArrayList(Entry) = .empty,

tmp_entry: Entry,

// maxItems is the maximum number of entries allowed in history
max_items: usize = 100,

dmp: Dmp.DiffMatchPatch,

const Entry = struct {
    alloc: std.mem.Allocator,

    redo_patch: []const u8 = "",

    undo_patch: []const u8 = "",

    undo_cursor_pos: CursorPos = .{},

    redo_cursor_pos: CursorPos = .{},

    hash: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) !Entry {
        return .{ .alloc = alloc };
    }

    // This should only be called for entries that where committed to the
    // history. Never call this on a `tmp_entry`.
    // Committed entries always own allocated redo_patch and undo_patch.
    pub fn deinit(self: Entry) void {
        self.alloc.free(self.redo_patch);
        self.alloc.free(self.undo_patch);
    }
};

pub fn init(alloc: std.mem.Allocator) !*History {
    const self = try alloc.create(History);
    self.* = .{
        .alloc = alloc,
        .tmp_entry = try .init(self.alloc),
        .dmp = .init(self.alloc),
    };
    return self;
}

/// Creates a new temporary entry.
pub fn newTmpEntry(self: *History, cursor_pos: CursorPos) void {
    self.tmp_entry.undo_cursor_pos = cursor_pos;
}

/// Creates a new persistent history entry.
/// If future entries exist (after undo), they are discarded.
pub fn newEntry(self: *History, cursor_pos: CursorPos) !void {
    // if the current index is lower than the length of all entries
    // truncate the slice to the current index to get rid of all
    // the old entries and free the obsolete entrie's memory
    // so the history doesn't get too confusing.
    if (self.entry_index + 1 < self.numEntries()) {
        for (@intCast(self.entry_index + 1)..self.numEntries()) |i| {
            self.entries.items[i].deinit();
        }
    }
    self.entries.shrinkAndFree(self.alloc, @intCast(self.entry_index + 1));

    self.tmp_entry.undo_cursor_pos = cursor_pos;
    try self.entries.append(self.alloc, self.tmp_entry);

    self.entry_index = @intCast(self.numEntries() - 1);
}

/// Creates a new persistent history entry from he temporary entry.
pub fn appendTmpEntry(self: *History) !void {
    try self.newEntry(self.tmp_entry.undo_cursor_pos);
    self.tmp_entry = try .init(self.alloc);
}

/// Updates the current entry with patches and metadata.
pub fn updateEntry(
    self: *History,
    redo_patch: Dmp.PatchList,
    undo_patch: Dmp.PatchList,
    cursor_pos: CursorPos,
    hash: u64,
) !void {
    try self.appendTmpEntry();

    if (self.entry_index >= self.numEntries() or self.entry_index < 0) {
        std.log.warn("History entry index {} not found.", .{self.entry_index});
        return HistoryError.EntryNotFound;
    }

    var entries = self.entries.items;
    const index: usize = @intCast(self.entry_index);

    const redo_p = try self.dmp.patchToText(redo_patch);
    defer self.alloc.free(redo_p);

    const undo_p = try self.dmp.patchToText(undo_patch);
    defer self.alloc.free(undo_p);

    var entry_alloc = entries[index].alloc;
    entries[index].deinit();
    entries[index].redo_patch = try entry_alloc.dupe(u8, redo_p);
    entries[index].undo_patch = try entry_alloc.dupe(u8, undo_p);

    entries[index].redo_cursor_pos = cursor_pos;
    entries[index].hash = hash;
}

/// Returns the entry at the given index or nil if out of bounds.
pub fn getEntry(self: History, index: usize) !Entry {
    if (index > self.numEntries() - 1) {
        return HistoryError.EntryNotFound;
    }
    return self.entries.items[index];
}

/// Generates a diff patch between `old_str` and `new_str`.
pub fn makePatch(
    self: *History,
    old_str: []const u8,
    new_str: []const u8,
) !Dmp.PatchList {
    return try self.dmp.patchMakeStringString(old_str, new_str);
}

/// Returns the undo patch, content hash, and cursor position.
/// Returns HistoryError if no undo patch is available.
pub fn undo(self: *History) !struct {
    patch: Dmp.PatchList,
    hash: u64,
    cursor_pos: CursorPos,
} {
    if (self.entry_index < 0 or self.entry_index >= self.numEntries()) {
        return HistoryError.NoUndoEntry;
    }

    const entry: Entry = try self.getEntry(@intCast(self.entry_index));
    const cursor_pos: CursorPos = entry.undo_cursor_pos;
    const patch: Dmp.PatchList = try self.dmp.patchFromText(entry.undo_patch);

    self.entry_index -= 1;

    return .{
        .patch = patch,
        .hash = entry.hash,
        .cursor_pos = cursor_pos,
    };
}

/// Returns the redo patch, content hash, and cursor position.
/// Returns HistoryError if no redo patch is available.
pub fn redo(self: *History) !struct {
    patch: Dmp.PatchList,
    hash: u64,
    cursor_pos: CursorPos,
} {
    if (self.entry_index + 1 >= self.numEntries()) {
        return HistoryError.NoUndoEntry;
    }

    self.entry_index += 1;

    const entry: Entry = try self.getEntry(@intCast(self.entry_index));
    const cursor_pos: CursorPos = entry.redo_cursor_pos;
    const patch: Dmp.PatchList = try self.dmp.patchFromText(entry.redo_patch);

    return .{
        .patch = patch,
        .hash = entry.hash,
        .cursor_pos = cursor_pos,
    };
}

fn numEntries(self: History) usize {
    return self.entries.items.len;
}

pub fn deinit(self: *History) void {
    for (self.entries.items) |entry| {
        entry.deinit();
    }
    self.entries.deinit(self.alloc);
}
