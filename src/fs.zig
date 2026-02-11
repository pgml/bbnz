const std = @import("std");
const Walker = std.fs.Dir.Walker;

const Config = @import("Config.zig");

pub const Directories = struct {
    pub const Entry = struct {
        basename: []const u8 = "",
        path: []const u8 = "",
        num_files: usize = 0,
        num_dirs: usize = 0,
    };

    pub fn list(alloc: std.mem.Allocator, path: []const u8) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(alloc);

        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();

        while (try iter.next()) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) {
                continue;
            }

            const dir_path = try std.fs.path.join(alloc, &.{ path, entry.name });
            defer alloc.free(dir_path);

            try entries.append(alloc, .{
                .basename = try alloc.dupe(u8, entry.name),
                .path = try alloc.dupe(u8, dir_path),
                .num_files = try getChildCount(dir_path, .file),
                .num_dirs = try getChildCount(dir_path, .directory),
            });
        }

        const owned = try entries.toOwnedSlice(alloc);
        return owned;
    }

    pub fn getChildCount(path: []const u8, kind: std.fs.File.Kind) !usize {
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        var count: usize = 0;

        while (try iter.next()) |entry| {
            if (entry.kind != kind) {
                continue;
            }
            count += 1;
        }

        return count;
    }

    pub fn create(
        alloc: std.mem.Allocator,
        dir_path: []const u8,
        dir_name: []const u8,
    ) !?[]const u8 {
        if (try makePath(alloc, dir_path, dir_name)) |new_path| {
            try std.fs.makeDirAbsolute(new_path);
            return new_path;
        }
        return null;
    }

    /// Attempts to rename the given directory in `old_path` to `new_name`.
    /// Returns the new path on success, null on failure.
    pub fn rename(
        alloc: std.mem.Allocator,
        old_path: []const u8,
        new_name: []const u8,
    ) !?[]const u8 {
        var dir = try std.fs.openDirAbsolute(old_path, .{ .access_sub_paths = false });
        defer dir.close();

        if ((try dir.stat()).kind != .directory) {
            return null;
        }

        if (try makePath(alloc, old_path, new_name)) |new_path| {
            try std.fs.renameAbsolute(old_path, new_path);
            return new_path;
        }

        return null;
    }
};

pub const Notes = struct {
    pub const Entry = struct {
        name: []const u8,
        path: []const u8,
    };

    pub fn list(alloc: std.mem.Allocator, path: []const u8) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(alloc);

        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();

        while (try iter.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }

            const dir_path = try std.fs.path.join(alloc, &.{ path, entry.name });
            defer alloc.free(dir_path);

            try entries.append(alloc, .{
                .name = try alloc.dupe(u8, entry.name),
                .path = try alloc.dupe(u8, dir_path),
            });
        }

        const owned = try entries.toOwnedSlice(alloc);
        return owned;
    }

    pub fn create(
        alloc: std.mem.Allocator,
        dir_path: []const u8,
        note_name: []const u8,
    ) ![]const u8 {
        const path = try std.fs.path.join(alloc, &[_][]const u8{ dir_path, note_name });
        _ = try std.fs.createFileAbsolute(path, .{});
        return path;
    }

    /// Attempts to rename the given file in `old_path` to `new_name`.
    /// Returns the new path on success, null on failure.
    pub fn rename(
        alloc: std.mem.Allocator,
        old_path: []const u8,
        new_name: []const u8,
    ) !?[]const u8 {
        const file = try std.fs.openFileAbsolute(old_path, .{ .mode = .read_only });
        defer file.close();

        if ((try file.stat()).kind != .file) {
            return null;
        }

        if (try makePath(alloc, old_path, new_name)) |new_path| {
            try std.fs.renameAbsolute(old_path, new_path);
            return new_path;
        }
        return null;
    }
};

fn makePath(
    alloc: std.mem.Allocator,
    old_path: []const u8,
    name: []const u8,
) !?[]const u8 {
    // get the parent of the directory to build the new path
    const path = std.fs.path.dirname(old_path) orelse return null;
    return try std.fmt.allocPrint(alloc, "{s}/{s}", .{
        path,
        name,
    });
}
