const Config = @This();

const std = @import("std");
const known_folders = @import("known-folders");

var arena: std.heap.ArenaAllocator = undefined;

var alloc: std.mem.Allocator = undefined;

pub const application_name = "bellbird-notes-dev";

pub fn init(allocator: std.mem.Allocator) !void {
    arena = std.heap.ArenaAllocator.init(allocator);
    alloc = arena.allocator();
}

pub fn getConfDirPath() ![]const u8 {
    if (try known_folders.getPath(alloc, .local_configuration)) |conf_home_path| {
        const app_dir_path: []const u8 = try std.mem.concat(alloc, u8, &[_][]const u8{
            conf_home_path,
            "/",
            application_name,
        });

        try getCreateDir(app_dir_path, conf_home_path);
        return app_dir_path;
    }

    return "";
}

pub fn getNotesRootDir() ![]const u8 {
    if (try known_folders.getPath(alloc, .home)) |home_path| {
        const notes_dir_path: []const u8 = try std.mem.concat(alloc, u8, &[_][]const u8{
            home_path,
            "/.",
            application_name,
        });

        try getCreateDir(notes_dir_path, home_path);

        return notes_dir_path;
    }

    return "";
}

fn getCreateDir(dir_path: []const u8, parent: []const u8) !void {
    var parent_dir: std.fs.Dir = try std.fs.openDirAbsolute(parent, .{});

    parent_dir.makePath(dir_path) catch |err| {
        std.log.err("Failed to create config directory: {}", .{err});
        return err;
    };
}

pub fn deinit() void {
    arena.deinit();
}
