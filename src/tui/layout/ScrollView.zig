const ScrollView = @This();
const std = @import("std");
const vx = @import("vaxis");

view: vx.widgets.ScrollView,

height: u16,

row: u32 = 0,

pub fn init() ScrollView {
    return .{
        .view = .{},
        .height = 0,
    };
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
