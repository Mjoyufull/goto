const std = @import("std");

pub fn generateShellHook(allocator: std.mem.Allocator, shell: []const u8) ![]const u8 {
    if (std.mem.eql(u8, shell, "fish")) {
        return std.fmt.allocPrint(
            allocator,
            \\function cd --wraps=cd
            \\    builtin cd $argv
            \\    command goto --record $PWD 2>/dev/null || true
            \\end
        , .{});
    } else if (std.mem.eql(u8, shell, "bash") or std.mem.eql(u8, shell, "zsh")) {
        return std.fmt.allocPrint(
            allocator,
            \\cd() {{
            \\    builtin cd "$@"
            \\    goto --record "$PWD" 2>/dev/null || true
            \\}}
        , .{});
    } else {
        return error.UnsupportedShell;
    }
}

