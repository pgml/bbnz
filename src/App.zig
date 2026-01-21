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
    self.directory_tree = try .init(self.alloc, self);
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
    try self.initComponents(win);
}

fn initComponents(self: *App, win: vaxis.Window) !void {
    const sb_height = self.status_bar.cell.height;

    self.directory_tree.cell.setHeight(win.height - sb_height);
    self.directory_tree.cell.setOffsetY(0);
    self.directory_tree.draw(win);

    self.notes_list.cell.setHeight(win.height - sb_height);
    self.notes_list.cell.setOffsetY(0);
    self.notes_list.cell.setOffsetX(self.directory_tree.cell.width);
    self.notes_list.draw(win);

    const editor_xoff = self.notes_list.cell.width + self.directory_tree.cell.width;
    self.editor.cell.setHeight(win.height - sb_height);
    self.editor.cell.setOffsetY(0);
    self.editor.cell.setOffsetX(editor_xoff);
    self.editor.draw(win);

    self.status_bar.cell.setOffsetY(self.editor.cell.height);
    self.status_bar.draw(win);
}

pub fn deinit(self: *App) void {
    Config.deinit();

    self.directory_tree.deinit();
    self.alloc.destroy(self.directory_tree);

    self.notes_list.deinit();
    self.alloc.destroy(self.notes_list.cell);
    self.alloc.destroy(self.notes_list);

    self.editor.deinit();
    self.alloc.destroy(self.editor);

    self.status_bar.deinit();
    self.alloc.destroy(self.status_bar);

    self.vx.deinit(self.alloc, self.tty.writer());
    self.tty.deinit();
}
