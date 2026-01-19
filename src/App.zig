const App = @This();

const std = @import("std");
const vaxis = @import("vaxis");

const Config = @import("Config.zig");
const DirectoryTree = @import("tui/DirectoryTree.zig");
const Editor = @import("tui/Editor.zig");
const NotesList = @import("tui/NotesList.zig");
const StatusBar = @import("tui/StatusBar.zig");
const log = @import("log.zig");

alloc: std.mem.Allocator,

should_quit: bool,

tty: vaxis.tty.PosixTty,

vx: vaxis.Vaxis,

notes_list: *NotesList,

directory_tree: *DirectoryTree,

editor: *Editor,

status_bar: *StatusBar,

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn init(alloc: std.mem.Allocator) !App {
    var buffer: [1024]u8 = undefined;

    try Config.init(alloc);

    return .{
        .alloc = alloc,
        .tty = try vaxis.Tty.init(&buffer),
        .vx = try vaxis.init(alloc, .{}),
        .should_quit = false,
        .notes_list = undefined,
        .directory_tree = undefined,
        .editor = undefined,
        .status_bar = undefined,
    };
}

pub fn run(self: *App) !void {
    const writer: *std.Io.Writer = self.tty.writer();

    var loop: vaxis.Loop(Event) = .{
        .vaxis = &self.vx,
        .tty = &self.tty,
    };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try self.vx.enterAltScreen(writer);

    self.notes_list = try .init(self.alloc);
    self.directory_tree = try .init(self.alloc);
    self.editor = try .init(self.alloc);
    self.status_bar = try .init(self.alloc);

    try writer.flush();

    try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

    while (!self.should_quit) {
        const event: Event = loop.nextEvent();
        try self.update(event);

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.should_quit = true;
                    return;
                }
            },
            .winsize => |ws| {
                try self.vx.resize(self.alloc, self.tty.writer(), ws);
            },
        }

        try self.draw();

        // Render the screen
        try self.vx.render(writer);
        try writer.flush();
    }
}

pub fn update(self: *App, event: Event) !void {
    try self.notes_list.update(event);
    try self.directory_tree.update(event);
    try self.editor.update(event);
    try self.status_bar.update(event);

    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                self.should_quit = true;
                return;
            }
        },
        .winsize => |ws| {
            try self.vx.resize(self.alloc, self.tty.writer(), ws);
        },
    }
}

pub fn draw(self: *App) !void {
    var win: vaxis.Window = self.vx.window();
    win.clear();
    self.initComponents(win);
}

fn initComponents(self: *App, win: vaxis.Window) void {
    const sb_height = self.status_bar.col.height;

    self.notes_list.col.setHeight(win.height - sb_height);
    self.notes_list.col.setOffsetY(0);
    self.notes_list.draw(win);

    self.directory_tree.col.setHeight(win.height - sb_height);
    self.directory_tree.col.setOffsetY(0);
    self.directory_tree.col.setOffsetX(self.notes_list.col.width);
    self.directory_tree.draw(win);

    const editor_xoff = self.notes_list.col.width + self.directory_tree.col.width;
    self.editor.col.setHeight(win.height - sb_height);
    self.editor.col.setOffsetY(0);
    self.editor.col.setOffsetX(editor_xoff);
    self.editor.draw(win);

    self.status_bar.col.setOffsetY(self.editor.col.height);
    self.status_bar.draw(win);
}

pub fn deinit(self: *App) void {
    Config.deinit();

    self.notes_list.deinit();
    self.alloc.destroy(self.notes_list);

    self.directory_tree.deinit();
    self.alloc.destroy(self.directory_tree);

    self.editor.deinit();
    self.alloc.destroy(self.editor);

    self.status_bar.deinit();
    self.alloc.destroy(self.status_bar);

    self.vx.deinit(self.alloc, self.tty.writer());
    self.tty.deinit();
}
