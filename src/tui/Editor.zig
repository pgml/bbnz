const Editor = @This();

const std = @import("std");
const vx = @import("vaxis");
const ScrollView = vx.widgets.ScrollView;
const Window = vx.Window;

const App = @import("../App.zig");
const Column = @import("layout/Column.zig");
const log = @import("../log.zig");
const TextArea = @import("widgets/TextArea/TextArea.zig");

const theme = @import("layout/theme.zig");

alloc: std.mem.Allocator,

col: *Column,

default_width: u16 = 0,

default_height: u16 = 0,

scroll_view: ScrollView,

textarea: TextArea,

pub fn init(alloc: std.mem.Allocator) !*Editor {
    const self = try alloc.create(Editor);

    self.* = .{
        .alloc = alloc,
        .col = try .init(alloc),
        .textarea = try .init(alloc),
        .scroll_view = .{},
    };

    self.col.setWidth(self.default_width);
    self.col.focus();

    return self;
}

pub fn update(self: *Editor, event: App.Event) !void {
    if (self.textarea.nbrBufs() == 0) {
        return;
    }

    try self.textarea.enableVimMode();

    switch (event) {
        .key_press => |key| {
            try self.textarea.update(.{ .key_press = key });
        },
        else => {},
    }
}

pub fn draw(self: *Editor, win: vx.Window) void {
    var child_win: vx.Window = win.child(self.col.getChild());
    const gutter_width = 6;
    const top_padding = 0;

    child_win.y_off += top_padding;
    child_win.x_off += gutter_width;
    child_win.width -= gutter_width;
    //child_win.height -= top_padding;

    self.textarea.win = child_win;

    if (self.textarea.nbrBufs() > 0) {
        self.scroll_view.draw(child_win, .{
            .cols = self.textarea.width,
            .rows = self.textarea.curBuf().nbrRows(),
        });

        self.textarea.scroll_view = &self.scroll_view;

        const ln: vx.widgets.LineNumbers = .{
            .num_lines = self.textarea.curBuf().nbrRows() +| 1,
            .style = .{
                .fg = theme.Color.LineNumber.fg,
            },
        };

        ln.draw(win.child(.{
            .x_off = self.col.offset_x,
            .y_off = self.col.offset_y + 1,
            .width = gutter_width,
            .height = self.textarea.height,
        }), self.scroll_view.scroll.y);

        self.textarea.draw();
    }
}

pub fn deinit(self: *Editor) void {
    self.col.deinit();
    self.textarea.deinit();
}
