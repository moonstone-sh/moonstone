const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const CompletionsCommand = struct {
    pub const name = "completions";
    pub const description = "Generate shell completion scripts";

    positionals: []const []const u8 = &.{},
    complete: ?[]const u8 = null, // Raw string to complete, e.g. "moon add "
    shell: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon completions [shell] [flags]
            \\
            \\Generate shell completion scripts or provide dynamic completions.
            \\
            \\Arguments:
            \\  [shell]            Target shell: bash, zsh, fish, sh
            \\
            \\Flags:
            \\  --shell <name>     Target shell (alternative to positional arg)
            \\  --complete <cmd>   Return completions for the given command string
            \\
        , .{});
    }

    pub fn run(self: CompletionsCommand, ctx: *router.Context) !void {
        if (self.complete) |cmd_line| {
            return self.handleDynamic(ctx, cmd_line);
        }

        const shell_name = blk: {
            if (self.shell) |s| break :blk s;
            if (self.positionals.len > 0) break :blk self.positionals[0];
            
            // Try to infer from $SHELL
            if (ctx.env.get("SHELL")) |shell_path| {
                const base = std.fs.path.basename(shell_path);
                if (std.mem.eql(u8, base, "zsh")) break :blk "zsh";
                if (std.mem.eql(u8, base, "bash")) break :blk "bash";
                if (std.mem.eql(u8, base, "fish")) break :blk "fish";
                if (std.mem.eql(u8, base, "sh")) break :blk "sh";
            }

            // Fallback to error
            ctx.error_detail = .{ .missing_argument = .{ .flag = "shell" } };
            return error.MissingArgument;
        };

        if (std.mem.eql(u8, shell_name, "zsh")) {
            try self.generateZsh(ctx);
        } else if (std.mem.eql(u8, shell_name, "bash")) {
            try self.generateBash(ctx);
        } else if (std.mem.eql(u8, shell_name, "fish")) {
            try self.generateFish(ctx);
        } else {
            // reportError will be called by router.zig
            return error.InvalidShell;
        }
    }

    fn handleDynamic(self: CompletionsCommand, ctx: *router.Context, cmd_line: []const u8) !void {
        _ = self;
        var args_list = std.ArrayList([]const u8).empty;
        defer args_list.deinit(ctx.allocator);

        var it = std.mem.splitScalar(u8, cmd_line, ' ');
        // Skip the first word (the executable)
        _ = it.next();

        while (it.next()) |arg| {
            if (arg.len > 0) {
                try args_list.append(ctx.allocator, arg);
            }
        }

        // If the command line ends in a space, it means we are starting a new argument
        if (cmd_line.len > 0 and cmd_line[cmd_line.len - 1] == ' ') {
            try args_list.append(ctx.allocator, "");
        }

        const suggestions = try router.complete(ctx.root.?, args_list.items, ctx);
        for (suggestions) |s| {
            try ctx.stdout.print("{s}\n", .{s});
        }
    }

    fn generateZsh(self: CompletionsCommand, ctx: *router.Context) !void {
        _ = self;
        try ctx.stdout.print(
            \\_moon() {{
            \\  local cmd="$words[1]"
            \\  local -a commands
            \\  commands=(
            \\
        , .{});

        for (ctx.root.?.subcommands) |sub| {
            try ctx.stdout.print("    '{s}:{s}'\n", .{ sub.name, sub.description });
        }

        try ctx.stdout.print(
            \\  )
            \\  if (( CURRENT == 2 )); then
            \\    _describe -t commands "moon command" commands
            \\  else
            \\    local -a comps
            \\    comps=($($cmd completions --complete "$BUFFER"))
            \\    if (( ${{#comps}} > 0 )); then
            \\        _values 'completions' $comps
            \\    fi
            \\  fi
            \\}}
            \\compdef _moon moon
            \\
        , .{});
    }

    fn generateBash(self: CompletionsCommand, ctx: *router.Context) !void {
        _ = self;
        try ctx.stdout.print(
            \\_moon_completions() {{
            \\  local cur="${{COMP_WORDS[COMP_CWORD]}}"
            \\  local cmd="${{COMP_WORDS[0]}}"
            \\  local completions
            \\  completions="$($cmd completions --complete "$COMP_LINE" 2>/dev/null)"
            \\  COMPREPLY=( $(compgen -W "$completions" -- "$cur") )
            \\}}
            \\complete -F _moon_completions moon
            \\
        , .{});
    }

    fn generateFish(self: CompletionsCommand, ctx: *router.Context) !void {
        _ = self;
        try ctx.stdout.print("complete -c moon -f\n", .{});

        for (ctx.root.?.subcommands) |sub| {
            try ctx.stdout.print("complete -c moon -n \"__fish_use_subcommand\" -a {s} -d \"{s}\"\n", .{ sub.name, sub.description });
            
            if (sub.subcommands.len > 0) {
                for (sub.subcommands) |nested| {
                    try ctx.stdout.print("complete -c moon -n \"__fish_seen_subcommand_from {s}\" -a {s} -d \"{s}\"\n", .{ sub.name, nested.name, nested.description });
                }
            }
        }

        try ctx.stdout.print("\n# Dynamic completions\n", .{});
        for (ctx.root.?.subcommands) |sub| {
            if (sub.complete_fn != null or sub.subcommands.len > 0) {
                try ctx.stdout.print("complete -c moon -n \"__fish_seen_subcommand_from {s}\" -a \"(moon completions --complete (commandline -cp))\"\n", .{sub.name});
            }
        }
    }
};
