const std = @import("std");
const search = @import("search.zig");
const config = @import("config.zig");
const history = @import("history.zig");
const frecency = @import("frecency.zig");
const init = @import("init.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for help flags
    if (args.len >= 2) {
        const first_arg = args[1];
        if (std.mem.eql(u8, first_arg, "-h") or std.mem.eql(u8, first_arg, "--help")) {
            try printHelp();
            return;
        }
    }

    if (args.len < 2) {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll("Usage: goto <name>\n");
        try stderr.writeAll("       goto init <shell>\n");
        try stderr.writeAll("       goto --record <path>\n");
        try stderr.writeAll("       goto -h|--help\n");
        std.process.exit(1);
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "init")) {
        if (args.len < 3) {
            try std.fs.File.stderr().writeAll("Usage: goto init <shell>\n");
            std.process.exit(1);
        }
        const shell = args[2];
        const hook_code = try init.generateShellHook(allocator, shell);
        defer allocator.free(hook_code);
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(hook_code);
        try stdout.writeAll("\n");
        return;
    }

    if (std.mem.eql(u8, cmd, "--record")) {
        if (args.len < 3) {
            try std.fs.File.stderr().writeAll("Usage: goto --record <path>\n");
            std.process.exit(1);
        }
        const path = args[2];
        const history_path = try history.History.getHistoryPath(allocator);
        defer allocator.free(history_path);
        var hist = try history.History.init(allocator, history_path);
        defer hist.deinit();
        try hist.record(path);
        return;
    }

    // Normal goto command
    var cfg = try config.Config.load(allocator);
    defer cfg.deinit(allocator);

    const history_path = try history.History.getHistoryPath(allocator);
    defer allocator.free(history_path);
    var hist = try history.History.init(allocator, history_path);
    defer hist.deinit();

    const stdout = std.fs.File.stdout();

    // Check priority dirs first
    for (cfg.priority_dirs) |priority_dir| {
        const basename = std.fs.path.basename(priority_dir);
        if (std.mem.indexOf(u8, basename, cmd) != null or
            std.mem.indexOf(u8, priority_dir, cmd) != null)
        {
            try stdout.writeAll(priority_dir);
            try stdout.writeAll("\n");
            try hist.record(priority_dir);
            return;
        }
    }

    // Search history and filesystem
    var results = try search.searchDirectories(allocator, cmd, &hist, &cfg);
    defer {
        for (results.items) |item| {
            allocator.free(item);
        }
        results.deinit(allocator);
    }

    if (results.items.len == 0) {
        try std.fs.File.stderr().writeAll("No matches found\n");
        return;
    }

    if (results.items.len == 1) {
        // Auto-select
        try stdout.writeAll(results.items[0]);
        try stdout.writeAll("\n");
        try hist.record(results.items[0]);
        return;
    }

    // Multiple matches - check if we should auto-select based on threshold
    // For now, just select first match (completion menu can be added later)
    try stdout.writeAll(results.items[0]);
    try stdout.writeAll("\n");
    try hist.record(results.items[0]);
}

fn printHelp() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(
        \\goto - Smart directory navigator with frecency-based history
        \\
        \\USAGE:
        \\    goto <name>                    # Navigate to a directory
        \\    goto init <shell>              # Generate shell hook
        \\    goto --record <path>           # Record a directory in history
        \\    goto -h|--help                 # Show this help message
        \\
        \\COMMANDS:
        \\    <name>                         Search for and navigate to a directory
        \\                                   Searches history first (sorted by frecency),
        \\                                   then falls back to filesystem search
        \\
        \\    init <shell>                   Generate shell hook for fish, bash, or zsh
        \\                                   Wraps 'cd' to automatically record directories
        \\
        \\    --record <path>                Manually add a directory to history
        \\
        \\EXAMPLES:
        \\    goto pro                       # Navigate to a directory matching "pro"
        \\    cd $(goto pro)                # Use with shell (bash/zsh)
        \\    set -l dir (goto pro); cd $dir # Use with fish
        \\    goto init fish                 # Generate fish hook
        \\    goto --record /some/path       # Record a directory
        \\
        \\PRIORITY ORDER:
        \\    1. Priority directories from config
        \\    2. History matches (sorted by frecency)
        \\    3. Filesystem matches (.config, home, etc.)
        \\
        \\CONFIGURATION:
        \\    Config file: ~/.config/goto/config.toml
        \\    History: ~/.local/share/fend/history (shared with fend)
        \\
    );
}
