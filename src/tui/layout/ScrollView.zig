const ScrollView = @This();
const std = @import("std");
const vx = @import("vaxis");

view: vx.widgets.ScrollView,

height: u16,

row: u32 = 0,

default_vbar: vx.widgets.ScrollView.VerticalScrollbar,

pub fn init(alloc: std.mem.Allocator) !*ScrollView {
    const self = try alloc.create(ScrollView);

    self.* = .{
        .view = .{},
        .height = 0,
        .default_vbar = self.view.vertical_scrollbar.?,
    };

    return self;
}

pub fn setRow(self: *ScrollView, row: i32) void {
    self.row = @intCast(row);
}

/// Repositions the view to the cursor position, ensuring it's always
/// in the viewport.
pub fn reposition(self: *ScrollView) void {
    const min = self.view.scroll.y;
    const max = min + self.height - 1;

    if (self.row < min) {
        self.view.scroll.y -= min - self.row;
    } else if (self.row > max) {
        self.view.scroll.y += self.row - max;
    }
}

pub fn showScrollBar(self: *ScrollView) void {
    var vbar = self.view.vertical_scrollbar orelse return;
    vbar.character = .{ .grapheme = self.default_vbar.character.grapheme };
    self.view.vertical_scrollbar = vbar;
}

pub fn hideScrollBar(self: *ScrollView) void {
    var vbar = self.view.vertical_scrollbar orelse return;
    //vbar.bg = .{ .fg = .{ .rgb = .{ 255, 100, 100 } } };
    vbar.character = .{ .grapheme = " " };
    self.view.vertical_scrollbar = vbar;
}
