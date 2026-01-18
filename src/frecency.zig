const std = @import("std");

pub fn calculateFrecency(access_count: u64, last_accessed: i64, now: i64) f64 {
    const hours_since = @as(f64, @floatFromInt(now - last_accessed)) / 3600.0;
    const days_since = hours_since / 24.0;
    return @as(f64, @floatFromInt(access_count)) / (1.0 + days_since);
}

pub const FrecencyEntry = struct {
    path: []const u8,
    frecency: f64,
    access_count: u64,
    last_accessed: i64,

    pub fn lessThan(ctx: void, a: FrecencyEntry, b: FrecencyEntry) bool {
        _ = ctx;
        return a.frecency > b.frecency; // Sort descending
    }
};

pub fn sortByFrecency(_: std.mem.Allocator, entries: []FrecencyEntry) !void {
    std.mem.sort(FrecencyEntry, entries, {}, FrecencyEntry.lessThan);
}

