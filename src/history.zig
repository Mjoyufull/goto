const std = @import("std");

pub const HistoryEntry = struct {
    path: []const u8,
    access_count: u64,
    last_accessed: i64,

    pub fn deinit(self: *HistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const History = struct {
    entries: std.ArrayListUnmanaged(HistoryEntry),
    allocator: std.mem.Allocator,
    history_path: []const u8,

    const MagicNumber: u64 = 0x46454E4448495354; // "FENDHIST"
    const Version: u64 = 1;

    pub fn init(allocator: std.mem.Allocator, history_path: []const u8) !History {
        var self = History{
            .entries = std.ArrayListUnmanaged(HistoryEntry){},
            .allocator = allocator,
            .history_path = history_path,
        };
        try self.load();
        return self;
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn load(self: *History) !void {
        const file = std.fs.openFileAbsolute(self.history_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No history file yet, start fresh
                return;
            }
            return err;
        };
        defer file.close();

        // Acquire shared lock for reading
        std.posix.flock(file.handle, std.posix.LOCK.SH) catch {};
        defer std.posix.flock(file.handle, std.posix.LOCK.UN) catch {};

        const file_size = try file.getEndPos();
        if (file_size == 0) {
            // Empty file, start fresh
            return;
        }

        // Read file directly using file.read() instead of reader
        var magic_buf: [8]u8 = undefined;
        const magic_read = try file.read(&magic_buf);
        if (magic_read != 8) return error.UnexpectedEndOfFile;
        const magic = std.mem.readInt(u64, &magic_buf, .little);
        if (magic != MagicNumber) {
            std.log.err("History file corrupted or incompatible. Delete {s} to reset.", .{self.history_path});
            return error.InvalidMagic;
        }

        var version_buf: [8]u8 = undefined;
        const version_read = try file.read(&version_buf);
        if (version_read != 8) return error.UnexpectedEndOfFile;
        const version = std.mem.readInt(u64, &version_buf, .little);
        if (version != Version) {
            return error.InvalidVersion;
        }

        var count_buf: [8]u8 = undefined;
        const count_read = try file.read(&count_buf);
        if (count_read != 8) return error.UnexpectedEndOfFile;
        const entry_count = std.mem.readInt(u64, &count_buf, .little);

        for (0..entry_count) |_| {
            var path_len_buf: [4]u8 = undefined;
            const path_len_read = try file.read(&path_len_buf);
            if (path_len_read != 4) return error.UnexpectedEndOfFile;
            const path_len = std.mem.readInt(u32, &path_len_buf, .little);
            if (path_len == 0 or path_len > 4096) {
                // Sanity check
                return error.InvalidData;
            }
            const path_buf = try self.allocator.alloc(u8, path_len);
            errdefer self.allocator.free(path_buf);
            const path_read = try file.read(path_buf);
            if (path_read != path_len) return error.UnexpectedEndOfFile;

            var access_count_buf: [8]u8 = undefined;
            const access_count_read = try file.read(&access_count_buf);
            if (access_count_read != 8) return error.UnexpectedEndOfFile;
            const access_count = std.mem.readInt(u64, &access_count_buf, .little);

            var last_accessed_buf: [8]u8 = undefined;
            const last_accessed_read = try file.read(&last_accessed_buf);
            if (last_accessed_read != 8) return error.UnexpectedEndOfFile;
            const last_accessed = std.mem.readInt(i64, &last_accessed_buf, .little);

            try self.entries.append(self.allocator, HistoryEntry{
                .path = path_buf,
                .access_count = access_count,
                .last_accessed = last_accessed,
            });
        }
    }

    pub fn save(self: *History) !void {
        // Create directory if it doesn't exist
        const dir_path = std.fs.path.dirname(self.history_path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const file = try std.fs.createFileAbsolute(self.history_path, .{});
        defer file.close();

        // Acquire exclusive lock for writing
        std.posix.flock(file.handle, std.posix.LOCK.EX) catch {};
        defer std.posix.flock(file.handle, std.posix.LOCK.UN) catch {};

        // Write directly using file.write() instead of writer

        var magic_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &magic_buf, MagicNumber, .little);
        _ = try file.write(&magic_buf);

        var version_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &version_buf, Version, .little);
        _ = try file.write(&version_buf);

        var count_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &count_buf, @as(u64, self.entries.items.len), .little);
        _ = try file.write(&count_buf);

        for (self.entries.items) |entry| {
            var path_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &path_len_buf, @as(u32, @intCast(entry.path.len)), .little);
            _ = try file.write(&path_len_buf);
            _ = try file.write(entry.path);

            var access_count_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &access_count_buf, entry.access_count, .little);
            _ = try file.write(&access_count_buf);

            var last_accessed_buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &last_accessed_buf, entry.last_accessed, .little);
            _ = try file.write(&last_accessed_buf);
        }
    }

    pub fn record(self: *History, path: []const u8) !void {
        const now = std.time.timestamp();

        // Find existing entry
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                entry.access_count += 1;
                entry.last_accessed = now;
                try self.save();
                return;
            }
        }

        // New entry
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.entries.append(self.allocator, HistoryEntry{
            .path = path_copy,
            .access_count = 1,
            .last_accessed = now,
        });

        try self.save();
    }

    pub fn getHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        return std.fmt.allocPrint(allocator, "{s}/.local/share/fend/history", .{home});
    }

    pub fn clear(_: std.mem.Allocator, history_path: []const u8) !void {
        // Delete the history file
        std.fs.deleteFileAbsolute(history_path) catch |err| {
            if (err == error.FileNotFound) {
                // File doesn't exist, that's fine
                return;
            }
            return err;
        };
    }
};

