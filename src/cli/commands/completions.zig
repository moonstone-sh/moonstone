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
            \\_moon_opaque_boundary() {{
            \\  local -a w
            \\  w=("${{words[@]:1}}")
            \\  local n=$#w
            \\  local i=1
            \\  local need=0
            \\
            \\  if [[ "${{w[1]:-}}" == "exec" ]]; then
            \\    i=2; need=1
            \\  elif [[ "${{w[1]:-}}" == "orbit" && "${{w[2]:-}}" == "exec" ]]; then
            \\    i=3; need=2
            \\  elif [[ "${{w[1]:-}}" == "orbit" && "${{w[2]:-}}" == "run" ]]; then
            \\    i=3; need=2
            \\  else
            \\    return 1
            \\  fi
            \\
            \\  local dashdash=0
            \\  while (( i <= n )); do
            \\    local wd="${{w[$i]}}"
            \\    if [[ "$wd" == "--" && $dashdash -eq 0 ]]; then
            \\      dashdash=1; (( i++ )); continue
            \\    fi
            \\    if (( need == 1 )) && [[ "$wd" == --* ]] && (( dashdash == 0 )); then
            \\      if [[ "$wd" == "--interpreter" ]]; then (( i += 2 )); else (( i++ )); fi
            \\      continue
            \\    fi
            \\    break
            \\  done
            \\
            \\  local consumed=0
            \\  while (( consumed < need - 1 && i <= n )); do
            \\    (( i++ )); (( consumed++ ))
            \\  done
            \\
            \\  reply=($((i + 1)))
            \\  return 0
            \\}}
            \\
            \\_moon() {{
            \\  local name_index
            \\  if _moon_opaque_boundary; then
            \\    name_index=$reply[1]
            \\    if (( CURRENT > name_index )); then
            \\      shift $((name_index - 1)) words
            \\      (( CURRENT -= name_index - 1 ))
            \\      local PATH="$(moon env --paths 2>/dev/null):$PATH"
            \\
            \\      local delegate="$words[1]"
            \\      if (( ! $+_comps[$delegate] )); then
            \\        local delegate_path
            \\        delegate_path="$(command -v -- "$delegate" 2>/dev/null)"
            \\        if [[ -n "$delegate_path" ]]; then
            \\          local script
            \\          script="$("$delegate_path" --__moonstone-complete-script zsh "$delegate" 2>/dev/null)"
            \\          if [[ -n "$script" ]]; then
            \\            eval "$script"
            \\          fi
            \\        fi
            \\      fi
            \\
            \\      _normal -p moon
            \\      return
            \\    elif (( CURRENT == name_index )); then
            \\      local PATH="$(moon env --paths 2>/dev/null):$PATH"
            \\      _command_names
            \\      return
            \\    fi
            \\  fi
            \\
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
            \\    if compset -P '*:'; then
            \\        comps=(${{comps#*:}})
            \\    fi
            \\    if (( ${{#comps}} > 0 )); then
            \\        compadd -a comps
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
            \\_moon_opaque_boundary() {{
            \\  local words=("${{COMP_WORDS[@]:1}}")   # drop "moon"
            \\  local n=${{#words[@]}}
            \\  local i=0
            \\  local need=0
            \\
            \\  if [[ "${{words[0]:-}}" == "exec" ]]; then
            \\    i=1; need=1
            \\  elif [[ "${{words[0]:-}}" == "orbit" && "${{words[1]:-}}" == "exec" ]]; then
            \\    i=2; need=2
            \\  elif [[ "${{words[0]:-}}" == "orbit" && "${{words[1]:-}}" == "run" ]]; then
            \\    i=2; need=2
            \\  else
            \\    return 1
            \\  fi
            \\
            \\  local dashdash_seen=0
            \\  while (( i < n )); do
            \\    local w="${{words[$i]}}"
            \\    if [[ "$w" == "--" && $dashdash_seen -eq 0 ]]; then
            \\      dashdash_seen=1; i=$((i+1)); continue
            \\    fi
            \\    if (( need == 1 )) && [[ "$w" == --* ]] && [[ $dashdash_seen -eq 0 ]]; then
            \\      if [[ "$w" == "--interpreter" ]]; then i=$((i+2)); else i=$((i+1)); fi
            \\      continue
            \\    fi
            \\    break
            \\  done
            \\
            \\  local consumed=0
            \\  while (( consumed < need - 1 && i < n )); do
            \\    i=$((i+1)); consumed=$((consumed+1))
            \\  done
            \\
            \\  MOON_NAME_INDEX=$((i+1))
            \\  return 0
            \\}}
            \\
            \\_moon_completions() {{
            \\  local cur prev words cword
            \\  if type _get_comp_words_by_ref &>/dev/null; then
            \\      _get_comp_words_by_ref -n : cur prev words cword
            \\  else
            \\      cur="${{COMP_WORDS[COMP_CWORD]}}"
            \\  fi
            \\
            \\  if _moon_opaque_boundary; then
            \\    if (( COMP_CWORD > MOON_NAME_INDEX )); then
            \\      local delegate="${{COMP_WORDS[$MOON_NAME_INDEX]}}"
            \\      local offset=$MOON_NAME_INDEX
            \\
            \\      local saved_path="$PATH"
            \\      PATH="$(moon env --paths 2>/dev/null):$PATH"
            \\
            \\      local saved_words=("${{COMP_WORDS[@]}}")
            \\      local saved_cword=$COMP_CWORD
            \\      local saved_line="$COMP_LINE"
            \\      local saved_point=$COMP_POINT
            \\
            \\      COMP_WORDS=("${{saved_words[@]:$offset}}")
            \\      COMP_CWORD=$(( saved_cword - offset ))
            \\      COMP_LINE="${{COMP_WORDS[*]}}"
            \\      if [[ "${{saved_line: -1}}" == " " ]] && (( saved_cword == ${{#saved_words[@]}} - 1 )); then
            \\        COMP_LINE+=" "
            \\      fi
            \\      COMP_POINT=${{#COMP_LINE}}
            \\
            \\      local delegate_fn
            \\      delegate_fn=$(complete -p "$delegate" 2>/dev/null | sed -n 's/.*-F \([^ ]*\).*/\1/p')
            \\
            \\      if [[ -z "$delegate_fn" ]]; then
            \\        local delegate_path
            \\        delegate_path=$(command -v -- "$delegate" 2>/dev/null)
            \\        if [[ -n "$delegate_path" ]]; then
            \\          local script
            \\          script=$("$delegate_path" --__moonstone-complete-script bash "$delegate" 2>/dev/null)
            \\          if [[ -n "$script" ]]; then
            \\            eval "$script"
            \\            delegate_fn=$(complete -p "$delegate" 2>/dev/null | sed -n 's/.*-F \([^ ]*\).*/\1/p')
            \\          fi
            \\        fi
            \\      fi
            \\
            \\      if [[ -n "$delegate_fn" ]]; then
            \\        "$delegate_fn"
            \\      else
            \\        COMPREPLY=( $(compgen -c -- "${{COMP_WORDS[COMP_CWORD]}}") )
            \\      fi
            \\
            \\      PATH="$saved_path"
            \\      COMP_WORDS=("${{saved_words[@]}}")
            \\      COMP_CWORD=$saved_cword
            \\      COMP_LINE="$saved_line"
            \\      COMP_POINT=$saved_point
            \\      return
            \\    elif (( COMP_CWORD == MOON_NAME_INDEX )); then
            \\      local extra_path
            \\      extra_path="$(moon env --paths 2>/dev/null)"
            \\      COMPREPLY=( $(PATH="${{extra_path}}:${{PATH}}" compgen -c -- "$cur") )
            \\      return
            \\    fi
            \\  fi
            \\
            \\  local cmd="${{COMP_WORDS[0]}}"
            \\  local completions
            \\  completions="$($cmd completions --complete "$COMP_LINE" 2>/dev/null)"
            \\  COMPREPLY=( $(compgen -W "$completions" -- "$cur") )
            \\  if type __ltrim_colon_completions &>/dev/null; then
            \\      __ltrim_colon_completions "$cur"
            \\  fi
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

        try ctx.stdout.print(
            \\
            \\# UNVERIFIED: fish is not available in the environment this was written in
            \\# to test against a live session. Written from documented fish semantics
            \\# (commandline -opc/-ct, complete -C) rather than exercised interactively --
            \\# treat this as a design, not a shipped guarantee, until someone runs it.
            \\
            \\function __moon_boundary --description 'index (1-based, toks[1]=="moon") of the delegated command-name token, or nothing if this isn\'t an exec/orbit-exec/orbit-run line'
            \\    set -l toks (commandline -opc)
            \\    set -l n (count $toks)
            \\    set -l i 2
            \\    set -l need 0
            \\
            \\    if test $n -ge 2 -a "$toks[2]" = exec
            \\        set i 3; set need 1
            \\    else if test $n -ge 3 -a "$toks[2]" = orbit -a "$toks[3]" = exec
            \\        set i 4; set need 2
            \\    else if test $n -ge 3 -a "$toks[2]" = orbit -a "$toks[3]" = run
            \\        set i 4; set need 2
            \\    else
            \\        return 1
            \\    end
            \\
            \\    set -l dashdash 0
            \\    while test $i -le $n
            \\        set -l w $toks[$i]
            \\        if test "$w" = -- -a $dashdash -eq 0
            \\            set dashdash 1
            \\            set i (math $i + 1)
            \\            continue
            \\        end
            \\        if test $need -eq 1 -a $dashdash -eq 0 && string match -q -- '--*' $w
            \\            if test "$w" = --interpreter
            \\                set i (math $i + 2)
            \\            else
            \\                set i (math $i + 1)
            \\            end
            \\            continue
            \\        end
            \\        break
            \\    end
            \\
            \\    set -l consumed 0
            \\    while test $consumed -lt (math $need - 1) -a $i -le $n
            \\        set i (math $i + 1)
            \\        set consumed (math $consumed + 1)
            \\    end
            \\
            \\    echo $i
            \\    return 0
            \\end
            \\
            \\function __moon_env_path
            \\    moon env --paths 2>/dev/null
            \\end
            \\
            \\function __moon_choosing_command --description 'true while the CURRENT token being typed is the delegate command-name slot itself'
            \\    set -l boundary (__moon_boundary)
            \\    test -n "$boundary"; or return 1
            \\    set -l toks (commandline -opc)
            \\    test (count $toks) -eq (math $boundary - 1)
            \\end
            \\
            \\function __moon_past_command --description 'true once a delegate command name has been fully typed and we\'re completing ITS arguments'
            \\    set -l boundary (__moon_boundary)
            \\    test -n "$boundary"; or return 1
            \\    set -l toks (commandline -opc)
            \\    test (count $toks) -ge $boundary
            \\end
            \\
            \\function __moon_delegate_complete --description 'ask fish for completions of the shifted line, as if the delegate had been typed directly'
            \\    set -l boundary (__moon_boundary)
            \\    set -l toks (commandline -opc)
            \\    set -l delegate $toks[$boundary]
            \\    set -lx PATH (__moon_env_path) $PATH
            \\
            \\    if test -z "$(complete -c $delegate)"
            \\        set -l delegate_path (command -v -- $delegate 2>/dev/null)
            \\        if test -n "$delegate_path"
            \\            set -l script ("$delegate_path" --__moonstone-complete-script fish $delegate 2>/dev/null)
            \\            if test -n "$script"
            \\                eval $script
            \\            end
            \\        end
            \\    end
            \\
            \\    set -l shifted $toks[$boundary..-1] (commandline -ct)
            \\    complete -C(string join ' ' -- $shifted)
            \\end
            \\
            \\# Completing the bare command name: every executable on the ambient PATH
            \\# plus whatever this moon environment additionally materializes.
            \\complete -c moon -n __moon_choosing_command -x -a '(set -lx PATH (__moon_env_path) $PATH; __fish_complete_command)'
            \\
            \\# Past the command name: delegate to fish's own completion for it,
            \\# verbatim, exactly like plain env/nice/time wrapping does.
            \\complete -c moon -n __moon_past_command -x -a '(__moon_delegate_complete)'
            \\
        , .{});
    }
};
