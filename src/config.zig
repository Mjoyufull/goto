const std = @import("std");

pub const Config = struct {
    priority_dirs: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{ "node_modules", ".git", "target", "build", ".cache" },
    remember_history: bool = true,
    auto_select_threshold: f64 = 0.8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/goto/config.toml", .{home});
        defer allocator.free(config_path);

        _ = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return Config{};
            }
            return err;
        };

        // TODO: Parse TOML
        return Config{};
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

