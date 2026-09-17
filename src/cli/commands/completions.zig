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
            \\  local n=$#words
            \\  local i
            \\
            \\  if [[ "${{words[2]:-}}" == "exec" ]]; then
            \\    i=3
            \\  elif [[ "${{words[2]:-}}" == "orbit" && "${{words[3]:-}}" == "exec" ]]; then
            \\    i=4
            \\  elif [[ "${{words[2]:-}}" == "orbit" && "${{words[3]:-}}" == "run" ]]; then
            \\    i=4
            \\  else
            \\    return 1
            \\  fi
            \\
            \\  # '--' is now mandatory and single-purpose (see exec.zig/
            \\  # orbit_exec.zig/orbit_run.zig's printHelp): the boundary is simply
            \\  # the first literal '--' after the recognized subcommand shape. No
            \\  # positional counting or --interpreter-consumes-two-tokens special
            \\  # case is needed any more -- that machinery only ever existed to
            \\  # avoid miscounting positions before an *implicit* boundary.
            \\  local is_global=0
            \\  local dashdash=0
            \\  local j=$i
            \\  while (( j <= n )); do
            \\    [[ "${{words[$j]}}" == "--global" ]] && is_global=1
            \\    if [[ "${{words[$j]}}" == "--" ]]; then
            \\      dashdash=$j
            \\      break
            \\    fi
            \\    (( j++ ))
            \\  done
            \\
            \\  # No '--' typed yet: under the mandatory-'--' grammar there is no
            \\  # delegate command-name slot to complete yet -- fall through to
            \\  # moon's own normal flag/subcommand completion instead of guessing.
            \\  (( dashdash == 0 )) && return 1
            \\
            \\  reply=($((dashdash + 1)) $is_global)
            \\  return 0
            \\}}
            \\
            \\_moon() {{
            \\  local name_index is_global
            \\  if _moon_opaque_boundary; then
            \\    name_index=$reply[1]
            \\    is_global=$reply[2]
            \\    local -a global_flag
            \\    (( is_global )) && global_flag=(--global)
            \\
            \\    if (( CURRENT > name_index )); then
            \\      shift $((name_index - 1)) words
            \\      (( CURRENT -= name_index - 1 ))
            \\      local PATH="$(moon env --paths ${{global_flag[@]}} 2>/dev/null):$PATH"
            \\
            \\      local delegate="$words[1]"
            \\      if (( ! $+_comps[$delegate] )); then
            \\        local delegate_path
            \\        delegate_path="$(moon provision resolve --json ${{global_flag[@]}} -- "$delegate" 2>/dev/null | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
            \\        if [[ -z "$delegate_path" ]]; then
            \\          delegate_path="$(command -v -- "$delegate" 2>/dev/null)"
            \\        fi
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
            \\      local PATH="$(moon env --paths ${{global_flag[@]}} 2>/dev/null):$PATH"
            \\      local -a bin_runtime_names
            \\      bin_runtime_names=(${{(f)"$(moon env --bin-runtime-names ${{global_flag[@]}} 2>/dev/null)"}})
            \\      _command_names
            \\      (( $#bin_runtime_names )) && compadd -a bin_runtime_names
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
            \\  local n=${{#COMP_WORDS[@]}}
            \\  local i
            \\
            \\  if [[ "${{COMP_WORDS[1]:-}}" == "exec" ]]; then
            \\    i=2
            \\  elif [[ "${{COMP_WORDS[1]:-}}" == "orbit" && "${{COMP_WORDS[2]:-}}" == "exec" ]]; then
            \\    i=3
            \\  elif [[ "${{COMP_WORDS[1]:-}}" == "orbit" && "${{COMP_WORDS[2]:-}}" == "run" ]]; then
            \\    i=3
            \\  else
            \\    return 1
            \\  fi
            \\
            \\  # '--' is now mandatory and single-purpose (see exec.zig/
            \\  # orbit_exec.zig/orbit_run.zig's printHelp): the boundary is simply
            \\  # the first literal '--' after the recognized subcommand shape. No
            \\  # positional counting or --interpreter-consumes-two-tokens special
            \\  # case is needed any more -- that machinery only ever existed to
            \\  # avoid miscounting positions before an *implicit* boundary.
            \\  MOON_BOUNDARY_GLOBAL=0
            \\  local dashdash=-1
            \\  local j=$i
            \\  while (( j < n )); do
            \\    [[ "${{COMP_WORDS[$j]}}" == "--global" ]] && MOON_BOUNDARY_GLOBAL=1
            \\    if [[ "${{COMP_WORDS[$j]}}" == "--" ]]; then
            \\      dashdash=$j
            \\      break
            \\    fi
            \\    j=$((j+1))
            \\  done
            \\
            \\  # No '--' typed yet: under the mandatory-'--' grammar there is no
            \\  # delegate command-name slot to complete yet -- fall through to
            \\  # moon's own normal flag/subcommand completion instead of guessing.
            \\  if (( dashdash < 0 )); then
            \\    return 1
            \\  fi
            \\
            \\  MOON_NAME_INDEX=$((dashdash + 1))
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
            \\    # A plain scalar, not an array: on bash 3.2 (macOS's default, and
            \\    # this harness runs under `set -u`), referencing "${{arr[@]}}" on an
            \\    # array declared empty via arr=() raises "unbound variable" -- a
            \\    # long-fixed bug (4.4+) that macOS's stock bash still has. A scalar
            \\    # that is either empty or exactly "--global" sidesteps it entirely;
            \\    # unquoted below, it word-splits into zero or one argument.
            \\    local global_flag=""
            \\    (( MOON_BOUNDARY_GLOBAL )) && global_flag="--global"
            \\
            \\    if (( COMP_CWORD > MOON_NAME_INDEX )); then
            \\      local delegate="${{COMP_WORDS[$MOON_NAME_INDEX]}}"
            \\      local offset=$MOON_NAME_INDEX
            \\
            \\      local saved_path="$PATH"
            \\      PATH="$(moon env --paths $global_flag 2>/dev/null):$PATH"
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
            \\        delegate_path=$(moon provision resolve --json $global_flag -- "$delegate" 2>/dev/null | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')
            \\        if [[ -z "$delegate_path" ]]; then
            \\          delegate_path=$(command -v -- "$delegate" 2>/dev/null)
            \\        fi
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
            \\      extra_path="$(moon env --paths $global_flag 2>/dev/null)"
            \\      local bin_runtime_names
            \\      bin_runtime_names="$(moon env --bin-runtime-names $global_flag 2>/dev/null)"
            \\      local -a raw_candidates
            \\      raw_candidates=( $(PATH="${{extra_path}}:${{PATH}}" compgen -c -- "$cur") $(compgen -W "$bin_runtime_names" -- "$cur") )
            \\      COMPREPLY=( $(printf '%s\n' "${{raw_candidates[@]}}" | sort -u) )
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
            \\# UNVERIFIED: written from documented fish semantics (commandline
            \\# -opc/-ct, complete -C, string match -r/-g) rather than exercised
            \\# against a live interactive session -- treat this as a design, not a
            \\# shipped guarantee, until someone drives it with a real fish TTY.
            \\
            \\function __moon_boundary --description 'echoes "name_index\nis_global" (1-based, toks[1]=="moon") for the delegated command-name token, or nothing if this isn\'t an exec/orbit-exec/orbit-run line, or "--" has not been typed yet'
            \\    set -l toks (commandline -opc)
            \\    set -l n (count $toks)
            \\    set -l i
            \\
            \\    if test $n -ge 2 -a "$toks[2]" = exec
            \\        set i 3
            \\    else if test $n -ge 3 -a "$toks[2]" = orbit -a "$toks[3]" = exec
            \\        set i 4
            \\    else if test $n -ge 3 -a "$toks[2]" = orbit -a "$toks[3]" = run
            \\        set i 4
            \\    else
            \\        return 1
            \\    end
            \\
            \\    # '--' is now mandatory and single-purpose: the boundary is simply
            \\    # the first literal '--' after the recognized subcommand shape. No
            \\    # positional counting or --interpreter-consumes-two-tokens special
            \\    # case is needed any more -- that machinery only ever existed to
            \\    # avoid miscounting positions before an *implicit* boundary.
            \\    set -l is_global 0
            \\    set -l dashdash 0
            \\    set -l j $i
            \\    while test $j -le $n
            \\        if test "$toks[$j]" = --global
            \\            set is_global 1
            \\        end
            \\        if test "$toks[$j]" = --
            \\            set dashdash $j
            \\            break
            \\        end
            \\        set j (math $j + 1)
            \\    end
            \\
            \\    # No '--' typed yet: under the mandatory-'--' grammar there is no
            \\    # delegate command-name slot to complete yet -- fall through to
            \\    # moon's own normal flag/subcommand completion instead of guessing.
            \\    if test $dashdash -eq 0
            \\        return 1
            \\    end
            \\
            \\    echo (math $dashdash + 1)
            \\    echo $is_global
            \\    return 0
            \\end
            \\
            \\function __moon_env_path
            \\    set -l parts (__moon_boundary)
            \\    set -l global_flag
            \\    if test -n "$parts[2]" -a "$parts[2]" = 1
            \\        set global_flag --global
            \\    end
            \\    moon env --paths $global_flag 2>/dev/null
            \\end
            \\
            \\function __moon_env_bin_runtime_names
            \\    set -l parts (__moon_boundary)
            \\    set -l global_flag
            \\    if test -n "$parts[2]" -a "$parts[2]" = 1
            \\        set global_flag --global
            \\    end
            \\    moon env --bin-runtime-names $global_flag 2>/dev/null
            \\end
            \\
            \\function __moon_choosing_command --description 'true while the CURRENT token being typed is the delegate command-name slot itself'
            \\    set -l parts (__moon_boundary)
            \\    test -n "$parts[1]"; or return 1
            \\    set -l toks (commandline -opc)
            \\    test (count $toks) -eq (math $parts[1] - 1)
            \\end
            \\
            \\function __moon_past_command --description 'true once a delegate command name has been fully typed and we\'re completing ITS arguments'
            \\    set -l parts (__moon_boundary)
            \\    test -n "$parts[1]"; or return 1
            \\    set -l toks (commandline -opc)
            \\    test (count $toks) -ge $parts[1]
            \\end
            \\
            \\function __moon_delegate_complete --description 'ask fish for completions of the shifted line, as if the delegate had been typed directly'
            \\    set -l parts (__moon_boundary)
            \\    set -l boundary $parts[1]
            \\    set -l global_flag
            \\    if test -n "$parts[2]" -a "$parts[2]" = 1
            \\        set global_flag --global
            \\    end
            \\    set -l toks (commandline -opc)
            \\    set -l delegate $toks[$boundary]
            \\    set -lx PATH (__moon_env_path) $PATH
            \\
            \\    if test -z "$(complete -c $delegate)"
            \\        set -l delegate_path (moon provision resolve --json $global_flag -- $delegate 2>/dev/null | string match -r '"path":"([^"]*)"' -g)
            \\        if test -z "$delegate_path"
            \\            set delegate_path (command -v -- $delegate 2>/dev/null)
            \\        end
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
            \\# Completing the bare delegate command name (the token right after
            \\# '--'): merge the ambient-PATH-plus-moon-env completer with
            \\# bin-runtime-isolated tool names (which are never on PATH at all),
            \\# so `moon exec -- <tab>` finds both.
            \\complete -c moon -n __moon_choosing_command -x -a '(set -lx PATH (__moon_env_path) $PATH; __fish_complete_command; __moon_env_bin_runtime_names)'
            \\
            \\# Past the command name: delegate to fish's own completion for it,
            \\# verbatim, exactly like plain env/nice/time wrapping does.
            \\complete -c moon -n __moon_past_command -x -a '(__moon_delegate_complete)'
            \\
        , .{});
    }
};
