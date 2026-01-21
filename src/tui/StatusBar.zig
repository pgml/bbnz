const StatusBar = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Cell = @import("layout/Cell.zig");

alloc: std.mem.Allocator,

cell: *Cell,

default_width: u16 = 0,

default_height: u16 = 1,

content_cols: [4]*Cell,

const SbColumn = struct {
    width: u16,
};

pub fn init(alloc: std.mem.Allocator) !*StatusBar {
    const self = try alloc.create(StatusBar);

    self.* = .{
        .alloc = alloc,
        .cell = try .init(alloc),
        .content_cols = undefined,
    };

    self.cell.setHeight(self.default_height);

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
    var child_opts: vx.Window.ChildOptions = self.cell.getChild();
    child_opts.border = .{};
    _ = win.child(child_opts);
}

pub fn deinit(self: *StatusBar) void {
    self.alloc.destroy(self.cell);
}
