# goto

Smart directory navigator. Remembers where you go and learns your habits.

Works great with `fend` - they share history so `goto` learns from files you open with `fend`.

## Building

```bash
zig build
```

Binary ends up in `zig-out/bin/goto`.

## Usage

### Navigate to a directory

```bash
goto pro
```

Searches your history first (sorted by frecency - frequency + recency), then falls back to filesystem search. Prints the path to stdout. Use it with your shell:

```bash
cd $(goto pro)
```

Or wrap it in a shell function:

```fish
function goto
    set -l dir (command goto $argv)
    if test -d "$dir"
        cd "$dir"
    end
end
```

### Track cd commands

To make `goto` learn from all your `cd` commands, generate a shell hook:

```bash
goto init fish >> ~/.config/fish/config.fish
goto init bash >> ~/.bashrc
goto init zsh >> ~/.zshrc
```

This wraps `cd` to automatically record directories in history. After sourcing your config, every `cd` updates the history.

### Record a directory manually

```bash
goto --record /some/path
```

Useful if you want to manually add something to history without navigating there.

## How frecency works

Frecency = frequency / (1 + days_since_last_access / 24)

Directories you visit often and recently rank higher. The algorithm balances how many times you've been somewhere with how long it's been since you last visited.

## Priority order

1. Priority directories from config (checked first)
2. History matches (sorted by frecency)
3. Filesystem matches:
   - `.config` directories first
   - Home directories second
   - Other directories last

## Configuration

Config file at `~/.config/goto/config.toml`:

```toml
priority_dirs = ["/home/user/projects", "/home/user/.config"]
remember_history = true
auto_select_threshold = 0.8
```

If multiple matches have the same frecency score, you'll get an interactive menu to pick. If one match is clearly dominant (above the threshold), it auto-selects.

## History

History is shared with `fend` and stored in `~/.local/share/fend/history`. Both tools update the same file, so `goto` learns from files you open with `fend` and vice versa.

