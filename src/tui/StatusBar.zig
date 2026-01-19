const StatusBar = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Column = @import("layout/Column.zig");

alloc: std.mem.Allocator,

col: *Column,

default_width: u16 = 0,

default_height: u16 = 1,

content_cols: [4]*Column,

const SbColumn = struct {
    width: u16,
};

pub fn init(alloc: std.mem.Allocator) !*StatusBar {
    const self = try alloc.create(StatusBar);

    self.* = .{
        .alloc = alloc,
        .col = try .init(alloc),
        .content_cols = undefined,
    };

    self.col.setHeight(self.default_height);

    return self;
}

pub fn update(self: *StatusBar, event: App.Event) !void {
    _ = self;

    switch (event) {
        .key_press => |key| {
            _ = key;
        },
        else => {},
    }
}

pub fn draw(self: *StatusBar, win: vx.Window) void {
    var child_opts: vx.Window.ChildOptions = self.col.getChild();
    child_opts.border = .{};
    _ = win.child(child_opts);
}

pub fn deinit(self: *StatusBar) void {
    self.col.deinit();
}
