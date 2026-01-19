const NotesList = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Column = @import("layout/Column.zig");

alloc: std.mem.Allocator,

col: *Column,

default_width: u16 = 30,

default_height: u16 = 0,

pub fn init(alloc: std.mem.Allocator) !*NotesList {
    const self = try alloc.create(NotesList);

    self.* = .{
        .alloc = alloc,
        .col = try .init(alloc),
    };

    self.col.setWidth(self.default_width);

    return self;
}

pub fn update(self: *NotesList, event: App.Event) !void {
    _ = self;

    switch (event) {
        .key_press => |key| {
            _ = key;
        },
        else => {},
    }
}

pub fn draw(self: *NotesList, win: vx.Window) void {
    _ = win.child(self.col.getChild());
}

pub fn deinit(self: NotesList) void {
    self.col.deinit();
}
