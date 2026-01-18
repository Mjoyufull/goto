const std = @import("std");
const history = @import("history.zig");
const frecency = @import("frecency.zig");
const config = @import("config.zig");

pub fn searchDirectories(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    hist: *history.History,
    cfg: *const config.Config,
) !std.ArrayListUnmanaged([]const u8) {
    var results = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (results.items) |item| {
            allocator.free(item);
        }
        results.deinit(allocator);
    }

    const now = std.time.timestamp();

    // Search history first
    var history_matches = std.ArrayListUnmanaged(frecency.FrecencyEntry){};
    defer {
        for (history_matches.items) |entry| {
            allocator.free(entry.path);
        }
        history_matches.deinit(allocator);
    }

    for (hist.entries.items) |entry| {
        const basename = std.fs.path.basename(entry.path);
        if (std.mem.indexOf(u8, basename, pattern) != null or
            std.mem.indexOf(u8, entry.path, pattern) != null)
        {
            const score = frecency.calculateFrecency(entry.access_count, entry.last_accessed, now);
            const path_copy = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(path_copy);
            try history_matches.append(allocator, frecency.FrecencyEntry{
                .path = path_copy,
                .frecency = score,
                .access_count = entry.access_count,
                .last_accessed = entry.last_accessed,
            });
        }
    }

    // Sort by frecency
    try frecency.sortByFrecency(allocator, history_matches.items);

    // Add history matches to results
    for (history_matches.items) |entry| {
        const path_copy = try allocator.dupe(u8, entry.path);
        try results.append(allocator, path_copy);
    }

    // Search filesystem if not enough results
    if (results.items.len == 0) {
        try searchFilesystem(allocator, pattern, &results, cfg.exclude);
    }

    return results;
}

fn searchFilesystem(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
    exclude: []const []const u8,
) !void {
    const home = std.posix.getenv("HOME") orelse return;

    // First, check common project directories for exact matches
    const projects_dir = try std.fmt.allocPrint(allocator, "{s}/projects", .{home});
    defer allocator.free(projects_dir);
    
    // Search projects directory first (shallow, depth 1) if it exists
    searchInDirectoryWithDepth(allocator, projects_dir, pattern, results, exclude, 0, 1) catch {};
    // If we found results, return early
    if (results.items.len > 0) return;

    // Then search home directory (shallow, depth 2)
    searchInDirectoryWithDepth(allocator, home, pattern, results, exclude, 0, 2) catch {};
    
    // If still no results, search .config (but with lower priority)
    if (results.items.len == 0) {
        const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        defer allocator.free(config_dir);
        searchInDirectory(allocator, config_dir, pattern, results, exclude) catch {};
    }

    // Skip root search to avoid permission issues and long searches
}

fn searchInDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    pattern: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
    exclude: []const []const u8,
) !void {
    searchInDirectoryWithDepth(allocator, dir_path, pattern, results, exclude, 0, 3) catch {};
}

fn searchInDirectoryWithDepth(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    pattern: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
    exclude: []const []const u8,
    depth: usize,
    max_depth: usize,
) !void {
    // Limit depth to prevent deep recursion
    if (depth > max_depth) return;
    
    // Limit results to prevent excessive searching
    if (results.items.len >= 20) return;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        // Limit results
        if (results.items.len >= 20) break;
        
        if (entry.kind != .directory) continue;

        const basename = entry.name;

        // Check exclusion patterns from config
        var should_exclude = false;
        for (exclude) |excl| {
            if (std.mem.eql(u8, basename, excl)) {
                should_exclude = true;
                break;
            }
        }
        if (should_exclude) continue;

        if (std.mem.indexOf(u8, basename, pattern) != null) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, basename });

            // Check if already in results
            var found = false;
            for (results.items) |existing| {
                if (std.mem.eql(u8, existing, full_path)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Use full_path directly instead of duplicating
                try results.append(allocator, full_path);
            } else {
                // Free full_path since we're not using it
                allocator.free(full_path);
            }
        }

        // Recursively search subdirectories
        const subdir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, basename });
        defer allocator.free(subdir_path);
        try searchInDirectoryWithDepth(allocator, subdir_path, pattern, results, exclude, depth + 1, max_depth);
    }
}

