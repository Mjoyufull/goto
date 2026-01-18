const std = @import("std");
const history = @import("history.zig");
const frecency = @import("frecency.zig");
const config = @import("config.zig");

const ScoredPath = struct {
    path: []const u8,
    score: f64,
};

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

    const home = std.posix.getenv("HOME") orelse "";
    
    // First pass: collect basename matches only
    var basename_matches = std.ArrayListUnmanaged(frecency.FrecencyEntry){};
    defer {
        for (basename_matches.items) |entry| {
            allocator.free(entry.path);
        }
        basename_matches.deinit(allocator);
    }
    
    // Second pass: collect path-only matches (only if no basename matches)
    var path_only_matches = std.ArrayListUnmanaged(frecency.FrecencyEntry){};
    defer {
        for (path_only_matches.items) |entry| {
            allocator.free(entry.path);
        }
        path_only_matches.deinit(allocator);
    }
    
    for (hist.entries.items) |entry| {
        const basename = std.fs.path.basename(entry.path);
        const basename_match: bool = std.mem.eql(u8, basename, pattern) or
            std.mem.startsWith(u8, basename, pattern) or
            std.mem.indexOf(u8, basename, pattern) != null;
        const path_match: bool = std.mem.indexOf(u8, entry.path, pattern) != null and !basename_match;
        
        if (basename_match) {
            const frecency_score = frecency.calculateFrecency(entry.access_count, entry.last_accessed, now);
            // Boost score for exact basename matches
            const match_boost: f64 = if (std.mem.eql(u8, basename, pattern))
                1000.0
            else if (std.mem.startsWith(u8, basename, pattern))
                500.0
            else if (basename_match)
                200.0
            else
                50.0; // Path match only
            
            // Penalize longer paths
            var depth: usize = 0;
            for (entry.path) |c| {
                if (c == '/') depth += 1;
            }
            const depth_penalty = @as(f64, @floatFromInt(depth)) * 10.0;
            
            const combined_score = frecency_score + match_boost - depth_penalty;
            
            const path_copy = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(path_copy);
            try basename_matches.append(allocator, frecency.FrecencyEntry{
                .path = path_copy,
                .frecency = combined_score,
                .access_count = entry.access_count,
                .last_accessed = entry.last_accessed,
            });
        } else if (path_match) {
            // Path-only match - heavily penalize
            const frecency_score = frecency.calculateFrecency(entry.access_count, entry.last_accessed, now);
            var depth: usize = 0;
            for (entry.path) |c| {
                if (c == '/') depth += 1;
            }
            const depth_penalty = @as(f64, @floatFromInt(depth)) * 50.0; // Much heavier penalty
            const combined_score = frecency_score - depth_penalty - 500.0; // Heavy penalty for path-only
            
            const path_copy = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(path_copy);
            try path_only_matches.append(allocator, frecency.FrecencyEntry{
                .path = path_copy,
                .frecency = combined_score,
                .access_count = entry.access_count,
                .last_accessed = entry.last_accessed,
            });
        }
    }

    // Sort both lists
    try frecency.sortByFrecency(allocator, basename_matches.items);
    try frecency.sortByFrecency(allocator, path_only_matches.items);
    
    // Combine: basename matches first, then path-only matches (only if no basename matches)
    var combined_history = std.ArrayListUnmanaged(frecency.FrecencyEntry){};
    defer {
        for (combined_history.items) |entry| {
            allocator.free(entry.path);
        }
        combined_history.deinit(allocator);
    }
    
    // Add all basename matches
    for (basename_matches.items) |entry| {
        const path_copy = try allocator.dupe(u8, entry.path);
        try combined_history.append(allocator, frecency.FrecencyEntry{
            .path = path_copy,
            .frecency = entry.frecency,
            .access_count = entry.access_count,
            .last_accessed = entry.last_accessed,
        });
    }
    
    // Only add path-only matches if we have no basename matches
    if (combined_history.items.len == 0) {
        for (path_only_matches.items) |entry| {
            const path_copy = try allocator.dupe(u8, entry.path);
            try combined_history.append(allocator, frecency.FrecencyEntry{
                .path = path_copy,
                .frecency = entry.frecency,
                .access_count = entry.access_count,
                .last_accessed = entry.last_accessed,
            });
        }
    }

    // Add history matches to results
    for (combined_history.items) |entry| {
        const path_copy = try allocator.dupe(u8, entry.path);
        try results.append(allocator, path_copy);
    }

    // Search filesystem if not enough results
    if (results.items.len == 0) {
        try searchFilesystem(allocator, pattern, &results, cfg.exclude);
        // Sort filesystem results by score (home first, then .config, shorter paths preferred)
        try sortFilesystemResults(allocator, &results, pattern);
    } else {
        // Even if we have history results, search filesystem and merge/sort together
        // This ensures filesystem matches with better scores can rank higher
        var filesystem_results = std.ArrayListUnmanaged([]const u8){};
        
        try searchFilesystem(allocator, pattern, &filesystem_results, cfg.exclude);
        try sortFilesystemResults(allocator, &filesystem_results, pattern);
        
        // Merge and re-sort all results together by score
        // mergeAndSortResults takes ownership of filesystem_results items
        try mergeAndSortResults(allocator, &results, &filesystem_results, pattern, home);
        
        // Free any remaining filesystem_results that weren't merged
        for (filesystem_results.items) |item| {
            allocator.free(item);
        }
        filesystem_results.deinit(allocator);
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

    // Search home directory first (shallow, depth 2) - prioritize direct children
    searchInDirectoryWithDepth(allocator, home, pattern, results, exclude, 0, 2) catch {};
    
    // If still no results, search .config (deeper search)
    if (results.items.len == 0) {
        const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        defer allocator.free(config_dir);
        searchInDirectoryWithDepth(allocator, config_dir, pattern, results, exclude, 0, 3) catch {};
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

fn calculatePathScore(path: []const u8, pattern: []const u8, home: []const u8) f64 {
    var score: f64 = 0.0;
    const basename = std.fs.path.basename(path);
    
    // Exact match in basename gets highest score
    if (std.mem.eql(u8, basename, pattern)) {
        score += 1000.0;
    } else if (std.mem.startsWith(u8, basename, pattern)) {
        score += 500.0;
    } else {
        score += 100.0; // Partial match
    }
    
    // Prefer paths in home directory (not .config)
    if (std.mem.startsWith(u8, path, home)) {
        score += 200.0;
        // Penalize .config paths
        if (std.mem.indexOf(u8, path, "/.config/") != null) {
            score -= 150.0;
        }
    }
    
    // Prefer shorter paths (fewer directory separators)
    var depth: usize = 0;
    for (path) |c| {
        if (c == '/') depth += 1;
    }
    score -= @as(f64, @floatFromInt(depth)) * 10.0;
    
    // Prefer paths closer to home root
    if (std.mem.startsWith(u8, path, home)) {
        const relative = path[home.len..];
        var relative_depth: usize = 0;
        for (relative) |c| {
            if (c == '/') relative_depth += 1;
        }
        score -= @as(f64, @floatFromInt(relative_depth)) * 20.0;
    }
    
    return score;
}

fn sortFilesystemResults(
    allocator: std.mem.Allocator,
    results: *std.ArrayListUnmanaged([]const u8),
    pattern: []const u8,
) !void {
    const home = std.posix.getenv("HOME") orelse return;
    
    // Create scored entries
    var scored = std.ArrayListUnmanaged(ScoredPath){};
    errdefer {
        // Only free on error - otherwise ownership transfers to results
        for (scored.items) |entry| {
            allocator.free(entry.path);
        }
        scored.deinit(allocator);
    }
    
    // Calculate scores
    for (results.items) |path| {
        const score = calculatePathScore(path, pattern, home);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        try scored.append(allocator, ScoredPath{
            .path = path_copy,
            .score = score,
        });
    }
    
    // Sort by score (descending)
    const SortContext = struct {
        pub fn lessThan(ctx: @This(), a: ScoredPath, b: ScoredPath) bool {
            _ = ctx;
            return a.score > b.score;
        }
    };
    const sort_ctx = SortContext{};
    std.mem.sort(ScoredPath, scored.items, sort_ctx, SortContext.lessThan);
    
    // Clear and repopulate results with sorted order
    for (results.items) |item| {
        allocator.free(item);
    }
    results.clearRetainingCapacity();
    
    // Transfer ownership from scored to results (don't free in defer)
    for (scored.items) |entry| {
        try results.append(allocator, entry.path);
    }
    // Clear scored without freeing (ownership transferred)
    scored.clearRetainingCapacity();
    scored.deinit(allocator);
}

fn mergeAndSortResults(
    allocator: std.mem.Allocator,
    history_results: *std.ArrayListUnmanaged([]const u8),
    filesystem_results: *std.ArrayListUnmanaged([]const u8),
    pattern: []const u8,
    home: []const u8,
) !void {
    // Combine all results with scores
    var all_scored = std.ArrayListUnmanaged(ScoredPath){};
    errdefer {
        for (all_scored.items) |entry| {
            allocator.free(entry.path);
        }
        all_scored.deinit(allocator);
    }
    
    // Add history results (they already have some priority from frecency)
    for (history_results.items) |path| {
        const score = calculatePathScore(path, pattern, home) + 100.0; // Small boost for history
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        try all_scored.append(allocator, ScoredPath{
            .path = path_copy,
            .score = score,
        });
    }
    
    // Add filesystem results (check for duplicates first)
    for (filesystem_results.items) |path| {
        // Check if already in history_results
        var found = false;
        for (history_results.items) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const score = calculatePathScore(path, pattern, home);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            try all_scored.append(allocator, ScoredPath{
                .path = path_copy,
                .score = score,
            });
        }
    }
    
    // Sort all by score
    const SortContext = struct {
        pub fn lessThan(ctx: @This(), a: ScoredPath, b: ScoredPath) bool {
            _ = ctx;
            return a.score > b.score;
        }
    };
    const sort_ctx = SortContext{};
    std.mem.sort(ScoredPath, all_scored.items, sort_ctx, SortContext.lessThan);
    
    // Free original history_results items
    for (history_results.items) |item| {
        allocator.free(item);
    }
    history_results.clearRetainingCapacity();
    
    // Transfer ownership from all_scored to history_results
    for (all_scored.items) |entry| {
        try history_results.append(allocator, entry.path);
    }
    
    // Clear all_scored without freeing (ownership transferred)
    all_scored.clearRetainingCapacity();
    all_scored.deinit(allocator);
}
