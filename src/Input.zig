//! `Input` handles all keyboard actions including parsing both
//! default and user keymap (not implemented yet) files and mapping
//! keymap file function to their corresponding internal functions.
const Input = @This();
const std = @import("std");
const vx = @import("vaxis");

const App = @import("App.zig");
const DirectoryTree = @import("tui/DirectoryTree.zig");
const NotesList = @import("tui/NotesList.zig");
const Editor = @import("tui/Editor.zig");
const TextArea = @import("tui/widgets/TextArea/TextArea.zig");
const Vim = @import("tui/widgets/TextArea/Vim.zig");

const keymap_path = "keymap/default";

arena: std.heap.ArenaAllocator,

alloc: std.mem.Allocator,

app: *App,

keymap: KeyMap,

cur_seq: std.ArrayList([]const u8) = .empty,

/// The time in milliseconds to wait for a mapped
/// sequence to complete. This is basically `timeoutlen` from Vim.
seq_timeout: u64 = 300,

seq_generation: std.atomic.Value(u64) = .init(0),

should_reset_seq: u64 = 0,

pub const FlagValue = enum {
    none,
    non_white,
    end,
    await,
    prev,
    line,
    from_cursor,
    word,
    outer,
};

pub const Flags = std.ArrayList(FlagValue);

const AppFn = *const fn (*App) void;
const InputFn = *const fn (*Input, ?Flags) void;
const VimFn = *const fn (*Vim, ?Flags) void;
const DirTreeFn = *const fn (*DirectoryTree) void;
const NotesFn = *const fn (*NotesList) void;
const EditorFn = *const fn (*Editor) void;
const TextAreaFn = *const fn (*TextArea) void;

const FnTarget = union(enum) {
    input: InputFn,
    app: AppFn,
    tree: DirTreeFn,
    notes: NotesFn,
    editor: EditorFn,
    textarea: TextAreaFn,
    vim: VimFn,
};

const FnMap = struct {
    name: []const u8,
    exec: FnTarget,
    flags: ?Flags = null,
};

// zig fmt: off
const fn_registry = [_]FnMap{
    .{ .name = "lineDown",          .exec = .{ .input = lineDown }},
    .{ .name = "lineUp",            .exec = .{ .input = lineUp }},
    .{ .name = "cmd",               .exec = .{ .input = cmd }},
    .{ .name = "confirmAction",     .exec = .{ .input = confirmAction }},
    .{ .name = "cancelAction",      .exec = .{ .input = cancelAction }},
    .{ .name = "focusNextColumn",   .exec = .{ .app = App.cmdNextCol }},
    .{ .name = "focusPrevColumn",   .exec = .{ .app = App.cmdPrevCol }},
    .{ .name = "goToTop",           .exec = .{ .input = goToTop }},
    .{ .name = "goToBottom",        .exec = .{ .input = goToBottom }},
    .{ .name = "closeNote",         .exec = .{ .input = closeNote }},

    .{ .name = "dirtree.treeExpand",     .exec = .{ .tree = DirectoryTree.cmdExpand }},
    .{ .name = "dirtree.treeCollapse",   .exec = .{ .tree = DirectoryTree.cmdCollapse }},

    .{ .name = "statusbar.deleteBefore",  .exec = .{ .input = statusBarDeleteBefore }},

    // VIM/Editor stuff
    .{ .name = "editor.lineStart",   .exec = .{ .vim = Vim.beginLine }},
    .{ .name = "editor.lineEnd",     .exec = .{ .textarea = TextArea.lineEnd }},

    .{ .name = "editor.insertAfterLine",   .exec = .{ .vim = Vim.edit }},
    .{ .name = "editor.changeAfterCursor", .exec = .{ .vim = Vim.del }},
    .{ .name = "editor.deleteAfterCursor", .exec = .{ .vim = Vim.del }},
    .{ .name = "editor.goToTop",           .exec = .{ .vim = Vim.gCmd }},
    .{ .name = "editor.goToBottom",        .exec = .{ .textarea = TextArea.goToBottom }},
    .{ .name = "editor.insertBeforeLine",  .exec = .{ .vim = Vim.edit }},
    .{ .name = "editor.insertAbove",       .exec = .{ .vim = Vim.newLine }},
    .{ .name = "editor.mergeLines",        .exec = .{ .input = joinLine }},

    .{ .name = "editor.insertAfter",   .exec = .{ .vim = Vim.edit }},
    .{ .name = "editor.nextWord",      .exec = .{ .input = wordRight }},
    .{ .name = "editor.prevWord",      .exec = .{ .input = wordLeft }},
    .{ .name = "editor.halfPageDown",  .exec = .{ .textarea = TextArea.halfPageDown }},
    .{ .name = "editor.halfPageUp",    .exec = .{ .textarea = TextArea.halfPageUp }},
    .{ .name = "editor.changeLine",    .exec = .{ .vim = Vim.cCmd }},
    .{ .name = "editor.deleteLine",    .exec = .{ .vim = Vim.dCmd }},
    .{ .name = "editor.charLeft",      .exec = .{ .textarea = TextArea.characterLeft }},
    .{ .name = "editor.insertBefore",  .exec = .{ .vim = Vim.edit }},
    .{ .name = "editor.lineDown",      .exec = .{ .vim = Vim.down }},
    .{ .name = "editor.lineUp",        .exec = .{ .vim = Vim.up }},
    .{ .name = "editor.charRight",     .exec = .{ .textarea = TextArea.characterRight }},
    .{ .name = "editor.insertBelow",   .exec = .{ .vim = Vim.newLine }},
    .{ .name = "editor.redo",          .exec = .{ .textarea = TextArea.redo }},
    .{ .name = "editor.undo",          .exec = .{ .textarea = TextArea.undo }},
    .{ .name = "editor.delChar",       .exec = .{ .vim = Vim.del }},
    .{ .name = "editor.newLine",       .exec = .{ .vim = Vim.newLine }},
    .{ .name = "editor.yank",          .exec = .{ .input = yank }},
    .{ .name = "editor.select",        .exec = .{ .vim = Vim.select }},
    //.{ .cp = Key.enter,   .v_fn = newLine },
    //.{ .cp = Key.up,      .v_fn = up },
    //.{ .cp = Key.down,    .v_fn = down },
    //.{ .cp = Key.left,    .t_fn = ta.characterLeft },
    //.{ .cp = Key.right,   .t_fn = ta.characterRight },
    .{ .name = "editor.enterNormalMode",    .exec = .{ .vim = Vim.esc }},
    .{ .name = "editor.toggleVisualMode",   .exec = .{ .vim = Vim.visual }},
    .{ .name = "editor.insertTabChar",      .exec = .{ .vim = Vim.tab }},
    .{ .name = "editor.deleteCharBefore",   .exec = .{ .vim = Vim.del }},
    .{ .name = "editor.deleteCharAfter",    .exec = .{ .vim = Vim.del }},
};
// zig fmt: on

const KeyMap = struct {
    alloc: std.mem.Allocator,

    entries: Map,

    seq_keys: std.ArrayList([]const u8) = .empty,

    const KeyBinding = struct {
        @"fn": []const u8,
        flags: ?Flags,
    };

    const KeyBindings = std.StringHashMap(KeyBinding);
    const ComponentsMap = std.StringHashMap(KeyBindings);
    const Map = std.AutoHashMap(TextArea.Vim.Mode, ComponentsMap);

    const ScopedMode = struct {
        mode: TextArea.Vim.Mode,
        component: []const u8,
    };

    pub fn init(alloc: std.mem.Allocator) !KeyMap {
        return .{
            .alloc = alloc,
            .entries = .init(alloc),
        };
    }

    /// Reads the keymap file and parses it's content.
    pub fn parse(self: *KeyMap, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        const size = stat.size;

        const read_buf = try self.alloc.alloc(u8, size);
        defer self.alloc.free(read_buf);

        var reader = file.reader(read_buf);
        var scoped_targets = std.ArrayList(ScopedMode).empty;

        while (try reader.interface.takeDelimiter('\n')) |line_slice| {
            const line_trim = std.mem.trim(u8, line_slice, " \t");

            // skip comments and empty lines
            if (line_trim.len == 0 or line_trim[0] == '#') continue;

            if (try self.parseScopedModes(&scoped_targets, line_trim)) {
                continue;
            }

            var rest = std.mem.trim(u8, line_trim[5..], " \t");
            const keybind = try self.getKeyBind(rest) orelse continue;

            var fn_name: []const u8 = "";
            var components = std.ArrayList([]const u8).empty;
            var flags: ?Flags = null;

            // position after closing quote
            var i = keybind.start_pos + 1 + keybind.end_pos + 1;

            // Scan key: value pairs until end of line
            while (i < rest.len) : (i += 1) {
                // skip whitespace
                if (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) {
                    continue;
                }

                // eol, we're done here...
                if (i >= rest.len) {
                    break;
                }

                // find separator
                const eq_pos = std.mem.indexOf(u8, rest[i..], ":") orelse break;

                // the key to the value
                const key = std.mem.trim(u8, rest[i .. i + eq_pos], " \t");

                i += eq_pos + 2;

                // find value end (next space or end-of-line)
                var val_end = i;
                while (val_end < rest.len and
                    rest[val_end] != ' ' and
                    rest[val_end] != '\t') : (val_end += 1)
                {}

                const val = rest[i..val_end];
                i = val_end;

                // Process key: value
                if (std.mem.eql(u8, key, "fn")) {
                    // get a copy of the function name.
                    fn_name = try self.alloc.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "flags")) {
                    // @todo make flags work with spaces
                    // currently only [end,prev,bla] works
                    // and not [end, prev, bla]
                    if (val.len >= 2 and val[0] == '[' and
                        val[val.len - 1] == ']')
                    {
                        const flags_slice = val[1 .. val.len - 1];
                        var flags_iter = std.mem.splitAny(u8, flags_slice, ",");
                        var flags_map: Flags = .empty;

                        while (flags_iter.next()) |flag| {
                            const trimmed = std.mem.trim(u8, flag, " \t");

                            try flags_map.append(
                                self.alloc,
                                self.resolveFlags(trimmed),
                            );
                        }
                        flags = flags_map;
                    }
                }
            }

            // fallback if no components specified
            if (components.items.len == 0) {
                try components.append(self.alloc, "all");
            }

            if (std.mem.eql(u8, fn_name, "") or scoped_targets.items.len == 0) {
                continue;
            }

            // If we are inside a mode-scope, expand into all scoped targets
            for (scoped_targets.items) |t| {
                const mode_entry = try self.entries.getOrPut(t.mode);
                if (!mode_entry.found_existing) {
                    mode_entry.value_ptr.* = .init(self.alloc);
                }

                const comp_entry = try mode_entry.value_ptr.getOrPut(t.component);
                if (!comp_entry.found_existing) {
                    comp_entry.value_ptr.* = .init(self.alloc);
                }

                try comp_entry.value_ptr.put(keybind.keys, .{
                    .@"fn" = fn_name,
                    .flags = flags,
                });
            }
        }
    }

    fn parseScopedModes(
        self: *KeyMap,
        scoped_targets: *std.ArrayList(ScopedMode),
        line_trim: []const u8,
    ) !bool {
        // close scope
        if (std.mem.eql(u8, line_trim, "}")) {
            scoped_targets.clearRetainingCapacity();
            return true;
        }

        if (!std.mem.startsWith(u8, line_trim, "mode")) {
            return false;
        }

        const rest = std.mem.trim(u8, line_trim[5..], " \t");
        scoped_targets.clearRetainingCapacity();

        const brace_pos = std.mem.indexOf(u8, rest, "{") orelse return true;
        const spec_list = std.mem.trim(u8, rest[0..brace_pos], " \t");

        var start: usize = 0;
        var paren_depth: usize = 0;

        for (0..spec_list.len) |i| {
            const c = spec_list[i];

            if (c == '(') {
                paren_depth += 1;
            } else if (c == ')') {
                paren_depth -= 1;
            } else if (c == ',' and paren_depth == 0) {
                // slice from start to i
                const slice = std.mem.trim(u8, spec_list[start..i], " \t");
                try self.processModeScope(slice, scoped_targets);
                start = i + 1;
            }
        }

        // last slice after loop
        const last_slice = std.mem.trim(u8, spec_list[start..], " \t");
        try self.processModeScope(last_slice, scoped_targets);

        return true;
    }

    /// Searches and returns the a keybind, it's start and end position from a line.
    /// If none could be found null is returned.
    fn getKeyBind(self: *KeyMap, line: []const u8) !?struct {
        start_pos: usize,
        end_pos: usize,
        keys: []const u8,
    } {
        // Extract quoted keybind
        const start_pos = std.mem.indexOf(u8, line, "\"") orelse return null;
        const end_pos = std.mem.indexOf(
            u8,
            line[start_pos + 1 ..],
            "\"",
        ) orelse return null;

        const keybind = try self.alloc.dupe(
            u8,
            line[start_pos + 1 .. start_pos + 1 + end_pos],
        );

        // collect sequence keys
        if (keybind.len > 1 and
            std.mem.indexOf(u8, keybind, "esc") == null and
            std.mem.indexOf(u8, keybind, "enter") == null)
        {
            if (std.mem.indexOf(u8, keybind, "space") != null) {
                // This is basically the leader key
                // @todo: make it configurable.
                try self.seq_keys.append(self.alloc, keybind[0..5]);
            } else if (std.mem.indexOf(u8, keybind, "-") != null) {
                // Every ctrl-, alt-, etc.. combo - since these combos
                // are written as C-, A-, M- getting the first three characters
                // (which would be the modifier + key) is sufficient.
                try self.seq_keys.append(self.alloc, keybind[0..3]);
            } else {
                // For simple motions we only need the first character so we
                // now when to wait for another keypress.
                try self.seq_keys.append(self.alloc, keybind[0..1]);
            }
        }

        return .{
            .start_pos = start_pos,
            .end_pos = end_pos,
            .keys = keybind,
        };
    }

    fn processModeScope(
        self: *KeyMap,
        spec: []const u8,
        scoped_targets: *std.ArrayList(ScopedMode),
    ) !void {
        const open_paren = std.mem.indexOf(u8, spec, "(") orelse {
            const mode = resolveMode(spec);
            try self.fillAllComponents(mode, scoped_targets);
            return;
        };

        const close_paren = std.mem.indexOf(u8, spec[open_paren + 1 ..], ")") orelse {
            return;
        };
        const mode_name = std.mem.trim(u8, spec[0..open_paren], " \t");
        const comp_slice = spec[open_paren + 1 .. open_paren + 1 + close_paren];
        const mode = resolveMode(mode_name);

        var comp_iter = std.mem.splitAny(u8, comp_slice, ",");
        while (comp_iter.next()) |c| {
            const comp = std.mem.trim(u8, c, " \t");
            const comp_dup = try self.alloc.dupe(u8, comp);

            if (std.mem.eql(u8, comp, "all")) {
                try self.fillAllComponents(mode, scoped_targets);
            } else {
                try scoped_targets.append(
                    self.alloc,
                    .{ .mode = mode, .component = comp_dup },
                );
            }
        }
    }

    fn fillAllComponents(
        self: *KeyMap,
        mode: TextArea.Vim.Mode,
        scoped_targets: *std.ArrayList(ScopedMode),
    ) !void {
        const all_comps = [_][]const u8{
            "Folders",
            "Notes",
            "Editor",
            "StatusBar",
            "BufferList",
        };
        for (all_comps) |ac| {
            try scoped_targets.append(
                self.alloc,
                .{ .mode = mode, .component = ac },
            );
        }
    }

    fn resolveFlags(self: KeyMap, flag_str: []const u8) FlagValue {
        _ = self;
        var flag: FlagValue = .none;
        if (std.mem.eql(u8, flag_str, "non_white")) flag = .non_white;
        if (std.mem.eql(u8, flag_str, "end")) flag = .end;
        if (std.mem.eql(u8, flag_str, "await")) flag = .await;
        if (std.mem.eql(u8, flag_str, "prev")) flag = .prev;
        if (std.mem.eql(u8, flag_str, "line")) flag = .line;
        if (std.mem.eql(u8, flag_str, "from_cursor")) flag = .from_cursor;
        if (std.mem.eql(u8, flag_str, "word")) flag = .word;
        if (std.mem.eql(u8, flag_str, "outer")) flag = .outer;
        return flag;
    }
};

pub fn init(alloc: std.mem.Allocator) !*Input {
    const self = try alloc.create(Input);

    self.* = .{
        .arena = .init(alloc),
        .alloc = self.arena.allocator(),
        .app = undefined,
        .keymap = try .init(self.alloc),
    };

    try self.keymap.parse(keymap_path);

    return self;
}

/// Processes an incoming key string, updating the internal
/// key sequence and modifier states as needed, and executing any matching
/// actions.
pub fn handleSeq(self: *Input, vx_key: vx.Key) !void {
    var key = vx_key;

    if (key.text == null) {
        key.text = switch (key.codepoint) {
            9 => "tab",
            13 => "enter",
            27 => "esc",
            127 => "backspace",
            57349 => "delete",
            else => key.text,
        };
    }

    // space-key acts as the leader key for now and starts a little temporary
    // thread to achieve vim's `timeoutlen`.
    // It should reset itself after a delay, preferably non-blocking.
    if (key.codepoint == 32) {
        key.text = "space";
        const gen = self.seq_generation.fetchAdd(1, .seq_cst) + 1;
        const thread = try std.Thread.spawn(.{}, sleep, .{ self, gen });
        thread.detach();
    }

    // get keybinds from components keymap
    const comp_map = self.keymap.entries.get(self.app.mode) orelse return;
    const bindings = comp_map.getEntry(self.app.focusedColumnName()) orelse {
        return;
    };

    // detect ctrl key and set key.text to "C-" which matches the a
    // Ctrl+ key combination from the keymap file.
    if (key.mods.ctrl) {
        var buf: [4]u8 = undefined; // max UTF-8 length
        const len = std.unicode.utf8Encode(key.codepoint, &buf) catch unreachable;

        key.text = try std.mem.concat(
            self.alloc,
            u8,
            &[_][]const u8{ "C-", buf[0..len] },
        );
    }

    var key_text = key.text orelse return;

    if (self.app.mode != .insert and self.app.mode != .command) {
        // look for current key sequence keys and build a correct
        // string rep of the keybind that matches the one from the keymap file
        for (self.cur_seq.items) |seq| {
            // append with no spaces for keybinds like `gg`, `dd` etc.
            var conc = [_][]const u8{ seq, "", key_text };

            // add a space for leader or modifier keybinds
            if (std.mem.indexOf(u8, seq, "-") != null or
                std.mem.eql(u8, seq, "space"))
            {
                conc = [_][]const u8{ seq, " ", key_text };
            }

            key_text = try std.mem.concat(self.alloc, u8, &conc);
        }

        // clear keyinfo statusbar column on escape
        if (key.codepoint == 27 and
            self.cur_seq.items.len > 0 and
            self.app.mode != .insert)
        {
            try self.app.status_bar.clearColumn(.key_info);
        }

        // if the current key is a sequence key and not a registered keybind
        // add them to the current sequence
        if (self.isSeqKey(key_text) and
            self.cur_seq.items.len == 0 and
            !self.isBinding(key_text))
        {
            try self.app.status_bar.setColumnContent(.key_info, key_text);
            try self.cur_seq.append(self.alloc, key_text);
            return;
        }
    }

    var iter = bindings.value_ptr.iterator();
    while (iter.next()) |entry| {
        const motion = entry.key_ptr.*;
        const reg_fn = entry.value_ptr;

        if (!std.mem.eql(u8, motion, key_text)) {
            self.resetKeySeq();
            continue;
        }

        for (fn_registry) |func| {
            if (!std.mem.eql(u8, reg_fn.@"fn", func.name)) {
                continue;
            }

            // dispatch functions
            switch (func.exec) {
                .input => |f| f(self, reg_fn.flags),
                .app => |f| f(self.app),
                .tree => |f| f(self.app.directory_tree),
                .notes => |f| f(self.app.notes_list),
                .editor => |f| f(self.app.editor),
                .textarea => |f| f(&self.app.editor.textarea),
                .vim => |f| f(self.app.editor.textarea.vim, reg_fn.flags),
            }

            if (self.app.mode != .insert) {
                try self.app.status_bar.clearColumn(.key_info);
            }

            self.resetKeySeq();
        }
    }
}

/// returns wether the given `keys` string is a known and valid key binding
fn isBinding(self: *Input, keys: []const u8) bool {
    const comp_keymap = self.keymap.entries.get(self.app.mode) orelse {
        return false;
    };
    const bindings = comp_keymap.getEntry(self.app.focusedColumnName()) orelse {
        return false;
    };

    var iter = bindings.value_ptr.iterator();
    while (iter.next()) |entry| {
        const motion = entry.key_ptr.*;
        if (std.mem.eql(u8, motion, keys)) {
            return true;
        }
    }

    return false;
}

fn sleep(self: *Input, gen: u64) void {
    std.Thread.sleep(self.seq_timeout * std.time.ns_per_ms);
    // Only reset if no newer timer was started
    if (self.seq_generation.load(.seq_cst) == gen) {
        self.resetKeySeq();
        self.app.status_bar.clearColumn(.key_info) catch return;
    }
}

/// Returns whether `key` is a registered sequence key.
fn isSeqKey(self: Input, key: []const u8) bool {
    for (self.keymap.seq_keys.items) |k| {
        if (std.mem.eql(u8, key, k)) {
            return true;
        }
    }
    return false;
}

fn resetKeySeq(self: *Input) void {
    self.cur_seq.clearAndFree(self.alloc);
    self.cur_seq = .empty;
}

fn lineDown(self: *Input, flags: ?Flags) void {
    _ = flags;
    switch (self.app.current_column) {
        1 => self.app.directory_tree.cmdLineDown(),
        2 => self.app.notes_list.cmdLineDown(),
        else => {},
    }
}

fn lineUp(self: *Input, flags: ?Flags) void {
    _ = flags;
    switch (self.app.current_column) {
        1 => self.app.directory_tree.cmdLineUp(),
        2 => self.app.notes_list.cmdLineUp(),
        else => {},
    }
}

fn treeExpand(self: *Input, flags: ?Flags) void {
    _ = flags;
    self.app.directory_tree.cmdExpand();
}

fn treeCollapse(self: *Input, flags: ?Flags) void {
    _ = flags;
    self.app.directory_tree.cmdCollapse();
}

fn cmd(self: *Input, flags: ?Flags) void {
    _ = flags;
    self.app.setMode(.command);
}

fn confirmAction(self: *Input, flags: ?Flags) void {
    _ = flags;
    switch (self.app.current_column) {
        1 => self.app.directory_tree.cmdSelectDir(),
        2 => self.app.notes_list.cmdSelectNote(),
        else => {},
    }
}

fn cancelAction(self: *Input, flags: ?Flags) void {
    _ = flags;
    self.app.cancelAction();
    self.resetKeySeq();
}

fn goToTop(self: *Input, flags: ?Flags) void {
    _ = flags;
    switch (self.app.current_column) {
        1 => self.app.directory_tree.cmdGoToTop(),
        2 => self.app.notes_list.cmdGoToTop(),
        else => {},
    }
}

fn goToBottom(self: *Input, flags: ?Flags) void {
    _ = flags;
    switch (self.app.current_column) {
        1 => self.app.directory_tree.cmdGoToBottom(),
        2 => self.app.notes_list.cmdGoToBottom(),
        else => {},
    }
}

fn wordRight(self: *Input, flags: ?Flags) void {
    if (flags == null) {
        self.app.editor.textarea.wordRight();
        return;
    }

    for (flags.?.items) |flag| {
        if (flag == .end) {
            self.app.editor.textarea.wordRightEnd();
        }
    }
}

fn wordLeft(self: *Input, flags: ?Flags) void {
    if (flags == null) {
        self.app.editor.textarea.wordLeft();
        return;
    }

    for (flags.?.items) |flag| {
        if (flag == .end) {
            self.app.editor.textarea.wordLeftEnd();
        }
    }
}

/// Redirects to Editor.textarea.joinLine.
/// `flags` exists for Input command API compatibility and is ignored here.
fn joinLine(self: *Input, flags: ?Flags) void {
    _ = flags;
    self.app.editor.textarea.joinLine();
}

fn closeNote(self: *Input, flags: ?Flags) void {
    _ = self;
    _ = flags;
    std.log.debug("ads", .{});
}

fn statusBarDeleteBefore(self: *Input, flags: ?Flags) void {
    _ = flags;
    if (self.app.status_bar.colums.getEntry(.general)) |entry| {
        entry.value_ptr.*.deleteCharBefore();
    }
}

fn yank(self: *Input, flags: ?Flags) void {
    var line = false;
    var from_cursor = false;
    var ta = self.app.editor.textarea;
    //const buf = ta.curBuf();

    if (flags) |f| {
        line = Input.flagsContain(f, .line);
        from_cursor = Input.flagsContain(f, .from_cursor);
    }

    if (from_cursor) {
        // @todo
    } else {
        ta.yankSelection(false) catch return;
    }
}

pub fn deinit(self: *Input) void {
    self.arena.deinit();
}

fn resolveMode(mode_str: []const u8) TextArea.Vim.Mode {
    var mode: TextArea.Vim.Mode = .normal;
    if (std.mem.eql(u8, mode_str, "insert")) mode = .insert;
    if (std.mem.eql(u8, mode_str, "command")) mode = .command;
    if (std.mem.eql(u8, mode_str, "visual")) mode = .visual;
    if (std.mem.eql(u8, mode_str, "visual_line")) mode = .visual_line;
    if (std.mem.eql(u8, mode_str, "visual_block")) mode = .visual_block;

    return mode;
}

pub fn flagsContain(haystack: Flags, needle: FlagValue) bool {
    for (haystack.items) |item| {
        if (item == needle) {
            return true;
        }
    }

    return false;
}
