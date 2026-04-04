const Config = @This();

const std = @import("std");
const known_folders = @import("known-folders");
const microwave = @import("microwave");

const tui = @import("tui/tui.zig");
const TextArea = tui.Editor.TextArea;

const log = @import("log.zig");
const theme = @import("tui/layout/theme.zig");
const utils = @import("utils.zig");

pub const application_name = "bellbird-notes-dev";
pub const config_file_name = "config";
pub const meta_file_name = ".metainfos";

alloc: std.mem.Allocator,

meta_infos: *MetaInfos,

@"notes-directory": []const u8 = "",

/// Doesn't enter alternate screen.
@"no-alt": bool = false,

/// Use a virtual cursor instead of the native cursor provided by the
/// terminal.
/// In future update this will be more meaningful as different app modes
/// will have different cursor colours and/or shapes.
//
// @todo: do what I said above
@"virtual-cursor": bool = false,

pub const MetaInfos = struct {
    var meta_file: []const u8 = "";

    arena: std.heap.ArenaAllocator,

    alloc: std.mem.Allocator,

    /// The path of the meta info file.
    /// A list of all open notes
    @"last-notes": LastNotes = .{},

    /// The last open note
    @"last-open-note": []const u8 = "",

    /// The last opened directory
    @"last-directory": []const u8 = "",

    /// Currently selected column
    @"current-column": u16 = 1,

    /// Map of files and directories that holds information about
    /// of a file's cursor position and pinned state and a directorie's
    /// expanded and pinned state.
    files_info: std.StringArrayHashMap(FileInfo) = undefined,

    const FileInfo = struct {
        type: FileType = .file,

        path: []const u8 = "",

        @"is-expanded": ConfBool = .{ .name = "is-expanded" },

        @"is-pinned": ConfBool = .{ .name = "is-pinned" },

        @"cursor-pos": CursorPos = .{},

        const FileType = enum {
            file,
            dir,
        };
    };

    pub const ConfBool = struct {
        name: []const u8 = "",
        value: bool = false,
        ctx: FileInfo.FileType = .file,

        pub fn setValue(self: *ConfBool, value: bool) void {
            self.value = value;
        }
    };

    pub const CursorPos = struct {
        name: []const u8 = "cursor-pos",

        value: TextArea.Buffer.CursorPos = .{},

        pub fn str(self: CursorPos) []const u8 {
            return self.name;
        }
    };

    const LastNotes = struct {
        name: []const u8 = "last-notes",

        list: std.ArrayList([]u8) = .empty,

        pub fn str(self: LastNotes) []const u8 {
            return self.name;
        }

        pub fn toStr(self: LastNotes, alloc: std.mem.Allocator) ![]const u8 {
            var last_notes = try std.mem.join(alloc, ",", self.list.items);
            // prevent starting comma
            if (std.mem.startsWith(u8, last_notes, ",")) {
                last_notes = last_notes[1..];
            }
            return last_notes;
        }

        fn contains(self: LastNotes, path: []const u8) bool {
            for (self.list.items) |note_path| {
                if (std.mem.eql(u8, note_path, path)) {
                    return true;
                }
            }
            return false;
        }
    };

    /// All available meta options
    pub const MetaOpts = enum {
        last_directory,
        last_open_note,
        current_column,
        file_info,
        last_notes,
        is_expanded,
        is_pinned,
        cursor_pos,
    };

    pub fn init(alloc: std.mem.Allocator) !*MetaInfos {
        const self = try alloc.create(MetaInfos);
        self.* = .{
            .arena = .init(alloc),
            .alloc = self.arena.allocator(),
        };
        return self;
    }

    /// Loads the meta info file and populate the meta info struct with the
    /// data from the file.
    pub fn loadAndPopulate(self: *MetaInfos, file_path: []const u8) !void {
        self.files_info = .init(self.alloc);
        meta_file = try self.alloc.dupe(u8, file_path);

        const doc = try Config.readFile(self.alloc, meta_file) orelse return;
        defer doc.deinit();

        var iter = doc.table.iterator();
        // iterate through the parse meta infos file and populate the struct
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr;
            const section = try self.alloc.dupe(u8, key);

            // populate primitive types
            const meta_struct = @typeInfo(MetaInfos).@"struct";
            inline for (comptime meta_struct.fields) |field| {
                if (!std.mem.eql(u8, key, field.name)) {
                    comptime continue;
                }

                switch (field.type) {
                    bool => @field(self, field.name) = val.bool,
                    []const u8 => {
                        if (std.mem.count(u8, val.string, ",") > 0) {
                            break;
                        }
                        const str = try self.alloc.dupe(u8, val.string);
                        @field(self, field.name) = str;
                    },
                    u16 => @field(self, field.name) = @intCast(val.integer),
                    else => {},
                }
            }

            if (std.mem.eql(u8, key, self.@"last-notes".str())) {
                var split_iter = std.mem.splitAny(u8, val.string, ",");
                while (split_iter.next()) |note| {
                    const path = try self.alloc.dupe(u8, note);
                    try self.@"last-notes".list.append(self.alloc, path);
                }
            }

            // popule files info map
            if (val.anyTableOrNull()) |table| {
                var finfo: FileInfo = .{
                    .path = section,
                };
                var info_iter = table.iterator();
                while (info_iter.next()) |_| {
                    const info_struct = @typeInfo(FileInfo).@"struct";

                    inline for (comptime info_struct.fields) |field| {
                        switch (field.type) {
                            ConfBool => {
                                const fentry = table.getEntry(field.name) orelse break;
                                @field(finfo, field.name) = .{
                                    .name = field.name,
                                    .value = fentry.value_ptr.bool,
                                };
                            },
                            CursorPos => {
                                const fentry = table.getEntry(field.name) orelse break;
                                const farray = fentry.value_ptr.anyArrayOrNull() orelse break;

                                finfo.@"cursor-pos" = .{ .value = .{
                                    .row = @intCast(farray.items[0].integer),
                                    .row_offset = @intCast(farray.items[1].integer),
                                    .col = @intCast(farray.items[2].integer),
                                } };
                            },
                            else => {},
                        }
                    }
                }

                try self.files_info.put(section, finfo);
            }
        }
    }

    /// Updates a meta info value
    pub fn setValue(self: *MetaInfos, opt: MetaOpts, val: anytype) !void {
        const ValType = @TypeOf(val);
        const val_type_info = @typeInfo(ValType);

        switch (val_type_info) {
            .int, .float, .bool => {
                if (opt == .current_column) {
                    self.current_column = val;
                }
            },
            .pointer => |ptr| blk: {
                // allow empty strings as well
                if (ptr.child != u8 and ptr.child != [0:0]u8) break :blk;

                switch (opt) {
                    .last_directory => {
                        self.alloc.free(self.@"last-directory");
                        self.@"last-directory" = try self.alloc.dupe(u8, val);
                    },
                    .last_open_note => {
                        self.alloc.free(self.@"last-open-note");
                        self.@"last-open-note" = try self.alloc.dupe(u8, val);
                    },
                    .last_notes => {
                        if (self.@"last-notes".contains(val)) {
                            return;
                        }
                        try self.@"last-notes".list.append(
                            self.alloc,
                            try self.alloc.dupe(u8, val),
                        );
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    pub fn addFileInfo(self: *MetaInfos, file: FileInfo) !void {
        const path = try self.alloc.dupe(u8, file.path);

        if (self.files_info.contains(file.path)) {
            return;
        }

        switch (file.type) {
            .file => try self.files_info.put(path, file),
            .dir => try self.files_info.put(path, file),
        }

        try self.write();
    }

    pub fn updateFileInfo(
        self: *MetaInfos,
        filepath: []const u8,
        opt: MetaOpts,
        val: anytype,
    ) !void {
        if (!self.files_info.contains(filepath)) {
            try self.addFileInfo(.{ .path = filepath, .type = .file });
        }

        const path = try self.alloc.dupe(u8, filepath);
        const file = try self.files_info.getOrPut(path);
        const ValType = @TypeOf(val);

        switch (ValType) {
            bool => {
                switch (opt) {
                    .is_expanded => file.value_ptr.@"is-expanded".value = val,
                    .is_pinned => file.value_ptr.@"is-pinned".value = val,
                    else => {},
                }
            },
            TextArea.Buffer.CursorPos => {
                file.value_ptr.@"cursor-pos".value = val;
            },
            else => {},
        }

        try self.write();
    }

    /// Writes the info struct to the meta info file.
    pub fn write(self: *MetaInfos) !void {
        const file = std.fs.createFileAbsolute(
            meta_file,
            .{ .truncate = true },
        ) catch |e| {
            std.log.debug("{}", .{e});
            return;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        var write_stream: microwave.WriteStream = .{
            .allocator = self.alloc,
            .writer = &writer.interface,
        };
        defer write_stream.deinit();

        // write primitive types
        const meta_struct = @typeInfo(MetaInfos).@"struct";
        inline for (comptime meta_struct.fields) |field| {
            const value = @field(self, field.name);
            switch (field.type) {
                bool => {
                    try write_stream.beginKeyPair(field.name);
                    try write_stream.writeBoolean(value);
                },
                []const u8 => {
                    try write_stream.beginKeyPair(field.name);
                    try write_stream.writeString(value);
                },
                u16 => {
                    try write_stream.beginKeyPair(field.name);
                    try write_stream.writeInteger(value);
                },
                else => {},
            }
        }

        try write_stream.beginKeyPair(self.@"last-notes".str());
        const last_notes = try self.@"last-notes".toStr(self.alloc);
        defer self.alloc.free(last_notes);
        try write_stream.writeString(last_notes);

        var file_iter = self.files_info.iterator();
        while (file_iter.next()) |entry| {
            const section = entry.key_ptr.*;
            const val = entry.value_ptr;
            // this is a cheap check but it's okay for now.
            const is_file = !utils.strEql(std.fs.path.extension(section), "");

            try write_stream.writeTable(section);

            const info_struct = @typeInfo(FileInfo).@"struct";
            inline for (comptime info_struct.fields) |field| {
                switch (field.type) {
                    ConfBool => {
                        const bool_val: ConfBool = @field(val, field.name);
                        try write_stream.beginKeyPair(field.name);
                        try write_stream.writeBoolean(bool_val.value);
                    },
                    CursorPos => {
                        if (!is_file) {
                            break;
                        }

                        const pos: CursorPos = @field(val, field.name);
                        try write_stream.beginKeyPair(pos.str());
                        try write_stream.beginArray();
                        {
                            try write_stream.writeInteger(pos.value.row);
                            try write_stream.writeInteger(pos.value.row_offset);
                            try write_stream.writeInteger(pos.value.col);
                        }
                        try write_stream.endArray();
                    },
                    else => {},
                }
            }
        }

        try write_stream.writer.writeByte('\n');
        try write_stream.writer.flush();
    }

    pub fn deinit(self: *MetaInfos) void {
        self.arena.deinit();
    }
};

pub fn init(alloc: std.mem.Allocator) !*Config {
    const self = try alloc.create(Config);

    self.* = .{
        .alloc = alloc,
        .meta_infos = try .init(alloc),
    };

    try self.loadAndPopulate();

    return self;
}

/// Loads the meta info file.
pub fn loadMetaInfo(self: *Config) !void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const file_path = try std.mem.concat(arena_alloc, u8, &[_][]const u8{
        try self.getNotesRootDir(),
        "/",
        meta_file_name,
    });
    defer arena_alloc.free(file_path);
    try self.meta_infos.loadAndPopulate(file_path);
}

/// Loads the meta info file and populate the meta info struct with the
/// data from the file.
pub fn loadAndPopulate(self: *Config) !void {
    const conf_dir = try Config.getConfDirPath(self.alloc);
    defer self.alloc.free(conf_dir);
    const file_path = try std.fs.path.join(self.alloc, &.{
        conf_dir,
        config_file_name,
    });
    defer self.alloc.free(file_path);

    const doc = try Config.readFile(self.alloc, file_path) orelse return;
    defer doc.deinit();

    var iter = doc.table.iterator();
    // iterate through the parse meta infos file and populate the struct
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr;

        const conf_struct = @typeInfo(Config).@"struct";
        inline for (conf_struct.fields) |field| {
            if (!utils.strEql(key, field.name)) {
                comptime continue;
            }

            switch (field.type) {
                bool => @field(self, field.name) = val.bool,
                []const u8 => {
                    const str = try self.alloc.dupe(u8, val.string);
                    @field(self, field.name) = str;
                },
                else => {},
            }
        }
    }
}

/// Returns the path to the config directory
pub fn getConfDirPath(alloc: std.mem.Allocator) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    if (try known_folders.getPath(arena_alloc, .local_configuration)) |conf_home_path| {
        const app_dir_path = try std.fs.path.join(
            arena_alloc,
            &.{ conf_home_path, application_name },
        );

        try getCreateDir(app_dir_path, conf_home_path);

        return alloc.dupe(u8, app_dir_path);
    }

    return "";
}

/// Returns the path to the root directory of the notes.
pub fn getNotesRootDir(self: *Config) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const home_path = known_folders.getPath(arena_alloc, .home) catch |err| {
        return err;
    } orelse return "";

    if (!std.mem.eql(u8, self.@"notes-directory", "")) {
        const needle = "~";
        if (std.mem.startsWith(u8, self.@"notes-directory", needle)) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const input = self.@"notes-directory";
            _ = std.mem.replace(u8, input, needle, home_path, &buf);
            const len = std.mem.replacementSize(u8, input, needle, home_path);
            self.alloc.free(self.@"notes-directory");
            self.@"notes-directory" = try self.alloc.dupe(u8, buf[0..len]);
        }
        return self.@"notes-directory";
    } else {
        const notes_dir_path: []const u8 = try std.mem.concat(
            arena_alloc,
            u8,
            &[_][]const u8{ home_path, "/.", application_name },
        );
        try getCreateDir(notes_dir_path, home_path);
        return notes_dir_path;
    }

    return "";
}

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) !?microwave.Document {
    const file = std.fs.createFileAbsolute(path, .{
        .truncate = false,
        .read = true,
    }) catch |e| {
        std.log.debug("{s} {}", .{ path, e });
        return null;
    };
    defer file.close();

    const stat = try file.stat();
    const buf_size = @max(stat.size, 128);
    const read_buf = try alloc.alloc(u8, buf_size);
    defer alloc.free(read_buf);

    var reader = file.reader(read_buf);
    const doc = microwave.parseFromReader(
        alloc,
        &reader.interface,
    ) catch |err| {
        switch (err) {
            microwave.Parser.Error.InvalidUtf8 => {
                log.err("Failed to parse config file.", .{});
                return err;
            },
            else => return err,
        }
    };

    return doc;
}

fn getCreateDir(dir_path: []const u8, parent: []const u8) !void {
    var parent_dir: std.fs.Dir = try std.fs.openDirAbsolute(parent, .{});

    parent_dir.makePath(dir_path) catch |err| {
        std.log.err("Failed to create config directory: {}", .{err});
        return err;
    };
}

pub fn deinit(self: Config) void {
    self.alloc.free(self.@"notes-directory");
    self.meta_infos.deinit();
    self.alloc.destroy(self.meta_infos);
}
