# This shell script aims to be written in a way where it can't really fail
# or all failure scenarios are handled, so that we never leave the shell in
# a weird state. If you find a way to break this, please report a bug!

function ghostty_restore_xdg_data_dir -d "restore the original XDG_DATA_DIR value"
    # If we don't have our own data dir then we don't need to do anything.
    if not set -q GHOSTTY_SHELL_INTEGRATION_XDG_DIR
        return
    end

    # If the data dir isn't set at all then we don't need to do anything.
    if not set -q XDG_DATA_DIRS
        return
    end

    # We need to do this so that XDG_DATA_DIRS turns into an array.
    set --function --path xdg_data_dirs "$XDG_DATA_DIRS"

    # If our data dir is in the list then remove it.
    if set --function index (contains --index "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" $xdg_data_dirs)
        set --erase --function xdg_data_dirs[$index]
    end

    # Re-export our data dir
    if set -q xdg_data_dirs[1]
        set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
    else
        set --erase --global XDG_DATA_DIRS
    end

    set --erase GHOSTTY_SHELL_INTEGRATION_XDG_DIR
end

function ghostty_exit -d "exit the shell integration setup"
    functions -e ghostty_restore_xdg_data_dir
    functions -e ghostty_exit
    exit 0
end

# We always try to restore the XDG data dir
ghostty_restore_xdg_data_dir

# If we aren't interactive or we've already run, don't run.
status --is-interactive || ghostty_exit

# We do the full setup on the first prompt render. We do this so that other
# shell integrations that setup the prompt and modify things are able to run
# first. We want to run _last_.
function __ghostty_setup --on-event fish_prompt -d "Setup ghostty integration"
    functions -e __ghostty_setup

    set --local features (string split , $GHOSTTY_SHELL_FEATURES)

    # Parse the fish version for feature detection.
    # Default to 0.0 if version is unavailable or malformed.
    set -l fish_major 0
    set -l fish_minor 0
    if set -q version[1]
        set -l fish_ver (string match -r '(\d+)\.(\d+)' -- $version[1])
        if set -q fish_ver[2]; and test -n "$fish_ver[2]"
            set fish_major "$fish_ver[2]"
        end
        if set -q fish_ver[3]; and test -n "$fish_ver[3]"
            set fish_minor "$fish_ver[3]"
        end
    end

    # Our OSC133A (prompt start) sequence. If we're using Fish >= 4.1
    # then it supports click_events so we enable that.
    set -g __ghostty_prompt_start_mark "\e]133;A\a"
    if test "$fish_major" -gt 4; or test "$fish_major" -eq 4 -a "$fish_minor" -ge 1
        set -g __ghostty_prompt_start_mark "\e]133;A;click_events=1\a"
    end

    if string match -q 'cursor*' -- $features
        set -l cursor 5                                   # blinking bar
        contains cursor:steady $features && set cursor 6  # steady bar

        # Change the cursor to a beam on prompt.
        function __ghostty_set_cursor_beam --on-event fish_prompt -V cursor -d "Set cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[$cursor q"
            end
        end
        function __ghostty_reset_cursor --on-event fish_preexec -d "Reset cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[0 q"
            end
        end
    end

    # Add Ghostty binary to PATH if the path feature is enabled
    if contains path $features; and test -n "$GHOSTTY_BIN_DIR"
        fish_add_path --global --path --append "$GHOSTTY_BIN_DIR"
    end

    # When using sudo shell integration feature, ensure $TERMINFO is set
    # and `sudo` is not already a function or alias
    if contains sudo $features; and test -n "$TERMINFO"; and test file = (type -t sudo 2> /dev/null; or echo "x")
        # Wrap `sudo` command to ensure Ghostty terminfo is preserved
        function sudo -d "Wrap sudo to preserve terminfo"
            set --function sudo_has_sudoedit_flags no
            for arg in $argv
                # Check if argument is '-e' or '--edit' (sudoedit flags)
                if string match -q -- -e "$arg"; or string match -q -- --edit "$arg"
                    set --function sudo_has_sudoedit_flags yes
                    break
                end
                # Check if argument is neither an option nor a key-value pair
                if not string match -r -q -- "^-" "$arg"; and not string match -r -q -- "=" "$arg"
                    break
                end
            end
            if test "$sudo_has_sudoedit_flags" = yes
                command sudo $argv
            else
                command sudo --preserve-env=TERMINFO $argv
            end
        end
    end

    # SSH Integration
    set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
    if contains ssh-env $features; or contains ssh-terminfo $features
        function ssh --wraps=ssh --description "SSH wrapper with Ghostty integration"
            set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
            set -l ssh_term xterm-256color
            set -l ssh_opts

            # Configure environment variables for remote session
            if contains ssh-env $features
                set -a ssh_opts -o "SetEnv COLORTERM=truecolor"
                set -a ssh_opts -o "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"
            end

            # Install terminfo on remote host if needed
            if contains ssh-terminfo $features
                set -l ssh_user
                set -l ssh_hostname

                for line in (command ssh -G $argv 2>/dev/null)
                    set -l parts (string split ' ' -- $line)
                    if test (count $parts) -ge 2
                        switch $parts[1]
                            case user
                                set ssh_user $parts[2]
                            case hostname
                                set ssh_hostname $parts[2]
                        end
                        if test -n "$ssh_user"; and test -n "$ssh_hostname"
                            break
                        end
                    end
                end

                if test -n "$ssh_hostname"
                    set -l ssh_target "$ssh_user@$ssh_hostname"

                    # Check if terminfo is already cached
                    if test -x "$GHOSTTY_BIN_DIR/ghostty"; and "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --host="$ssh_target" >/dev/null 2>&1
                        set ssh_term xterm-ghostty
                    else if command -q infocmp
                        set -l ssh_terminfo
                        set -l ssh_cpath_dir
                        set -l ssh_cpath

                        set ssh_terminfo "$(infocmp -0 -x xterm-ghostty 2>/dev/null)"

                        if test -n "$ssh_terminfo"
                            echo "Setting up xterm-ghostty terminfo on $ssh_hostname..." >&2

                            set ssh_cpath_dir (mktemp -d "/tmp/ghostty-ssh-$ssh_user.XXXXXX" 2>/dev/null; or echo "/tmp/ghostty-ssh-$ssh_user."(random))
                            set ssh_cpath "$ssh_cpath_dir/socket"

                            if echo "$ssh_terminfo" | command ssh $ssh_opts -o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s $argv '
                                infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                                command -v tic >/dev/null 2>&1 || exit 1
                                mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
                                exit 1
                            ' 2>/dev/null
                                set ssh_term xterm-ghostty
                                set -a ssh_opts -o "ControlPath=$ssh_cpath"

                                # Cache successful installation
                                if test -x "$GHOSTTY_BIN_DIR/ghostty"
                                    "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --add="$ssh_target" >/dev/null 2>&1; or true
                                end
                            else
                                echo "Warning: Failed to install terminfo." >&2
                            end
                        else
                            echo "Warning: Could not generate terminfo data." >&2
                        end
                    else
                        echo "Warning: ghostty command not available for cache management." >&2
                    end
                end
            end

            # Execute SSH with TERM environment variable
            TERM="$ssh_term" command ssh $ssh_opts $argv
        end
    end

    # Setup prompt marking
    function __ghostty_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        # If we never got the output end event, then we need to send it now.
        if test "$__ghostty_prompt_state" != prompt-start
            echo -en "\e]133;D\a"
        end

        set --global __ghostty_prompt_state prompt-start
        echo -en $__ghostty_prompt_start_mark
    end

    # Wortel: true if the command line launches a long-lived interactive program
    # (agent CLI, editor, pager, REPL, system monitor, TUI) that sits at its own
    # prompt instead of returning to the shell. For those the synthetic busy
    # spinner (OSC 9;4;3 below) would never clear until you quit — no OSC 133;D
    # fires — so we skip it. Builds and tests still spin.
    function __ghostty_wortel_interactive
        set --local words (string split --no-empty ' ' -- $argv[1])
        set --local n (count $words)
        set --local i 1
        set --local cmd ''
        # Skip leading env assignments (FOO=bar) and command wrappers.
        while test $i -le $n
            set --local w $words[$i]
            switch $w
                case '*=*'
                    set i (math $i + 1)
                case sudo doas command builtin exec nohup nice stdbuf setsid env
                    set i (math $i + 1)
                case '-*'
                    set i (math $i + 1)
                case '*'
                    set cmd $w
                    break
            end
        end
        test -z "$cmd"; and return 1
        set cmd (string replace --regex '^.*/' '' -- $cmd)
        switch $cmd
            case claude pi aider codex cursor-agent gemini opencode goose cline ollama llm crush amp
                return 0
            case vi vim nvim vis nano emacs emacsclient helix hx kak micro ne joe
                return 0
            case less more most moar man bat w3m lynx
                return 0
            case top htop btop btm glances gtop nvtop s-tui
                return 0
            case ssh mosh telnet tmux screen zellij dtach abduco
                return 0
            case watch journalctl dmesg
                return 0
            case fzf sk gitui lazygit lazydocker k9s tig ranger nnn yazi lf vifm mc broot xplr
                return 0
            case gdb lldb pdb
                return 0
            case psql mysql mariadb sqlite3 litecli pgcli mycli redis-cli mongosh mongo usql duckdb clickhouse-client cqlsh
                return 0
            case python python2 python3 ipython bpython ptpython node nodejs bun deno irb pry php lua luajit julia R ghci iex erl scala clj clojure
                # Dual-use: a bare REPL is interactive, but `python script.py`,
                # `python -m mod` and `-c ...` are batch jobs that keep the
                # spinner. Interactive only with no such argument.
                set --local j (math $i + 1)
                while test $j -le $n
                    set --local a $words[$j]
                    switch $a
                        case -i -q -u -B -E -O -OO -s -S -I --
                            set j (math $j + 1)
                        case -c -m
                            return 1
                        case '*<*' '*>*' '*|*' '*&*' '*;*'
                            return 0
                        case '-*'
                            set j (math $j + 1)
                        case '*'
                            return 1
                    end
                end
                return 0
        end
        return 1
    end

    # Wortel: directory shared with the app (AgentResumeStore) for agent markers.
    # Global, not local: the event-driven functions below read it at run time,
    # long after this one-shot setup function's locals are gone.
    set --global _ghostty_wortel_agent_dir "$HOME/Library/Application Support/Wortel/agents"

    # Wortel: echo the agent-CLI basename if the command line launches one (the
    # resumable subset), else nothing. Same launcher/env-assignment skipping as
    # __ghostty_wortel_interactive. Recorded per session so a relaunch can resume it.
    function __ghostty_wortel_agent
        set --local words (string split --no-empty ' ' -- $argv[1])
        set --local n (count $words)
        set --local i 1
        set --local cmd ''
        while test $i -le $n
            set --local w $words[$i]
            switch $w
                case '*=*'
                    set i (math $i + 1)
                case sudo doas command builtin exec nohup nice stdbuf setsid env
                    set i (math $i + 1)
                case '-*'
                    set i (math $i + 1)
                case '*'
                    set cmd $w
                    break
            end
        end
        test -z "$cmd"; and return
        set cmd (string replace --regex '^.*/' '' -- $cmd)
        switch $cmd
            case claude pi aider codex cursor-agent gemini opencode goose cline ollama llm crush amp
                echo -n $cmd
        end
    end

    # Wortel: echo the model the command line selects (--model/-m/--models value),
    # else nothing. Best-effort, for the sidebar badge; only consulted for commands
    # __ghostty_wortel_agent already matched.
    function __ghostty_wortel_model
        set --local words (string split --no-empty ' ' -- $argv[1])
        set --local n (count $words)
        set --local i 1
        set --local val ''
        while test $i -le $n
            set --local w $words[$i]
            switch $w
                case '--model=*' '--models=*' '-m=*'
                    set val (string replace --regex '^[^=]*=' '' -- $w)
                    break
                case --model --models -m
                    set --local j (math $i + 1)
                    test $j -le $n; and set val $words[$j]
                    break
            end
            set i (math $i + 1)
        end
        test -n "$val"; and echo -n (string replace --all --regex "[\"']" '' -- $val)
    end

    # Wortel: clear this session's agent marker at every prompt, so a marker only
    # survives while an agent is actually running — which is precisely when no
    # prompt fires. See __ghostty_wortel_agent.
    function __ghostty_wortel_clear_agent --on-event fish_prompt
        test -n "$WORTEL_SESSION_ID"; and command rm -f $_ghostty_wortel_agent_dir/$WORTEL_SESSION_ID 2>/dev/null
    end

    function __ghostty_mark_output_start --on-event fish_preexec
        set --global __ghostty_prompt_state pre-exec
        echo -en "\e]133;C\a"
        # Wortel: mark the session busy for the sidebar spinner (ConEmu OSC
        # 9;4;3, "indeterminate progress"). Clears at the next prompt (133;D) —
        # but long-lived interactive programs never return to the prompt, so
        # skip it for those (see __ghostty_wortel_interactive).
        if not __ghostty_wortel_interactive $argv[1]
            echo -en "\e]9;4;3;\a"
        end
        # Wortel: record a launched agent CLI so a relaunch can resume it. key=value
        # marker keyed by the surface's session id; cleared at the next prompt. A
        # marker that outlives the app means the agent was still running at quit.
        if test -n "$WORTEL_SESSION_ID"
            set --local _wortel_agent (__ghostty_wortel_agent $argv[1])
            if test -n "$_wortel_agent"
                command mkdir -p $_ghostty_wortel_agent_dir 2>/dev/null
                begin
                    echo "agent=$_wortel_agent"
                    echo "model="(__ghostty_wortel_model $argv[1])
                    echo "cwd=$PWD"
                    echo "argv="(string join ' ' (string split \n -- $argv[1]))
                    # The shell's own pid — see the zsh integration: it lets the
                    # app verify from the process table that the agent is really
                    # still running.
                    echo "shellpid=$fish_pid"
                    # When the agent started — see the zsh integration.
                    echo "startedat="(command date +%s)
                end >$_ghostty_wortel_agent_dir/$WORTEL_SESSION_ID 2>/dev/null
            end
        end
    end

    function __ghostty_mark_output_end --on-event fish_postexec
        set --global __ghostty_prompt_state post-exec
        echo -en "\e]133;D;$status\a"
    end

    # Report pwd. This is actually built-in to fish but only for terminals
    # that match an allowlist and that isn't us.
    function __update_cwd_osc --on-variable PWD -d 'Notify capable terminals when $PWD changes'
        if status --is-command-substitution || set -q INSIDE_EMACS
            return
        end
        # Wortel: "localhost", not $hostname — see the zsh integration's
        # _ghostty_report_pwd. Same exposure: a cleared $hostname emits a
        # hostless URI that libghostty drops, and a captured one goes stale
        # when the machine is renamed mid-session.
        printf \e\]7\;file://localhost%s\a (string escape --style=url $PWD)
    end

    # Enable fish to handle reflow because Ghostty clears the prompt on resize.
    set --global fish_handle_reflow 1

    # Initial calls for first prompt
    if string match -q 'cursor*' -- $features
        __ghostty_set_cursor_beam
    end
    __ghostty_mark_prompt_start
    __update_cwd_osc
end

ghostty_exit
